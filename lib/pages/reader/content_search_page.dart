// 文件说明：正文搜索页（对标 Legado SearchContentActivity）。
// 技术要点：
// - 顶部搜索框 + 正则/净化开关，Debounce 自动触发，可手动回车；
// - 逐章增量上屏：进度条 + 已扫描 n/N 章，命中列表实时刷新；
// - 命中行展示「章名 + 片段」，关键词高亮；点击回跳阅读器对应章节；
// - 搜索任务通过序号作废旧请求（防竞态）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_content_search_service.dart';
import '../../book_sources/services/book_source_client.dart';
import '../../book_sources/services/replace_rule_service.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/localization_extension.dart';

class ContentSearchPage extends StatefulWidget {
  const ContentSearchPage({
    super.key,
    required this.source,
    required this.bookId,
    required this.chapters,
    required this.onOpenChapter,
    this.client,
    this.searchService,
  });

  final RegisteredBookSource source;
  final String bookId;
  final List<BookSourceChapter> chapters;
  final void Function(int chapterIndex) onOpenChapter;
  final BookSourceClient? client;
  final BookSourceContentSearchService? searchService;

  @override
  State<ContentSearchPage> createState() => _ContentSearchPageState();
}

class _ContentSearchPageState extends State<ContentSearchPage> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  Timer? _debounce;

  bool _regex = false;
  bool _purify = true;
  bool _searching = false;
  int _requestSeq = 0;
  int _scanned = 0;
  int _total = 0;
  List<ContentSearchMatch> _matches = const [];
  List<ReplaceRule> _rules = const [];

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final service = ReplaceRuleService.instance;
    await service.ensureLoaded();
    final rules = service.rules;
    if (!mounted) return;
    setState(() => _rules = rules);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _scheduleSearch({Duration delay = const Duration(milliseconds: 350)}) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(_runSearch()));
  }

  Future<void> _runSearch() async {
    final query = _queryController.text.trim();
    final seq = ++_requestSeq;
    setState(() {
      _searching = query.isNotEmpty;
      _scanned = 0;
      _total = widget.chapters.length;
      _matches = const [];
    });
    if (query.isEmpty || widget.chapters.isEmpty) return;

    final service = widget.searchService ?? const BookSourceContentSearchService();
    await service.searchBook(
      source: widget.source,
      bookId: widget.bookId,
      chapters: widget.chapters,
      query: query,
      regex: _regex,
      useReplace: _purify,
      replaceRules: _purify ? _rules : const [],
      client: widget.client,
      concurrent: 3,
      onProgress: (progress) {
        if (seq != _requestSeq || !mounted) return;
        setState(() {
          _scanned = progress.scannedChapters;
          _total = progress.totalChapters;
          _matches = progress.matches;
        });
      },
      isCancelled: () => seq != _requestSeq,
    );
    if (seq != _requestSeq || !mounted) return;
    setState(() => _searching = false);
  }

  void _toggleOptions() {
    _debounce?.cancel();
    unawaited(_runSearch());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.contentSearchTitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('content-search-field'),
                  controller: _queryController,
                  focusNode: _queryFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_runSearch()),
                  onChanged: (_) => _scheduleSearch(),
                  decoration: InputDecoration(
                    hintText: l10n.contentSearchHint,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _queryController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.contentSearchClear,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _queryController.clear();
                              unawaited(_runSearch());
                            },
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _switchChip(
                        key: const ValueKey('content-search-regex'),
                        label: l10n.contentSearchRegex,
                        value: _regex,
                        onChanged: (value) => setState(() {
                          _regex = value;
                          _toggleOptions();
                        }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _switchChip(
                        key: const ValueKey('content-search-purify'),
                        label: l10n.contentSearchPurify,
                        value: _purify,
                        onChanged: (value) => setState(() {
                          _purify = value;
                          _toggleOptions();
                        }),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: _searching || _matches.isNotEmpty || _scanned > 0
          ? Column(
              children: [
                if (_searching || _scanned > 0) ...[
                  LinearProgressIndicator(
                    value: _total == 0 ? null : _scanned / _total,
                    minHeight: 2,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          l10n.contentSearchProgressLabel(_scanned, _total),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          l10n.contentSearchHitCount(_matches.length),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Expanded(
                  child: _matches.isEmpty
                      ? _searching
                            ? const Center(
                                child: CircularProgressIndicator(),
                              )
                            : _emptyResult(l10n)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                          itemCount: _matches.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (context, index) =>
                              _resultTile(l10n, _matches[index]),
                        ),
                ),
              ],
            )
          : _idleHint(l10n),
    );
  }

  Widget _switchChip({
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return FilterChip(
      key: key,
      label: Text(label),
      selected: value,
      showCheckmark: false,
      onSelected: onChanged,
    );
  }

  Widget _idleHint(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 52,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.contentSearchIdleHint,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _emptyResult(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 52,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(l10n.contentSearchEmpty, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            l10n.contentSearchEmptyHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultTile(AppLocalizations l10n, ContentSearchMatch match) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('content-search-hit-${match.chapterIndex}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          widget.onOpenChapter(match.chapterIndex);
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.notes_rounded, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      match.chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text.rich(
                _highlightedSnippet(
                  match.snippet,
                  match.queryIndexInSnippet,
                  match.isRegex,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 关键词高亮：正则命中在片段内重新匹配定位。
  TextSpan _highlightedSnippet(String snippet, int start, bool isRegex) {
    final scheme = Theme.of(context).colorScheme;
    int end;
    if (isRegex) {
      final pattern = _queryController.text.trim();
      try {
        final match = RegExp(pattern).firstMatch(snippet);
        if (match != null) {
          start = match.start;
          end = match.end;
        } else {
          end = start + pattern.length;
        }
      } on FormatException {
        end = start;
      }
    } else {
      end = (start + _queryController.text.trim().length).clamp(0, snippet.length);
    }
    start = start.clamp(0, snippet.length);
    if (end > snippet.length) end = snippet.length;
    if (start >= end) return TextSpan(text: snippet);
    return TextSpan(
      children: [
        TextSpan(text: snippet.substring(0, start)),
        TextSpan(
          text: snippet.substring(start, end),
          style: TextStyle(
            backgroundColor: scheme.primary.withValues(alpha: 0.22),
            color: scheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: snippet.substring(end)),
      ],
    );
  }
}