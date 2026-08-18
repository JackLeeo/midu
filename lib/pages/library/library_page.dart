// 文件说明：书库页面，负责书籍列表、筛选、排序和进入阅读。
// 技术要点：Flutter UI、文件系统、渲染层。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:midu/book_sources/services/book_source_shelf_service.dart';
import 'package:midu/core/reader/native_reader_service.dart';
import 'package:midu/models/book.dart';
import 'package:midu/pages/home/home_mobile_chrome.dart';
import 'package:midu/pages/home/home_shell_page.dart';
import 'package:midu/pages/reader/book_source_reader_page.dart';
import 'package:midu/pages/settings/sync/book_file_sync_page.dart';
import 'package:midu/services/books/book_services.dart';
import 'package:midu/services/core/app_settings_service.dart';
import 'package:midu/services/library/library_services.dart';
import 'package:midu/services/library/download_task_controller.dart';
import 'package:midu/services/sync/webdav_sync_controller.dart';
import 'package:midu/utils/book_open_transition.dart';
import 'package:midu/utils/glass_config.dart';
import 'package:midu/utils/layout_helper.dart';
import 'package:midu/utils/localization_extension.dart';
import 'package:midu/utils/page_transitions.dart';
import 'package:midu/utils/page_style_helper.dart';
import 'package:midu/utils/reader_themes.dart';
import 'package:midu/utils/system_ui_helper.dart';
import 'package:midu/utils/ui_style.dart';
import 'package:midu/widgets/generated_book_cover.dart';
import 'package:midu/widgets/scrolling_text.dart';
import 'package:midu/widgets/side_toast.dart';
import 'package:midu/widgets/source_cover_image.dart';

import 'import_book/import_book_page.dart';
import 'download_tasks_page.dart';
import 'library_selection_model.dart';

enum _LibraryFilter { all, reading, finished }

/// 首页壳层顶栏与书库页之间的桥：顶栏按钮触发搜索/筛选，
/// 书库页把筛选是否生效同步回来点亮按钮。
class LibraryPageController {
  _LibraryPageState? _state;

  /// 当前是否有生效的筛选（非“全部”）。顶栏据此点亮筛选按钮。
  final ValueNotifier<bool> filterActive = ValueNotifier<bool>(false);
  final ValueNotifier<LibrarySelectionSnapshot> selection =
      ValueNotifier<LibrarySelectionSnapshot>(
        const LibrarySelectionSnapshot.inactive(),
      );

  void toggleSearch() => _state?._toggleSearchBar();

  Future<void> showFilterMenu(Rect anchor) async =>
      _state?._showFilterMenu(anchor);

  void exitSelection() => _state?._exitSelectionMode();

  void selectAllVisible() => _state?._selectAllVisibleBooks();

  Future<void> deleteSelected() async => _state?._confirmDeleteSelectedBooks();

  void dispose() {
    filterActive.dispose();
    selection.dispose();
  }
}

class LibrarySelectionSnapshot {
  final bool isActive;
  final int selectedCount;

  const LibrarySelectionSnapshot({
    required this.isActive,
    required this.selectedCount,
  });

  const LibrarySelectionSnapshot.inactive()
    : isActive = false,
      selectedCount = 0;

  @override
  bool operator ==(Object other) =>
      other is LibrarySelectionSnapshot &&
      other.isActive == isActive &&
      other.selectedCount == selectedCount;

  @override
  int get hashCode => Object.hash(isActive, selectedCount);
}

class LibraryPage extends StatefulWidget {
  final LibraryPageController? controller;

  const LibraryPage({super.key, this.controller});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Book> _books = [];
  bool _isInitialLoading = true;
  final _bookDao = BookDao();
  final _sourceShelfService = BookSourceShelfService();
  StreamSubscription<void>? _librarySubscription;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  String _searchQuery = '';
  bool _searchBarVisible = false;
  _LibraryFilter _selectedFilter = _LibraryFilter.all;
  final LibrarySelectionModel _selection = LibrarySelectionModel();
  final Set<String> _exportingBookPaths = <String>{};

  /// 经典封面展开需要在点击和返回时定位书库里的原封面。
  final Map<int, GlobalKey> _coverKeys = <int, GlobalKey>{};

  GlobalKey _coverKeyFor(Book book) =>
      _coverKeys.putIfAbsent(book.id!, () => GlobalKey());

  bool get _isMaterial3Style {
    return Theme.of(
          context,
        ).extension<UiStyleThemeExtension>()?.isMaterial3Style ??
        false;
  }

  Future<void> _openBook(
    Book book, {
    required LibraryBookOpenAnimation libraryAnimation,
    BookOpenAnimation? animation,
  }) async {
    final openingActivity = BookOpenTransition.beginActivity();
    try {
      final fullBook = await _bookDao.getBookById(book.id!);
      if (fullBook == null || !mounted) return;
      if (fullBook.isOnline) {
        try {
          final initialTheme = await ReaderThemes.loadSavedPalette();
          if (!mounted) return;
          final source = _sourceShelfService.sourceFrom(fullBook);
          final sourceBook = _sourceShelfService.sourceBookFrom(fullBook);
          final route = BookOpenTransition.createRoute<void>(
            BookSourceReaderPage(
              source: source,
              book: sourceBook,
              shelfService: _sourceShelfService,
              initialTheme: initialTheme,
            ),
            animation: animation,
            libraryAnimation: animation == null ? libraryAnimation : null,
            readerBackgroundColor: initialTheme.background,
            waitForReaderReady: animation != null,
          );
          await BookOpenTransition.push<void>(context, route);
        } catch (error) {
          if (mounted) {
            showSideToast(
              context,
              context.l10n.bookSourceOnlineDataBroken('$error'),
              kind: SideToastKind.error,
            );
          }
        }
      } else {
        await NativeReaderService.openBook(
          context,
          fullBook,
          animation: animation,
          libraryAnimation: animation == null ? libraryAnimation : null,
        );
      }
      if (mounted) _loadBooks();
    } finally {
      openingActivity.dispose();
    }
  }

  Future<void> _openBookFromCover(
    Book book, {
    required GlobalKey coverKey,
    required BorderRadius radius,
    required WidgetBuilder coverBuilder,
  }) {
    final selected = context
        .read<AppSettingsNotifier>()
        .libraryBookOpenAnimation;
    final animation = selected == LibraryBookOpenAnimation.classicCover
        ? BookOpenAnimation.fromCoverKey(
            coverKey,
            radius: radius,
            coverBuilder: coverBuilder,
          )
        : null;
    return _openBook(book, libraryAnimation: selected, animation: animation);
  }

