// 文件说明：书籍书签管理页，对标 Legado BookmarkFragment —— 按书展示该书全部书签，
// 支持编辑备注、删除与跳转阅读；书架长按菜单「书签」入口进入。
// 技术要点：SQLite 书签 DAO、章节分组展示、备注编辑对话框、时间格式化。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/bookmark.dart';
import '../../services/books/bookmark_dao.dart';
import '../../utils/localization_extension.dart';
import '../../utils/reader_themes.dart';
import '../../widgets/side_toast.dart';

/// 书签管理页返回结果：用户是否点击了某个书签想要跳转阅读。
class BookmarkManagerResult {
  const BookmarkManagerResult({
    required this.bookmarkId,
    required this.chapterIndex,
    this.chapterTitle,
  });

  final int bookmarkId;
  final int chapterIndex;
  final String? chapterTitle;
}

/// 按书籍展示与管理的独立书签页。
class BookmarkManagerPage extends StatefulWidget {
  const BookmarkManagerPage({
    super.key,
    required this.book,
    this.initialTheme,
  });

  final Book book;
  final ReaderThemePalette? initialTheme;

  @override
  State<BookmarkManagerPage> createState() => _BookmarkManagerPageState();
}

class _BookmarkManagerPageState extends State<BookmarkManagerPage> {
  final BookmarkDao _bookmarkDao = BookmarkDao();
  List<Bookmark> _bookmarks = const [];
  bool _loading = true;
  late ReaderThemePalette _palette;

  @override
  void initState() {
    super.initState();
    _palette = ReaderThemes.day;
    _loadPalette();
    _loadBookmarks();
  }

  Future<void> _loadPalette() async {
    final palette = widget.initialTheme ?? await ReaderThemes.loadSavedPalette();
    if (!mounted) return;
    setState(() => _palette = palette);
  }

  Future<void> _loadBookmarks() async {
    final bookId = widget.book.id;
    if (bookId == null) {
      setState(() => _loading = false);
      return;
    }
    final bookmarks = await _bookmarkDao.getBookmarksForBook(bookId);
    if (!mounted) return;
    setState(() {
      _bookmarks = bookmarks.toList(growable: false);
      _loading = false;
    });
  }

  Future<void> _editNote(Bookmark bookmark) async {
    final id = bookmark.id;
    if (id == null) return;
    final editorKey = GlobalKey<_BookmarkNoteEditorState>();
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.bookmarkEditNoteTitle),
        content: _BookmarkNoteEditor(
          key: editorKey,
          initialNote: bookmark.note,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(editorKey.currentState?.text ?? ''),
            child: Text(
              MaterialLocalizations.of(dialogContext).saveButtonLabel,
            ),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await _bookmarkDao.updateBookmarkNote(id, saved.trim());
    if (!mounted) return;
    setState(() {
      _bookmarks = [
        for (final item in _bookmarks)
          if (item.id == id) item.copyWith(note: saved.trim()) else item,
      ];
    });
  }

  Future<void> _delete(Bookmark bookmark) async {
    final id = bookmark.id;
    if (id == null) return;
    await _bookmarkDao.deleteBookmark(id);
    if (!mounted) return;
    setState(() {
      _bookmarks = _bookmarks
          .where((candidate) => candidate.id != id)
          .toList(growable: false);
    });
    showSideToast(
      context,
      context.l10n.bookmarkRemoved,
      duration: const Duration(milliseconds: 1600),
      icon: Icons.bookmark_remove_rounded,
      kind: SideToastKind.success,
    );
  }

  void _open(Bookmark bookmark) {
    final chapterIndex = bookmark.chapterIndex ?? bookmark.pageNumber;
    final result = BookmarkManagerResult(
      bookmarkId: bookmark.id ?? 0,
      chapterIndex: chapterIndex,
      chapterTitle: bookmark.chapterTitle,
    );
    Navigator.of(context).pop(result);
  }

  String _dateText(DateTime date) {
    final now = DateTime.now();
    final sameDay =
        date.year == now.year && date.month == now.month && date.day == now.day;
    if (sameDay) {
      final hour = date.hour.toString().padLeft(2, '0');
      final minute = date.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _chapterLabel(Bookmark bookmark) {
    final title = bookmark.chapterTitle?.trim();
    if (title != null && title.isNotEmpty) return title;
    final number = (bookmark.chapterIndex ?? bookmark.pageNumber).clamp(
      0,
      1000000,
    ) + 1;
    return context.l10n.readerChapterFallback(number);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = _palette.background;
    final text = _palette.text;
    final secondary = _palette.secondaryText;

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.bookmarkManagerTitle,
              style: TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Text(
              widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: secondary, fontSize: 12),
            ),
          ],
        ),
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: _palette.accent),
            )
          : _bookmarks.isEmpty
          ? _emptyState(scheme, secondary)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: _bookmarks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final bookmark = _bookmarks[index];
                return _buildTile(context, bookmark, scheme, text, secondary);
              },
            ),
    );
  }

  Widget _emptyState(ColorScheme scheme, Color secondary) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_border_rounded,
              size: 52,
              color: secondary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.readerNoBookmarks,
              style: TextStyle(color: secondary, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              context.l10n.readerNoBookmarksHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondary.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    Bookmark bookmark,
    ColorScheme scheme,
    Color text,
    Color secondary,
  ) {
    final excerpt = bookmark.excerpt?.trim() ?? '';
    final note = bookmark.note.trim();
    final displayNote = note.isNotEmpty ? note : null;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey('bookmark-manager-${bookmark.id}'),
        onTap: () => _open(bookmark),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 8, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bookmark_rounded,
                          size: 17,
                          color: _palette.accent,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _chapterLabel(bookmark),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: text,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (excerpt.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        excerpt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: secondary, fontSize: 13, height: 1.4),
                      ),
                    ],
                    if (displayNote != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        displayNote,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _palette.accent.withValues(alpha: 0.92),
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                    const SizedBox(height: 7),
                    Text(
                      _dateText(bookmark.createDate),
                      style: TextStyle(color: secondary.withValues(alpha: 0.8), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    unawaited(_editNote(bookmark));
                  } else if (value == 'delete') {
                    unawaited(_delete(bookmark));
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(context.l10n.edit),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      MaterialLocalizations.of(context).deleteButtonTooltip,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书签备注编辑输入框（自持 controller，随对话框销毁而释放，
/// 避免弹窗退场动画期间 TextField 访问已 dispose 的 controller）。
class _BookmarkNoteEditor extends StatefulWidget {
  const _BookmarkNoteEditor({super.key, required this.initialNote});

  final String initialNote;

  @override
  State<_BookmarkNoteEditor> createState() => _BookmarkNoteEditorState();
}

class _BookmarkNoteEditorState extends State<_BookmarkNoteEditor> {
  late final TextEditingController _controller;

  String get text => _controller.text;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNote);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('bookmark-manager-note-editor'),
      controller: _controller,
      autofocus: true,
      maxLines: 4,
      minLines: 2,
      decoration: InputDecoration(
        hintText: context.l10n.bookmarkEditNoteHint,
        border: const OutlineInputBorder(),
      ),
    );
  }
}