import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_aggregated_search.dart';
import 'package:midu/book_sources/services/book_source_chapter_text.dart';
import 'package:midu/book_sources/services/book_source_reading_progress.dart';
import 'package:midu/book_sources/services/book_source_shelf_service.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';
import 'package:midu/book_sources/services/book_source_text_paginator.dart';
import 'package:midu/core/reader/canonical_locator.dart';
import 'package:midu/core/reader/android_reader_aloud_notification.dart';
import 'package:midu/core/reader/native_text_paginator.dart';
import 'package:midu/core/reader/reader_annotation.dart';
import 'package:midu/core/reader/reader_custom_theme.dart';
import 'package:midu/core/reader/reader_leaf_status.dart';
import 'package:midu/core/reader/reader_layout.dart';
import 'package:midu/core/reader/reader_keep_screen_on.dart';
import 'package:midu/core/reader/reader_margin_settings.dart';
import 'package:midu/core/reader/reader_aloud_controller.dart';
import 'package:midu/core/reader/reader_safe_area.dart';
import 'package:midu/core/reader/reader_settings.dart';
import 'package:midu/core/reader/reader_system_ui.dart';
import 'package:midu/core/reader/reader_tap_zones.dart';
import 'package:midu/core/reader/reader_text_pagination.dart';
import 'package:midu/core/reader/reader_theme_order.dart';
import 'package:midu/core/reader/reader_vertical_paging.dart';
import 'package:midu/core/reader/reader_volume_key_controller.dart';
import 'package:midu/models/book.dart';
import 'package:midu/models/bookmark.dart';
import 'package:midu/models/book_note.dart';
import 'package:midu/services/books/book_note_dao.dart';
import 'package:midu/services/books/book_dao.dart';
import 'package:midu/services/books/book_source_switcher.dart';
import 'package:midu/services/books/bookmark_dao.dart';
import 'package:midu/services/core/app_settings_service.dart';
import 'package:midu/services/reading/reading_resume_service.dart';
import 'package:midu/services/reading/reading_stats_dao.dart';
import 'package:midu/services/library/library_event_bus_service.dart';
import 'package:midu/services/tts_service.dart';
import 'package:midu/services/reader_aloud_service.dart';
import 'package:midu/utils/book_open_transition.dart';
import 'package:midu/utils/debug_logger.dart';
import 'package:midu/utils/font_catalog_helper.dart';
import 'package:midu/utils/glass_config.dart';
import 'package:midu/utils/localization_extension.dart';
import 'package:midu/utils/midu_theme.dart';
import 'package:midu/utils/reader_themes.dart';
import 'package:midu/utils/system_ui_helper.dart';
import 'package:midu/pages/reader/network_comic_viewer.dart';
import 'package:midu/widgets/reader_annotated_text_page.dart';
import 'package:midu/widgets/reader_aloud_panel.dart';
import 'package:midu/widgets/reader_control_chrome.dart';
import 'package:midu/widgets/reader_cover_page_turn.dart';
import 'package:midu/widgets/reader_chapter_title_page.dart';
import 'package:midu/widgets/reader_navigation_sheet.dart';
import 'package:midu/widgets/reader_opening_loader.dart';
import 'package:midu/widgets/reader_paper_page_leaf.dart';
import 'package:midu/widgets/reader_pull_bookmark.dart';
import 'package:midu/widgets/reader_settings_controls.dart';
import 'package:midu/widgets/reader_shader_page_curl.dart';
import 'package:midu/widgets/reader_tap_observer.dart';
import 'package:midu/widgets/reader_tap_zone_editor.dart';
import 'package:midu/widgets/reader_theme_background.dart';
import 'package:midu/widgets/reader_top_information_bar.dart';
import 'package:midu/widgets/reader_vertical_paging_surface.dart';
import 'package:midu/widgets/side_toast.dart';

import 'themes/reader_custom_themes_page.dart';

typedef BookSourcePageMode = ReaderPageMode;

/// Immersive reader for chapters streamed from a MiDu book source.
class BookSourceReaderPage extends StatefulWidget {
  final RegisteredBookSource source;
  final BookSourceBook book;
  final BookSourceClient? client;
  final BookSourceReadingProgressStore progressStore;
  final BookSourceShelfService? shelfService;
  final ReaderThemePalette? initialTheme;
  final List<SourcedBookPointer>? alternateSources;

  const BookSourceReaderPage({
    super.key,
    required this.source,
    required this.book,
    this.client,
    this.progressStore = const BookSourceReadingProgressStore(),
    this.shelfService,
    this.initialTheme,
    this.alternateSources,
  });

  @override
  State<BookSourceReaderPage> createState() => _BookSourceReaderPageState();
}