  BoxDecoration _panelDecoration({
    double radius = 16,
    bool stronger = false,
    bool addShadow = false,
    double borderAlpha = 0.12,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = PageStyleHelper.palette(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMaterial3Style = _isMaterial3Style;
    return BoxDecoration(
      color:
          color ??
          (isMaterial3Style
              ? (stronger
                    ? scheme.surfaceContainer
                    : scheme.surfaceContainerLow)
              : (stronger ? palette.cardStrong : palette.card)),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: scheme.outline.withValues(
          alpha: isMaterial3Style ? 0.22 : borderAlpha,
        ),
        width: 0.9,
      ),
      boxShadow: addShadow
          ? [
              BoxShadow(
                color: scheme.shadow.withValues(
                  alpha: isMaterial3Style
                      ? (isDark ? 0.16 : 0.07)
                      : (isDark ? 0.24 : 0.09),
                ),
                blurRadius: isMaterial3Style ? 12 : 16,
                offset: Offset(0, isMaterial3Style ? 6 : 8),
              ),
            ]
          : null,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _loadBooks();
    _librarySubscription = LibraryEventBus().stream.listen((_) {
      if (mounted) {
        _loadBooks();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setupThemeBasedImmersiveMode();
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) {
      widget.controller?._state = null;
    }
    _librarySubscription?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearchBar() {
    setState(() {
      _searchBarVisible = !_searchBarVisible;
      if (_searchBarVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      } else {
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  Future<void> _showFilterMenu(Rect anchor) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final selected = await showMenu<_LibraryFilter>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      initialValue: _selectedFilter,
      items: [
        _buildFilterMenuItem(
          _LibraryFilter.all,
          context.l10n.libraryFilterAll(_books.length),
        ),
        _buildFilterMenuItem(
          _LibraryFilter.reading,
          context.l10n.libraryFilterReading(
            _books.where(_isReadingBook).length,
          ),
        ),
        _buildFilterMenuItem(
          _LibraryFilter.finished,
          context.l10n.libraryFilterFinished(
            _books.where(_isFinishedBook).length,
          ),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    setState(() => _selectedFilter = selected);
    _syncFilterActive();
  }

  PopupMenuItem<_LibraryFilter> _buildFilterMenuItem(
    _LibraryFilter filter,
    String label,
  ) {
    final selected = _selectedFilter == filter;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_LibraryFilter>(
      value: filter,
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 18,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  void _syncFilterActive() {
    widget.controller?.filterActive.value =
        _selectedFilter != _LibraryFilter.all;
  }

  void _syncSelection() {
    widget.controller?.selection.value = LibrarySelectionSnapshot(
      isActive: _selection.isActive,
      selectedCount: _selection.selectedIds.length,
    );
  }

  void _enterSelectionMode(Book book) {
    final id = book.id;
    if (id == null) return;
    setState(() => _selection.enter(id));
    _syncSelection();
  }

  void _toggleBookSelection(Book book) {
    final id = book.id;
    if (id == null) return;
    setState(() => _selection.toggle(id));
    _syncSelection();
  }

  void _selectAllVisibleBooks() {
    final visibleIds = _visibleBooks.map((book) => book.id).nonNulls;
    setState(() => _selection.selectAllVisible(visibleIds));
    _syncSelection();
  }

  void _exitSelectionMode() {
    if (!_selection.isActive) return;
    setState(_selection.exit);
    _syncSelection();
  }

  bool _isBookSelected(Book book) {
    final id = book.id;
    return id != null && _selection.selectedIds.contains(id);
  }

  Future<void> _handleBookTap(
    Book book, {
    required Future<void> Function() openBook,
  }) async {
    if (_selection.isActive) {
      _toggleBookSelection(book);
      return;
    }
    await openBook();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (_searchQuery == value) return;
      setState(() => _searchQuery = value);
    });
  }

  bool _shouldApplySystemUI() {
    final route = ModalRoute.of(context);
    return route?.isCurrent ?? true;
  }

  void _setupThemeBasedImmersiveMode() {
    if (!_shouldApplySystemUI()) {
      return;
    }
    final overlayStyle = SystemUiHelper.overlayStyleForBrightness(
      Theme.of(context).brightness,
    );
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);
  }

  Future<void> _loadBooks() async {
    try {
      final books = await _bookDao.getAllBooks();
      if (mounted) {
        setState(() {
          _books = books;
          _selection.retainOnly(books.map((book) => book.id).nonNulls.toSet());
          _isInitialLoading = false;
        });
        _syncSelection();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isInitialLoading = false);
      }
      // Handle error
    }
  }

  @override
  Widget build(BuildContext context) {
    // 检查是否在侧边导航栏模式下
    final navContext = NavigationContext.of(context);
    final useRailNavigation = navContext?.useRailNavigation ?? false;
    final scheme = Theme.of(context).colorScheme;
    final appBarColor = _isMaterial3Style ? scheme.surface : Colors.transparent;

    // 在侧边导航栏模式下，不显示 Scaffold 和 AppBar
    if (useRailNavigation) {
      return Stack(
        children: [
          _buildContent(context, useRailNavigation: useRailNavigation),
          if (_selection.isActive) _buildRailSelectionBottomBar(),
        ],
      );
    }

    // 手机模式：显示完整的 Scaffold + AppBar
    return PopScope(
      canPop: !_selection.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.isActive) _exitSelectionMode();
      },
      child: Scaffold(
        extendBody: true, // 让内容延伸到导航区，配合手势小白条
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: appBarColor,
          elevation: 0,
          toolbarHeight: 0,
          surfaceTintColor: appBarColor,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiHelper.overlayStyleForBrightness(
            Theme.of(context).brightness,
          ),
        ),
        body: _buildContent(context, useRailNavigation: useRailNavigation),
        // 手机端改为顶部“+”按钮入口，宽屏继续保留FAB
        floatingActionButton:
            LayoutHelper.getNavigationType(context) == NavigationType.rail
            ? _buildFloatingActionButton()
            : null,
      ),
    );
  }

  // 提取页面内容部分，在两种模式下共用
  Widget _buildContent(
    BuildContext context, {
    required bool useRailNavigation,
  }) {
    final books = _visibleBooks;
    final libraryLayoutMode = context
        .select<AppSettingsNotifier, LibraryLayoutMode>(
          (settings) => settings.libraryLayoutMode,
        );
    final libraryGridColumns = context.select<AppSettingsNotifier, int>(
      (settings) => settings.libraryGridColumns,
    );
    final libraryGridShowDetails = context.select<AppSettingsNotifier, bool>(
      (settings) => settings.libraryGridShowDetails,
    );
    final palette = PageStyleHelper.palette(context);
    final mobileChrome = HomeMobileChromeScope.of(context);
    // 手机模式：内容从屏幕顶端开始、滚动时穿过毛玻璃顶栏，
    // 顶栏的模糊层才有真实内容可以取样；用内边距避开首屏遮挡。
    final mobileTopInset = mobileChrome.pageTopPadding;
    final listTopPadding = useRailNavigation
        ? 8.0
        : (_searchBarVisible ? 10.0 : mobileTopInset);
    final content = Column(
      children: [
        if (useRailNavigation) ...[_buildTopBar(), const SizedBox(height: 10)],
        if (_searchBarVisible) ...[
          if (!useRailNavigation) SizedBox(height: mobileTopInset),
          _buildSearchBar(),
        ],
        Expanded(
          child: _isInitialLoading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _loadBooks,
                  strokeWidth: 2.5,
                  displacement: 40,
                  // 与首页/发现页对齐：出场裁剪线贴住毛玻璃顶栏下边缘，
                  // 圆圈看起来从顶栏底下滑出；用 pageTopPadding 会让裁剪线
                  // 悬在顶栏下方 8dp，圆圈在半空被“隐形层”切头。
                  edgeOffset: useRailNavigation || _searchBarVisible
                      ? 0
                      : mobileChrome.topBarHeight,
                  color: Theme.of(context).colorScheme.primary,
                  backgroundColor: palette.cardStrong,
                  child: _books.isEmpty
                      ? _buildRefreshableState(_buildEmptyLibrary())
                      : books.isEmpty
                      ? _buildRefreshableState(_buildNoSearchResult())
                      : libraryLayoutMode == LibraryLayoutMode.grid
                      ? _buildCoverOnlyGrid(
                          books,
                          topPadding: listTopPadding,
                          mobileColumns: libraryGridColumns,
                          showDetails: libraryGridShowDetails,
                        )
                      : _buildBooksGrid(books, topPadding: listTopPadding),
                ),
        ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: useRailNavigation
          ? SafeArea(bottom: false, child: content)
          : content,
    );
  }

  List<Book> get _visibleBooks {
    final filteredByStatus = _books
        .where((book) => _matchesSelectedFilter(book))
        .toList();
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return filteredByStatus;
    return filteredByStatus.where((book) {
      return book.title.toLowerCase().contains(query) ||
          book.author.toLowerCase().contains(query);
    }).toList();
  }

  bool _matchesSelectedFilter(Book book) {
    switch (_selectedFilter) {
      case _LibraryFilter.all:
        return true;
      case _LibraryFilter.reading:
        return _isReadingBook(book);
      case _LibraryFilter.finished:
        return _isFinishedBook(book);
    }
  }

  bool _isFinishedBook(Book book) {
    return book.progress >= 1;
  }

  bool _isReadingBook(Book book) {
    return book.progress > 0 && !_isFinishedBook(book);
  }

  Widget _buildTopBar() {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    final webDavSync = context.watch<WebDavSyncController?>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          if (_selection.isActive) ...[
            IconButton(
              tooltip: context.l10n.cancel,
              onPressed: _exitSelectionMode,
              icon: const Icon(Icons.close_rounded),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              _selection.isActive
                  ? context.l10n.librarySelectedBooks(
                      _selection.selectedIds.length,
                    )
                  : context.l10n.library,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _selection.isActive ? 24 : 36,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
                height: 1.05,
              ),
            ),
          ),
          if (_selection.isActive)
            TextButton(
              onPressed: _selectAllVisibleBooks,
              child: Text(context.l10n.librarySelectAll),
            )
          else ...[
            if (webDavSync?.isConfigured ?? false) ...[
              _buildTopBarIcon(
                icon: Icons.cloud_sync_rounded,
                active: webDavSync!.remoteBooks.any(
                  (book) => book.fileAvailable,
                ),
                tooltip: context.l10n.webDavBookFilesTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BookFileSyncPage(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            _buildTopBarIcon(
              icon: Icons.downloading_rounded,
              active:
                  context.watch<DownloadTaskController?>()?.hasActiveTasks ??
                  false,
              tooltip: context.l10n.downloadTasksTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DownloadTasksPage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildTopBarIcon(
              icon: Icons.search_rounded,
              active: _searchBarVisible,
              tooltip: context.l10n.bookSourcesSearch,
              onTap: _toggleSearchBar,
            ),
            const SizedBox(width: 8),
            _LibraryFilterButton(
              active: _selectedFilter != _LibraryFilter.all,
              decoration: (active) => _panelDecoration(
                radius: 22,
                stronger: true,
                color: active
                    ? scheme.primaryContainer
                    : (_isMaterial3Style
                          ? scheme.surfaceContainer
                          : palette.card),
              ),
              iconColor: _selectedFilter != _LibraryFilter.all
                  ? scheme.onPrimaryContainer
                  : palette.iconMuted,
              onTapWithRect: _showFilterMenu,
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ImportBookPage(),
                  ),
                );
                if (result == true && mounted) {
                  _loadBooks();
                }
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: _panelDecoration(
                  radius: 22,
                  stronger: true,
                  color: _isMaterial3Style
                      ? scheme.surfaceContainer
                      : palette.card,
                ),
                child: Icon(Icons.add_rounded, color: palette.iconMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRailSelectionBottomBar() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.viewPaddingOf(context).bottom + 18,
      child: SafeArea(
        top: false,
        child: Center(
          child: FilledButton.icon(
            key: const ValueKey('library-delete-selected'),
            onPressed: _selection.selectedIds.isEmpty
                ? null
                : _confirmDeleteSelectedBooks,
            style: FilledButton.styleFrom(
              minimumSize: const Size(260, 52),
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(
              context.l10n.libraryDeleteSelected(_selection.selectedIds.length),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarIcon({
    required IconData icon,
    required bool active,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: _panelDecoration(
            radius: 22,
            stronger: true,
            color: active
                ? scheme.primaryContainer
                : (_isMaterial3Style ? scheme.surfaceContainer : palette.card),
          ),
          child: Icon(
            icon,
            color: active ? scheme.onPrimaryContainer : palette.iconMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: _panelDecoration(
          radius: 14,
          stronger: true,
          color: _isMaterial3Style ? scheme.surfaceContainerLow : palette.card,
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: palette.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: context.l10n.librarySearchHint,
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            if (_searchQuery.isNotEmpty)
              InkWell(
                onTap: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: palette.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingActionButton() {
    final isTablet = LayoutHelper.isTablet(context);
    final isDesktop = LayoutHelper.isDesktop(context);
    final useRailNav = isTablet || isDesktop;
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    final mobileChrome = HomeMobileChromeScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    // 侧边导航栏模式：FAB 在右下角，边距较小
    // 底部导航栏模式：FAB 需要避开导航栏
    final double bottomMargin = useRailNav
        ? bottomPadding +
              16 // 侧边导航：只需避开安全区域
        : mobileChrome.floatingActionBottomMargin; // 底部导航：避开悬浮导航栏

    if (_isMaterial3Style) {
      return Container(
        margin: EdgeInsets.only(bottom: bottomMargin),
        child: FloatingActionButton(
          onPressed: () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ImportBookPage()),
            );
            if (result == true && mounted) {
              _loadBooks();
            }
          },
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          elevation: 2,
          heroTag: "add_book_fab",
          child: const Icon(Icons.add, size: 28),
        ),
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: bottomMargin),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          enabled: !GlassEffectConfig.shouldDisableBlur,
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: FloatingActionButton(
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ImportBookPage()),
              );
              // 导入完成后刷新书籍列表
              if (result == true && mounted) {
                _loadBooks();
              }
            },
            backgroundColor: Theme.of(context).colorScheme.primary.withValues(
              alpha: GlassEffectConfig.effectiveOpacity(0.9),
            ),
            foregroundColor: Colors.white,
            elevation: 0,
            heroTag: "add_book_fab", // 添加唯一标识避免冲突
            child: const Icon(Icons.add, size: 28),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyLibrary() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFF7A5C), Color(0xFFE8503A)],
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.menu_book_rounded,
              color: Colors.white,
              size: 40,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            context.l10n.libraryNoBooks,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('library-empty-import'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ImportBookPage()),
              );
              _loadBooks();
            },
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(context.l10n.importBooks),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              minimumSize: const Size(150, 46),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(23),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoSearchResult() {
    final scheme = Theme.of(context).colorScheme;
    final palette = PageStyleHelper.palette(context);
    final hasSearch = _searchQuery.trim().isNotEmpty;
    final message = hasSearch
        ? context.l10n.libraryNoMatchingBooks
        : switch (_selectedFilter) {
            _LibraryFilter.reading => context.l10n.libraryNoReadingBooks,
            _LibraryFilter.finished => context.l10n.libraryNoFinishedBooks,
            _LibraryFilter.all => context.l10n.libraryNoBooks,
          };
    final icon = hasSearch
        ? Icons.search_off_rounded
        : Icons.filter_alt_off_rounded;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 32, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: palette.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildRefreshableState(Widget state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          children: [SizedBox(height: constraints.maxHeight, child: state)],
        );
      },
    );
  }

  Widget _buildCoverOnlyGrid(
    List<Book> books, {
    required double topPadding,
    required int mobileColumns,
    required bool showDetails,
  }) {
    final useRail =
        LayoutHelper.getNavigationType(context) == NavigationType.rail;
    final spacing = useRail ? 14.0 : 10.0;
    final horizontalPadding = useRail ? 16.0 : 12.0;
    final bottomPadding = useRail
        ? MediaQuery.viewPaddingOf(context).bottom +
              (_selection.isActive ? 104 : 24)
        : HomeMobileChromeScope.of(context).pageBottomPadding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = LayoutHelper.coverOnlyGridColumnsForWidth(
          constraints.maxWidth,
          mobileColumns: mobileColumns,
        );
        final itemWidth =
            (constraints.maxWidth -
                horizontalPadding * 2 -
                spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        final itemHeight =
            itemWidth * 3 / 2 + _BookCoverItem.textHeight + _BookCoverItem.gap;
        return GridView.builder(
          key: const ValueKey('library-cover-grid'),
          scrollCacheExtent: const ScrollCacheExtent.pixels(720),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            topPadding,
            horizontalPadding,
            bottomPadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing + 2,
            childAspectRatio: itemWidth / itemHeight,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            final coverKey = _coverKeyFor(book);
            return RepaintBoundary(
              child: _BookCoverItem(
                book: book,
                coverKey: coverKey,
                selectionActive: _selection.isActive,
                selected: _isBookSelected(book),
                showDetails: showDetails,
                onTap: () async {
                  await _handleBookTap(
                    book,
                    openBook: () => _openBookFromCover(
                      book,
                      coverKey: coverKey,
                      radius: BorderRadius.circular(8),
                      coverBuilder: (context) => _gridCoverArt(context, book),
                    ),
                  );
                },
                onLongPress: _selection.isActive
                    ? () => _toggleBookSelection(book)
                    : () => _showBookOptions(book),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBooksGrid(List<Book> books, {required double topPadding}) {
    final useRail =
        LayoutHelper.getNavigationType(context) == NavigationType.rail;
    if (!useRail) {
      return _buildBooksList(books, topPadding: topPadding);
    }

    final spacing = LayoutHelper.isDesktop(context) ? 16.0 : 14.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数由可用宽度和目标封面宽度推导：旋转屏幕时封面大小基本不变，
        // 只是列数重排，不再按断点写死列数。
        const double horizontalPadding = 32.0;
        final crossAxisCount = LayoutHelper.bookGridColumnsForWidth(
          constraints.maxWidth,
        );
        final totalSpacing = spacing * (crossAxisCount - 1);
        final availableWidth = math.max(
          0.0,
          constraints.maxWidth - horizontalPadding - totalSpacing,
        );
        final itemWidth = availableWidth / crossAxisCount;
        // 网格高度为 2:3 封面 + 文本区域预留高度（更接近常见书封比例）
        final itemHeight =
            (itemWidth * 3 / 2) +
            _BookCoverItem.textHeight +
            _BookCoverItem.gap;
        final childAspectRatio = itemWidth > 0 ? itemWidth / itemHeight : 0.75;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.3, 0.7, 1.0],
              colors: [
                Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
                Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.03),
                Theme.of(
                  context,
                ).colorScheme.secondaryContainer.withValues(alpha: 0.03),
                Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
              ],
            ),
          ),
          child: GridView.builder(
            scrollCacheExtent: const ScrollCacheExtent.pixels(720),
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.viewPaddingOf(context).bottom +
                  (_selection.isActive ? 104 : 24),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing + 8,
              childAspectRatio: childAspectRatio,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              final coverKey = _coverKeyFor(book);
              return RepaintBoundary(
                child: _BookCoverItem(
                  book: book,
                  coverKey: coverKey,
                  selectionActive: _selection.isActive,
                  selected: _isBookSelected(book),
                  onTap: () async {
                    await _handleBookTap(
                      book,
                      openBook: () => _openBookFromCover(
                        book,
                        coverKey: coverKey,
                        radius: BorderRadius.circular(8),
                        coverBuilder: (context) => _gridCoverArt(context, book),
                      ),
                    );
                  },
                  onLongPress: _selection.isActive
                      ? () => _toggleBookSelection(book)
                      : () => _showBookOptions(book),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBooksList(List<Book> books, {required double topPadding}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView.builder(
      scrollCacheExtent: const ScrollCacheExtent.pixels(720),
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        topPadding,
        16,
        HomeMobileChromeScope.of(context).pageBottomPadding,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        final coverKey = _coverKeyFor(book);

        final progress = book.progress.clamp(0.0, 1.0);
        final percent = (progress * 100).round();
        final isSelected = _selection.isActive && _isBookSelected(book);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _isMaterial3Style
                ? scheme.surfaceContainerLow
                : scheme.surface.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? scheme.primary
                  : scheme.outline.withValues(
                      alpha: _isMaterial3Style ? 0.18 : 0.1,
                    ),
              width: isSelected ? 1.6 : 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(
                  alpha: _isMaterial3Style ? 0.07 : 0.12,
                ),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              await _handleBookTap(
                book,
                openBook: () => _openBookFromCover(
                  book,
                  coverKey: coverKey,
                  radius: BorderRadius.circular(8),
                  coverBuilder: (context) => _buildListCover(context, book),
                ),
              );
            },
            onLongPress: _selection.isActive
                ? () => _toggleBookSelection(book)
                : () => _showBookOptions(book),
            child: Row(
              children: [
                // 竖版封面（2:3、圆角 8、多选时主色描边）
                Container(
                  key: coverKey,
                  width: 60,
                  height: 90,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: isSelected
                        ? Border.all(color: scheme.primary, width: 1.6)
                        : null,
                    boxShadow: [
                      BoxShadow(
                        color: scheme.shadow.withValues(alpha: 0.16),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildListCover(context, book),
                        if (progress > 0)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              backgroundColor: Colors.black26,
                              valueColor: AlwaysStoppedAnimation(
                                scheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              book.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (book.isOnline) ...[
                            const SizedBox(width: 8),
                            _onlineBadge(context),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.78,
                          ),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 4,
                                backgroundColor: scheme.primary.withValues(
                                  alpha: 0.12,
                                ),
                                valueColor: AlwaysStoppedAnimation(
                                  scheme.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '$percent%',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_selection.isActive)
                  _BookSelectionIndicator(selected: isSelected)
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurface.withValues(alpha: 0.35),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildListCover(BuildContext context, Book book) {
    if (!kIsWeb &&
        book.coverImagePath != null &&
        book.coverImagePath!.isNotEmpty) {
      // 列表封面显示宽度固定 64，按屏幕像素密度限制解码尺寸即可
      return Image.file(
        File(book.coverImagePath!),
        fit: LayoutHelper.bookCoverFit,
        cacheWidth: (64 * MediaQuery.of(context).devicePixelRatio).round(),
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _buildListDefaultCover(context, book),
      );
    }
    final sourceCover = _sourceCoverUrl(book);
    if (sourceCover != null) {
      return SourceCoverImage(
        url: sourceCover,
        fit: LayoutHelper.bookCoverFit,
        cacheWidth: (64 * MediaQuery.of(context).devicePixelRatio).round(),
        fallback: _buildListDefaultCover(context, book),
      );
    }
    return _buildListDefaultCover(context, book);
  }

  Widget _buildListDefaultCover(BuildContext context, Book book) {
    return GeneratedBookCover(title: book.title, author: book.author);
  }

  Widget _onlineBadge(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      context.l10n.bookSourceOnlineBadge,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onPrimaryContainer,
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Future<void> _downloadOnlineBook(Book book) async {
    final source = _sourceShelfService.sourceFrom(book);
    final sourceBook = _sourceShelfService.sourceBookFrom(book);
    final taskId = context.read<DownloadTaskController>().enqueueBookDownload(
      source: source,
      book: sourceBook,
      shelfService: _sourceShelfService,
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BookDownloadTaskDialog(taskId: taskId),
    );
    if (!mounted) return;
    showSideToast(context, context.l10n.downloadRunningInBackground);
  }

  Future<void> _exportBook(Book book) async {
    if (!_exportingBookPaths.add(book.filePath)) return;
    showSideToast(context, context.l10n.bookExportInProgress);
    try {
      final result = await BookExportService().export(book);
      if (!mounted) return;
      switch (result.status) {
        case BookExportStatus.success:
          final location = result.location ?? result.displayName ?? book.title;
          showSideToast(
            context,
            context.l10n.bookExportSuccess(location),
            kind: SideToastKind.success,
          );
        case BookExportStatus.cancelled:
          break;
        case BookExportStatus.sourceMissing:
        case BookExportStatus.notDownloaded:
          showSideToast(
            context,
            context.l10n.bookExportSourceMissing,
            kind: SideToastKind.warning,
          );
        case BookExportStatus.unsupported:
          showSideToast(
            context,
            context.l10n.bookExportUnsupported,
            kind: SideToastKind.warning,
          );
        case BookExportStatus.failure:
          showSideToast(
            context,
            context.l10n.bookExportFailed,
            kind: SideToastKind.error,
          );
      }
    } finally {
      _exportingBookPaths.remove(book.filePath);
    }
  }

  void _showBookOptions(Book book) {
    final scheme = Theme.of(context).colorScheme;
    final isMaterial3Style = _isMaterial3Style;
    final useBlur = !isMaterial3Style && !GlassEffectConfig.shouldDisableBlur;
    showModalBottomSheet(
      context: context,
      backgroundColor: isMaterial3Style
          ? scheme.surfaceContainerHigh
          : Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final localScheme = Theme.of(context).colorScheme;
        final progress = book.progress;
        final content = Container(
          decoration: BoxDecoration(
            color: isMaterial3Style
                ? localScheme.surfaceContainerHigh
                : GlassEffectConfig.surfaceColor(context, opacity: 0.95),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: localScheme.outline.withValues(
                  alpha: isMaterial3Style ? 0.24 : 0.2,
                ),
                width: 1,
              ),
            ),
            boxShadow: isMaterial3Style
                ? [
                    BoxShadow(
                      color: localScheme.shadow.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, -2),
                    ),
                  ]
                : null,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: localScheme.onSurface.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 50,
                        height: 70,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              localScheme.primary.withValues(alpha: 0.8),
                              localScheme.secondary.withValues(alpha: 0.6),
                            ],
                          ),
                          border: Border.all(
                            color: localScheme.outline.withValues(
                              alpha: isMaterial3Style ? 0.22 : 0.12,
                            ),
                            width: 0.8,
                          ),
                          boxShadow: isMaterial3Style
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _buildListCover(context, book),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              book.author,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: localScheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 5,
                                      backgroundColor: localScheme.primary
                                          .withValues(alpha: 0.14),
                                      color: localScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${(progress * 100).toStringAsFixed(1)}%',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: localScheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: localScheme.outline.withValues(alpha: 0.15),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Column(
                    children: [
                      _buildOptionItem(
                        context: context,
                        icon: Icons.library_add_check_outlined,
                        iconColor: localScheme.primary,
                        title: context.l10n.librarySelectMultiple,
                        onTap: () {
                          Navigator.pop(context);
                          _enterSelectionMode(book);
                        },
                      ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.play_circle_outline,
                        iconColor: localScheme.primary,
                        title: context.l10n.continueReading,
                        trailing: book.isOnline
                            ? context.l10n.bookSourceOnlineBadge
                            : book.currentPage > 0
                            ? context.l10n.libraryPageNumber(book.currentPage)
                            : context.l10n.libraryStartFromBeginning,
                        onTap: () async {
                          Navigator.pop(context);
                          final fullBook = await _bookDao.getBookById(book.id!);
                          if (fullBook != null && context.mounted) {
                            await _openBook(
                              fullBook,
                              libraryAnimation: context
                                  .read<AppSettingsNotifier>()
                                  .libraryBookOpenAnimation,
                            );
                            _loadBooks();
                          }
                        },
                      ),
                      if (book.isOnline)
                        _buildOptionItem(
                          context: context,
                          icon: Icons.download_for_offline_outlined,
                          iconColor: localScheme.secondary,
                          title: context.l10n.bookSourceDownloadLocal,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_downloadOnlineBook(book));
                          },
                        ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.info_outline,
                        iconColor: localScheme.tertiary,
                        title: context.l10n.libraryBookInfo,
                        trailing: _bookInfoSubtitle(context, book),
                        onTap: () {
                          Navigator.pop(context);
                          _showBookInfo(book);
                        },
                      ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.edit_outlined,
                        iconColor: localScheme.secondary,
                        title: context.l10n.libraryRenameBook,
                        onTap: () {
                          Navigator.pop(context);
                          _renameBook(book);
                        },
                      ),
                      if (!kIsWeb) ...[
                        _buildOptionItem(
                          context: context,
                          icon: Icons.image_outlined,
                          iconColor: localScheme.secondary,
                          title: context.l10n.libraryCustomCover,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_pickCustomCover(book));
                          },
                        ),
                        if (BookCoverEditService.hasCustomCover(book))
                          _buildOptionItem(
                            context: context,
                            icon: Icons.restore,
                            iconColor: localScheme.secondary,
                            title: context.l10n.libraryResetCover,
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_resetCustomCover(book));
                            },
                          ),
                      ],
                      if (!book.isOnline && book.filePath.isNotEmpty)
                        _buildOptionItem(
                          context: context,
                          icon: Icons.file_upload_outlined,
                          iconColor: localScheme.secondary,
                          title: context.l10n.libraryExportBook,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_exportBook(book));
                          },
                        ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.delete_outline_rounded,
                        iconColor: localScheme.error,
                        title: context.l10n.deleteBook,
                        destructive: true,
                        onTap: () {
                          Navigator.pop(context);
                          _confirmDeleteBook(book);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );

        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: useBlur
              ? BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: content,
                )
              : content,
        );
      },
    );
  }

  /// 书籍格式与页数/章节数摘要。
  ///
  /// 在线书源书籍的 totalPages 存储的是章节序号换算出的进度单位（见
  /// [BookSourceShelfService.unitsPerChapter]），不是真实页码，大部头小说会
  /// 显示成几十万"页"。因此在线书籍改为展示真实章节数。
  String _bookInfoSubtitle(BuildContext context, Book book) {
    final format = book.format.toUpperCase();
    if (!book.isOnline) {
      return context.l10n.libraryFormatAndPages(format, book.totalPages);
    }
    final unitsPerChapter = BookSourceShelfService.unitsPerChapter;
    if (book.totalPages < unitsPerChapter) return format;
    final chapters = (book.totalPages / unitsPerChapter).round();
    return context.l10n.libraryFormatAndChapters(format, chapters);
  }

  /// 重命名书籍：更新书名，若存在本地文件则同步重命名磁盘文件。
  Future<void> _renameBook(Book book) async {
    final controller = TextEditingController(text: book.title);
    final isMaterial3Style = _isMaterial3Style;
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isMaterial3Style
            ? scheme.surfaceContainerHigh
            : GlassEffectConfig.surfaceColor(dialogContext, opacity: 0.95),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.libraryRenameBook),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(labelText: l10n.libraryBookTitle),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == book.title) return;

    final toastContext = context;
    try {
      await BookRenameService().rename(book, trimmed);
      _loadBooks();
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryRenameBookSuccess,
        kind: SideToastKind.success,
      );
    } catch (_) {
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryRenameBookFailed,
        kind: SideToastKind.error,
      );
    }
  }

  /// 让用户挑选本地图片替换 [book] 的封面，成功后刷新书库。
  Future<void> _pickCustomCover(Book book) async {
    final l10n = context.l10n;
    final toastContext = context;
    try {
      final applied = await BookCoverEditService().pickAndApplyCover(book);
      if (!applied) return; // 用户取消挑选
      _loadBooks();
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryCustomCoverSuccess,
        kind: SideToastKind.success,
      );
    } on BookCoverEditException catch (error) {
      if (!toastContext.mounted) return;
      final message = switch (error.code) {
        BookCoverEditError.unsupportedFormat =>
          l10n.libraryCoverUnsupportedFormat,
        BookCoverEditError.fileTooLarge => l10n.libraryCoverFileTooLarge,
        BookCoverEditError.readFailed => l10n.libraryCoverReadFailed,
        BookCoverEditError.storageFailed => l10n.libraryCoverSaveFailed,
      };
      showSideToast(toastContext, message, kind: SideToastKind.error);
    } catch (_) {
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryCoverSaveFailed,
        kind: SideToastKind.error,
      );
    }
  }

  /// 撤销 [book] 的自定义封面，恢复原封面或回退到书源/生成封面。
  Future<void> _resetCustomCover(Book book) async {
    final l10n = context.l10n;
    final toastContext = context;
    try {
      await BookCoverEditService().resetCover(book);
      _loadBooks();
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryResetCoverSuccess,
        kind: SideToastKind.success,
      );
    } catch (_) {
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryCoverSaveFailed,
        kind: SideToastKind.error,
      );
    }
  }

  /// 构建操作选项项
  /// 紧凑操作行：小图标 + 标题 +（可选）右侧摘要，替代旧版大卡片。
  Widget _buildOptionItem({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? trailing,
    bool destructive = false,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: destructive ? scheme.error : scheme.onSurface,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    trailing,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 显示书籍详细信息
  void _showBookInfo(Book book) {
    final scheme = Theme.of(context).colorScheme;
    final isMaterial3Style = _isMaterial3Style;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isMaterial3Style
            ? scheme.surfaceContainerHigh
            : scheme.surface.withValues(alpha: 0.95),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(context.l10n.libraryBookInfo),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(context.l10n.libraryBookTitle, book.title),
            const SizedBox(height: 12),
            _buildInfoRow(context.l10n.author, book.author),
            const SizedBox(height: 12),
            _buildInfoRow(
              context.l10n.libraryFormat,
              book.format.toUpperCase(),
            ),
            const SizedBox(height: 12),
            if (book.isOnline) ...[
              _buildInfoRow(
                context.l10n.totalChapters,
                context.l10n.libraryChaptersCount(
                  (book.totalPages / BookSourceShelfService.unitsPerChapter)
                      .round(),
                ),
              ),
              const SizedBox(height: 12),
              _buildInfoRow(
                context.l10n.currentChapter,
                context.l10n.libraryChaptersCount(
                  (book.currentPage / BookSourceShelfService.unitsPerChapter)
                      .round(),
                ),
              ),
            ] else ...[
              _buildInfoRow(
                context.l10n.totalPages,
                context.l10n.libraryPagesCount(book.totalPages),
              ),
              const SizedBox(height: 12),
              _buildInfoRow(
                context.l10n.currentPage,
                context.l10n.libraryPagesCount(book.currentPage),
              ),
            ],
            const SizedBox(height: 12),
            _buildInfoRow(
              context.l10n.readingProgress,
              '${(book.progress * 100).toStringAsFixed(1)}%',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.libraryClose),
          ),
        ],
      ),
    );
  }

  /// 构建信息行
  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  void _confirmDeleteBook(Book book) {
    final isMaterial3Style = _isMaterial3Style;
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) {
        final dialog = AlertDialog(
          backgroundColor: isMaterial3Style
              ? scheme.surfaceContainerHigh
              : GlassEffectConfig.surfaceColor(context, opacity: 0.95),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            context.l10n.libraryConfirmDeleteTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          content: Text(context.l10n.libraryDeleteBookMessage(book.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final toastContext = this.context;
                navigator.pop();

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => PopScope(
                    canPop: false,
                    child: AlertDialog(
                      backgroundColor: isMaterial3Style
                          ? scheme.surfaceContainerHigh
                          : Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.95),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      content: Row(
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Text(
                              context.l10n.libraryDeletingBook(book.title),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );

                try {
                  await _performBookDeletion(book);
                  if (!mounted) return;

                  navigator.pop();
                  _loadBooks();
                  if (!toastContext.mounted) return;
                  showSideToast(
                    toastContext,
                    toastContext.l10n.libraryBookDeletedToast(book.title),
                    kind: SideToastKind.success,
                  );
                } catch (e) {
                  if (!mounted) return;
                  navigator.pop();

                  if (!toastContext.mounted) return;
                  showSideToast(
                    toastContext,
                    toastContext.l10n.libraryDeleteFailed('$e'),
                    kind: SideToastKind.error,
                  );
                }
              },
              child: Text(
                context.l10n.delete,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        );

        if (isMaterial3Style || GlassEffectConfig.shouldDisableBlur) {
          return dialog;
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: dialog,
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteSelectedBooks() async {
    final selectedIds = _selection.selectedIds;
    if (selectedIds.isEmpty) return;
    final selectedBooks = _books
        .where((book) => book.id != null && selectedIds.contains(book.id))
        .toList(growable: false);
    if (selectedBooks.isEmpty) return;

    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.libraryBatchDeleteTitle),
        content: Text(l10n.libraryBatchDeleteMessage(selectedBooks.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _deleteSelectedBooks(selectedBooks);
  }

  Future<void> _deleteSelectedBooks(List<Book> selectedBooks) async {
    final progress = ValueNotifier<int>(0);
    final l10n = context.l10n;
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (context, done, _) => Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    l10n.libraryDeletingSelected(done, selectedBooks.length),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final failedIds = <int>{};
    final deletedIds = <int>{};
    for (var index = 0; index < selectedBooks.length; index += 1) {
      final book = selectedBooks[index];
      try {
        await _performBookDeletion(book);
        if (book.id != null) deletedIds.add(book.id!);
      } catch (_) {
        if (book.id != null) failedIds.add(book.id!);
      }
      progress.value = index + 1;
    }

    if (!mounted) {
      progress.dispose();
      return;
    }
    navigator.pop();
    progress.dispose();
    setState(() {
      _books.removeWhere((book) => deletedIds.contains(book.id));
      if (failedIds.isEmpty) {
        _selection.exit();
      } else {
        _selection.retainOnly(failedIds);
      }
    });
    _syncSelection();
    LibraryEventBus().notifyLibraryChanged();

    if (failedIds.isEmpty) {
      showSideToast(
        context,
        l10n.libraryBatchDeleteSuccess(deletedIds.length),
        kind: SideToastKind.success,
      );
    } else {
      showSideToast(
        context,
        l10n.libraryBatchDeletePartial(deletedIds.length, failedIds.length),
        kind: SideToastKind.error,
      );
    }
  }

  /// 执行书籍删除操作（在后台执行）
  ///
  /// 彻底删除书籍及其所有相关文件和缓存：
  /// 1. 删除书籍原文件
  /// 2. 删除封面图片文件
  /// 3. 删除分页缓存文件
  /// 4. 删除数据库记录（会级联删除笔记、书签等）
  ///
  /// 参数 [onProgress] 进度回调，用于更新UI提示信息
  Future<void> _performBookDeletion(
    Book book, {
    void Function(String message)? onProgress,
  }) async {
    debugPrint('🗑️ 开始删除书籍: ${book.title}');
    final l10n = context.l10n;
    final startTime = DateTime.now();

    try {
      // 1. 删除书籍文件
      onProgress?.call(l10n.libraryDeletingBookFile);
      if (!kIsWeb && book.filePath.isNotEmpty) {
        final file = File(book.filePath);
        if (await file.exists()) {
          await file.delete();
          debugPrint('✅ 已删除书籍文件: ${book.filePath}');
        } else {
          debugPrint('⚠️ 书籍文件不存在: ${book.filePath}');
        }

        // 2. 删除封面图片文件
      }
      onProgress?.call(l10n.libraryDeletingCoverImage);
      if (!kIsWeb &&
          book.coverImagePath != null &&
          book.coverImagePath!.isNotEmpty) {
        final coverFile = File(book.coverImagePath!);
        if (await coverFile.exists()) {
          await coverFile.delete();
          debugPrint('✅ 已删除封面图片: ${book.coverImagePath}');
        }
      }
      if (!kIsWeb) {
        // 清理换封面留下的原封面备份等残留文件
        await BookCoverEditService().cleanupForDeletedBook(book);
      }

      // 3. 删除数据库记录（会级联删除笔记、书签等）
      onProgress?.call(l10n.libraryCleaningDatabase);
      await _bookDao.deleteBook(book.id!);
      debugPrint('✅ 已删除数据库记录');

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('🎉 书籍删除完成: ${book.title} (总耗时: ${duration}ms)');
      onProgress?.call(l10n.libraryDeleteComplete);
    } catch (e, stackTrace) {
      debugPrint('❌ 删除书籍失败: $e');
      debugPrint('堆栈跟踪: $stackTrace');
      rethrow;
    }
  }
}

class _BookCoverItem extends StatelessWidget {
  final Book book;
  final GlobalKey coverKey;
  final Future<void> Function() onTap;
  final VoidCallback onLongPress;
  final bool selectionActive;
  final bool selected;
  final bool showDetails;

  const _BookCoverItem({
    required this.book,
    required this.coverKey,
    required this.onTap,
    required this.onLongPress,
    required this.selectionActive,
    required this.selected,
    this.showDetails = true,
  });

  /// 封面下方文本区域高度与间距，网格计算格子高度时复用。
  static const double textHeight = 44.0;
  static const double gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isMaterial3Style =
        theme.extension<UiStyleThemeExtension>()?.isMaterial3Style ?? false;
    final progress = book.progress.clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final isReading = book.currentPage > 0;
    final isSelected = selectionActive && selected;

    return Semantics(
      button: true,
      label: showDetails
          ? '${book.title}，${context.l10n.libraryProgressContinue(percent)}'
          : book.title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => unawaited(onTap()),
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 现代书架：大号竖版封面卡（2:3、圆角 8、弱阴影/浅描边）
              Container(
                key: coverKey,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? scheme.primary
                        : scheme.outline.withValues(
                            alpha: isMaterial3Style ? 0.18 : 0.1,
                          ),
                    width: isSelected ? 2 : 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(
                        alpha: isMaterial3Style ? 0.1 : 0.18,
                      ),
                      blurRadius: isMaterial3Style ? 8 : 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _gridCoverArt(context, book),
                        // 在线阅读角标
                        if (!selectionActive && book.isOnline)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                context.l10n.bookSourceOnlineBadge,
                                style: TextStyle(
                                  color: scheme.onPrimary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        // "在读"标签
                        if (!selectionActive && isReading)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                context.l10n.libraryReadingBadge,
                                style: TextStyle(
                                  color: scheme.onPrimary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        // 底部优雅阅读进度条
                        if (progress > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black26],
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 3,
                                  backgroundColor: Colors.black26,
                                  valueColor: AlwaysStoppedAnimation(
                                    scheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // 多选角标（主色描边 + 对勾）
                        if (selectionActive)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: _BookSelectionIndicator(
                              selected: isSelected,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: gap),
              // 封面下方信息：书名（加粗）+ 进度百分比 / 作者
              SizedBox(
                width: double.infinity,
                height: textHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ScrollingText(
                        text: book.title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 1.2,
                        ),
                        duration: const Duration(seconds: 5),
                        pauseDuration: const Duration(milliseconds: 1200),
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (showDetails)
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                                backgroundColor: scheme.primary.withValues(
                                  alpha: 0.12,
                                ),
                                valueColor: AlwaysStoppedAnimation(
                                  scheme.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '$percent%',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  height: 1,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      )
                    else
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.78,
                          ),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookSelectionIndicator extends StatelessWidget {
  const _BookSelectionIndicator({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : scheme.surface.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 18, color: scheme.onPrimary)
          : null,
    );
  }
}

/// 网格封面画面（真实封面或默认设计），不带圆角：
/// 由格子里的 ClipRRect 或打开动画的飞行图层负责裁剪。
Widget _gridCoverArt(BuildContext context, Book book) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isMaterial3Style =
      theme.extension<UiStyleThemeExtension>()?.isMaterial3Style ?? false;
  if (!kIsWeb &&
      book.coverImagePath != null &&
      book.coverImagePath!.isNotEmpty) {
    // 有封面图片时，直接显示真实的书籍封面
    // cacheWidth 限制解码分辨率：网格封面显示宽度不会超过 ~240 逻辑像素，
    // 全分辨率解码原图会占用大量内存并在滑动切页时造成掉帧。
    // 打开动画复用同一 provider，展开时无需重新解码即可立即上屏。
    final cacheWidth = (240 * MediaQuery.of(context).devicePixelRatio).round();
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ColoredBox(
        color: scheme.surface.withValues(alpha: isMaterial3Style ? 0.2 : 0.12),
        child: Image.file(
          File(book.coverImagePath!),
          fit: LayoutHelper.bookCoverFit,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            return _gridDefaultCover(context, book);
          },
        ),
      ),
    );
  }
  final sourceCover = _sourceCoverUrl(book);
  if (sourceCover != null) {
    return SourceCoverImage(
      url: sourceCover,
      width: double.infinity,
      height: double.infinity,
      fit: LayoutHelper.bookCoverFit,
      cacheWidth: (240 * MediaQuery.of(context).devicePixelRatio).round(),
      fallback: _gridDefaultCover(context, book),
    );
  }
  // 没有封面图片时，显示默认封面设计
  return _gridDefaultCover(context, book);
}

/// 构建默认封面设计
Widget _gridDefaultCover(BuildContext context, Book book) {
  return GeneratedBookCover(title: book.title, author: book.author);
}

Uri? _sourceCoverUrl(Book book) {
  final raw = book.sourceBookJson;
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final value = decoded['coverUrl'];
    return value is String && value.isNotEmpty ? Uri.tryParse(value) : null;
  } catch (_) {
    return null;
  }
}

/// 顶栏筛选按钮：点击时把自身在屏幕上的位置传给菜单定位。
class _LibraryFilterButton extends StatelessWidget {
  final bool active;
  final BoxDecoration Function(bool active) decoration;
  final Color iconColor;
  final Future<void> Function(Rect anchor) onTapWithRect;

  const _LibraryFilterButton({
    required this.active,
    required this.decoration,
    required this.iconColor,
    required this.onTapWithRect,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l10n.libraryFilterTooltip,
      child: Builder(
        builder: (buttonContext) => InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            final box = buttonContext.findRenderObject()! as RenderBox;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            unawaited(onTapWithRect(rect));
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: decoration(active),
            child: Icon(
              active ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