class _BookSourceReaderPageState extends State<BookSourceReaderPage>
    with WidgetsBindingObserver {
  static const double _spreadGutter = 24;
  static const int _readableChapterTextLimit = 8;
  static const _openingLoaderDelay = Duration(milliseconds: 650);
  static const _openingContentSettleDelay = Duration(milliseconds: 360);

  late final BookSourceClient _client =
      widget.client ?? BookSourceClient.shared();
  late final BookSourceShelfService _shelfService =
      widget.shelfService ?? BookSourceShelfService(client: _client);
  final BookDao _bookDao = BookDao();
  // 当前阅读所使用的源/书籍。换源后会被替换为切换后的源/书籍，
  // 这样章节加载、进度保存与缓存键都能跟随切换后的源生效。
  late RegisteredBookSource _activeSource;
  late BookSourceBook _activeBook;
  // 已加入书架的 Book 记录缓存（含多源信息），用于换源面板列出备选源。
  Book? _shelfBook;
  // 从搜索结果带入的备选源指针；即便未加入书架，也用于换源面板列表。
  List<SourcedBookPointer> _extraAlternates = const [];
  PageController _pageController = PageController();
  final ItemScrollController _verticalPageScrollController =
      ItemScrollController();
  final ItemPositionsListener _verticalPagePositionsListener =
      ItemPositionsListener.create();
  final ItemScrollController _verticalChapterScrollController =
      ItemScrollController();
  final ScrollOffsetController _verticalChapterOffsetController =
      ScrollOffsetController();
  final ItemPositionsListener _verticalChapterPositionsListener =
      ItemPositionsListener.create();
  final ReaderPageCurlController _pageCurlController =
      ReaderPageCurlController();
  final ReaderPageCurlController _spreadForwardPageCurlController =
      ReaderPageCurlController();
  final ReaderPageCurlController _spreadBackwardPageCurlController =
      ReaderPageCurlController();
  final ReaderPageCurlCoordinator _spreadPageCurlCoordinator =
      ReaderPageCurlCoordinator(gutterWidth: _spreadGutter);
  final ReaderCoverPageTurnController _coverPageTurnController =
      ReaderCoverPageTurnController();
  final ValueNotifier<double> _scrollProgress = ValueNotifier(0);
  final ReaderLeafStatusController _leafStatusController =
      ReaderLeafStatusController();

  List<BookSourceChapter> _chapters = const [];
  List<ReaderNavigationChapter> _navigationChapters = const [];
  BookSourceChapterContent? _content;
  int _chapterIndex = 0;
  bool _loadingCatalog = true;
  bool _loadingContent = false;
  bool _controlsVisible = false;
  Object? _error;
  double _fontSize = 19;
  double _lineHeight = 1.75;
  double _letterSpacing = ReaderSettings.defaultLetterSpacing;
  ReaderTextAlignment _textAlignment = ReaderSettings.defaultTextAlignment;
  int _firstLineIndent = ReaderSettings.defaultFirstLineIndent;
  int _paragraphSpacing = ReaderSettings.defaultParagraphSpacing;
  FontOption _readerFont = FontCatalog.defaultReaderFont;
  bool _readerFontReady = true;
  double _horizontalMargin = ReaderSettings.defaultHorizontalMargin;
  double _topMargin = ReaderMarginSettings.defaultTop;
  double _bottomMargin = ReaderMarginSettings.defaultBottom;
  String _readerThemeId = ReaderThemes.parchment.id;
  BookSourcePageMode _pageMode = ReaderSettings.defaultPageMode;
  bool _pullBookmarkEnabled = false;
  bool _tapPageAnimationEnabled = true;
  ReaderTapZones _tapZones = ReaderTapZones.defaults;
  bool _tapZoneEditorVisible = false;
  bool _tabletTwoPageEnabled = ReaderSettings.defaultTabletTwoPageEnabled;
  int _pageIndex = 0;
  bool _usesTwoPageLayout = false;
  int _pageCount = 1;
  int _verticalPageIndex = 0;
  int _verticalPageCount = 1;
  int _pageViewLeading = 0;
  bool _ignoreSlidePageChanges = true;
  int? _pendingSlideChapterIndex;
  int? _pendingSlideBoundaryViewIndex;
  double _pendingSlideRestoreProgress = 0;
  bool _slideChapterCommitCheckScheduled = false;
  double _restorePageProgress = 0;
  bool _restorePagedPosition = false;
  int? _restoreTextOffset;
  int? _verticalCanonicalOffset;
  String? _paginationKey;
  List<BookSourceTextPage> _paginatedPages = const [];
  int _chapterLoadSerial = 0;
  final Map<int, BookSourceChapterContent> _prefetchedContent = {};
  final Map<int, String> _readableChapterText = {};
  final Map<int, Future<BookSourceChapterContent>> _continuousContentLoads = {};
  // 换源时自增；用于丢弃上一源仍在飞行中的章节内容回调，避免脏写。
  int _contentGeneration = 0;
  final Map<int, _BookSourcePagedLayout> _pagedLayouts = {};
  final Set<int> _queuedPagedLayoutWarms = {};
  final Set<int> _warmedPagedLayoutIndexes = {};
  final Map<int, _BookSourceVerticalLayout> _verticalLayouts = {};
  final Map<String, GlobalKey> _verticalPartKeys = {};
  Future<void> _progressSaveQueue = Future<void>.value();
  bool _scrollByChapter = true;
  Size _pagedViewportSize = Size.zero;
  Size _verticalViewportSize = Size.zero;
  bool _exitPromptVisible = false;
  bool _allowPop = false;
  int? _shelfBookId;
  Timer? _progressSaveTimer;
  Timer? _controlsTimer;
  Timer? _pagedLayoutWarmTimer;
  int? _pagedLayoutWarmTimerIndex;
  final ReadingStatsDao _readingStatsDao = ReadingStatsDao();
  final BookmarkDao _bookmarkDao = BookmarkDao();
  final BookNoteDao _bookNoteDao = BookNoteDao();
  final ReaderSettingsStore _readerSettingsStore = const ReaderSettingsStore();
  final ReaderCustomThemeStore _customThemeStore =
      const ReaderCustomThemeStore();
  final ReaderThemeOrderStore _themeOrderStore = const ReaderThemeOrderStore();
  List<Bookmark> _bookmarks = const [];
  bool _bookmarkBusy = false;
  List<BookNote> _annotations = const [];
  bool _annotationBusy = false;
  bool _annotationInteractionActive = false;
  int _annotationRevision = 0;
  DateTime? _readingSessionStartedAt;
  int _sessionPagesRead = 0;
  bool _readerSystemUiApplied = false;
  bool _showOpeningLoader = false;
  bool _openingContentReadyScheduled = false;
  Timer? _openingLoaderTimer;
  Timer? _openingContentReadyTimer;
  ReaderTopBarStyle _topBarStyle = ReaderTopBarStyle.reader;
  ReaderAloudController? _readerAloudController;
  bool _readerAloudActive = false;
  ReaderAloudHighlight? _readerAloudHighlight;
  bool _downloadingBook = false;
  double _downloadProgress = 0;
  OverlayEntry? _downloadOverlay;

  ReaderThemePalette get _readerTheme =>
      _loadingCatalog && widget.initialTheme != null
      ? widget.initialTheme!
      : ReaderThemes.byId(_readerThemeId);

  bool get _canPopWithoutPrompt => _allowPop || _shelfBookId != null;

  ThemeData get _readerThemeData =>
      _readerTheme.toThemeData(typography: Theme.of(context).textTheme);

  ReaderSettings get _readerSettings => ReaderSettings(
    fontSize: _fontSize,
    lineHeight: _lineHeight,
    letterSpacing: _letterSpacing,
    textAlignment: _textAlignment,
    horizontalMargin: _horizontalMargin,
    topMargin: _topMargin,
    bottomMargin: _bottomMargin,
    themeId: _readerThemeId,
    pageMode: _pageMode,
    firstLineIndent: _firstLineIndent,
    paragraphSpacing: _paragraphSpacing,
    pullBookmarkEnabled: _pullBookmarkEnabled,
    tapPageAnimationEnabled: _tapPageAnimationEnabled,
    tabletTwoPageEnabled: _tabletTwoPageEnabled,
  );

  ReaderSafeAreaMetrics get _readerSafeArea => ReaderSafeAreaMetrics(
    viewPadding: MediaQuery.viewPaddingOf(context),
    topMargin: _topMargin,
    bottomMargin: _bottomMargin,
    topChromeReserve: _topChromeReserveFor(_topBarStyle),
  );

  /// 阅读信息栏占一条固定信息条；灵动信息栏借用状态栏区域，仅在设备
  /// 没有状态栏 inset（隐藏后归零）时补足最小高度，避免正文顶进时间与
  /// 电量。其余样式顶部只避开状态栏本身。
  double _topChromeReserveFor(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.reader => ReaderSafeAreaMetrics.readerTopBarReserve,
    ReaderTopBarStyle.floating => math.max(
      0,
      ReaderSafeAreaMetrics.floatingStatusMinHeight -
          MediaQuery.viewPaddingOf(context).top,
    ),
    _ => 0,
  };

  bool get _showLeafFloatingStatus =>
      _topBarStyle == ReaderTopBarStyle.floating;

  double get _floatingStatusHorizontalPadding =>
      math.max(32, _horizontalMargin);

  /// 阅读信息栏与灵动信息栏都画进纸页快照，需要随分钟时钟/电量刷新重绘。
  int get _leafContentRevision => Object.hash(
    _topBarStyle == ReaderTopBarStyle.reader || _showLeafFloatingStatus
        ? _leafStatusController.value.revision
        : 0,
    _annotationRevision,
  );

  bool _shouldUseTwoPageLayout(Size size) =>
      _tabletTwoPageEnabled &&
      _pageMode == BookSourcePageMode.pageCurl &&
      ReaderLayoutBreakpoints.supportsTwoPageLayout(size);

  Size _paginationViewport(Size viewport, bool usesTwoPageLayout) =>
      usesTwoPageLayout
      ? Size((viewport.width - _spreadGutter) / 2, viewport.height)
      : viewport;

  int _spreadStartForPage(int pageIndex) => (pageIndex ~/ 2) * 2;

  int _lastVisiblePagedIndex(int pageIndex, int pageCount) {
    if (pageCount <= 0) return 0;
    final clamped = pageIndex.clamp(0, pageCount - 1);
    if (!_usesTwoPageLayout) return clamped;
    return math.min(_spreadStartForPage(clamped) + 1, pageCount - 1);
  }

  double _pagedReadingProgress(int pageIndex, int pageCount) => pageCount <= 1
      ? 1
      : (_lastVisiblePagedIndex(pageIndex, pageCount) / (pageCount - 1)).clamp(
          0.0,
          1.0,
        );

  @override
  void initState() {
    super.initState();
    _activeSource = widget.source;
    _activeBook = widget.book;
    _extraAlternates = widget.alternateSources ?? const [];
    _showOpeningLoader = widget.initialTheme == null;
    if (!_showOpeningLoader) {
      _openingLoaderTimer = Timer(_openingLoaderDelay, () {
        if (mounted) setState(() => _showOpeningLoader = true);
      });
    }
    WidgetsBinding.instance.addObserver(this);
    _leafStatusController
      ..addListener(_onLeafStatusChanged)
      ..start();
    unawaited(ReaderKeepScreenOnController.activate(this));
    _startReadingSession();
    _verticalPagePositionsListener.itemPositions.addListener(
      _onVerticalPagePositionsChanged,
    );
    _verticalChapterPositionsListener.itemPositions.addListener(
      _onVerticalChapterPositionsChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _readerSystemUiApplied) return;
      final topBarStyle = await ReaderSystemUiController.applySavedPreference(
        overlayStyle: _readerSystemUiOverlayStyle,
      );
      if (!mounted) return;
      setState(() {
        _topBarStyle = topBarStyle;
        _readerSystemUiApplied = true;
      });
    });
    unawaited(_initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    var nextReaderFont = FontCatalog.defaultReaderFont;
    var nextReaderFontReady = true;
    try {
      final appSettings = context.watch<AppSettingsNotifier>();
      nextReaderFontReady = appSettings.isInitialized;
      if (nextReaderFontReady) nextReaderFont = appSettings.readerFont;
    } on ProviderNotFoundException {
      // Reader widgets remain embeddable in tests and isolated previews.
    }
    _readerFontReady = nextReaderFontReady;
    if (_readerFont.id == nextReaderFont.id) return;
    _readerFont = nextReaderFont;
    _paginationKey = null;
    _paginatedPages = const [];
    _pagedLayouts.clear();
    _warmedPagedLayoutIndexes.clear();
    _verticalLayouts.clear();
    _restorePagedPosition = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startReadingSession();
      unawaited(ReaderKeepScreenOnController.reapply(this));
      if (_readerSystemUiApplied) unawaited(_applyReaderSystemUi());
      if (!_loadingCatalog && _error == null) {
        unawaited(_syncVolumeKeyPaging());
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress());
      unawaited(_flushReadingSession());
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted && _readerThemeId == ReaderThemes.systemId) {
      setState(() {});
      if (_readerSystemUiApplied) unawaited(_applyReaderSystemUi());
    }
  }

  void _startReadingSession() {
    _readingSessionStartedAt ??= DateTime.now();
  }

  Future<void> _flushReadingSession() async {
    final startedAt = _readingSessionStartedAt;
    if (startedAt == null) return;

    final endedAt = DateTime.now();
    final pagesRead = _sessionPagesRead;
    _readingSessionStartedAt = null;
    _sessionPagesRead = 0;

    try {
      await _readingStatsDao.recordReadingSession(
        startTime: startedAt,
        endTime: endedAt,
        bookId: _shelfBookId,
        pagesRead: pagesRead,
      );
    } catch (error) {
      debugPrint('record source reading session failed: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _downloadOverlay?.remove();
    _downloadOverlay = null;
    _openingLoaderTimer?.cancel();
    _openingContentReadyTimer?.cancel();
    _progressSaveTimer?.cancel();
    _controlsTimer?.cancel();
    _pagedLayoutWarmTimer?.cancel();
    _readerAloudController?.dispose();
    unawaited(_saveProgress());
    unawaited(_flushReadingSession());
    _verticalPagePositionsListener.itemPositions.removeListener(
      _onVerticalPagePositionsChanged,
    );
    _verticalChapterPositionsListener.itemPositions.removeListener(
      _onVerticalChapterPositionsChanged,
    );
    _pageController.dispose();
    _scrollProgress.dispose();
    _spreadPageCurlCoordinator.dispose();
    _leafStatusController
      ..removeListener(_onLeafStatusChanged)
      ..dispose();
    unawaited(ReaderVolumeKeyController.deactivate(this));
    unawaited(ReaderKeepScreenOnController.deactivate(this));
    unawaited(ReaderSystemUiController.restore());
    unawaited(ReadingResumeService.markClosed(_shelfBookId));
    super.dispose();
  }

  SystemUiOverlayStyle get _readerSystemUiOverlayStyle =>
      SystemUiHelper.overlayStyleForBackground(
        _readerTheme.background,
        transparentSystemBars: !GlassEffectConfig.shouldDisableBlur,
      );

  Future<void> _applyReaderSystemUi() => ReaderSystemUiController.apply(
    style: _topBarStyle,
    overlayStyle: _readerSystemUiOverlayStyle,
  );

  void _onLeafStatusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    setState(() {
      _loadingCatalog = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object?>([
        _client.getChapters(_activeSource, _activeBook.id),
        widget.progressStore.load(
          sourceId: _activeSource.id,
          bookId: _activeBook.id,
        ),
        _readerSettingsStore.load(),
        _readerSettingsStore.loadScrollByChapter(),
        _customThemeStore.loadAll(),
        _themeOrderStore.load(),
        _readerSettingsStore.loadTapZones(),
      ]);
      final chapters = [...results[0]! as List<BookSourceChapter>]
        ..sort((a, b) => a.order.compareTo(b.order));
      final navigationChapters = List<ReaderNavigationChapter>.generate(
        chapters.length,
        (index) => ReaderNavigationChapter(
          title: chapters[index].title,
          index: index,
          id: chapters[index].id,
        ),
        growable: false,
      );
      final saved = results[1] as BookSourceReadingProgress?;
      final settings = results[2]! as ReaderSettings;
      final scrollByChapter = results[3]! as bool;
      final customThemes = results[4] as List<ReaderCustomTheme>;
      final themeOrder = results[5] as List<String>;
      final tapZones = results[6] as ReaderTapZones;
      var initialIndex = saved?.chapterIndex ?? 0;
      if (saved != null && saved.chapterId.isNotEmpty) {
        final byId = chapters.indexWhere(
          (chapter) => chapter.id == saved.chapterId,
        );
        if (byId >= 0) initialIndex = byId;
      }
      if (chapters.isNotEmpty) {
        initialIndex = initialIndex.clamp(0, chapters.length - 1);
      }
      if (!mounted) return;
      ReaderThemes.setCustomThemes(customThemes);
      ReaderThemes.setThemeOrder(themeOrder);
      setState(() {
        _chapters = chapters;
        _navigationChapters = navigationChapters;
        _chapterIndex = initialIndex;
        _fontSize = settings.fontSize;
        _horizontalMargin = settings.horizontalMargin;
        _topMargin = settings.topMargin;
        _bottomMargin = settings.bottomMargin;
        _lineHeight = settings.lineHeight;
        _letterSpacing = settings.letterSpacing;
        _textAlignment = settings.textAlignment;
        _firstLineIndent = settings.firstLineIndent;
        _paragraphSpacing = settings.paragraphSpacing;
        _readerThemeId = ReaderThemes.byId(settings.themeId).id;
        _pageMode = settings.pageMode;
        _pullBookmarkEnabled = settings.pullBookmarkEnabled;
        _tapPageAnimationEnabled = settings.tapPageAnimationEnabled;
        _tapZones = tapZones;
        _tabletTwoPageEnabled = settings.tabletTwoPageEnabled;
        _scrollByChapter = scrollByChapter;
        _loadingCatalog = false;
      });
      unawaited(_syncVolumeKeyPaging());
      if (chapters.isNotEmpty) {
        unawaited(_resolveShelfBook());
        await _loadChapter(
          initialIndex,
          restoreProgress: saved?.chapterProgress ?? 0,
          saveCurrent: false,
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingCatalog = false;
        _error = error;
        _controlsVisible = true;
      });
    }
  }

  Future<void> _syncVolumeKeyPaging() => ReaderVolumeKeyController.activate(
    owner: this,
    pageTurningAvailable: _pageMode != BookSourcePageMode.verticalScroll,
    onNextPage: () => unawaited(_handleVolumePageTurn(forward: true)),
    onPreviousPage: () => unawaited(_handleVolumePageTurn(forward: false)),
  );

  Future<void> _handleVolumePageTurn({required bool forward}) async {
    if (!mounted ||
        _loadingCatalog ||
        _loadingContent ||
        _pageMode == BookSourcePageMode.verticalScroll) {
      return;
    }
    if (_pageMode == BookSourcePageMode.pageCurl) {
      final controller = _usesTwoPageLayout
          ? (forward
                ? _spreadForwardPageCurlController
                : _spreadBackwardPageCurlController)
          : _pageCurlController;
      if (forward) {
        await controller.turnForward();
      } else {
        await controller.turnBackward();
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.coverSlide) {
      if (forward) {
        await _coverPageTurnController.turnForward();
      } else {
        await _coverPageTurnController.turnBackward();
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.horizontalSlide &&
        _pageController.hasClients) {
      if (forward) {
        await _pageController.nextPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } else {
        await _pageController.previousPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    if (forward) {
      await _turnForward();
    } else {
      await _turnBackward();
    }
  }

  Future<void> _saveProgress() {
    if (_chapters.isEmpty || _chapterIndex >= _chapters.length) {
      return Future<void>.value();
    }
    final chapterIndex = _chapterIndex;
    final chapterId = _chapters[chapterIndex].id;
    final chapterCount = _chapters.length;
    final shelfBookId = _shelfBookId;
    var progress = _scrollProgress.value;
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      progress = _verticalPageCount <= 1
          ? 0
          : (_verticalPageIndex / (_verticalPageCount - 1)).clamp(0.0, 1.0);
    } else {
      progress = _pagedReadingProgress(_pageIndex, _pageCount);
    }
    final progressSnapshot = BookSourceReadingProgress(
      chapterId: chapterId,
      chapterIndex: chapterIndex,
      chapterProgress: progress,
      updatedAt: DateTime.now().toUtc(),
    );
    _progressSaveQueue = _progressSaveQueue.then((_) async {
      try {
        await widget.progressStore.save(
          sourceId: _activeSource.id,
          bookId: _activeBook.id,
          progress: progressSnapshot,
        );
        if (shelfBookId != null) {
          await _shelfService.updateShelfProgress(
            shelfBookId: shelfBookId,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            chapterProgress: progress,
          );
        }
      } catch (error) {
        debugPrint('save source reading progress failed: $error');
      }
    });
    return _progressSaveQueue;
  }

  /// 当前章节内的阅读进度（0..1），供控制栏进度滑块展示。
  double get _currentChapterProgress {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return _verticalPageCount <= 1
          ? 0
          : (_verticalPageIndex / (_verticalPageCount - 1)).clamp(0.0, 1.0);
    }
    return _pagedReadingProgress(_pageIndex, _pageCount);
  }

  /// 整本阅读进度（0..1），chapterIndex + 章节内进度 / 总章节数。
  double get _currentBookProgress {
    final count = _chapters.length;
    if (count == 0) return 0;
    return ((_chapterIndex + _currentChapterProgress) / count).clamp(0.0, 1.0);
  }

  Future<void> _resolveShelfBook() async {
    Book? shelfBook;
    try {
      shelfBook = await _shelfService.findShelfBook(
        sourceId: _activeSource.id,
        sourceBookId: _activeBook.id,
      );
    } catch (error) {
      debugPrint('resolve source shelf book failed: $error');
      return;
    }
    if (!mounted) return;
    // 若搜索结果带了备选源，把当前源连同备选一起并进书架书的多源信息。
    if (shelfBook != null && _extraAlternates.isNotEmpty) {
      final merged = _mergePointers(
        [...shelfBook!.decodeAllSources(), ..._extraAlternates],
      );
      if (merged.length > shelfBook!.decodeAllSources().length) {
        try {
          final updated = shelfBook!.withMultiSourceList(merged).copyWith(
            currentSourceId: _activeSource.id,
            sourceId: _activeSource.id,
            sourceBookId: _activeBook.id,
          );
          await _bookDao.updateBook(updated);
          shelfBook = updated;
        } catch (error) {
          debugPrint('persist multi-source into shelf book failed: $error');
        }
      }
    }
    _shelfBook = shelfBook;
    setState(() => _shelfBookId = shelfBook?.id);
    final shelfBookId = _shelfBookId;
    if (shelfBookId == null) return;
    unawaited(ReadingResumeService.markReading(shelfBookId));
    try {
      final results = await Future.wait<Object>([
        _bookmarkDao.getBookmarksForBook(shelfBookId),
        _bookNoteDao.selectBookNotesByBookId(shelfBookId),
      ]);
      if (mounted) {
        setState(() {
          _bookmarks = results[0] as List<Bookmark>;
          _annotations = results[1] as List<BookNote>;
          _annotationRevision++;
        });
      }
    } catch (error) {
      debugPrint('load source bookmarks and annotations failed: $error');
    }
  }

  Future<void> _reloadAnnotations() async {
    final bookId = _shelfBookId;
    if (bookId == null) return;
    final annotations = await _bookNoteDao.selectBookNotesByBookId(bookId);
    if (!mounted) return;
    setState(() {
      _annotations = annotations;
      _annotationRevision++;
    });
  }

  bool _ensureAnnotationBook() {
    if (_shelfBookId != null) return true;
    showSideToast(
      context,
      context.l10n.readerAnnotationShelfRequired,
      duration: const Duration(milliseconds: 2200),
      icon: Icons.add_to_photos_outlined,
      kind: SideToastKind.info,
    );
    return false;
  }

  Future<void> _saveTextAnnotation(
    ReaderSelectionSnapshot selection,
    ReaderAnnotationEditorResult annotation,
  ) async {
    if (!_ensureAnnotationBook() || _annotationBusy) return;
    final bookId = _shelfBookId!;
    setState(() => _annotationBusy = true);
    try {
      final now = DateTime.now();
      await _bookNoteDao.insertBookNote(
        BookNote(
          bookId: bookId,
          content: selection.selectedText,
          cfi: selection.cfiFor(annotation.type),
          canonicalLocator: selection.canonicalLocatorJson,
          chapter: selection.chapterTitle,
          type: annotation.type,
          color: annotation.colorHex,
          readerNote: annotation.note,
          pageNumber: selection.pageIndex,
          startOffset: selection.startOffset,
          endOffset: selection.endOffset,
          createTime: now,
          updateTime: now,
        ),
      );
      await _reloadAnnotations();
      if (!mounted) return;
      showSideToast(
        context,
        context.l10n.readerAnnotationSaved,
        duration: const Duration(milliseconds: 1600),
        icon: annotation.type == readerAnnotationTypeNote
            ? Icons.mode_comment_rounded
            : Icons.auto_awesome_rounded,
        kind: SideToastKind.success,
      );
    } catch (error) {
      debugPrint('save source annotation failed: $error');
    } finally {
      if (mounted) setState(() => _annotationBusy = false);
    }
  }

  Future<void> _deleteAnnotation(BookNote annotation) async {
    final id = annotation.id;
    if (id == null) return;
    await _bookNoteDao.deleteBookNoteById(id);
    if (!mounted) return;
    setState(() {
      _annotations = _annotations
          .where((candidate) => candidate.id != id)
          .toList(growable: false);
      _annotationRevision++;
    });
    showSideToast(
      context,
      context.l10n.readerAnnotationDeleted,
      duration: const Duration(milliseconds: 1600),
      icon: Icons.delete_outline_rounded,
      kind: SideToastKind.success,
    );
  }

  Future<void> _loadChapter(
    int index, {
    double restoreProgress = 0,
    bool saveCurrent = true,
  }) async {
    final logger = DebugLogger.instance;
    if (index < 0 || index >= _chapters.length || _loadingContent) {
      logger.log('reader', '跳过加载章节', details: {
        'reason': index < 0
            ? 'index<0'
            : index >= _chapters.length
                ? 'index超出章节范围'
                : '已有章节加载进行中',
        'index': index,
        'total': _chapters.length,
        'loadingContent': _loadingContent,
      });
      return;
    }
    if (saveCurrent && index > _chapterIndex) _sessionPagesRead++;
    if (saveCurrent && _content != null) unawaited(_saveProgress());
    if (!mounted) return;
    final loadSerial = ++_chapterLoadSerial;
    logger.log('reader', '开始加载章节', details: {
      'index': index,
      'serial': loadSerial,
      'title': index < _chapters.length ? _chapters[index].title : '',
      'currentChapterIndex': _chapterIndex,
      'loadingContentBefore': _loadingContent,
    });
    final prefetched = _prefetchedContent[index];
    if (prefetched != null && _readableChapterText.containsKey(index)) {
      logger.log('reader', '命中预缓存', details: {
        'index': index,
        'serial': loadSerial,
      });
      if (await _deferChapterApplyForOpeningFlight(index)) {
        if (!mounted || loadSerial != _chapterLoadSerial) {
          logger.log('reader', 'defer后取消(缓存路径)', details: {
            'index': index,
            'serial': loadSerial,
            'currentSerial': _chapterLoadSerial,
            'mounted': mounted,
          });
          return;
        }
      }
      _applyLoadedChapter(index, prefetched, restoreProgress: restoreProgress);
      return;
    }
    setState(() {
      _loadingContent = true;
      _error = null;
    });
    logger.log('reader', 'setState 设置loading=true', details: {
      'index': index,
      'serial': loadSerial,
    });
    try {
      final contentFuture = _continuousContentFor(index);
      final content = await contentFuture;
      logger.log('reader', 'contentFuture完成', details: {
        'index': index,
        'serial': loadSerial,
        'totalLength': content.content.length,
      });
      if (!mounted || loadSerial != _chapterLoadSerial) {
        logger.log('reader', 'content返回后取消→重置loading', details: {
          'index': index,
          'serial': loadSerial,
          'currentSerial': _chapterLoadSerial,
          'mounted': mounted,
          'willResetLoading': true,
        });
        if (mounted) {
          setState(() {
            _loadingContent = false;
          });
        }
        return;
      }
      if (await _deferChapterApplyForOpeningFlight(index)) {
        logger.log('reader', 'defer完成后二次检查', details: {
          'index': index,
          'serial': loadSerial,
          'currentSerial': _chapterLoadSerial,
          'mounted': mounted,
        });
        if (!mounted || loadSerial != _chapterLoadSerial) {
          logger.log('reader', 'defer后取消→重置loading', details: {
            'index': index,
            'serial': loadSerial,
            'currentSerial': _chapterLoadSerial,
            'mounted': mounted,
          });
          if (mounted) {
            setState(() {
              _loadingContent = false;
            });
          }
          return;
        }
      }
      logger.log('reader', '进入applyLoadedChapter', details: {
        'index': index,
        'serial': loadSerial,
      });
      _applyLoadedChapter(index, content, restoreProgress: restoreProgress);
      logger.log('reader', 'applyLoadedChapter完成', details: {
        'index': index,
        'serial': loadSerial,
        'loadingContentAfter': _loadingContent,
      });
    } catch (error) {
      logger.log('reader', '加载异常', details: {
        'index': index,
        'serial': loadSerial,
        'error': error.runtimeType.toString(),
        'message': error.toString().substring(0, error.toString().length > 500 ? 500 : error.toString().length),
      });
      if (!mounted || loadSerial != _chapterLoadSerial) {
        if (mounted) {
          setState(() {
            _loadingContent = false;
          });
        }
        return;
      }
      setState(() {
        _loadingContent = false;
        _error = error;
        _controlsVisible = true;
      });
    }
  }

  void _applyLoadedChapter(
    int index,
    BookSourceChapterContent content, {
    required double restoreProgress,
  }) {
    final normalizedProgress = restoreProgress.clamp(0.0, 1.0);
    final preparedLayout = _preparedPagedLayoutForChapter(index, content);
    final preparedPages = preparedLayout?.pages;
    final preparedPageCount = preparedPages?.length ?? 1;
    final preparedPageIndex = preparedPages == null
        ? 0
        : (_usesTwoPageLayout
                  ? _spreadStartForPage(
                      ((preparedPageCount - 1) * normalizedProgress).round(),
                    )
                  : ((preparedPageCount - 1) * normalizedProgress).round())
              .clamp(0, preparedPageCount - 1);
    final slideLeading = _slideLeadingPageCount(index);
    _pagedLayouts.removeWhere(
      (chapterIndex, _) => chapterIndex < index - 1 || chapterIndex > index + 2,
    );
    _warmedPagedLayoutIndexes.removeWhere(
      (chapterIndex) => chapterIndex < index - 1 || chapterIndex > index + 2,
    );
    setState(() {
      _chapterIndex = index;
      _content = content;
      _prefetchedContent[index] = content;
      _loadingContent = false;
      _pageIndex = preparedPageIndex;
      _pageCount = preparedPageCount;
      _pageViewLeading = slideLeading;
      _paginatedPages = preparedPages ?? const [];
      _paginationKey = preparedLayout?.fingerprint;
      _restorePageProgress = normalizedProgress;
      _restorePagedPosition = preparedLayout == null;
      _ignoreSlidePageChanges = true;
      _pendingSlideChapterIndex = null;
      _pendingSlideBoundaryViewIndex = null;
    });
    if (_pageMode == BookSourcePageMode.horizontalSlide) {
      _replaceSlidePageController(
        initialPage: preparedPageIndex + slideLeading,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ignoreSlidePageChanges = false;
      });
    }
    _scrollProgress.value = normalizedProgress;
    unawaited(_preloadAround(index));
  }

  _BookSourcePagedLayout? _preparedPagedLayoutForChapter(
    int index,
    BookSourceChapterContent content,
  ) {
    if (_pageMode == BookSourcePageMode.verticalScroll ||
        _pagedViewportSize.isEmpty) {
      return null;
    }
    return _pagedLayoutFor(index, content, _pagedViewportSize);
  }

  int _slideLeadingPageCount(int chapterIndex) {
    if (chapterIndex <= 0) return 0;
    final previousContent = _prefetchedContent[chapterIndex - 1];
    if (previousContent == null || _pagedViewportSize.isEmpty) return 1;
    final previousLayout = _pagedLayoutFor(
      chapterIndex - 1,
      previousContent,
      _pagedViewportSize,
    );
    return previousLayout.pages.length;
  }

  void _replaceSlidePageController({required int initialPage}) {
    final previous = _pageController;
    _pageController = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  Future<void> _preloadAround(int index) async {
    // The next chapter is the only cache entry needed for a forward turn.
    // Load and lay it out before competing for a source connection with the
    // backwards preview or the farther look-ahead chapter.
    await _preloadChapter(index + 1);
    for (final chapterIndex in <int>[index - 1, index + 2]) {
      unawaited(_preloadChapter(chapterIndex));
    }
  }

  Future<void> _preloadChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    try {
      await _continuousContentFor(index);
      _schedulePagedLayoutWarm(index);
    } catch (_) {
      // Adjacent content is opportunistic and can be retried on demand.
    }
  }

  Future<BookSourceChapterContent> _continuousContentFor(int index) {
    final cached = _prefetchedContent[index];
    if (cached != null && _readableChapterText.containsKey(index)) {
      return Future.value(cached);
    }
    final inFlight = _continuousContentLoads[index];
    if (inFlight != null) return inFlight;
    late final Future<BookSourceChapterContent> future;
    final generation = _contentGeneration;
    final logger = DebugLogger.instance;
    final contentFuture = cached != null
        ? Future<BookSourceChapterContent>.value(cached)
        : _client.getChapterContent(
            _activeSource,
            bookId: _activeBook.id,
            chapterId: _chapters[index].id,
          );
    logger.log('reader', '_continuousContentFor:发起', details: {
      'index': index,
      'generation': generation,
      'cached': cached != null,
      'title': index < _chapters.length ? _chapters[index].title : '',
    });
    future = contentFuture
        .then((content) async {
          logger.log('reader', '_continuousContentFor:getChapterContent返回',
              details: {
                'index': index,
                'totalLength': content.content.length,
              });
          // 换源后，上一源仍在飞行中的回调直接丢弃，不写缓存/状态。
          if (_contentGeneration != generation) {
            logger.log('reader', '_continuousContentFor:generation变→丢弃',
                details: {
                  'index': index,
                  'expect': generation,
                  'actual': _contentGeneration,
                });
            return content;
          }
          _readableChapterText.remove(index);
          try {
            final rendered = await readableBookSourceChapterTextAsync(
              content,
              fallbackTitle: _chapters[index].title,
            );
            _readableChapterText[index] = rendered;
            logger.log('reader', '_continuousContentFor:排版渲染完成', details: {
              'index': index,
              'renderedLength': rendered.length,
            });
          } catch (e) {
            logger.log('reader', '_continuousContentFor:排版渲染异常', details: {
              'index': index,
              'error': e.runtimeType.toString(),
              'message': e.toString().substring(
                    0,
                    e.toString().length > 500 ? 500 : e.toString().length,
                  ),
            });
            rethrow;
          }
          if (_contentGeneration != generation) return content;
          while (_readableChapterText.length > _readableChapterTextLimit) {
            _readableChapterText.remove(_readableChapterText.keys.first);
          }
          _prefetchedContent[index] = content;
          if (!mounted) {
            return content;
          }
          final pageStep = _usesTwoPageLayout ? 2 : 1;
          final updatesCurrentContent =
              !_loadingContent && _chapterIndex == index && _content != content;
          final revealsPagedBoundary =
              !_loadingContent &&
              _pageMode != BookSourcePageMode.verticalScroll &&
              ((index == _chapterIndex + 1 &&
                      _pageIndex + pageStep >= _pageCount) ||
                  (index == _chapterIndex - 1 && _pageIndex < pageStep));
          if (updatesCurrentContent || revealsPagedBoundary) {
            setState(() {
              if (updatesCurrentContent) {
                _content = content;
              }
            });
          }
          _schedulePagedLayoutWarm(index);
          return content;
        })
        .whenComplete(() {
          if (identical(_continuousContentLoads[index], future)) {
            _continuousContentLoads.remove(index);
          }
        });
    _continuousContentLoads[index] = future;
    return future;
  }

  void _schedulePagedLayoutWarm(int index) {
    if (!mounted ||
        _pageMode == BookSourcePageMode.verticalScroll ||
        index != _chapterIndex + 1 ||
        index < 0 ||
        index >= _chapters.length ||
        _pagedViewportSize.isEmpty ||
        _prefetchedContent[index] == null ||
        _warmedPagedLayoutIndexes.contains(index) ||
        !_queuedPagedLayoutWarms.add(index)) {
      return;
    }
    _pagedLayoutWarmTimer?.cancel();
    final previousWarmIndex = _pagedLayoutWarmTimerIndex;
    if (previousWarmIndex != null) {
      _queuedPagedLayoutWarms.remove(previousWarmIndex);
    }
    _pagedLayoutWarmTimerIndex = index;
    _pagedLayoutWarmTimer = Timer(const Duration(milliseconds: 32), () {
      _pagedLayoutWarmTimer = null;
      _pagedLayoutWarmTimerIndex = null;
      _queuedPagedLayoutWarms.remove(index);
      if (!mounted ||
          _pageMode == BookSourcePageMode.verticalScroll ||
          index != _chapterIndex + 1 ||
          _pagedViewportSize.isEmpty) {
        return;
      }
      // 打开动画（含正文渐显）没播完前不预热整章排版，落定后再重新排队。
      final settled = BookOpenTransition.openingFlightSettledListenableOf(
        context,
      );
      if (!settled.value) {
        late final VoidCallback onSettled;
        onSettled = () {
          settled.removeListener(onSettled);
          if (mounted) _schedulePagedLayoutWarm(index);
        };
        settled.addListener(onSettled);
        return;
      }
      final content = _prefetchedContent[index];
      if (content == null) return;
      _pagedLayoutFor(index, content, _pagedViewportSize);
      _warmedPagedLayoutIndexes.add(index);
    });
  }

  Future<void> _jumpToVerticalChapter(
    int index, {
    int? textOffset,
    double progress = 0,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    final content = await _continuousContentFor(index);
    if (!mounted) return;
    var targetPage = 0;
    _BookSourceVerticalLayout? layout;
    if (!_verticalViewportSize.isEmpty) {
      layout = _verticalLayoutFor(index, content, _verticalViewportSize);
      targetPage = textOffset != null
          ? bookSourcePageIndexForOffset(layout.pages, textOffset)
          : ((layout.pages.length - 1) * progress.clamp(0.0, 1.0)).round();
    }
    setState(() {
      _chapterIndex = index;
      _content = content;
      _pageIndex = targetPage;
      _verticalPageIndex = targetPage;
      _verticalPageCount = layout?.pages.length ?? 1;
      _restorePagedPosition = false;
      _restoreTextOffset = null;
    });
    _scrollProgress.value = _verticalPageCount <= 1
        ? 0
        : targetPage / (_verticalPageCount - 1);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (_scrollByChapter) {
      if (_verticalPageScrollController.isAttached) {
        await _verticalPageScrollController.scrollTo(
          index: targetPage,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      unawaited(_preloadAround(index));
      _scheduleProgressSave();
      return;
    }
    if (!_verticalChapterScrollController.isAttached) return;
    await _verticalChapterScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    if (targetPage > 0) {
      await _verticalChapterOffsetController.animateScroll(
        offset: targetPage * _verticalPageExtentFor(_verticalViewportSize),
        duration: const Duration(milliseconds: 1),
      );
      if (!mounted) return;
    }
    unawaited(_preloadAround(index));
    _scheduleProgressSave();
  }

  void _restoreScrollProgress(double progress) {
    _restorePageProgress = progress.clamp(0, 1);
    _restorePagedPosition = true;
    _scrollProgress.value = progress.clamp(0.0, 1.0);
  }

  void _showControlsTemporarily() {
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    _controlsTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_annotationInteractionActive) return;
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
  }

  Future<void> _requestExit() async {
    if (_exitPromptVisible) return;
    if (_shelfBookId != null) {
      BookOpenTransition.beginExit();
      await _saveProgress();
      unawaited(_flushReadingSession());
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
      return;
    }
    _exitPromptVisible = true;
    await _saveProgress();
    // 阅读统计是退出后的派生写入，不应阻塞“加入书架？”确认弹窗。
    unawaited(_flushReadingSession());
    final shelfBook = await _shelfService.findShelfBook(
      sourceId: _activeSource.id,
      sourceBookId: _activeBook.id,
    );
    if (!mounted) return;
    if (shelfBook != null) {
      BookOpenTransition.beginExit();
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
      return;
    }

    final shouldAdd = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.bookSourceExitAddTitle),
        content: Text(context.l10n.bookSourceExitAddMessage(_activeBook.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.bookSourceNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.bookSourceAddToShelf),
          ),
        ],
      ),
    );
    _exitPromptVisible = false;
    if (!mounted) return;
    if (shouldAdd == true) {
      final added = await _shelfService.addOnline(
        source: _activeSource,
        book: _activeBook,
      );
      _shelfBookId = added.id;
      await _saveProgress();
      if (!mounted) return;
    }
    BookOpenTransition.beginExit();
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    if (_annotationInteractionActive) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -350 && _chapterIndex < _chapters.length - 1) {
      unawaited(_loadChapter(_chapterIndex + 1));
    } else if (velocity > 350 && _chapterIndex > 0) {
      unawaited(_loadChapter(_chapterIndex - 1));
    }
  }

  void _handlePagedSwipe(DragEndDetails details) {
    if (_annotationInteractionActive) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -350) {
      unawaited(_turnForward());
    } else if (velocity > 350) {
      unawaited(_turnBackward());
    }
  }

  double get _currentReadingProgress {
    if (_pageMode != BookSourcePageMode.verticalScroll) {
      return _pagedReadingProgress(_pageIndex, _pageCount);
    }
    final text = _readableChapterText[_chapterIndex];
    final offset = _currentTextOffset;
    if (text == null || text.isEmpty || offset == null) return 0;
    return (offset / text.length).clamp(0.0, 1.0);
  }

  int? get _currentTextOffset {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return _verticalCanonicalOffset;
    }
    if (_paginatedPages.isEmpty) return null;
    return _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)]
        .startOffset;
  }

  void _setPagedIndex(int index, {bool jumpPageView = false}) {
    if (_paginatedPages.isEmpty) return;
    final clamped = index.clamp(0, _paginatedPages.length - 1);
    final next = _usesTwoPageLayout ? _spreadStartForPage(clamped) : clamped;
    if (next > _pageIndex) _sessionPagesRead++;
    if (next != _pageIndex) setState(() => _pageIndex = next);
    _pageCount = _paginatedPages.length;
    _scrollProgress.value = _pagedReadingProgress(_pageIndex, _pageCount);
    if (jumpPageView && _pageController.hasClients) {
      _pageController.jumpToPage(_pageIndex + _pageViewLeading);
    }
    if (_pageCount - _pageIndex <= 3) {
      unawaited(_preloadChapter(_chapterIndex + 1));
    }
    _scheduleProgressSave();
  }

  void _scheduleProgressSave() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_saveProgress()),
    );
  }

  void _queueSlideChapterCommit({
    required int chapterIndex,
    required int boundaryViewIndex,
    required double restoreProgress,
  }) {
    _pendingSlideChapterIndex = chapterIndex;
    _pendingSlideBoundaryViewIndex = boundaryViewIndex;
    _pendingSlideRestoreProgress = restoreProgress;
  }

  void _commitPendingSlideChapter() {
    final chapterIndex = _pendingSlideChapterIndex;
    final boundaryViewIndex = _pendingSlideBoundaryViewIndex;
    if (chapterIndex == null || boundaryViewIndex == null) return;
    final settledPage = _pageController.hasClients
        ? _pageController.page
        : null;
    if (settledPage == null ||
        (settledPage - boundaryViewIndex).abs() > 0.001) {
      return;
    }
    _pendingSlideChapterIndex = null;
    _pendingSlideBoundaryViewIndex = null;
    final restoreProgress = _pendingSlideRestoreProgress;
    // Let PageController.nextPage/previousPage finish their own ScrollEnd
    // future before replacing the PageView with the target chapter.
    Timer.run(() {
      if (!mounted) return;
      unawaited(_loadChapter(chapterIndex, restoreProgress: restoreProgress));
    });
  }

  void _schedulePendingSlideChapterCommit() {
    if (_slideChapterCommitCheckScheduled) return;
    _slideChapterCommitCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _slideChapterCommitCheckScheduled = false;
      if (mounted) _commitPendingSlideChapter();
    });
  }

  void _handleReaderTap(Offset localPosition) {
    if (_pageMode == BookSourcePageMode.horizontalSlide &&
        _pageController.hasClients) {
      final page = _pageController.page;
      if (page != null && (page - page.round()).abs() > 0.001) return;
    }
    _handleTapZoneAction(
      _tapZones.actionAt(localPosition, MediaQuery.sizeOf(context)),
    );
  }

  void _setTapZones(ReaderTapZones zones) {
    if (zones == _tapZones) return;
    setState(() => _tapZones = zones);
    unawaited(_readerSettingsStore.saveTapZones(zones));
  }

  Future<void> _showTapZoneSettings() async {
    Navigator.of(context).pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _controlsTimer?.cancel();
    setState(() {
      _controlsVisible = false;
      _tapZoneEditorVisible = true;
    });
  }

  Future<void> _turnForward() async {
    final pageStep = _usesTwoPageLayout ? 2 : 1;
    if (_pageIndex + pageStep < _pageCount) {
      _setPagedIndex(_pageIndex + pageStep, jumpPageView: true);
    } else if (_chapterIndex + 1 < _chapters.length) {
      await _loadChapter(_chapterIndex + 1, restoreProgress: 0);
    } else {
      _showControlsTemporarily();
    }
  }

  Future<void> _turnBackward() async {
    final pageStep = _usesTwoPageLayout ? 2 : 1;
    if (_pageIndex >= pageStep) {
      _setPagedIndex(_pageIndex - pageStep, jumpPageView: true);
    } else if (_chapterIndex > 0) {
      await _loadChapter(_chapterIndex - 1, restoreProgress: 1);
    } else {
      _showControlsTemporarily();
    }
  }

  int _currentBookmarkOffset(String text) {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      final pages = _verticalLayouts[_chapterIndex]?.pages;
      if (pages != null && pages.isNotEmpty) {
        return _verticalCanonicalOffset ?? pages.first.startOffset;
      }
    } else if (_paginatedPages.isNotEmpty) {
      return _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)]
          .startOffset;
    }
    return (_scrollProgress.value * text.length).round().clamp(0, text.length);
  }

  String? get _currentBookmarkAnchorKey {
    final content = _content;
    if (content == null || _chapters.isEmpty) return null;
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: _chapters[_chapterIndex].title,
    );
    final offset = _currentBookmarkOffset(text);
    return '${_chapters[_chapterIndex].id}:$offset';
  }

  Future<void> _toggleCurrentBookmark() async {
    final shelfBookId = _shelfBookId;
    final content = _content;
    if (_bookmarkBusy || content == null || _chapters.isEmpty) return;
    if (shelfBookId == null) {
      showSideToast(
        context,
        context.l10n.readerBookmarkRequiresShelf,
        duration: const Duration(milliseconds: 1900),
        icon: Icons.library_add_rounded,
        kind: SideToastKind.warning,
      );
      return;
    }
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: _chapters[_chapterIndex].title,
    );
    final offset = _currentBookmarkOffset(text);
    final anchorKey = '${_chapters[_chapterIndex].id}:$offset';
    Bookmark? existing;
    for (final bookmark in _bookmarks) {
      if (bookmark.anchorKey == anchorKey) {
        existing = bookmark;
        break;
      }
    }
    setState(() => _bookmarkBusy = true);
    try {
      if (existing != null) {
        final existingId = existing.id!;
        await _bookmarkDao.deleteBookmark(existingId);
        if (!mounted) return;
        setState(() {
          _bookmarks = _bookmarks
              .where((bookmark) => bookmark.id != existingId)
              .toList(growable: false);
        });
        showSideToast(
          context,
          context.l10n.bookmarkRemoved,
          duration: const Duration(milliseconds: 1600),
          icon: Icons.bookmark_remove_rounded,
          kind: SideToastKind.success,
        );
        return;
      }
      final excerptEnd = (offset + 120).clamp(offset, text.length);
      final excerpt = text
          .substring(offset, excerptEnd)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final locator = CanonicalLocator.fromComponents(
        format: content.contentType == 'text/html'
            ? BookFormat.html
            : BookFormat.txt,
        chapterId: _chapters[_chapterIndex].id,
        offset: offset,
        excerpt: excerpt,
        progression: text.isEmpty ? 0 : offset / text.length,
      );
      final bookmark = Bookmark(
        bookId: shelfBookId,
        pageNumber: _chapterIndex,
        canonicalLocator: LocatorCodec.encodeCanonicalLocator(locator),
        anchorKey: anchorKey,
        chapterIndex: _chapterIndex,
        chapterTitle: _chapters[_chapterIndex].title,
        excerpt: excerpt,
      );
      final id = await _bookmarkDao.insertBookmark(bookmark);
      if (!mounted) return;
      setState(() {
        _bookmarks = [..._bookmarks, bookmark.copyWith(id: id)]
          ..sort(
            (a, b) => (a.chapterIndex ?? a.pageNumber).compareTo(
              b.chapterIndex ?? b.pageNumber,
            ),
          );
      });
      showSideToast(
        context,
        context.l10n.bookmarkAdded,
        duration: const Duration(milliseconds: 1600),
        icon: Icons.bookmark_added_rounded,
        kind: SideToastKind.success,
      );
    } catch (error) {
      debugPrint('toggle source bookmark failed: $error');
    } finally {
      if (mounted) setState(() => _bookmarkBusy = false);
    }
  }

  Future<void> _deleteBookmark(Bookmark bookmark) async {
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

  Future<void> _jumpToBookmark(Bookmark bookmark) async {
    final raw = bookmark.canonicalLocator;
    final locator = raw == null
        ? null
        : LocatorCodec.decodeCanonicalLocator(raw);
    final chapterId = locator?.chapterId ?? locator?.textAnchor?.chapterId;
    var chapterIndex = chapterId == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (chapterIndex < 0) {
      chapterIndex = (bookmark.chapterIndex ?? bookmark.pageNumber).clamp(
        0,
        _chapters.length - 1,
      );
    }
    _restoreTextOffset = locator?.textAnchor?.startOffsetUtf16;
    if (_pageMode == BookSourcePageMode.verticalScroll && !_scrollByChapter) {
      await _jumpToVerticalChapter(
        chapterIndex,
        textOffset: _restoreTextOffset,
        progress: locator?.progression ?? 0,
      );
      return;
    }
    await _loadChapter(
      chapterIndex,
      restoreProgress: locator?.progression ?? 0,
    );
  }

  Future<void> _jumpToAnnotation(BookNote annotation) {
    final chapterId = readerAnnotationChapterId(annotation);
    var chapterIndex = chapterId == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (chapterIndex < 0 && annotation.chapter.trim().isNotEmpty) {
      chapterIndex = _chapters.indexWhere(
        (chapter) => chapter.title.trim() == annotation.chapter.trim(),
      );
    }
    return _jumpToBookmark(
      Bookmark(
        bookId: annotation.bookId,
        pageNumber: annotation.pageNumber ?? 0,
        canonicalLocator: annotation.canonicalLocator,
        chapterIndex: chapterIndex < 0 ? null : chapterIndex,
        chapterTitle: annotation.chapter,
        excerpt: annotation.content,
      ),
    );
  }

  Future<void> _showCatalog() async {
    if (_chapters.isEmpty) return;
    _controlsTimer?.cancel();
    // Prepared with the catalog so the interaction frame only mounts the
    // sheet instead of allocating one navigation model per chapter.
    final navigationChapters = _navigationChapters;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: _readerTheme.shadow.withValues(
        alpha: _readerTheme.brightness == Brightness.dark ? 0.72 : 0.38,
      ),
      showDragHandle: false,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.86,
          child: ReaderNavigationSheet(
            palette: _readerTheme,
            chapters: navigationChapters,
            currentChapterIndex: _chapterIndex,
            bookmarks: _bookmarks,
            annotations: _annotations,
            currentAnchorKey: _currentBookmarkAnchorKey,
            onChapterSelected: (index) {
              Navigator.of(sheetContext).pop();
              if (_pageMode == BookSourcePageMode.verticalScroll &&
                  !_scrollByChapter) {
                unawaited(_jumpToVerticalChapter(index));
              } else {
                unawaited(_loadChapter(index));
              }
            },
            onBookmarkSelected: (bookmark) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToBookmark(bookmark));
            },
            onBookmarkDeleted: (bookmark) async {
              await _deleteBookmark(bookmark);
              if (mounted) setSheetState(() {});
            },
            onAnnotationSelected: (annotation) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToAnnotation(annotation));
            },
            onAnnotationDeleted: (annotation) async {
              await _deleteAnnotation(annotation);
              if (mounted) setSheetState(() {});
            },
          ),
        ),
      ),
    );
  }

  String _readerThemeName(String themeId) {
    final customName = ReaderThemes.customThemeById(themeId)?.name.trim();
    if (customName != null && customName.isNotEmpty) return customName;
    return switch (themeId) {
      ReaderThemes.systemId => context.l10n.readerThemeFollowSystem,
      'mist' => context.l10n.readerThemeMist,
      'green' => context.l10n.readerThemeGreen,
      'rose' => context.l10n.readerThemeRose,
      'navy' => context.l10n.readerThemeNavy,
      'night' => context.l10n.readerThemeNight,
      'pureBlack' => context.l10n.readerThemePureBlack,
      'parchment' => context.l10n.readerThemeParchment,
      ReaderCustomTheme.themeId => context.l10n.readerThemeCustom,
      _ => context.l10n.readerThemeDay,
    };
  }

  Future<void> _updateReadingSettings({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    ReaderTextAlignment? textAlignment,
    int? firstLineIndent,
    int? paragraphSpacing,
    double? horizontalMargin,
    double? topMargin,
    double? bottomMargin,
    String? themeId,
    BookSourcePageMode? pageMode,
    bool? pullBookmarkEnabled,
    bool? tapPageAnimationEnabled,
    bool? tabletTwoPageEnabled,
  }) async {
    final repaginate =
        fontSize != null ||
        lineHeight != null ||
        letterSpacing != null ||
        textAlignment != null ||
        firstLineIndent != null ||
        paragraphSpacing != null ||
        horizontalMargin != null ||
        topMargin != null ||
        bottomMargin != null ||
        (tabletTwoPageEnabled != null &&
            tabletTwoPageEnabled != _tabletTwoPageEnabled) ||
        (pageMode != null && pageMode != _pageMode);
    final currentProgress = _currentReadingProgress;
    final currentTextOffset = _currentTextOffset;
    setState(() {
      _fontSize = fontSize ?? _fontSize;
      _lineHeight = (lineHeight ?? _lineHeight).clamp(1.4, 2.1);
      _letterSpacing = (letterSpacing ?? _letterSpacing).clamp(
        ReaderSettings.minLetterSpacing,
        ReaderSettings.maxLetterSpacing,
      );
      _textAlignment = textAlignment ?? _textAlignment;
      _firstLineIndent = (firstLineIndent ?? _firstLineIndent).clamp(0, 4);
      _paragraphSpacing = (paragraphSpacing ?? _paragraphSpacing).clamp(0, 2);
      _horizontalMargin = (horizontalMargin ?? _horizontalMargin).clamp(
        ReaderMarginSettings.horizontalMin,
        ReaderMarginSettings.horizontalMax,
      );
      _topMargin = (topMargin ?? _topMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      );
      _bottomMargin = (bottomMargin ?? _bottomMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      );
      _readerThemeId = ReaderThemes.byId(themeId ?? _readerThemeId).id;
      _pageMode = pageMode ?? _pageMode;
      _pullBookmarkEnabled = pullBookmarkEnabled ?? _pullBookmarkEnabled;
      _tapPageAnimationEnabled =
          tapPageAnimationEnabled ?? _tapPageAnimationEnabled;
      _tabletTwoPageEnabled = tabletTwoPageEnabled ?? _tabletTwoPageEnabled;
      if (repaginate) {
        _paginationKey = null;
        _paginatedPages = const [];
        _pagedLayouts.clear();
        _warmedPagedLayoutIndexes.clear();
        _verticalLayouts.clear();
        _restorePageProgress = currentProgress;
        _restorePagedPosition = true;
        _restoreTextOffset = currentTextOffset;
      }
    });
    unawaited(_syncVolumeKeyPaging());
    await _readerSettingsStore.save(_readerSettings);
    if (themeId != null && _readerSystemUiApplied) {
      await _applyReaderSystemUi();
    }
    if (repaginate) _restoreScrollProgress(currentProgress);
  }

  Future<void> _setTopBarStyle(ReaderTopBarStyle style) async {
    if (_topBarStyle == style) return;
    // 顶部预留高度随样式变化；完全沉浸在上下滚动时取消整个预留区域。
    final repaginate =
        _topChromeReserveFor(_topBarStyle) != _topChromeReserveFor(style) ||
        (_topBarStyle == ReaderTopBarStyle.hidden) !=
            (style == ReaderTopBarStyle.hidden);
    final currentProgress = _currentReadingProgress;
    final currentTextOffset = _currentTextOffset;
    setState(() {
      _topBarStyle = style;
      if (repaginate) {
        _paginationKey = null;
        _paginatedPages = const [];
        _pagedLayouts.clear();
        _warmedPagedLayoutIndexes.clear();
        _verticalLayouts.clear();
        _restorePageProgress = currentProgress;
        _restorePagedPosition = true;
        _restoreTextOffset = currentTextOffset;
      }
    });
    await ReaderSystemUiController.savePreference(style);
    await _applyReaderSystemUi();
    if (repaginate) _restoreScrollProgress(currentProgress);
  }

  Future<void> _setScrollByChapter(bool value) async {
    if (_scrollByChapter == value) return;
    final currentProgress = _currentReadingProgress;
    setState(() {
      _scrollByChapter = value;
      _restorePageProgress = currentProgress;
      _restorePagedPosition = true;
    });
    await _readerSettingsStore.saveScrollByChapter(value);
    _restoreScrollProgress(currentProgress);
  }

  String _pageModeSummary() {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return _scrollByChapter
          ? context.l10n.readerModeVerticalScrollHint
          : context.l10n.readerModeWholeBookScrollHint;
    }
    return _pageModeHint(_pageMode);
  }

  String _pageModeTitle(BookSourcePageMode mode) => switch (mode) {
    BookSourcePageMode.verticalScroll => context.l10n.pageTurningScroll,
    BookSourcePageMode.instantPage => context.l10n.readerModeHorizontalPage,
    BookSourcePageMode.horizontalSlide => context.l10n.pageTurningSlide,
    BookSourcePageMode.coverSlide => context.l10n.readerModeCoverSlide,
    BookSourcePageMode.pageCurl => context.l10n.readerModePageCurl,
  };

  String _pageModeHint(BookSourcePageMode mode) => switch (mode) {
    BookSourcePageMode.verticalScroll =>
      context.l10n.readerModeVerticalScrollHint,
    BookSourcePageMode.instantPage => context.l10n.readerModeHorizontalPageHint,
    BookSourcePageMode.horizontalSlide =>
      context.l10n.readerModeHorizontalSlideHint,
    BookSourcePageMode.coverSlide => context.l10n.readerModeCoverSlideHint,
    BookSourcePageMode.pageCurl => context.l10n.readerModePageCurlHint,
  };

  String _topBarStyleTitle(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.system => context.l10n.readerTopBarStyleSystem,
    ReaderTopBarStyle.reader => context.l10n.readerTopBarStyleReader,
    ReaderTopBarStyle.floating => context.l10n.readerTopBarStyleFloating,
    ReaderTopBarStyle.hidden => context.l10n.readerTopBarStyleHidden,
  };

  String _topBarStyleHint(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.system => context.l10n.readerTopBarStyleSystemHint,
    ReaderTopBarStyle.reader => context.l10n.readerTopBarStyleReaderHint,
    ReaderTopBarStyle.floating => context.l10n.readerTopBarStyleFloatingHint,
    ReaderTopBarStyle.hidden => context.l10n.readerTopBarStyleHiddenHint,
  };

  ReaderAloudController? _ensureReaderAloudController() {
    final existing = _readerAloudController;
    if (existing != null) return existing;
    ReaderAloudService aloudService;
    try {
      aloudService = context.read<ReaderAloudService>();
    } on ProviderNotFoundException {
      return null;
    }
    final controller = ReaderAloudController(
      engine: aloudService,
      notificationSink: AndroidReaderAloudNotification.instance,
      source: CallbackReaderAloudSource(
        bookTitle: _activeBook.title,
        chapterCount: () => _chapters.length,
        currentPosition: () async {
          if (_chapters.isEmpty) {
            return const ReaderAloudPosition(chapterIndex: 0, offset: 0);
          }
          final chapterIndex = _chapterIndex.clamp(0, _chapters.length - 1);
          final content = await _continuousContentFor(chapterIndex);
          final text =
              _readableChapterText[chapterIndex] ??
              await readableBookSourceChapterTextAsync(
                content,
                fallbackTitle: _chapters[chapterIndex].title,
              );
          final offset =
              _currentTextOffset ??
              (text.length * _currentReadingProgress).round();
          return ReaderAloudPosition(
            chapterIndex: chapterIndex,
            offset: offset.clamp(0, text.length),
          );
        },
        loadChapter: (index) async {
          if (index < 0 || index >= _chapters.length) return null;
          final content = await _continuousContentFor(index);
          final text =
              _readableChapterText[index] ??
              await readableBookSourceChapterTextAsync(
                content,
                fallbackTitle: _chapters[index].title,
              );
          return ReaderAloudChapter(
            index: index,
            id: _chapters[index].id,
            title: _chapters[index].title,
            text: text,
          );
        },
        revealPosition: _revealReaderAloudPosition,
        persistPosition: _persistReaderAloudPosition,
      ),
    )..addListener(_onReaderAloudChanged);
    _readerAloudController = controller;
    return controller;
  }

  void _onReaderAloudChanged() {
    final active = _readerAloudController?.isActive ?? false;
    final highlight = _readerAloudController?.highlight;
    if (!mounted) return;
    if (active == _readerAloudActive && highlight == _readerAloudHighlight) {
      return;
    }
    setState(() {
      _readerAloudActive = active;
      _readerAloudHighlight = highlight;
    });
  }

  Future<void> _revealReaderAloudPosition(ReaderAloudPosition position) async {
    if (!mounted || _chapters.isEmpty) return;
    final chapterIndex = position.chapterIndex.clamp(0, _chapters.length - 1);
    final content = await _continuousContentFor(chapterIndex);
    if (!mounted) return;
    final text =
        _readableChapterText[chapterIndex] ??
        await readableBookSourceChapterTextAsync(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    final offset = position.offset.clamp(0, text.length);
    final progress = text.isEmpty ? 0.0 : offset / text.length;

    if (_pageMode == BookSourcePageMode.verticalScroll) {
      await _jumpToVerticalChapter(
        chapterIndex,
        textOffset: offset,
        progress: progress,
      );
      return;
    }
    if (chapterIndex != _chapterIndex || _pagedViewportSize.isEmpty) {
      await _loadChapter(chapterIndex, restoreProgress: progress);
      return;
    }
    final layout = _pagedLayoutFor(chapterIndex, content, _pagedViewportSize);
    final pageIndex = bookSourcePageIndexForOffset(layout.pages, offset);
    _paginatedPages = layout.pages;
    _setPagedIndex(pageIndex, jumpPageView: true);
  }

  Future<void> _persistReaderAloudPosition(ReaderAloudPosition position) async {
    if (_chapters.isEmpty) return;
    final chapterIndex = position.chapterIndex.clamp(0, _chapters.length - 1);
    final content = await _continuousContentFor(chapterIndex);
    final text =
        _readableChapterText[chapterIndex] ??
        await readableBookSourceChapterTextAsync(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    final progress = text.isEmpty
        ? 0.0
        : (position.offset / text.length).clamp(0.0, 1.0);
    final progressSnapshot = BookSourceReadingProgress(
      chapterId: _chapters[chapterIndex].id,
      chapterIndex: chapterIndex,
      chapterProgress: progress,
      updatedAt: DateTime.now().toUtc(),
    );
    final shelfBookId = _shelfBookId;
    final chapterCount = _chapters.length;
    _progressSaveQueue = _progressSaveQueue.then((_) async {
      try {
        await widget.progressStore.save(
          sourceId: _activeSource.id,
          bookId: _activeBook.id,
          progress: progressSnapshot,
        );
        if (shelfBookId != null) {
          await _shelfService.updateShelfProgress(
            shelfBookId: shelfBookId,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            chapterProgress: progress,
          );
        }
      } catch (error) {
        debugPrint('save source reader aloud progress failed: $error');
      }
    });
    await _progressSaveQueue;
  }

  Future<void> _showReaderAloudPanel() async {
    final controller = _ensureReaderAloudController();
    if (controller == null) return;
    final ttsService = context.read<TtsService>();
    final aloudService = context.read<ReaderAloudService>();
    await showReaderAloudPanelSheet(
      context: context,
      controller: controller,
      ttsService: ttsService,
      aloudService: aloudService,
      palette: _readerTheme,
      themeData: _readerThemeData,
    );
  }

  /// 下载全书到本地（缓存离线阅读）。复用书架服务的下载逻辑，改为后台
  /// 静默下载 + 顶部悬浮进度浮窗，完成后用浮窗/Toast 提示，不再用挡路的
  /// 模态进度对话框（旧实现的对话框从不重建，进度条会一直卡在 0）。
  Future<void> _downloadCurrentBook() async {
    if (_chapters.isEmpty || _downloadingBook) return;
    _controlsTimer?.cancel();
    setState(() {
      _downloadingBook = true;
      _downloadProgress = 0;
    });
    _showDownloadOverlay();
    var succeeded = false;
    String? errorMessage;
    try {
      await _shelfService.downloadToLocal(
        source: _activeSource,
        book: _activeBook,
        onProgress: (completed, total) {
          _downloadProgress = total <= 0 ? 1.0 : completed / total;
          if (!mounted) return;
          _downloadOverlay?.markNeedsBuild();
          setState(() {});
        },
      );
      succeeded = true;
    } catch (error) {
      errorMessage = error.toString();
    }
    if (!mounted) return;
    _removeDownloadOverlay();
    setState(() {
      _downloadingBook = false;
      _downloadProgress = 0;
    });
    if (succeeded) {
      showSideToast(
        context,
        '《${_activeBook.title}》已缓存到本地',
        kind: SideToastKind.success,
      );
    } else {
      showSideToast(
        context,
        errorMessage == null ? '缓存失败' : '缓存失败：$errorMessage',
        kind: SideToastKind.error,
      );
    }
  }

  void _showDownloadOverlay() {
    _downloadOverlay?.remove();
    _downloadOverlay = OverlayEntry(builder: _buildCachingFloating);
    Overlay.of(context, rootOverlay: true).insert(_downloadOverlay!);
  }

  void _removeDownloadOverlay() {
    _downloadOverlay?.remove();
    _downloadOverlay = null;
  }

  Widget _buildCachingFloating(BuildContext overlayContext) {
    final scheme = Theme.of(overlayContext).colorScheme;
    return Positioned(
      left: 16,
      right: 16,
      top: MediaQuery.paddingOf(overlayContext).top + 12,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.35),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x223A1F7A),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                if (_downloadProgress <= 0)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                else
                  Icon(Icons.file_download_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在缓存《${_activeBook.title}》',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (_downloadProgress > 0) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: _downloadProgress.clamp(0.0, 1.0),
                            minHeight: 3,
                            color: scheme.primary,
                            backgroundColor: scheme.primary.withValues(
                              alpha: 0.12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 换源：解析书架书的多源信息并打开换源面板。
  Future<void> _showSwitchSourcePanel() async {
    if (_chapters.isEmpty) return;
    _controlsTimer?.cancel();
    var shelfBook = _shelfBook;
    if (shelfBook == null) {
      try {
        shelfBook = await _shelfService.findShelfBook(
          sourceId: _activeSource.id,
          sourceBookId: _activeBook.id,
        );
        if (mounted) _shelfBook = shelfBook;
      } catch (error) {
        debugPrint('resolve shelf book for switch panel failed: $error');
      }
    }
    if (!mounted) return;
    final shelfPointers =
        shelfBook?.decodeAllSources() ?? const <SourcedBookPointer>[];
    final pointers = _mergePointers([...shelfPointers, ..._extraAlternates]);
    // 若书架书尚未记录这些备选源，则补全并存档；下次从书架打开即可直接用。
    if (shelfBook != null && pointers.length > shelfPointers.length) {
      try {
        final updated = shelfBook!.withMultiSourceList(pointers).copyWith(
          currentSourceId: _activeSource.id,
          sourceId: _activeSource.id,
          sourceBookId: _activeBook.id,
        );
        await _bookDao.updateBook(updated);
        _shelfBook = updated;
      } catch (error) {
        debugPrint('persist alternates on switch panel open failed: $error');
      }
    }
    List<RegisteredBookSource> registered;
    try {
      registered = await BookSourceRegistry().load();
    } catch (error) {
      debugPrint('load registered sources for switch panel failed: $error');
      registered = const [];
    }
    if (!mounted) return;
    final registeredMap = <String, RegisteredBookSource>{
      for (final source in registered) source.id: source,
    };
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: _readerTheme.shadow.withValues(
        alpha: _readerTheme.brightness == Brightness.dark ? 0.72 : 0.38,
      ),
      showDragHandle: false,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (sheetContext) => _BookSourceSwitchSheet(
        palette: _readerTheme,
        pointers: pointers,
        registeredSources: registeredMap,
        currentSourceId: _activeSource.id,
        currentChapter: _chapters[_chapterIndex],
        currentChapterIndex: _chapterIndex,
        currentChaptersLength: _chapters.length,
        client: _client,
        fallbackBookTitle: _activeBook.title,
        fallbackBookAuthor: _activeBook.author,
        onSwitch: (source, pointer, book) => _applySourceSwitch(
          targetSource: source,
          pointer: pointer,
          targetBook: book,
        ),
        onSearchMore: _onSearchMoreSources,
      ),
    );
  }

  // 换源面板里点击"自动搜索其他源"后回调：把新发现的源一并储存到书架与本次会话。
  Future<void> _onSearchMoreSources(
    List<SourcedBookPointer> allSources,
  ) async {
    final merged = _mergePointers([..._extraAlternates, ...allSources]);
    _extraAlternates = merged;
    final shelfBook = _shelfBook;
    if (shelfBook == null) return;
    try {
      final updated = shelfBook
          .withMultiSourceList(_mergePointers([
            ...shelfBook.decodeAllSources(),
            ...allSources,
          ]))
          .copyWith(
            currentSourceId: _activeSource.id,
            sourceId: _activeSource.id,
            sourceBookId: _activeBook.id,
          );
      await _bookDao.updateBook(updated);
      _shelfBook = updated;
    } catch (error) {
      debugPrint('persist searched alternate sources failed: $error');
    }
  }

  /// 按 sourceId 去重合并指针，保留先出现的项；保证主源在前。
  List<SourcedBookPointer> _mergePointers(
    Iterable<SourcedBookPointer> sources,
  ) {
    final bySource = <String, SourcedBookPointer>{};
    for (final p in sources) {
      bySource.putIfAbsent(p.sourceId, () => p);
    }
    return bySource.values.toList(growable: false);
  }

  // 执行真正的换源：拉取目标源目录 → 对齐 → 刷新阅读器状态并跳转对齐章节。
  // 返回 true 表示切换成功；失败时调用方（换源面板）会保留打开并提示。
  Future<bool> _applySourceSwitch({
    required RegisteredBookSource targetSource,
    required SourcedBookPointer pointer,
    required BookSourceBook targetBook,
  }) async {
    if (_chapters.isEmpty) return false;
    final currentChapter = _chapters[_chapterIndex.clamp(0, _chapters.length - 1)];
    final switcher = BookSourceSwitcher(_client);
    try {
      final result = await switcher.switchTo(
        targetSource: targetSource,
        targetPointer: pointer,
        currentChapter: currentChapter,
        currentChapterIndexInBook: _chapterIndex,
        currentChaptersLength: _chapters.length,
      );
      final targetChapters = [...result.targetChapters]
        ..sort((a, b) => a.order.compareTo(b.order));
      var alignedIndex = targetChapters.indexWhere(
        (chapter) => chapter.id == result.alignedChapter.id,
      );
      if (alignedIndex < 0) alignedIndex = 0;
      // 持久化到书架（如有），让下次从书架打开时直接进入切换后的源。
      final shelfBook = _shelfBook;
      if (shelfBook != null) {
        try {
          final switched = shelfBook.copyWith(
            currentSourceId: pointer.sourceId,
            sourceId: pointer.sourceId,
            sourceBookId: pointer.bookId,
            sourceJson: jsonEncode(targetSource.toJson()),
            sourceBookJson: jsonEncode(targetBook.toJson()),
          );
          await _bookDao.updateBook(switched);
          _shelfBook = switched;
          LibraryEventBus().notifyLibraryChanged();
        } catch (error) {
          debugPrint('persist source switch to shelf failed: $error');
        }
      }
      if (!mounted) return false;
      final navigationChapters = List<ReaderNavigationChapter>.generate(
        targetChapters.length,
        (index) => ReaderNavigationChapter(
          title: targetChapters[index].title,
          index: index,
          id: targetChapters[index].id,
        ),
        growable: false,
      );
      _contentGeneration++;
      setState(() {
        _activeSource = targetSource;
        _activeBook = targetBook;
        _chapters = targetChapters;
        _navigationChapters = navigationChapters;
        _chapterIndex = alignedIndex;
        _content = null;
        _error = null;
        _paginatedPages = const [];
        _paginationKey = null;
        _pageIndex = 0;
        _pageCount = 1;
        _restorePageProgress = 0;
        _restorePagedPosition = true;
        _prefetchedContent.clear();
        _readableChapterText.clear();
        _continuousContentLoads.clear();
        _pagedLayouts.clear();
        _verticalLayouts.clear();
        _verticalPartKeys.clear();
        _queuedPagedLayoutWarms.clear();
        _warmedPagedLayoutIndexes.clear();
        _pagedLayoutWarmTimer?.cancel();
        _pagedLayoutWarmTimerIndex = null;
      });
      showSideToast(
        context,
        result.isApproximate
            ? '已切换到「${targetSource.name}」（对齐度 ${(result.confidence * 100).round()}%）'
            : '已切换到「${targetSource.name}」',
        duration: const Duration(milliseconds: 1800),
        icon: Icons.swap_horiz_rounded,
      );
      await _loadChapter(alignedIndex, saveCurrent: false);
      return true;
    } catch (error) {
      if (!mounted) return false;
      showSideToast(
        context,
        '换源失败：$error',
        duration: const Duration(milliseconds: 2400),
        icon: Icons.error_outline_rounded,
        kind: SideToastKind.warning,
      );
      return false;
    }
  }

  Future<void> _showReadingSettings() async {
    _controlsTimer?.cancel();
    final selectedMode = await showModalBottomSheet<BookSourcePageMode>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => ReaderSettingsSheet(
        title: context.l10n.readingSettings,
        tabThemeLabel: context.l10n.readerSettingsTabTheme,
        tabTextLabel: context.l10n.readerSettingsTabText,
        tabLayoutLabel: context.l10n.readerSettingsTabLayout,
        tabPagingLabel: context.l10n.readerSettingsTabPaging,
        advancedTypographyTitle: context.l10n.readerSettingsAdvancedTypography,
        themeDescription: context.l10n.readerThemeDescription,
        pageModeTitle: context.l10n.pageTurningMode,
        pageModeSummary: _pageModeSummary(),
        topBarStyleTitle: context.l10n.readerTopBarStyleTitle,
        topBarStyleSummary: _topBarStyleTitle(_topBarStyle),
        pullBookmarkTitle: context.l10n.readerPullBookmarkTitle,
        pullBookmarkHint: context.l10n.readerPullBookmarkHint,
        tapPageAnimationTitle: context.l10n.readerTapAnimationTitle,
        tapPageAnimationHint: context.l10n.readerTapAnimationHint,
        tapZonesTitle: context.l10n.tapZoneSettings,
        tapZonesHint: context.l10n.tapZoneSettingsHint,
        showTabletTwoPageToggle: ReaderLayoutBreakpoints.isTablet(
          MediaQuery.sizeOf(context),
        ),
        tabletTwoPageTitle: context.l10n.readerTabletTwoPageTitle,
        tabletTwoPageHint: context.l10n.readerTabletTwoPageHint,
        fontSizeLabel: context.l10n.fontSizeLabel,
        lineHeightLabel: context.l10n.lineSpacingLabel,
        letterSpacingLabel: context.l10n.letterSpacingLabel,
        textAlignmentLabel: context.l10n.textAlignmentLabel,
        textAlignmentNaturalLabel: context.l10n.textAlignmentNatural,
        textAlignmentJustifiedLabel: context.l10n.textAlignmentJustified,
        firstLineIndentLabel: context.l10n.firstLineIndentLabel,
        paragraphSpacingLabel: context.l10n.paragraphSpacingLabel,
        horizontalMarginLabel: context.l10n.readerHorizontalMarginLabel,
        topMarginLabel: context.l10n.readerTopMarginLabel,
        bottomMarginLabel: context.l10n.readerBottomMarginLabel,
        themeId: _readerThemeId,
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        letterSpacing: _letterSpacing,
        textAlignment: _textAlignment,
        firstLineIndent: _firstLineIndent,
        paragraphSpacing: _paragraphSpacing,
        horizontalMargin: _horizontalMargin,
        topMargin: _topMargin,
        bottomMargin: _bottomMargin,
        pullBookmarkEnabled: _pullBookmarkEnabled,
        tapPageAnimationEnabled: _tapPageAnimationEnabled,
        tabletTwoPageEnabled: _tabletTwoPageEnabled,
        themeLabelFor: _readerThemeName,
        onThemeChanged: (themeId) =>
            unawaited(_updateReadingSettings(themeId: themeId)),
        onCustomThemeTap: _showCustomThemeEditor,
        onPageModeTap: _showPageModeSettings,
        onTopBarStyleTap: _showTopBarStyleSettings,
        onTapZonesTap: () => unawaited(_showTapZoneSettings()),
        onFontSizeChanged: (value) =>
            unawaited(_updateReadingSettings(fontSize: value)),
        onLineHeightChanged: (value) =>
            unawaited(_updateReadingSettings(lineHeight: value)),
        onLetterSpacingChanged: (value) =>
            unawaited(_updateReadingSettings(letterSpacing: value)),
        onTextAlignmentChanged: (value) =>
            unawaited(_updateReadingSettings(textAlignment: value)),
        onFirstLineIndentChanged: (value) =>
            unawaited(_updateReadingSettings(firstLineIndent: value)),
        onParagraphSpacingChanged: (value) =>
            unawaited(_updateReadingSettings(paragraphSpacing: value)),
        onHorizontalMarginChanged: (value) =>
            unawaited(_updateReadingSettings(horizontalMargin: value)),
        onTopMarginChanged: (value) =>
            unawaited(_updateReadingSettings(topMargin: value)),
        onBottomMarginChanged: (value) =>
            unawaited(_updateReadingSettings(bottomMargin: value)),
        onPullBookmarkChanged: (value) =>
            unawaited(_updateReadingSettings(pullBookmarkEnabled: value)),
        onTapPageAnimationChanged: (value) =>
            unawaited(_updateReadingSettings(tapPageAnimationEnabled: value)),
        onTabletTwoPageChanged: (value) =>
            unawaited(_updateReadingSettings(tabletTwoPageEnabled: value)),
      ),
    );
    if (mounted) setState(() => _controlsVisible = false);
    if (!mounted) return;
    await _applyReaderSystemUi();
    if (selectedMode == null || !mounted) return;
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _updateReadingSettings(pageMode: selectedMode);
  }

  Future<void> _showCustomThemeEditor() async {
    Navigator.of(context).pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final result = await Navigator.of(context).push<ReaderCustomThemesResult>(
      MaterialPageRoute(
        builder: (_) => ReaderCustomThemesPage(
          initialThemes: ReaderThemes.customThemes,
          initialThemeOrder: ReaderThemes.themeOrder,
          initialSelectedThemeId: _readerThemeId,
        ),
      ),
    );
    if (result == null || !mounted) return;
    ReaderThemes.setCustomThemes(result.themes);
    ReaderThemes.setThemeOrder(result.themeOrder);
    final nextThemeId =
        result.selectedThemeId ??
        (ReaderCustomTheme.isCustomThemeId(_readerThemeId) &&
                ReaderThemes.customThemeById(_readerThemeId) == null
            ? ReaderSettings.defaultThemeId
            : _readerThemeId);
    await _updateReadingSettings(themeId: nextThemeId);
    await _applyReaderSystemUi();
  }

  Future<void> _showPageModeSettings() async {
    var previewScrollByChapter = _scrollByChapter;
    final selectedMode = await showModalBottomSheet<BookSourcePageMode>(
      context: context,
      backgroundColor: _readerTheme.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (menuContext) => StatefulBuilder(
        builder: (context, setMenuState) => ReaderPageModeSheet(
          palette: _readerTheme,
          title: context.l10n.pageTurningMode,
          selectedMode: _pageMode,
          titleFor: _pageModeTitle,
          hintFor: (mode) => mode == BookSourcePageMode.verticalScroll
              ? (previewScrollByChapter
                    ? context.l10n.readerModeVerticalScrollHint
                    : context.l10n.readerModeWholeBookScrollHint)
              : _pageModeHint(mode),
          onSelected: (mode) => Navigator.of(menuContext).pop(mode),
          scrollByChapter: previewScrollByChapter,
          scrollByChapterTitle: context.l10n.readerScrollByChapterTitle,
          scrollByChapterOnHint: context.l10n.readerScrollByChapterOnHint,
          scrollByChapterOffHint: context.l10n.readerScrollByChapterOffHint,
          onScrollByChapterChanged: (value) {
            setMenuState(() => previewScrollByChapter = value);
            unawaited(_setScrollByChapter(value));
          },
        ),
      ),
    );
    if (selectedMode == null || !mounted) return;
    Navigator.of(context).pop(selectedMode);
  }

  Future<void> _showTopBarStyleSettings() async {
    final selectedStyle = await showModalBottomSheet<ReaderTopBarStyle>(
      context: context,
      backgroundColor: _readerTheme.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (menuContext) => ReaderTopBarStyleSheet(
        palette: _readerTheme,
        title: context.l10n.readerTopBarStyleTitle,
        selectedStyle: _topBarStyle,
        titleFor: _topBarStyleTitle,
        hintFor: _topBarStyleHint,
        onSelected: (style) => Navigator.of(menuContext).pop(style),
      ),
    );
    if (selectedStyle == null || !mounted) return;
    Navigator.of(context).pop();
    await _setTopBarStyle(selectedStyle);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      key: const ValueKey('reader-system-ui-region'),
      value: _readerSystemUiOverlayStyle,
      child: PopScope(
        canPop: _canPopWithoutPrompt && !_tapZoneEditorVisible,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            BookOpenTransition.beginExit();
          } else if (_tapZoneEditorVisible) {
            setState(() => _tapZoneEditorVisible = false);
          } else {
            unawaited(_requestExit());
          }
        },
        child: Theme(
          data: _readerThemeData,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // The reader page has no text field of its own, but Scaffold
            // shrinks `body` for ANY keyboard inset by default, including
            // one raised by a TextField inside a modal sheet stacked on top
            // (e.g. the TOC search box). That resize changes the layout
            // constraints the pagination below reacts to on every animation
            // frame, forcing a full chapter re-pagination each frame.
            resizeToAvoidBottomInset: false,
            body: ReaderThemeBackground(
              palette: _readerTheme,
              child: ReaderPullBookmark(
                enabled:
                    _pullBookmarkEnabled &&
                    _chapters.isNotEmpty &&
                    !_tapZoneEditorVisible,
                bookmarked: _currentPageIsBookmarked,
                busy: _bookmarkBusy,
                palette: _readerTheme,
                addHint: context.l10n.readerPullBookmarkAddHint,
                removeHint: context.l10n.readerPullBookmarkRemoveHint,
                releaseHint: context.l10n.readerPullBookmarkReleaseHint,
                onTriggered: () => unawaited(_toggleCurrentBookmark()),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ReaderTapObserver(
                        key: const ValueKey('book-source-reader-tap-observer'),
                        enabled:
                            _readerFontReady &&
                            !_loadingCatalog &&
                            (!_loadingContent || _content != null) &&
                            _error == null &&
                            _chapters.isNotEmpty &&
                            _content != null &&
                            !_annotationInteractionActive,
                        onTap: _handleReaderTap,
                        child: Semantics(
                          label: _activeBook.title,
                          child: _buildBodyCrossfade(),
                        ),
                      ),
                    ),
                    if (_showLeafFloatingStatus &&
                        _pageMode == BookSourcePageMode.verticalScroll)
                      ReaderFloatingStatusOverlay(
                        palette: _readerTheme,
                        status: _leafStatusController.value,
                        safeArea: _readerSafeArea,
                        horizontalPadding: _floatingStatusHorizontalPadding,
                      ),
                    ReaderChromeOverlay(
                      palette: _readerTheme,
                      visible: _controlsVisible,
                      title: _chapters.isEmpty
                          ? _activeBook.title
                          : _chapters[_chapterIndex.clamp(
                                  0,
                                  _chapters.length - 1,
                                )]
                                .title,
                      statusBottom: _readerSafeArea.pageNumberBottom,
                      showViewportStatus:
                          _pageMode == BookSourcePageMode.verticalScroll &&
                          _topBarStyle != ReaderTopBarStyle.hidden,
                      showViewportTitle:
                          _pageMode == BookSourcePageMode.verticalScroll &&
                          _topBarStyle == ReaderTopBarStyle.reader,
                      viewportTitleTop: _readerSafeArea.readerTopBarTop,
                      viewportTitleKey: const ValueKey(
                        'book-source-viewport-title',
                      ),
                      readerStatus: _leafStatusController.value,
                      viewportStatusHorizontalPadding: math.max(
                        24,
                        _horizontalMargin,
                      ),
                      statusBuilder: _buildReaderStatusText,
                      onBack: () => unawaited(_requestExit()),
                      onBookmark: _chapters.isEmpty
                          ? null
                          : () => unawaited(_toggleCurrentBookmark()),
                      onTableOfContents: _chapters.isEmpty
                          ? null
                          : _showCatalog,
                      onReadAloud:
                          _chapters.isEmpty || !isReaderAloudPlatformSupported
                          ? null
                          : () => unawaited(_showReaderAloudPanel()),
                      readAloudTooltip: context.l10n.ttsReading,
                      readAloudActive: _readerAloudActive,
                      onDownload: _chapters.isEmpty
                          ? null
                          : () => unawaited(_downloadCurrentBook()),
                      downloadTooltip: '缓存本书',
                      onSwitchSource: _chapters.isEmpty
                          ? null
                          : _showSwitchSourcePanel,
                      switchSourceTooltip: '换源',
                      onSettings: _showReadingSettings,
                      backTooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      bookmarkTooltip: _currentPageIsBookmarked
                          ? context.l10n.bookmarkRemoved
                          : context.l10n.readerAddBookmark,
                      tableOfContentsTooltip: context.l10n.readerToolbarTOC,
                      settingsTooltip: context.l10n.readingSettings,
                      bookmarked: _currentPageIsBookmarked,
                      bookmarkBusy: _bookmarkBusy,
                      chapterLabel: _chapters.isEmpty
                          ? _activeBook.title
                          : _chapters[
                                _chapterIndex.clamp(0, _chapters.length - 1)
                              ].title,
                      chapterProgress: _currentChapterProgress,
                      bookProgress: _currentBookProgress,
                      onPreviousChapter:
                          _chapters.isNotEmpty && _chapterIndex > 0
                          ? () => unawaited(
                              _loadChapter(_chapterIndex - 1, restoreProgress: 1),
                            )
                          : null,
                      onNextChapter:
                          _chapters.isNotEmpty &&
                              _chapterIndex < _chapters.length - 1
                          ? () => unawaited(
                              _loadChapter(_chapterIndex + 1, restoreProgress: 0),
                            )
                          : null,
                      onSliderSeek: _chapters.isEmpty
                          ? null
                          : (fraction) {
                              final f = fraction.clamp(0.0, 0.999);
                              final idx = (f * _chapters.length)
                                  .floor()
                                  .clamp(0, _chapters.length - 1);
                              unawaited(_loadChapter(
                                idx,
                                restoreProgress:
                                    (f * _chapters.length - idx).clamp(0.0, 1.0),
                              ));
                            },
                      topKey: const ValueKey('book-source-top-controls'),
                      bottomKey: const ValueKey('book-source-bottom-controls'),
                      statusKey: const ValueKey('book-source-reader-status'),
                    ),
                    if (_tapZoneEditorVisible)
                      Positioned.fill(
                        child: ReaderTapZoneEditorOverlay(
                          palette: _readerTheme,
                          zones: _tapZones,
                          onZonesChanged: _setTapZones,
                          onClose: () =>
                              setState(() => _tapZoneEditorVisible = false),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _bodyTransitionKey {
    if (!_readerFontReady ||
        _loadingCatalog ||
        (_loadingContent && _content == null)) {
      return _showOpeningLoader ? 'loading' : 'loading-placeholder';
    }
    if (_error != null) return 'error';
    if (_chapters.isEmpty || _content == null) return 'empty';
    return 'content';
  }

  Widget _buildBodyCrossfade() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: KeyedSubtree(
        key: ValueKey('book-source-reader-$_bodyTransitionKey'),
        child: _buildBody(),
      ),
    );
  }

  void _scheduleOpeningContentReady() {
    if (_openingContentReadyScheduled) return;
    _openingContentReadyScheduled = true;
    _openingLoaderTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openingContentReadyTimer = Timer(_openingContentSettleDelay, () {
        if (mounted) BookOpenTransition.markReaderContentReady(context);
      });
    });
  }

  /// 打开动画封面仍在飞行时，把整章排版（`_applyLoadedChapter` 内同步执行，
  /// 数十毫秒）延后到封面到达静止停留画面之后；已有分页缓存或不在打开
  /// 转场中时立即返回 false，不引入任何延迟。
  Future<bool> _deferChapterApplyForOpeningFlight(int index) async {
    if (!mounted || _pagedLayouts[index] != null) return false;
    final listenable = BookOpenTransition.openingCoverHoldListenableOf(context);
    if (listenable.value) return false;
    final completer = Completer<void>();
    late final VoidCallback onChanged;
    onChanged = () {
      if (!listenable.value) return;
      listenable.removeListener(onChanged);
      if (!completer.isCompleted) completer.complete();
    };
    listenable.addListener(onChanged);
    await completer.future;
    return true;
  }

  Widget _buildBody() {
    if (!_readerFontReady ||
        _loadingCatalog ||
        (_loadingContent && _content == null)) {
      if (!_showOpeningLoader) {
        return GestureDetector(
          key: const ValueKey('book-source-reader-loading-placeholder'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: const SizedBox.expand(),
        );
      }
      return GestureDetector(
        key: const ValueKey('book-source-reader-loading-surface'),
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: ReaderOpeningLoader(palette: _readerTheme),
      );
    }
    _scheduleOpeningContentReady();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: _readerTheme.secondaryText,
              ),
              const SizedBox(height: 12),
              Text(
                _error.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _chapters.isEmpty
                    ? _initialize
                    : () => _loadChapter(_chapterIndex, saveCurrent: false),
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_chapters.isEmpty || _content == null) {
      return Center(child: Text(context.l10n.readerNoContent));
    }

    final content = _content!;
    // 漫画章节：正文是图片列表（imageUrls 非空），不走文本排版/分页，直接渲染
    // 网络漫画翻页视图。翻到最后一页继续翻则进入下一章。
    if (content.isImageChapter && content.imageUrls.isNotEmpty) {
      return NetworkComicViewer(
        imageUrls: content.imageUrls,
        initialPage: _pageIndex,
        background: _readerTheme.brightness == Brightness.dark
            ? _readerTheme.background
            : const Color(0xFF111111),
        loadPage: (index) => _client.fetchImageBytes(
          _activeSource,
          content.imageUrls[index],
        ),
        onEndReached: _chapterIndex + 1 < _chapters.length
            ? () => unawaited(
                _loadChapter(_chapterIndex + 1, restoreProgress: 0),
              )
            : null,
      );
    }
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          _verticalViewportSize = viewport;
          if (!_scrollByChapter) {
            return _buildVerticalReadingWindow(_buildVerticalBook(viewport));
          }
          final layout = _verticalLayoutFor(_chapterIndex, content, viewport);
          return _buildVerticalReadingWindow(
            _buildVerticalPageList(layout, viewport),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final usesTwoPageLayout = _shouldUseTwoPageLayout(constraints.biggest);
        _usesTwoPageLayout = usesTwoPageLayout;
        final paginationViewport = _paginationViewport(
          constraints.biggest,
          usesTwoPageLayout,
        );
        if (_pagedViewportSize != paginationViewport) {
          _pagedViewportSize = paginationViewport;
          _warmedPagedLayoutIndexes.clear();
        }
        _ensurePagination(paginationViewport, content: content);
        _schedulePagedLayoutWarm(_chapterIndex + 1);
        return switch (_pageMode) {
          BookSourcePageMode.instantPage => _buildInstantReader(),
          BookSourcePageMode.horizontalSlide => _buildSlideReader(),
          BookSourcePageMode.coverSlide => _buildCoverReader(),
          BookSourcePageMode.pageCurl => _buildCurlReader(
            usesTwoPageLayout: usesTwoPageLayout,
          ),
          BookSourcePageMode.verticalScroll => const SizedBox.shrink(),
        };
      },
    );
  }

  TextStyle get _bodyTextStyle => TextStyle(
    inherit: false,
    fontFamily: _readerFont.family,
    fontFamilyFallback: readerFontFamilyFallbacks(
      fontFamily: _readerFont.family,
      configuredFallbacks: _readerFont.fallbackFamilies,
      locale: Localizations.maybeLocaleOf(context),
    ),
    color: _readerTheme.text,
    fontSize: _fontSize,
    height: _lineHeight,
    letterSpacing: _letterSpacing,
  );

  TextAlign get _bodyTextAlign => switch (_textAlignment) {
    ReaderTextAlignment.natural => TextAlign.start,
    ReaderTextAlignment.justified => TextAlign.justify,
  };

  NativeTextFlowStyle _bodyTextFlowStyle({
    TextDirection? direction,
    TextScaler? textScaler,
    Locale? locale,
  }) => NativeTextFlowStyle(
    textDirection: direction ?? Directionality.of(context),
    textScaler: textScaler ?? readerBodyTextScaler,
    locale: locale ?? Localizations.maybeLocaleOf(context),
    strutStyle: readerStrutStyle(_bodyTextStyle),
    textHeightBehavior: readerTextHeightBehavior,
    textAlign: _bodyTextAlign,
  );

  ReaderViewportChromeMetrics get _verticalChrome =>
      ReaderViewportChromeMetrics(
        safeArea: _readerSafeArea,
        immersive: _topBarStyle == ReaderTopBarStyle.hidden,
        reservesTitle: _topBarStyle == ReaderTopBarStyle.reader,
      );

  double _verticalPageExtentFor(Size viewport) =>
      _verticalChrome.contentHeight(viewport.height);

  Widget _buildVerticalReadingWindow(Widget child) {
    final chrome = _verticalChrome;
    return Padding(
      key: const ValueKey('book-source-vertical-reading-window'),
      padding: EdgeInsets.only(
        top: chrome.contentTop,
        bottom: chrome.contentBottom,
      ),
      child: ClipRect(child: child),
    );
  }

  ReaderVisibleItemPosition _readerPosition(ItemPosition position) =>
      ReaderVisibleItemPosition(
        index: position.index,
        leadingEdge: position.itemLeadingEdge,
        trailingEdge: position.itemTrailingEdge,
      );

  GlobalKey _verticalPartKey(int chapterIndex, int partIndex) =>
      _verticalPartKeys.putIfAbsent('$chapterIndex:$partIndex', GlobalKey.new);

  RenderParagraph? _verticalParagraph(int chapterIndex, int partIndex) {
    final root = _verticalPartKey(chapterIndex, partIndex).currentContext;
    if (root == null) return null;
    RenderParagraph? result;
    void visit(Element element) {
      if (result != null) return;
      final renderObject = element.renderObject;
      if (renderObject is RenderParagraph) {
        result = renderObject;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return result;
  }

  int _verticalOffsetAtViewportCenter(
    int chapterIndex,
    int partIndex,
    BookSourceTextPage page,
  ) {
    final paragraph = _verticalParagraph(chapterIndex, partIndex);
    if (paragraph == null || !paragraph.hasSize || page.text.isEmpty) {
      return page.startOffset;
    }
    final center = Offset(
      paragraph.size.width / 2,
      MediaQuery.sizeOf(context).height / 2 -
          paragraph.localToGlobal(Offset.zero).dy,
    );
    return page.sourceOffsetForTextOffset(
      paragraph.getPositionForOffset(center).offset,
    );
  }

  double? _verticalCaretOffset(
    int chapterIndex,
    int partIndex,
    BookSourceTextPage page,
    int sourceOffset,
  ) {
    final paragraph = _verticalParagraph(chapterIndex, partIndex);
    if (paragraph == null || !paragraph.hasSize || page.text.isEmpty) {
      return null;
    }
    return paragraph
        .getOffsetForCaret(
          TextPosition(offset: page.textOffsetForSourceOffset(sourceOffset)),
          Rect.zero,
        )
        .dy;
  }

  List<BookSourceTextPage> _continuousTextParts(
    String text, {
    required double width,
    required TextDirection direction,
    required Locale? locale,
  }) {
    if (text.isEmpty) {
      return const [BookSourceTextPage(text: '')];
    }
    return paginateBookSourceText(
      text,
      width: width,
      firstPageHeight: 0,
      pageHeight: 0,
      style: _bodyTextStyle,
      textDirection: direction,
      textScaler: readerBodyTextScaler,
      textAlign: _bodyTextAlign,
      locale: locale,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      includeChapterTitlePage: false,
    );
  }

  _BookSourceVerticalLayout _verticalLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    final chrome = _verticalChrome;
    final width = readerTextContentWidth(viewport.width, _horizontalMargin);
    final height = _verticalPageExtentFor(viewport);
    const textScaler = readerBodyTextScaler;
    final locale = Localizations.maybeLocaleOf(context);
    final direction = Directionality.of(context);
    final fingerprint = ReaderLayoutFingerprint(
      contentKey: _chapters[chapterIndex].id,
      viewport: Size(width, height),
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      letterSpacing: _letterSpacing,
      textAlign: _bodyTextAlign,
      horizontalMargin: _horizontalMargin,
      verticalMargin: _topMargin + _bottomMargin,
      textScaler: textScaler,
      locale: locale,
      pageMode: BookSourcePageMode.verticalScroll,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      textDirection: direction,
      extra: '${chrome.paginationSignature}:${_readerFont.id}',
    ).cacheKey('book-source-vertical-v2');
    final cached = _verticalLayouts[chapterIndex];
    if (cached?.fingerprint == fingerprint) return cached!;
    final text =
        _readableChapterText[chapterIndex] ??
        readableBookSourceChapterText(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    final pages = _continuousTextParts(
      text,
      width: width,
      direction: direction,
      locale: locale,
    );
    final layout = _BookSourceVerticalLayout(
      fingerprint: fingerprint,
      pages: pages,
    );
    _verticalLayouts[chapterIndex] = layout;
    return layout;
  }

  void _restoreVerticalPosition(
    _BookSourceVerticalLayout layout, {
    required bool wholeBook,
  }) {
    if (!_restorePagedPosition) return;
    final restoreOffset = _restoreTextOffset;
    final target = restoreOffset != null
        ? bookSourcePageIndexForOffset(layout.pages, restoreOffset)
        : ((layout.pages.length - 1) * _restorePageProgress).round();
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = target.clamp(0, layout.pages.length - 1);
    _pageIndex = _verticalPageIndex;
    _restorePagedPosition = false;
    _restoreTextOffset = null;
    final textLength = _readableChapterText[_chapterIndex]?.length ?? 0;
    final restoredProgress = restoreOffset != null && textLength > 0
        ? (restoreOffset / textLength).clamp(0.0, 1.0)
        : _restorePageProgress;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollProgress.value = restoredProgress;
      if (!wholeBook && _verticalPageScrollController.isAttached) {
        _verticalPageScrollController.jumpTo(index: _verticalPageIndex);
      } else if (_verticalChapterScrollController.isAttached) {
        _verticalChapterScrollController.jumpTo(index: _chapterIndex);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final targetContext = _verticalPartKey(
          _chapterIndex,
          _verticalPageIndex,
        ).currentContext;
        if (targetContext == null) return;
        unawaited(
          Scrollable.ensureVisible(
            targetContext,
            alignment: 0,
            duration: Duration.zero,
          ),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final sourceOffset =
              restoreOffset ?? (restoredProgress * textLength).round();
          final caretOffset = _verticalCaretOffset(
            _chapterIndex,
            _verticalPageIndex,
            layout.pages[_verticalPageIndex],
            sourceOffset,
          );
          final currentTarget = _verticalPartKey(
            _chapterIndex,
            _verticalPageIndex,
          ).currentContext;
          final scrollable = currentTarget == null
              ? null
              : Scrollable.maybeOf(currentTarget);
          if (caretOffset != null && scrollable != null) {
            scrollable.position.jumpTo(
              (scrollable.position.pixels + caretOffset).clamp(
                scrollable.position.minScrollExtent,
                scrollable.position.maxScrollExtent,
              ),
            );
          }
        });
      });
    });
  }

  void _onVerticalPagePositionsChanged() {
    if (!mounted ||
        _pageMode != BookSourcePageMode.verticalScroll ||
        !_scrollByChapter) {
      return;
    }
    final layout = _verticalLayouts[_chapterIndex];
    if (layout == null || layout.pages.isEmpty) return;
    final primary = pickPrimaryReaderItem(
      _verticalPagePositionsListener.itemPositions.value.map(_readerPosition),
    );
    if (primary == null) return;
    final nextPage = primary.index.clamp(0, layout.pages.length - 1);
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = nextPage;
    final textLength = _readableChapterText[_chapterIndex]?.length ?? 0;
    final offset = _verticalOffsetAtViewportCenter(
      _chapterIndex,
      nextPage,
      layout.pages[nextPage],
    );
    _verticalCanonicalOffset = offset;
    _scrollProgress.value = textLength == 0
        ? 0
        : (offset / textLength).clamp(0.0, 1.0);
    if (nextPage != _pageIndex) {
      if (nextPage > _pageIndex) _sessionPagesRead++;
      setState(() => _pageIndex = nextPage);
    }
    _scheduleProgressSave();
  }

  void _onVerticalChapterPositionsChanged() {
    if (!mounted ||
        _pageMode != BookSourcePageMode.verticalScroll ||
        _scrollByChapter ||
        _chapters.isEmpty ||
        _verticalViewportSize.isEmpty) {
      return;
    }
    final primary = pickPrimaryReaderItem(
      _verticalChapterPositionsListener.itemPositions.value.map(
        _readerPosition,
      ),
    );
    if (primary == null) return;
    final nextChapter = primary.index.clamp(0, _chapters.length - 1);
    final content = _prefetchedContent[nextChapter];
    if (content == null) {
      unawaited(_continuousContentFor(nextChapter));
      return;
    }
    final layout = _verticalLayoutFor(
      nextChapter,
      content,
      _verticalViewportSize,
    );
    var nextPage = readerPageIndexWithinItem(primary, layout.pages.length);
    var closestDistance = double.infinity;
    final viewportCenter = MediaQuery.sizeOf(context).height / 2;
    for (var index = 0; index < layout.pages.length; index++) {
      final renderObject = _verticalPartKey(
        nextChapter,
        index,
      ).currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      if (top <= viewportCenter && bottom > viewportCenter) {
        nextPage = index;
        break;
      }
      final distance = math.min(
        (top - viewportCenter).abs(),
        (bottom - viewportCenter).abs(),
      );
      if (distance < closestDistance) {
        closestDistance = distance;
        nextPage = index;
      }
    }
    final movedForward =
        nextChapter > _chapterIndex ||
        (nextChapter == _chapterIndex && nextPage > _verticalPageIndex);
    final chapterChanged = nextChapter != _chapterIndex;
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = nextPage;
    final textLength = _readableChapterText[nextChapter]?.length ?? 0;
    final offset = _verticalOffsetAtViewportCenter(
      nextChapter,
      nextPage,
      layout.pages[nextPage],
    );
    _verticalCanonicalOffset = offset;
    _scrollProgress.value = textLength == 0
        ? 0
        : (offset / textLength).clamp(0.0, 1.0);
    if (chapterChanged || nextPage != _pageIndex || _content != content) {
      if (movedForward) _sessionPagesRead++;
      setState(() {
        _chapterIndex = nextChapter;
        _content = content;
        _pageIndex = nextPage;
      });
    }
    if (chapterChanged) unawaited(_preloadAround(nextChapter));
    _scheduleProgressSave();
  }

  Widget _buildAnnotatedTextPage(
    BookSourceTextPage page, {
    required int chapterIndex,
    required int pageIndex,
    required BookSourceChapterContent content,
    bool fillAvailableSpace = true,
  }) {
    final chapterTitle = content.title.isEmpty
        ? _chapters[chapterIndex].title
        : content.title;
    final sourceText =
        _readableChapterText[chapterIndex] ??
        readableBookSourceChapterText(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    return ReaderAnnotatedTextPage(
      key: ValueKey(
        'source-annotated-page:${_chapters[chapterIndex].id}:$pageIndex:'
        '${page.startOffset}:${page.endOffset}',
      ),
      page: page,
      sourceText: sourceText,
      chapterId: _chapters[chapterIndex].id,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      bookId: _shelfBookId,
      format: content.contentType == 'text/html'
          ? BookFormat.html
          : BookFormat.txt,
      renderer: ReaderRendererType.flutterNative,
      palette: _readerTheme,
      bodyStyle: _bodyTextStyle,
      flowStyle: _bodyTextFlowStyle(),
      annotations: _annotations,
      spokenHighlight: _readerAloudHighlight,
      onSaveTextAnnotation: _saveTextAnnotation,
      onAnnotationUnavailable: () => _ensureAnnotationBook(),
      fillAvailableSpace: fillAvailableSpace,
      onInteractionChanged: (active) {
        if (!mounted || _annotationInteractionActive == active) return;
        setState(() => _annotationInteractionActive = active);
      },
    );
  }

  Widget _buildVerticalPageCell(
    BookSourceTextPage page,
    Size viewport, {
    required int chapterIndex,
    required int pageIndex,
    required BookSourceChapterContent content,
  }) {
    return Padding(
      key: _verticalPartKey(chapterIndex, pageIndex),
      padding: EdgeInsets.symmetric(horizontal: _horizontalMargin),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: readerMaxTextContentWidth,
          ),
          child: Column(
            key: ValueKey(
              'book-source-vertical-part:${_chapters[chapterIndex].id}:'
              '${page.startOffset}:$pageIndex',
            ),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pageIndex == 0) ...[
                ReaderInlineChapterTitle(
                  title: content.title.isEmpty
                      ? _chapters[chapterIndex].title
                      : content.title,
                  bodyStyle: _bodyTextStyle,
                ),
                const SizedBox(height: ReaderInlineChapterTitle.spacingAfter),
              ],
              _buildAnnotatedTextPage(
                page,
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                content: content,
                fillAvailableSpace: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalChapter(int chapterIndex, Size viewport) {
    final cached = _prefetchedContent[chapterIndex];
    Widget buildContent(BookSourceChapterContent content) {
      final layout = _verticalLayoutFor(chapterIndex, content, viewport);
      return Column(
        children: [
          for (var pageIndex = 0; pageIndex < layout.pages.length; pageIndex++)
            _buildVerticalPageCell(
              layout.pages[pageIndex],
              viewport,
              chapterIndex: chapterIndex,
              pageIndex: pageIndex,
              content: content,
            ),
        ],
      );
    }

    if (cached != null && _readableChapterText.containsKey(chapterIndex)) {
      return buildContent(cached);
    }
    return FutureBuilder<BookSourceChapterContent>(
      future: _continuousContentFor(chapterIndex),
      builder: (context, snapshot) {
        final content = snapshot.data;
        if (content != null) return buildContent(content);
        if (snapshot.hasError) {
          return SizedBox(
            height: _verticalPageExtentFor(viewport),
            child: Center(
              child: TextButton.icon(
                onPressed: () {
                  setState(() => _continuousContentLoads.remove(chapterIndex));
                },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retry),
              ),
            ),
          );
        }
        return SizedBox(
          height: _verticalPageExtentFor(viewport),
          child: Center(
            child: CircularProgressIndicator(color: _readerTheme.accent),
          ),
        );
      },
    );
  }

  Widget _buildVerticalPageList(
    _BookSourceVerticalLayout layout,
    Size viewport,
  ) {
    final layoutStateChanged =
        _verticalPageCount != layout.pages.length ||
        _verticalPageIndex >= layout.pages.length;
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = _verticalPageIndex.clamp(0, layout.pages.length - 1);
    _pageIndex = _verticalPageIndex;
    if (layoutStateChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    _restoreVerticalPosition(layout, wholeBook: false);
    return ReaderVerticalPagingSurface(
      surfaceKey: const ValueKey('book-source-reader-surface'),
      onHorizontalDragEnd: _handleHorizontalSwipe,
      child: ScrollablePositionedList.builder(
        key: ValueKey(
          'source-vertical-pages:$_chapterIndex:${layout.fingerprint}',
        ),
        itemScrollController: _verticalPageScrollController,
        itemPositionsListener: _verticalPagePositionsListener,
        initialScrollIndex: _verticalPageIndex.clamp(
          0,
          layout.pages.length - 1,
        ),
        minCacheExtent: _verticalPageExtentFor(viewport),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: layout.pages.length,
        itemBuilder: (context, index) => _buildVerticalPageCell(
          layout.pages[index],
          viewport,
          chapterIndex: _chapterIndex,
          pageIndex: index,
          content: _content!,
        ),
      ),
    );
  }

  Widget _buildVerticalBook(Size viewport) {
    final content = _prefetchedContent[_chapterIndex] ?? _content!;
    final currentLayout = _verticalLayoutFor(_chapterIndex, content, viewport);
    final layoutStateChanged =
        _verticalPageCount != currentLayout.pages.length ||
        _verticalPageIndex >= currentLayout.pages.length;
    _verticalPageCount = currentLayout.pages.length;
    _verticalPageIndex = _verticalPageIndex.clamp(
      0,
      currentLayout.pages.length - 1,
    );
    _pageIndex = _verticalPageIndex;
    if (layoutStateChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    _restoreVerticalPosition(currentLayout, wholeBook: true);
    return ReaderVerticalPagingSurface(
      surfaceKey: const ValueKey('book-source-reader-surface'),
      child: ScrollablePositionedList.builder(
        key: ValueKey(
          'source-vertical-book:${viewport.width.toStringAsFixed(1)}:'
          '${viewport.height.toStringAsFixed(1)}:'
          '${_fontSize.toStringAsFixed(1)}:${_lineHeight.toStringAsFixed(2)}:'
          '${_letterSpacing.toStringAsFixed(1)}:${_textAlignment.name}:'
          '$_firstLineIndent:$_paragraphSpacing:${_readerFont.id}:'
          '${_verticalChrome.paginationSignature}',
        ),
        itemScrollController: _verticalChapterScrollController,
        scrollOffsetController: _verticalChapterOffsetController,
        itemPositionsListener: _verticalChapterPositionsListener,
        initialScrollIndex: _chapterIndex.clamp(0, _chapters.length - 1),
        minCacheExtent: _verticalPageExtentFor(viewport),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: _chapters.length,
        itemBuilder: (context, index) => _buildVerticalChapter(index, viewport),
      ),
    );
  }

  _BookSourcePagedLayout _pagedLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    final top = _readerSafeArea.contentTop;
    final bottom = _readerSafeArea.contentBottom;
    final width = readerTextContentWidth(viewport.width, _horizontalMargin);
    final height = readerTextContentHeight(viewport.height, top, bottom);
    const textScaler = readerBodyTextScaler;
    final locale = Localizations.maybeLocaleOf(context);
    final key = ReaderLayoutFingerprint(
      contentKey: _chapters[chapterIndex].id,
      viewport: Size(width, height),
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      letterSpacing: _letterSpacing,
      textAlign: _bodyTextAlign,
      horizontalMargin: _horizontalMargin,
      verticalMargin: _topMargin + _bottomMargin,
      textScaler: textScaler,
      locale: locale,
      pageMode: _pageMode,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      textDirection: Directionality.of(context),
      extra: '${_readerSafeArea.paginationSignature}:${_readerFont.id}',
    ).cacheKey('book-source-line-v5');
    final cached = _pagedLayouts[chapterIndex];
    if (cached?.fingerprint == key) return cached!;
    final pages = paginateBookSourceText(
      _readableChapterText[chapterIndex] ??
          readableBookSourceChapterText(
            content,
            fallbackTitle: _chapters[chapterIndex].title,
          ),
      width: width,
      firstPageHeight: height,
      pageHeight: height,
      style: _bodyTextStyle,
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      textAlign: _bodyTextAlign,
      locale: locale,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      includeChapterTitlePage: true,
    );
    final layout = _BookSourcePagedLayout(fingerprint: key, pages: pages);
    _pagedLayouts[chapterIndex] = layout;
    return layout;
  }

  void _ensurePagination(
    Size viewport, {
    required BookSourceChapterContent content,
  }) {
    final layout = _pagedLayoutFor(_chapterIndex, content, viewport);
    final key = layout.fingerprint;
    if (_paginationKey == key && _paginatedPages.isNotEmpty) return;
    final currentTextOffset = _paginatedPages.isEmpty
        ? null
        : _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)]
              .startOffset;
    final pages = layout.pages;
    _paginationKey = key;
    _paginatedPages = pages;
    _pageCount = pages.length;
    final restoredTarget = _restoreTextOffset != null
        ? bookSourcePageIndexForOffset(pages, _restoreTextOffset!)
        : _restorePagedPosition
        ? ((_pageCount - 1) * _restorePageProgress).round()
        : currentTextOffset != null
        ? bookSourcePageIndexForOffset(pages, currentTextOffset)
        : _pageIndex.clamp(0, _pageCount - 1);
    final target = _usesTwoPageLayout
        ? _spreadStartForPage(restoredTarget)
        : restoredTarget;
    _pageIndex = target.clamp(0, _pageCount - 1);
    _restorePagedPosition = false;
    _restoreTextOffset = null;
    final pageProgress = _pagedReadingProgress(_pageIndex, _pageCount);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollProgress.value = pageProgress;
      if (_pageMode == BookSourcePageMode.verticalScroll) {
        _verticalPageCount = _pageCount;
        _verticalPageIndex = (pageProgress * (_verticalPageCount - 1))
            .round()
            .clamp(0, _verticalPageCount - 1);
      }
      setState(() {});
      if (_pageMode != BookSourcePageMode.horizontalSlide) return;
      _pageViewLeading = _slideLeadingPageCount(_chapterIndex);
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_pageIndex + _pageViewLeading);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ignoreSlidePageChanges = false;
      });
    });
  }

  Widget _buildPageLeaf(
    BookSourceTextPage page, {
    required int pageIndex,
    required int pageCount,
    required String layoutFingerprint,
    int? chapterIndex,
    BookSourceChapterContent? chapterContent,
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    final resolvedIndex = chapterIndex ?? _chapterIndex;
    final resolvedContent = chapterContent ?? _content!;
    final chapterTitle = resolvedContent.title.isEmpty
        ? _chapters[resolvedIndex].title
        : resolvedContent.title;
    final metadata = ReaderPaperPageMetadata(
      pageIdentity:
          'source:${_activeSource.id}:${_activeBook.id}:'
          '${_chapters[resolvedIndex].id}:$pageIndex:${page.startOffset}',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
      chapterTitle: chapterTitle,
      pageNumber: pageIndex + 1,
      pageCount: pageCount,
    );
    return ReaderPaperPageLeaf(
      palette: _readerTheme,
      safeArea: _readerSafeArea,
      metadata: metadata,
      pageNumberPlacement: pageNumberPlacement,
      horizontalPadding: math.max(14, _horizontalMargin),
      pageNumberHorizontalPadding: math.max(24, _horizontalMargin),
      showTopInformation: _topBarStyle == ReaderTopBarStyle.reader,
      showFloatingStatus: _showLeafFloatingStatus,
      floatingStatusHorizontalPadding: _floatingStatusHorizontalPadding,
      topInformationLayout: topInformationLayout,
      status: _leafStatusController.value,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _horizontalMargin,
          _readerSafeArea.contentTop,
          _horizontalMargin,
          _readerSafeArea.contentBottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: readerMaxTextContentWidth,
            ),
            child: SizedBox.expand(
              child: _buildAnnotatedTextPage(
                page,
                chapterIndex: resolvedIndex,
                pageIndex: pageIndex,
                content: resolvedContent,
              ),
            ),
          ),
        ),
      ),
    );
  }

  ReaderPageSnapshot _buildPageSnapshot(
    BookSourceTextPage page, {
    required int pageIndex,
    required int pageCount,
    required String layoutFingerprint,
    int? chapterIndex,
    BookSourceChapterContent? chapterContent,
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    final resolvedIndex = chapterIndex ?? _chapterIndex;
    final metadata = ReaderPaperPageMetadata(
      pageIdentity:
          'source:${_activeSource.id}:${_activeBook.id}:'
          '${_chapters[resolvedIndex].id}:$pageIndex:${page.startOffset}',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
      chapterTitle: (chapterContent ?? _content!).title.isEmpty
          ? _chapters[resolvedIndex].title
          : (chapterContent ?? _content!).title,
      pageNumber: pageIndex + 1,
      pageCount: pageCount,
    );
    return ReaderPageSnapshot(
      key: metadata.snapshotKey,
      contentRevision: _leafContentRevision,
      child: _buildPageLeaf(
        page,
        pageIndex: pageIndex,
        pageCount: pageCount,
        layoutFingerprint: layoutFingerprint,
        chapterIndex: chapterIndex,
        chapterContent: chapterContent,
        pageNumberPlacement: pageNumberPlacement,
        topInformationLayout: topInformationLayout,
      ),
    );
  }

  ({
    BookSourceTextPage page,
    int pageIndex,
    int pageCount,
    String layoutFingerprint,
    BookSourceChapterContent content,
  })?
  _adjacentPageData(
    int chapterIndex,
    Size viewport, {
    required int Function(int pageCount) selectPageIndex,
  }) {
    final content = _prefetchedContent[chapterIndex];
    if (content == null) return null;
    final layout = _pagedLayoutFor(chapterIndex, content, viewport);
    final pages = layout.pages;
    final pageIndex = selectPageIndex(pages.length);
    if (pageIndex < 0 || pageIndex >= pages.length) return null;
    return (
      page: pages[pageIndex],
      pageIndex: pageIndex,
      pageCount: pages.length,
      layoutFingerprint: layout.fingerprint,
      content: content,
    );
  }

  Widget? _buildAdjacentPreview(
    int chapterIndex, {
    bool lastPage = false,
    int? pageIndex,
  }) {
    if (_prefetchedContent[chapterIndex] == null) return null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final data = _adjacentPageData(
          chapterIndex,
          constraints.biggest,
          selectPageIndex: pageIndex != null
              ? (_) => pageIndex
              : lastPage
              ? (pageCount) => pageCount - 1
              : (_) => 0,
        );
        if (data == null) return const SizedBox.shrink();
        return _buildPageLeaf(
          data.page,
          pageIndex: data.pageIndex,
          pageCount: data.pageCount,
          layoutFingerprint: data.layoutFingerprint,
          chapterIndex: chapterIndex,
          chapterContent: data.content,
        );
      },
    );
  }

  Widget _buildBoundaryLeaf({
    required bool forward,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
    String slotIdentity = '',
  }) {
    final targetChapterIndex = _chapterIndex + (forward ? 1 : -1);
    final chapterTitle =
        targetChapterIndex >= 0 && targetChapterIndex < _chapters.length
        ? _chapters[targetChapterIndex].title
        : '';
    return ReaderPaperPageLeaf(
      palette: _readerTheme,
      safeArea: _readerSafeArea,
      metadata: ReaderPaperPageMetadata(
        pageIdentity:
            'source:${_activeSource.id}:${_activeBook.id}:'
            'boundary:${forward ? 'forward' : 'backward'}'
            '${slotIdentity.isEmpty ? '' : ':$slotIdentity'}',
        layoutFingerprint: _paginationKey ?? 'unpaginated',
        themeId: _readerTheme.cacheKey,
        chapterTitle: chapterTitle,
        pageNumber: 0,
        pageCount: 0,
      ),
      horizontalPadding: math.max(14, _horizontalMargin),
      showTopInformation: _topBarStyle == ReaderTopBarStyle.reader,
      showFloatingStatus: _showLeafFloatingStatus,
      floatingStatusHorizontalPadding: _floatingStatusHorizontalPadding,
      topInformationLayout: topInformationLayout,
      showPageNumber: false,
      status: _leafStatusController.value,
      child: Center(
        child: Icon(
          forward
              ? Icons.arrow_forward_ios_rounded
              : Icons.arrow_back_ios_new_rounded,
          color: _readerTheme.secondaryText.withValues(alpha: 0.38),
        ),
      ),
    );
  }

  ReaderPageSnapshot _buildBoundarySnapshot({
    required bool forward,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
    String slotIdentity = '',
  }) => ReaderPageSnapshot(
    key: ReaderPageSnapshotKey(
      pageIdentity:
          'source:${_activeSource.id}:${_activeBook.id}:'
          'boundary:${forward ? 'forward' : 'backward'}'
          '${slotIdentity.isEmpty ? '' : ':$slotIdentity'}',
      layoutFingerprint: _paginationKey ?? 'unpaginated',
      themeId: _readerTheme.cacheKey,
    ),
    contentRevision: _leafContentRevision,
    child: _buildBoundaryLeaf(
      forward: forward,
      topInformationLayout: topInformationLayout,
      slotIdentity: slotIdentity,
    ),
  );

  void _handleTapZoneAction(ReaderTapZoneAction action) {
    if (_annotationInteractionActive) return;
    switch (action) {
      case ReaderTapZoneAction.menu:
        _toggleControls();
      case ReaderTapZoneAction.none:
        break;
      case ReaderTapZoneAction.previousPage:
        // 上下翻页由滚动手势负责，点击翻页保持关闭。
        if (_pageMode == BookSourcePageMode.verticalScroll) return;
        unawaited(_turnFromTap(forward: false));
      case ReaderTapZoneAction.nextPage:
        if (_pageMode == BookSourcePageMode.verticalScroll) return;
        unawaited(_turnFromTap(forward: true));
      case ReaderTapZoneAction.previousChapter:
        _openAdjacentChapter(-1);
      case ReaderTapZoneAction.nextChapter:
        _openAdjacentChapter(1);
    }
  }

  void _openAdjacentChapter(int delta) {
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) return;
    if (_pageMode == BookSourcePageMode.verticalScroll && !_scrollByChapter) {
      unawaited(_jumpToVerticalChapter(target));
    } else {
      unawaited(_loadChapter(target));
    }
  }

  Future<void> _turnFromTap({required bool forward}) async {
    if (!_tapPageAnimationEnabled ||
        _pageMode == BookSourcePageMode.instantPage) {
      if (forward) {
        await _turnForward();
      } else {
        await _turnBackward();
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.horizontalSlide &&
        _pageController.hasClients) {
      if (forward) {
        await _pageController.nextPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } else {
        await _pageController.previousPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.pageCurl) {
      final controller = _usesTwoPageLayout
          ? (forward
                ? _spreadForwardPageCurlController
                : _spreadBackwardPageCurlController)
          : _pageCurlController;
      if (forward) {
        await controller.turnForward();
      } else {
        await controller.turnBackward();
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.coverSlide) {
      if (forward) {
        await _coverPageTurnController.turnForward();
      } else {
        await _coverPageTurnController.turnBackward();
      }
      return;
    }
    if (forward) {
      await _turnForward();
    } else {
      await _turnBackward();
    }
  }

  Widget _buildInstantReader() => LayoutBuilder(
    builder: (context, constraints) => Semantics(
      label: _pageModeHint(BookSourcePageMode.instantPage),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _handlePagedSwipe,
        child: _buildPageLeaf(
          _paginatedPages[_pageIndex],
          pageIndex: _pageIndex,
          pageCount: _pageCount,
          layoutFingerprint: _paginationKey!,
        ),
      ),
    ),
  );

  Widget _buildSlideReader() {
    final previousChapterIndex = _chapterIndex - 1;
    final previousContent = previousChapterIndex >= 0
        ? _prefetchedContent[previousChapterIndex]
        : null;
    final previousLayout = previousContent == null || _pagedViewportSize.isEmpty
        ? null
        : _pagedLayoutFor(
            previousChapterIndex,
            previousContent,
            _pagedViewportSize,
          );
    final previousPageCount = previousLayout?.pages.length ?? 1;
    final nextChapterIndex = _chapterIndex + 1;
    final hasNextChapter = nextChapterIndex < _chapters.length;
    final nextContent = hasNextChapter
        ? _prefetchedContent[nextChapterIndex]
        : null;
    final nextLayout = nextContent == null || _pagedViewportSize.isEmpty
        ? null
        : _pagedLayoutFor(nextChapterIndex, nextContent, _pagedViewportSize);
    final nextPageCount = nextLayout?.pages.length ?? 1;
    final trailing = hasNextChapter ? nextPageCount : 0;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        _schedulePendingSlideChapterCommit();
        return false;
      },
      child: PageView.builder(
        key: ValueKey('source-slide:${_chapters[_chapterIndex].id}'),
        controller: _pageController,
        physics: _annotationInteractionActive
            ? const NeverScrollableScrollPhysics()
            : null,
        itemCount: _pageViewLeading + _pageCount + trailing,
        onPageChanged: (viewIndex) {
          if (_ignoreSlidePageChanges) return;
          final page = viewIndex - _pageViewLeading;
          if (page < 0) {
            final previousPageIndex = previousPageCount + page;
            _queueSlideChapterCommit(
              chapterIndex: previousChapterIndex,
              boundaryViewIndex: viewIndex,
              restoreProgress: previousLayout == null || previousPageCount <= 1
                  ? 1
                  : previousPageIndex / (previousPageCount - 1),
            );
            return;
          }
          if (page >= _pageCount) {
            final nextPageIndex = page - _pageCount;
            _queueSlideChapterCommit(
              chapterIndex: nextChapterIndex,
              boundaryViewIndex: viewIndex,
              restoreProgress: nextPageCount <= 1
                  ? 0
                  : nextPageIndex / (nextPageCount - 1),
            );
            return;
          }
          _pendingSlideChapterIndex = null;
          _pendingSlideBoundaryViewIndex = null;
          _setPagedIndex(page);
        },
        itemBuilder: (context, viewIndex) {
          final page = viewIndex - _pageViewLeading;
          final Widget child;
          if (page < 0) {
            final previousPageIndex = previousPageCount + page;
            child =
                _buildAdjacentPreview(
                  previousChapterIndex,
                  pageIndex: previousLayout == null ? null : previousPageIndex,
                  lastPage: previousLayout == null,
                ) ??
                _buildBoundaryLeaf(forward: false);
          } else if (page >= _pageCount) {
            final nextPageIndex = page - _pageCount;
            child =
                _buildAdjacentPreview(
                  nextChapterIndex,
                  pageIndex: nextPageIndex,
                ) ??
                _buildBoundaryLeaf(forward: true);
          } else {
            child = _buildPageLeaf(
              _paginatedPages[page],
              pageIndex: page,
              pageCount: _pageCount,
              layoutFingerprint: _paginationKey!,
            );
          }
          return child;
        },
      ),
    );
  }

  Widget _buildCurlReader({required bool usesTwoPageLayout}) =>
      usesTwoPageLayout ? _buildCurlSpreadReader() : _buildSingleCurlReader();

  ({
    ReaderPageSnapshot current,
    ReaderPageSnapshot? forward,
    ReaderPageSnapshot? backward,
  })
  _singlePageTurnSnapshots(Size viewport) {
    final hasForward =
        _pageIndex + 1 < _pageCount || _chapterIndex + 1 < _chapters.length;
    final hasBackward = _pageIndex > 0 || _chapterIndex > 0;
    final forwardData = _pageIndex + 1 < _pageCount
        ? null
        : _chapterIndex + 1 < _chapters.length
        ? _adjacentPageData(
            _chapterIndex + 1,
            viewport,
            selectPageIndex: (_) => 0,
          )
        : null;
    final backwardData = _pageIndex > 0
        ? null
        : _chapterIndex > 0
        ? _adjacentPageData(
            _chapterIndex - 1,
            viewport,
            selectPageIndex: (pageCount) => pageCount - 1,
          )
        : null;
    final currentSnapshot = _buildPageSnapshot(
      _paginatedPages[_pageIndex],
      pageIndex: _pageIndex,
      pageCount: _pageCount,
      layoutFingerprint: _paginationKey!,
    );
    final forwardSnapshot = !hasForward
        ? null
        : _pageIndex + 1 < _pageCount
        ? _buildPageSnapshot(
            _paginatedPages[_pageIndex + 1],
            pageIndex: _pageIndex + 1,
            pageCount: _pageCount,
            layoutFingerprint: _paginationKey!,
          )
        : forwardData == null
        ? _buildBoundarySnapshot(forward: true)
        : _buildPageSnapshot(
            forwardData.page,
            pageIndex: forwardData.pageIndex,
            pageCount: forwardData.pageCount,
            layoutFingerprint: forwardData.layoutFingerprint,
            chapterIndex: _chapterIndex + 1,
            chapterContent: forwardData.content,
          );
    final backwardSnapshot = !hasBackward
        ? null
        : _pageIndex > 0
        ? _buildPageSnapshot(
            _paginatedPages[_pageIndex - 1],
            pageIndex: _pageIndex - 1,
            pageCount: _pageCount,
            layoutFingerprint: _paginationKey!,
          )
        : backwardData == null
        ? _buildBoundarySnapshot(forward: false)
        : _buildPageSnapshot(
            backwardData.page,
            pageIndex: backwardData.pageIndex,
            pageCount: backwardData.pageCount,
            layoutFingerprint: backwardData.layoutFingerprint,
            chapterIndex: _chapterIndex - 1,
            chapterContent: backwardData.content,
          );
    return (
      current: currentSnapshot,
      forward: forwardSnapshot,
      backward: backwardSnapshot,
    );
  }

  Widget _buildSingleCurlReader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final snapshots = _singlePageTurnSnapshots(constraints.biggest);
        return ReaderShaderPageCurl(
          key: ValueKey('source-curl:${_activeSource.id}:${_activeBook.id}'),
          controller: _pageCurlController,
          paperColor: _readerTheme.background,
          currentPage: snapshots.current,
          forwardPage: snapshots.forward,
          backwardPage: snapshots.backward,
          onTurnForward: _turnForward,
          onTurnBackward: _turnBackward,
        );
      },
    );
  }

  Widget _buildCoverReader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final snapshots = _singlePageTurnSnapshots(constraints.biggest);
        return ReaderCoverPageTurn(
          key: ValueKey('source-cover:${_activeSource.id}:${_activeBook.id}'),
          controller: _coverPageTurnController,
          paperColor: _readerTheme.background,
          currentPage: snapshots.current,
          forwardPage: snapshots.forward,
          backwardPage: snapshots.backward,
          onTurnForward: _turnForward,
          onTurnBackward: _turnBackward,
        );
      },
    );
  }

  Widget _buildCurlSpreadReader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spreadStart = _spreadStartForPage(_pageIndex);
        final nextSpreadStart = spreadStart + 2;
        final hasPrevious = spreadStart >= 2 || _chapterIndex > 0;
        final hasNext =
            nextSpreadStart < _pageCount ||
            _chapterIndex + 1 < _chapters.length;
        final adjacentViewport = _paginationViewport(constraints.biggest, true);
        final previousChapterIndex = _chapterIndex - 1;
        final nextChapterIndex = _chapterIndex + 1;
        final usesPreviousChapter =
            spreadStart == 0 && previousChapterIndex >= 0;
        final usesNextChapter =
            nextSpreadStart >= _pageCount &&
            nextChapterIndex < _chapters.length;
        final previousChapterCached =
            usesPreviousChapter &&
            _prefetchedContent[previousChapterIndex] != null;
        final nextChapterCached =
            usesNextChapter && _prefetchedContent[nextChapterIndex] != null;
        final previousChapterLeftData = previousChapterCached
            ? _adjacentPageData(
                previousChapterIndex,
                adjacentViewport,
                selectPageIndex: (pageCount) =>
                    _spreadStartForPage(pageCount - 1),
              )
            : null;
        final previousChapterRightData = previousChapterCached
            ? _adjacentPageData(
                previousChapterIndex,
                adjacentViewport,
                selectPageIndex: (pageCount) =>
                    _spreadStartForPage(pageCount - 1) + 1,
              )
            : null;
        final nextChapterLeftData = nextChapterCached
            ? _adjacentPageData(
                nextChapterIndex,
                adjacentViewport,
                selectPageIndex: (_) => 0,
              )
            : null;
        final nextChapterRightData = nextChapterCached
            ? _adjacentPageData(
                nextChapterIndex,
                adjacentViewport,
                selectPageIndex: (_) => 1,
              )
            : null;

        final currentLeft = _buildPageSnapshot(
          _paginatedPages[spreadStart],
          pageIndex: spreadStart,
          pageCount: _pageCount,
          layoutFingerprint: _paginationKey!,
          pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
          topInformationLayout: ReaderTopInformationLayout.spreadLeft,
        );
        final currentRight = spreadStart + 1 < _pageCount
            ? _buildPageSnapshot(
                _paginatedPages[spreadStart + 1],
                pageIndex: spreadStart + 1,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : _buildBlankSourceSnapshot(
                'current-$spreadStart-right',
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              );

        final previousLeft = !hasPrevious
            ? null
            : spreadStart >= 2
            ? _buildPageSnapshot(
                _paginatedPages[spreadStart - 2],
                pageIndex: spreadStart - 2,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              )
            : !previousChapterCached
            ? _buildBoundarySnapshot(
                forward: false,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                slotIdentity: 'spread-left',
              )
            : previousChapterLeftData == null
            ? _buildBlankSourceSnapshot(
                'previous-chapter-$previousChapterIndex-left',
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                chapterTitle: _chapters[previousChapterIndex].title,
              )
            : _buildPageSnapshot(
                previousChapterLeftData.page,
                pageIndex: previousChapterLeftData.pageIndex,
                pageCount: previousChapterLeftData.pageCount,
                layoutFingerprint: previousChapterLeftData.layoutFingerprint,
                chapterIndex: previousChapterIndex,
                chapterContent: previousChapterLeftData.content,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              );
        final previousRight = !hasPrevious
            ? null
            : spreadStart >= 2
            ? _buildPageSnapshot(
                _paginatedPages[spreadStart - 1],
                pageIndex: spreadStart - 1,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : !previousChapterCached
            ? _buildBoundarySnapshot(
                forward: false,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
                slotIdentity: 'spread-right',
              )
            : previousChapterRightData == null
            ? _buildBlankSourceSnapshot(
                'previous-chapter-$previousChapterIndex-right',
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
                chapterTitle: _chapters[previousChapterIndex].title,
              )
            : _buildPageSnapshot(
                previousChapterRightData.page,
                pageIndex: previousChapterRightData.pageIndex,
                pageCount: previousChapterRightData.pageCount,
                layoutFingerprint: previousChapterRightData.layoutFingerprint,
                chapterIndex: previousChapterIndex,
                chapterContent: previousChapterRightData.content,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              );
        final nextLeft = !hasNext
            ? null
            : nextSpreadStart < _pageCount
            ? _buildPageSnapshot(
                _paginatedPages[nextSpreadStart],
                pageIndex: nextSpreadStart,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              )
            : !nextChapterCached
            ? _buildBoundarySnapshot(
                forward: true,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                slotIdentity: 'spread-left',
              )
            : nextChapterLeftData == null
            ? _buildBlankSourceSnapshot(
                'next-chapter-$nextChapterIndex-left',
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                chapterTitle: _chapters[nextChapterIndex].title,
              )
            : _buildPageSnapshot(
                nextChapterLeftData.page,
                pageIndex: nextChapterLeftData.pageIndex,
                pageCount: nextChapterLeftData.pageCount,
                layoutFingerprint: nextChapterLeftData.layoutFingerprint,
                chapterIndex: nextChapterIndex,
                chapterContent: nextChapterLeftData.content,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              );
        final nextRight = !hasNext
            ? null
            : nextSpreadStart < _pageCount
            ? nextSpreadStart + 1 < _pageCount
                  ? _buildPageSnapshot(
                      _paginatedPages[nextSpreadStart + 1],
                      pageIndex: nextSpreadStart + 1,
                      pageCount: _pageCount,
                      layoutFingerprint: _paginationKey!,
                      topInformationLayout:
                          ReaderTopInformationLayout.spreadRight,
                    )
                  : _buildBlankSourceSnapshot(
                      'next-$nextSpreadStart-right',
                      topInformationLayout:
                          ReaderTopInformationLayout.spreadRight,
                    )
            : !nextChapterCached
            ? _buildBoundarySnapshot(
                forward: true,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
                slotIdentity: 'spread-right',
              )
            : nextChapterRightData == null
            ? _buildBlankSourceSnapshot(
                'next-chapter-$nextChapterIndex-right',
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : _buildPageSnapshot(
                nextChapterRightData.page,
                pageIndex: nextChapterRightData.pageIndex,
                pageCount: nextChapterRightData.pageCount,
                layoutFingerprint: nextChapterRightData.layoutFingerprint,
                chapterIndex: nextChapterIndex,
                chapterContent: nextChapterRightData.content,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              );

        final left = ReaderShaderPageCurl(
          key: ValueKey(
            'source-spread-curl-left:${_activeSource.id}:${_activeBook.id}',
          ),
          controller: _spreadBackwardPageCurlController,
          coordinator: _spreadPageCurlCoordinator,
          edgeDragOnly: true,
          bindingEdge: ReaderPageBindingEdge.right,
          paperColor: _readerTheme.background,
          currentPage: currentLeft,
          backwardPage: previousLeft,
          outgoingBackPage: previousRight,
          onTurnForward: () {},
          onTurnBackward: _turnBackward,
        );
        final right = ReaderShaderPageCurl(
          key: ValueKey(
            'source-spread-curl-right:${_activeSource.id}:${_activeBook.id}',
          ),
          controller: _spreadForwardPageCurlController,
          coordinator: _spreadPageCurlCoordinator,
          edgeDragOnly: true,
          bindingEdge: ReaderPageBindingEdge.left,
          paperColor: _readerTheme.background,
          currentPage: currentRight,
          forwardPage: nextRight,
          outgoingBackPage: nextLeft,
          onTurnForward: _turnForward,
          onTurnBackward: () {},
        );

        return _buildSourceSpread(left: left, right: right);
      },
    );
  }

  ReaderPageSnapshot _buildBlankSourceSnapshot(
    String pageIdentity, {
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
    String chapterTitle = '',
  }) => ReaderPageSnapshot(
    key: ReaderPageSnapshotKey(
      pageIdentity:
          'source:${_activeSource.id}:${_activeBook.id}:'
          'blank:$pageIdentity',
      layoutFingerprint: _paginationKey ?? 'unpaginated',
      themeId: _readerTheme.cacheKey,
    ),
    contentRevision: _leafContentRevision,
    child: ReaderPaperPageLeaf(
      palette: _readerTheme,
      safeArea: _readerSafeArea,
      metadata: ReaderPaperPageMetadata(
        pageIdentity:
            'source:${_activeSource.id}:${_activeBook.id}:'
            'blank:$pageIdentity',
        layoutFingerprint: _paginationKey ?? 'unpaginated',
        themeId: _readerTheme.cacheKey,
        chapterTitle: chapterTitle,
        pageNumber: 0,
        pageCount: 0,
      ),
      horizontalPadding: math.max(14, _horizontalMargin),
      showTopInformation: _topBarStyle == ReaderTopBarStyle.reader,
      showFloatingStatus: _showLeafFloatingStatus,
      floatingStatusHorizontalPadding: _floatingStatusHorizontalPadding,
      topInformationLayout: topInformationLayout,
      showPageNumber: false,
      status: _leafStatusController.value,
      child: const SizedBox.expand(),
    ),
  );

  Widget _buildSourceSpread({required Widget left, required Widget right}) {
    return ReaderPageCurlSpread(
      coordinator: _spreadPageCurlCoordinator,
      left: left,
      right: right,
      gutter: _buildSourceSpreadGutter(),
    );
  }

  Widget _buildSourceSpreadGutter() {
    final colors = _readerThemeData.colorScheme;
    return SizedBox(
      width: _spreadGutter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colors.shadow.withValues(alpha: 0),
              colors.shadow.withValues(alpha: 0.09),
              colors.shadow.withValues(alpha: 0),
            ],
          ),
        ),
        child: Center(
          child: Container(
            width: 1,
            color: colors.outlineVariant.withValues(alpha: 0.48),
          ),
        ),
      ),
    );
  }

  String _readerStatus() {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return context.l10n.readerStatusPaged(
        _chapterIndex + 1,
        _chapters.length,
        _verticalPageIndex + 1,
        _verticalPageCount,
      );
    }
    return context.l10n.readerStatusPaged(
      _chapterIndex + 1,
      _chapters.length,
      _pageIndex + 1,
      _pageCount,
    );
  }

  bool get _currentPageIsBookmarked {
    final anchorKey = _currentBookmarkAnchorKey;
    return anchorKey != null &&
        _bookmarks.any((bookmark) => bookmark.anchorKey == anchorKey);
  }

  Widget _buildReaderStatusText(
    BuildContext context,
    TextStyle? style,
    Key? key,
  ) {
    return ValueListenableBuilder<double>(
      valueListenable: _scrollProgress,
      builder: (context, _, __) => Text(
        _chapters.isEmpty ? _activeBook.title : _readerStatus(),
        key: key,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

class _BookSourcePagedLayout {
  const _BookSourcePagedLayout({
    required this.fingerprint,
    required this.pages,
  });

  final String fingerprint;
  final List<BookSourceTextPage> pages;
}

class _BookSourceVerticalLayout {
  const _BookSourceVerticalLayout({
    required this.fingerprint,
    required this.pages,
  });

  final String fingerprint;
  final List<BookSourceTextPage> pages;
}

// ====================================================================
//  换源面板
// ====================================================================

enum _SwitchRowStatus { loading, ready, empty, error, unavailable }

class _SwitchRowData {
  const _SwitchRowData({
    required this.pointer,
    required this.source,
    required this.isCurrent,
    required this.status,
    this.confidence = 0,
    this.isApproximate = false,
    this.targetChapterCount = 0,
    this.alignedTitle,
  });

  final SourcedBookPointer pointer;
  final RegisteredBookSource? source;
  final bool isCurrent;
  final _SwitchRowStatus status;
  final double confidence;
  final bool isApproximate;
  final int targetChapterCount;
  final String? alignedTitle;

  _SwitchRowData copyWith({
    _SwitchRowStatus? status,
    double? confidence,
    bool? isApproximate,
    int? targetChapterCount,
    String? alignedTitle,
  }) {
    return _SwitchRowData(
      pointer: pointer,
      source: source,
      isCurrent: isCurrent,
      status: status ?? this.status,
      confidence: confidence ?? this.confidence,
      isApproximate: isApproximate ?? this.isApproximate,
      targetChapterCount: targetChapterCount ?? this.targetChapterCount,
      alignedTitle: alignedTitle ?? this.alignedTitle,
    );
  }
}

/// 换源面板后台对齐的输入/输出（compute 隔离传输用，仅含可发送基础字段）。
class _AlignInput {
  const _AlignInput({
    required this.currentTitle,
    required this.currentIndex,
    required this.currentTotal,
    required this.targetTitles,
  });

  final String currentTitle;
  final int currentIndex;
  final int currentTotal;
  final List<String> targetTitles;
}

class _AlignOutcome {
  const _AlignOutcome({
    required this.index,
    required this.confidence,
    required this.isApproximate,
  });

  final int index;
  final double confidence;
  final bool isApproximate;
}

/// 在后台 isolate 中执行章节对齐，避免大目录 O(N) 标题匹配阻塞主线程。
_AlignOutcome _alignChapters(_AlignInput input) {
  final target = List<BookSourceChapter>.generate(
    input.targetTitles.length,
    (i) => BookSourceChapter(
      id: '',
      title: input.targetTitles[i],
      order: i,
    ),
  );
  final current = BookSourceChapter(
    id: '',
    title: input.currentTitle,
    order: input.currentIndex,
  );
  final result = ChapterAligner.align(
    currentChapter: current,
    currentIndex: input.currentIndex,
    currentTotal: input.currentTotal,
    targetChapters: target,
  );
  return _AlignOutcome(
    index: result.index,
    confidence: result.confidence,
    isApproximate: result.isApproximate,
  );
}

class _BookSourceSwitchSheet extends StatefulWidget {
  const _BookSourceSwitchSheet({
    required this.palette,
    required this.pointers,
    required this.registeredSources,
    required this.currentSourceId,
    required this.currentChapter,
    required this.currentChapterIndex,
    required this.currentChaptersLength,
    required this.client,
    required this.fallbackBookTitle,
    required this.fallbackBookAuthor,
    required this.onSwitch,
    required this.onSearchMore,
  });

  final ReaderThemePalette palette;
  final List<SourcedBookPointer> pointers;
  final Map<String, RegisteredBookSource> registeredSources;
  final String currentSourceId;
  final BookSourceChapter currentChapter;
  final int currentChapterIndex;
  final int currentChaptersLength;
  final BookSourceClient client;
  final String fallbackBookTitle;
  final String fallbackBookAuthor;
  final Future<bool> Function(
    RegisteredBookSource source,
    SourcedBookPointer pointer,
    BookSourceBook book,
  ) onSwitch;
  final Future<void> Function(List<SourcedBookPointer> allSources) onSearchMore;

  @override
  State<_BookSourceSwitchSheet> createState() => _BookSourceSwitchSheetState();
}

class _BookSourceSwitchSheetState extends State<_BookSourceSwitchSheet> {
  late final List<_SwitchRowData> _rows;
  String? _switchingSourceId;
  bool _searchingMore = false;
  String? _searchMoreError;
  String? _lastSearchTerm;

  // 换源面板并发上限：避免一次打开就并发拉取全部源的目录并对齐，导致主线程卡顿。
  static const int _maxConcurrentLoads = 3;
  int _activeLoads = 0;
  final List<int> _loadQueue = [];

  @override
  void initState() {
    super.initState();
    _rows = widget.pointers.map((pointer) {
      final isCurrent = pointer.sourceId == widget.currentSourceId;
      final source = widget.registeredSources[pointer.sourceId];
      final status = isCurrent
          ? _SwitchRowStatus.ready
          : (source == null ? _SwitchRowStatus.unavailable : _SwitchRowStatus.loading);
      return _SwitchRowData(
        pointer: pointer,
        source: source,
        isCurrent: isCurrent,
        status: status,
      );
    }).toList();
    // 有限并发加载，避免一次性并发 N 个源的网络请求与对齐阻塞 UI。
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row.isCurrent || row.source == null) continue;
      _enqueueLoad(i);
    }
  }

  /// 入队一次目录加载；低于并发上限立即执行，否则排队等待空位。
  void _enqueueLoad(int index) {
    if (_activeLoads < _maxConcurrentLoads) {
      _activeLoads++;
      unawaited(_runLoad(index));
    } else {
      _loadQueue.add(index);
    }
  }

  void _drainQueue() {
    while (_activeLoads < _maxConcurrentLoads && _loadQueue.isNotEmpty) {
      final next = _loadQueue.removeAt(0);
      _activeLoads++;
      unawaited(_runLoad(next));
    }
  }

  Future<void> _runLoad(int index) async {
    final row = _rows[index];
    final source = row.source!;
    try {
      final chapters = await widget.client
          .getChapters(source, row.pointer.bookId)
          .timeout(const Duration(seconds: 10));
      if (chapters.isEmpty) {
        if (!mounted) return;
        setState(() => _rows[index] = row.copyWith(status: _SwitchRowStatus.empty));
        return;
      }
      final sorted = [...chapters]..sort((a, b) => a.order.compareTo(b.order));
      // 章节对齐放到后台 isolate 执行，避免大目录的 O(N) 标题匹配阻塞主线程。
      final outcome = await compute(
        _alignChapters,
        _AlignInput(
          currentTitle: widget.currentChapter.title,
          currentIndex: widget.currentChapterIndex,
          currentTotal: widget.currentChaptersLength,
          targetTitles: sorted.map((c) => c.title).toList(growable: false),
        ),
      );
      if (!mounted) return;
      setState(() {
        _rows[index] = row.copyWith(
          status: _SwitchRowStatus.ready,
          confidence: outcome.confidence,
          isApproximate: outcome.isApproximate,
          targetChapterCount: sorted.length,
          alignedTitle: sorted[outcome.index].title,
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _rows[index] = row.copyWith(status: _SwitchRowStatus.error));
    } finally {
      _activeLoads--;
      _drainQueue();
    }
  }

  Future<void> _onTapRow(_SwitchRowData row) async {
    if (row.isCurrent || row.source == null || _switchingSourceId != null) return;
    setState(() => _switchingSourceId = row.source!.id);
    final book = row.pointer.book ??
        BookSourceBook(
          id: row.pointer.bookId,
          title: widget.fallbackBookTitle,
          author: widget.fallbackBookAuthor,
        );
    final ok = await widget.onSwitch(row.source!, row.pointer, book);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _switchingSourceId = null);
    }
  }

  // 在换源面板内主动跨源搜索同名书籍，把发现的新源并入列表并储存。
  Future<void> _searchMore() async {
    if (_searchingMore) return;
    final query = widget.fallbackBookTitle.trim();
    if (query.isEmpty) return;
    final enabled = widget.registeredSources.values
        .where((s) => s.enabled)
        .toList(growable: false);
    if (enabled.isEmpty) {
      setState(() => _searchMoreError = '当前没有可搜索的已启用书源');
      return;
    }
    setState(() {
      _searchingMore = true;
      _searchMoreError = null;
    });
    try {
      final page = await BookSourceAggregatedSearch(widget.client)
          .search(enabled, query);
      AggregatedSearchHit? matched;
      for (final hit in page.hits) {
        if (hit.canonicalTitle.trim() == query) {
          matched = hit;
          break;
        }
      }
      matched ??= page.hits.isEmpty ? null : page.hits.first;
      if (!mounted) return;
      if (matched == null || matched.sources.isEmpty) {
        setState(() {
          _searchingMore = false;
          _searchMoreError = '未搜索到同名书籍的其他源';
        });
        return;
      }
      final existingIds = <String>{
        for (final r in _rows) r.pointer.sourceId,
        widget.currentSourceId,
      };
      final existingPointer = <String, SourcedBookPointer>{
        for (final r in _rows) r.pointer.sourceId: r.pointer,
      };
      final newPointers = <SourcedBookPointer>[];
      for (final pointer in matched.sources) {
        if (existingIds.contains(pointer.sourceId)) continue;
        existingIds.add(pointer.sourceId);
        newPointers.add(pointer);
      }
      // 把新源回传给阅读页（储存到书架与本次会话），下次打开也保留。
      final allSources = <SourcedBookPointer>[
        ...existingPointer.values,
        ...newPointers,
      ];
      await widget.onSearchMore(allSources);
      if (!mounted) return;
      setState(() {
        _searchingMore = false;
        _lastSearchTerm = query;
        _searchMoreError = null;
        if (newPointers.isEmpty) _searchMoreError = '未发现新的其他源';
      });
      if (newPointers.isNotEmpty) {
        for (final pointer in newPointers) {
          final source = widget.registeredSources[pointer.sourceId];
          final isCurrent = pointer.sourceId == widget.currentSourceId;
          final status = isCurrent
              ? _SwitchRowStatus.ready
              : (source == null
                    ? _SwitchRowStatus.unavailable
                    : _SwitchRowStatus.loading);
          _rows.add(_SwitchRowData(
            pointer: pointer,
            source: source,
            isCurrent: isCurrent,
            status: status,
          ));
        }
        for (var i = 0; i < _rows.length; i++) {
          final row = _rows[i];
          if (row.isCurrent || row.source == null) continue;
          if (row.status == _SwitchRowStatus.loading) {
            _enqueueLoad(i);
          }
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searchingMore = false;
        _searchMoreError = '搜索其他源失败：$error';
      });
    }
  }

  ({String label, Color color})? _confidenceBadge(_SwitchRowData row) {
    if (row.status != _SwitchRowStatus.ready) return null;
    if (!row.isApproximate) return (label: '高', color: MiduColors.success);
    if (row.confidence >= ChapterAligner.minMatchThreshold) {
      return (label: '中', color: MiduColors.warning);
    }
    return (label: '低', color: MiduColors.ink500);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final dark = palette.brightness == Brightness.dark;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.74;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(MiduRadius.xl),
            ),
            child: BackdropFilter(
              enabled: !GlassEffectConfig.shouldDisableBlur,
              filter: ImageFilter.blur(
                sigmaX: MiduGlassSigma.sheet,
                sigmaY: MiduGlassSigma.sheet,
              ),
              child: Container(
                color: GlassEffectConfig.shouldDisableBlur
                    ? (dark ? const Color(0xFF150A33) : const Color(0xFFFFFAF8))
                    : (dark ? const Color(0xF0150A33) : const Color(0xF5FAF8FF)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(),
                    Flexible(child: _buildBody(dark: dark)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: MiduColors.brandGradient,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz_rounded, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          const Text(
            '换源',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildBody({required bool dark}) {
    final searchMoreHeader = _buildSearchMoreStatus();
    if (_rows.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.compare_arrows_rounded,
                      size: 40,
                      color: widget.palette.secondaryText,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '暂无其他可用源',
                      style: TextStyle(
                        color: widget.palette.secondaryText,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '可自动搜索同名书籍，发现并储存可切换的书源',
                      style: TextStyle(
                        color: widget.palette.secondaryText,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
          _buildSearchMoreButton(),
          const SizedBox(height: 12),
        ],
      );
    }
    return Column(
      children: [
        if (searchMoreHeader != null) searchMoreHeader,
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            itemCount: _rows.length,
            itemBuilder: (context, index) => _buildRow(_rows[index], dark: dark),
          ),
        ),
        _buildSearchMoreButton(),
        const SizedBox(height: 12),
      ],
    );
  }

  // 展示搜索更多源的状态提示（错误信息等）。
  Widget? _buildSearchMoreStatus() {
    final error = _searchMoreError;
    if (error == null) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          error,
          style: TextStyle(
            color: widget.palette.secondaryText,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchMoreButton() {
    final searching = _searchingMore;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: TextButton.icon(
          key: const Key('bookSourceSearchMoreButton'),
          onPressed: searching ? null : _searchMore,
          style: TextButton.styleFrom(
            foregroundColor: scheme.primary,
            backgroundColor: scheme.primary.withValues(alpha: 0.1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MiduRadius.md),
            ),
          ),
          icon: searching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search_rounded, size: 20),
          label: Text(
            searching
                ? '正在搜索其他源…'
                : (_lastSearchTerm != null
                      ? '重新搜索「$_lastSearchTerm」的其他源'
                      : '自动搜索并储存其他源'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(_SwitchRowData row, {required bool dark}) {
    final palette = widget.palette;
    final isCurrent = row.isCurrent;
    final switching = _switchingSourceId == row.source?.id;
    final badge = _confidenceBadge(row);
    final sourceName = row.source?.name.isNotEmpty == true
        ? row.source!.name
        : (row.pointer.sourceName.isNotEmpty
              ? row.pointer.sourceName
              : row.pointer.sourceId);

    String? subtitle;
    switch (row.status) {
      case _SwitchRowStatus.ready:
        if (isCurrent) {
          subtitle = row.targetChapterCount > 0 ? '当前源 · ${row.targetChapterCount} 章' : '当前源';
        } else {
          subtitle = row.alignedTitle != null
              ? '对齐到「${row.alignedTitle}」${row.targetChapterCount > 0 ? ' · ${row.targetChapterCount} 章' : ''}'
              : (row.targetChapterCount > 0 ? '${row.targetChapterCount} 章' : null);
        }
        break;
      case _SwitchRowStatus.loading:
        subtitle = '正在加载目录…';
        break;
      case _SwitchRowStatus.empty:
        subtitle = '该源返回空目录';
        break;
      case _SwitchRowStatus.error:
        subtitle = '目录加载失败';
        break;
      case _SwitchRowStatus.unavailable:
        subtitle = '源未注册或已禁用';
        break;
    }

    final canTap = !isCurrent &&
        row.source != null &&
        row.status != _SwitchRowStatus.unavailable &&
        _switchingSourceId == null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canTap ? () => unawaited(_onTapRow(row)) : null,
          borderRadius: BorderRadius.circular(MiduRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: dark ? MiduColors.glassDark : MiduColors.glassLight,
              borderRadius: BorderRadius.circular(MiduRadius.md),
              border: Border.all(
                color: isCurrent
                    ? MiduColors.brand
                    : (dark ? MiduColors.glassBorderDark : MiduColors.glassBorderLight),
                width: isCurrent ? 1.6 : 0.8,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? MiduColors.brand.withValues(alpha: 0.18)
                        : MiduColors.brandBg.withValues(alpha: dark ? 0.22 : 0.7),
                    borderRadius: BorderRadius.circular(MiduRadius.sm),
                    border: Border.all(
                      color: isCurrent
                          ? MiduColors.brand
                          : MiduColors.brandSoft.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    isCurrent ? Icons.check_rounded : Icons.menu_book_rounded,
                    size: 20,
                    color: isCurrent ? MiduColors.brand : MiduColors.brandDeep,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.secondaryText,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildTrailing(row, badge: badge, switching: switching),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrailing(
    _SwitchRowData row, {
    required ({String label, Color color})? badge,
    required bool switching,
  }) {
    if (switching) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: MiduColors.brand,
        ),
      );
    }
    if (row.isCurrent) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: MiduColors.brand,
          borderRadius: BorderRadius.circular(MiduRadius.xs),
        ),
        child: const Text(
          '当前',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    if (row.status == _SwitchRowStatus.loading) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: MiduColors.brandSoft,
        ),
      );
    }
    if (badge != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: badge.color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(MiduRadius.xs),
          border: Border.all(color: badge.color.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Text(
          '对齐 ${badge.label}',
          style: TextStyle(
            color: badge.color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    if (row.status == _SwitchRowStatus.error || row.status == _SwitchRowStatus.empty) {
      return Icon(
        Icons.error_outline_rounded,
        size: 18,
        color: MiduColors.danger.withValues(alpha: 0.7),
      );
    }
    return const SizedBox(width: 18);
  }
}
