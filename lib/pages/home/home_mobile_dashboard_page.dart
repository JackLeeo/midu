// 文件说明：响应式首页，聚焦继续阅读、阅读节奏与最近阅读。
// 技术要点：Flutter UI、本地阅读统计、文件封面渲染。

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';
import 'package:midu/book_sources/services/book_source_shelf_service.dart';
import 'package:midu/core/reader/native_reader_service.dart';
import 'package:midu/models/book.dart';
import 'package:midu/pages/book_sources/book_source_management_page.dart';
import 'package:midu/pages/book_sources/book_sources_page.dart';
import 'package:midu/pages/book_sources/source_search_page.dart';
import 'package:midu/pages/reader/book_source_reader_page.dart';
import 'package:midu/pages/reading_stats/detailed_stats_page.dart';
import 'package:midu/services/books/book_services.dart';
import 'package:midu/services/library/library_event_bus_service.dart';
import 'package:midu/services/reading/reading_stats_dao.dart';
import 'package:midu/utils/book_open_transition.dart';
import 'package:midu/utils/layout_helper.dart';
import 'package:midu/utils/localization_extension.dart';
import 'package:midu/utils/page_style_helper.dart';
import 'package:midu/utils/page_transitions.dart';
import 'package:midu/widgets/generated_book_cover.dart';
import 'package:midu/widgets/side_toast.dart';

import 'home_mobile_chrome.dart';

class _HomeContentMetrics {
  final double refreshEdgeOffset;
  final double horizontalPadding;
  final double contentTopPadding;
  final double contentBottomPadding;

  const _HomeContentMetrics({
    required this.refreshEdgeOffset,
    required this.horizontalPadding,
    required this.contentTopPadding,
    required this.contentBottomPadding,
  });
}

class _HomePalette {
  final Color backgroundStart;
  final Color backgroundEnd;
  final Color cardColor;
  final Color heroColor;
  final Color primaryTextColor;
  final Color secondaryTextColor;
  final Color accentColor;
  final Color outlineColor;
  final Color mutedColor;
  final Color shadowColor;

  const _HomePalette({
    required this.backgroundStart,
    required this.backgroundEnd,
    required this.cardColor,
    required this.heroColor,
    required this.primaryTextColor,
    required this.secondaryTextColor,
    required this.accentColor,
    required this.outlineColor,
    required this.mutedColor,
    required this.shadowColor,
  });

  factory _HomePalette.fromTheme(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return _HomePalette(
      backgroundStart: Color.alphaBlend(
        scheme.primary.withValues(alpha: isDark ? 0.10 : 0.045),
        scheme.surface,
      ),
      backgroundEnd: scheme.surface,
      cardColor: scheme.surfaceContainerLow,
      heroColor: Color.alphaBlend(
        scheme.primary.withValues(alpha: isDark ? 0.16 : 0.085),
        scheme.surfaceContainerLow,
      ),
      primaryTextColor: scheme.onSurface,
      secondaryTextColor: scheme.onSurfaceVariant,
      accentColor: scheme.primary,
      outlineColor: scheme.outlineVariant.withValues(
        alpha: isDark ? 0.56 : 0.7,
      ),
      mutedColor: scheme.surfaceContainerHighest,
      shadowColor: scheme.shadow.withValues(alpha: isDark ? 0.18 : 0.055),
    );
  }
}

class HomeDashboardController extends ChangeNotifier {
  /// 米读：首页快捷入口"发现"按钮的回调。
  /// 由 HomeShellPage 设置，切换底栏到发现页 tab，避免 push 新实例。
  VoidCallback? onNavigateToDiscover;

  void refresh() => notifyListeners();
}

class HomeMobileDashboardPage extends StatefulWidget {
  const HomeMobileDashboardPage({super.key, this.controller});

  final HomeDashboardController? controller;

  @visibleForTesting
  static Widget? buildOnlineReader({
    required Book book,
    required BookSourceClient client,
    required BookSourceShelfService shelfService,
  }) {
    if (!book.isOnline) return null;
    return BookSourceReaderPage(
      source: shelfService.sourceFrom(book),
      book: shelfService.sourceBookFrom(book),
      client: client,
      shelfService: shelfService,
    );
  }

  @override
  State<HomeMobileDashboardPage> createState() =>
      _HomeMobileDashboardPageState();
}

class _HomeMobileDashboardPageState extends State<HomeMobileDashboardPage>
    with WidgetsBindingObserver {
  final _statsDao = ReadingStatsDao();
  final _bookDao = BookDao();
  late final BookSourceClient _sourceClient;
  late final BookSourceShelfService _sourceShelfService;
  StreamSubscription<void>? _libraryChangedSubscription;

  Map<String, int> _summaryStats = {};
  List<Map<String, dynamic>> _weeklyData = [];
  List<Book> _recentBooks = [];
  bool _isInitialLoading = true;
  int _loadGeneration = 0;

  _HomePalette get _palette => _HomePalette.fromTheme(Theme.of(context));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sourceClient = BookSourceClient.shared();
    _sourceShelfService = BookSourceShelfService(client: _sourceClient);
    widget.controller?.addListener(_handleRefreshRequest);
    _loadAllStats();
    _libraryChangedSubscription = LibraryEventBus().stream.listen((_) {
      if (mounted) _loadAllStats();
    });
  }

  @override
  void didUpdateWidget(covariant HomeMobileDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller?.removeListener(_handleRefreshRequest);
    widget.controller?.addListener(_handleRefreshRequest);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAllStats();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.removeListener(_handleRefreshRequest);
    _libraryChangedSubscription?.cancel();
    super.dispose();
  }

  void _handleRefreshRequest() {
    if (mounted) _loadAllStats();
  }

  Future<void> _loadAllStats() async {
    final loadGeneration = ++_loadGeneration;
    try {
      final summaryFuture = _statsDao.getSummaryStats();
      final weeklyFuture = _statsDao.getWeeklyChartData();
      final recentBooksFuture = _loadRecentBooks();

      final summary = await summaryFuture;
      final weekly = await weeklyFuture;
      final recentBooks = await recentBooksFuture;

      if (!mounted || loadGeneration != _loadGeneration) return;
      setState(() {
        _summaryStats = summary;
        _weeklyData = weekly;
        _recentBooks = recentBooks;
        _isInitialLoading = false;
      });
    } catch (_) {
      if (!mounted || loadGeneration != _loadGeneration) return;
      setState(() => _isInitialLoading = false);
    }
  }

  Future<List<Book>> _loadRecentBooks() async {
    try {
      final orderedBookIds = await _statsDao.getRecentBookIds(limit: 6);
      final books = <Book>[];
      final seen = <int>{};

      for (final id in orderedBookIds) {
        final book = await _bookDao.getBookById(id);
        if (book == null) continue;
        books.add(book);
        seen.add(id);
      }

      if (books.isNotEmpty) {
        return books.take(6).toList(growable: false);
      }

      final allBooks = await _bookDao.getAllBooks();
      final fallback = allBooks.where((book) => book.currentPage > 0).toList()
        ..sort((a, b) {
          final progressComparison = b.currentPage.compareTo(a.currentPage);
          return progressComparison != 0
              ? progressComparison
              : b.importDate.compareTo(a.importDate);
        });
      return fallback.take(6).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  _HomeContentMetrics _computeMetrics(
    MediaQueryData mediaQuery, {
    required bool useRailNavigation,
  }) {
    final mobileChrome = HomeMobileChromeScope.of(context);
    return _HomeContentMetrics(
      refreshEdgeOffset: useRailNavigation
          ? mediaQuery.viewPadding.top
          : mobileChrome.topBarHeight,
      horizontalPadding: useRailNavigation
          ? (mediaQuery.size.width >= 1440 ? 36 : 28)
          : 18,
      contentTopPadding: useRailNavigation
          ? mediaQuery.viewPadding.top + 28
          : mobileChrome.pageTopPadding + 6,
      contentBottomPadding: useRailNavigation
          ? mediaQuery.viewPadding.bottom + 36
          : mobileChrome.pageBottomPadding + 12,
    );
  }

  int get _todayMinutes => (_summaryStats['today'] ?? 0) ~/ 60;
  int get _weekMinutes => (_summaryStats['week'] ?? 0) ~/ 60;
  int get _totalMinutes => (_summaryStats['total'] ?? 0) ~/ 60;

  String _formatNumber(int number) {
    final raw = number.toString();
    return raw.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  }

  void _openStats() {
    Navigator.of(context).pushWithSlideScale(const DetailedStatsPage());
  }

  Future<void> _openBook(Book book) async {
    final openingActivity = BookOpenTransition.beginActivity();
    try {
      final fullBook = book.id == null
          ? book
          : await _bookDao.getBookById(book.id!);
      if (fullBook == null || !mounted) return;

      if (fullBook.isOnline) {
        try {
          final reader = HomeMobileDashboardPage.buildOnlineReader(
            book: fullBook,
            client: _sourceClient,
            shelfService: _sourceShelfService,
          )!;
          final route = BookOpenTransition.createRoute<void>(
            reader,
            origin: ReaderPageTransitionOrigin.home,
            waitForReaderReady: true,
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
          origin: ReaderPageTransitionOrigin.home,
        );
      }
      if (mounted) await _loadAllStats();
    } finally {
      openingActivity.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final useRailNavigation =
        LayoutHelper.getNavigationType(context) == NavigationType.rail;
    final metrics = _computeMetrics(
      mediaQuery,
      useRailNavigation: useRailNavigation,
    );
    final palette = _palette;
    final maxWidth = useRailNavigation
        ? (mediaQuery.size.width >= 1600 ? 1080.0 : 920.0)
        : double.infinity;
    final firstBook = _recentBooks.isEmpty ? null : _recentBooks.first;
    final carouselBooks = _recentBooks.skip(1).toList(growable: false);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: _isInitialLoading
          ? Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).colorScheme.primary,
                strokeWidth: 2.4,
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadAllStats,
              edgeOffset: metrics.refreshEdgeOffset,
              color: Theme.of(context).colorScheme.primary,
              backgroundColor: palette.cardColor,
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  SliverList(
                    delegate: SliverChildListDelegate([
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildWarmIntro(),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildSearchEntry(),
                        ),
                      ),
                      const SizedBox(height: 26),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildContinueReadingCard(
                            firstBook,
                            spacious: useRailNavigation,
                          ),
                        ),
                      ),
                      const SizedBox(height: 26),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildWeeklyMiniStats(),
                        ),
                      ),
                      const SizedBox(height: 26),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildReadingFootprint(),
                        ),
                      ),
                      const SizedBox(height: 26),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildSectionLabel(
                            context.l10n.homeRecentReading,
                            onMore: _openStats,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: _buildRecentBooksCarousel(carouselBooks),
                      ),
                      SizedBox(height: metrics.contentBottomPadding + 16),
                    ]),
                  ),
                ],
              ),
            ),
    );
  }

  /// 顶部暖色引言：头像位 + 问候，营造温馨阅读主页的开场。
  Widget _buildWarmIntro() {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          18,
          18,
          18,
          Theme.of(context).brightness == Brightness.dark ? 6 : 10,
        ),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            scheme.primary.withValues(alpha: isDark ? 0.16 : 0.10),
            scheme.surfaceContainerLow.withValues(alpha: 0.9),
          ),
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: scheme.primary.withValues(alpha: 0.16),
              child: Icon(
                Icons.menu_book_rounded,
                color: scheme.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _greetingForTime(DateTime.now()),
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Icon(
              Icons.auto_stories_rounded,
              color: scheme.primary.withValues(alpha: 0.85),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  /// 醒目搜索入口：圆角胶囊，点击进入既有搜索流程。
  Widget _buildSearchEntry() {
    final palette = _palette;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _navigateToSearch,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: scheme.outline.withValues(alpha: isDark ? 0.3 : 0.12),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: isDark ? 0.10 : 0.04),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.search,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.secondaryTextColor,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  color: scheme.onPrimary,
                  size: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 阅读足迹轻量小卡片（今日 / 本周 / 累计时长）。
  Widget _buildReadingFootprint() {
    return Row(
      children: [
        _buildStatCard(
          value: _formatNumber(_todayMinutes),
          unit: context.l10n.unitMinute,
          label: context.l10n.statsToday,
          onTap: _openStats,
        ),
        const SizedBox(width: 12),
        _buildStatCard(
          value: _formatNumber(_weekMinutes),
          unit: context.l10n.unitMinute,
          label: context.l10n.homeWeeklyTotal,
          onTap: _openStats,
        ),
        const SizedBox(width: 12),
        _buildStatCard(
          value: _formatNumber(_totalMinutes),
          unit: context.l10n.unitMinute,
          label: context.l10n.homeTotalReading,
          onTap: _openStats,
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String value,
    required String unit,
    required String label,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            child: _buildMiniStat(value: value, unit: unit, label: label),
          ),
        ),
      ),
    );
  }

  Widget _buildMaxWidthBox({
    required double maxWidth,
    required Widget child,
  }) {
    if (maxWidth == double.infinity) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }

  Color _glassBackgroundColor() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.03);
  }

  Color _glassBorderColor() {
    return Colors.white.withValues(alpha: 0.12);
  }

  String _greetingForTime(DateTime time) {
    final hour = time.hour;
    if (hour >= 18) return '晚上好';
    if (hour >= 12) return '下午好';
    if (hour >= 6) return '上午好';
    return '夜深了';
  }

  Widget _buildContinueReadingCard(Book? book, {required bool spacious}) {
    if (book == null) {
      return _buildContinueReadingEmptyCard();
    }

    final palette = _palette;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = book.progress;
    final percent = (progress * 100).round();
    final coverWidth = spacious ? 112.0 : 100.0;
    final coverHeight = spacious ? 168.0 : 150.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openBook(book),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          key: const ValueKey('home-continue-reading-card'),
          padding: EdgeInsets.all(spacious ? 22 : 18),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outline.withValues(alpha: isDark ? 0.3 : 0.12),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: isDark ? 0.12 : 0.05),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildBookCover(
                book,
                width: coverWidth,
                height: coverHeight,
                radius: 8,
                elevated: true,
              ),
              SizedBox(width: spacious ? 24 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        '继续阅读',
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    SizedBox(height: spacious ? 14 : 12),
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.primaryTextColor,
                        fontSize: spacious ? 24 : 22,
                        height: 1.16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.secondaryTextColor,
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: spacious ? 16 : 14),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 6,
                              backgroundColor: palette.mutedColor,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                scheme.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '$percent%',
                          style: TextStyle(
                            color: palette.secondaryTextColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: spacious ? 14 : 12),
                    Text(
                      '→ ${context.l10n.continueReading}',
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
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

  Widget _buildContinueReadingEmptyCard() {
    final palette = _palette;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        // 空态卡片引导去书城发现好书，不再重复承担搜索入口职责。
        onTap: _navigateToDiscover,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          key: const ValueKey('home-continue-reading-empty-card'),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outline.withValues(alpha: isDark ? 0.3 : 0.12),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.explore_rounded,
                  color: scheme.primary,
                  size: 26,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.homeTodayReadingJourneyStart,
                      style: TextStyle(
                        color: palette.primaryTextColor,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.homeNoRecentReading,
                      style: TextStyle(
                        color: palette.secondaryTextColor,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: palette.secondaryTextColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentBooksCarousel(List<Book> books) {
    if (books.isEmpty) {
      final palette = _palette;
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(
            context.l10n.homeTodayReadingJourneyStart,
            style: TextStyle(
              color: palette.secondaryTextColor,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 210,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: books.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) => _buildCarouselItem(books[index]),
      ),
    );
  }

  Widget _buildCarouselItem(Book book) {
    final palette = _palette;
    final progress = (book.progress * 100).round();
    return Semantics(
      button: true,
      label:
          '${book.title}，${context.l10n.homeReadingProgressPercent('$progress')}',
      child: InkWell(
        onTap: () => _openBook(book),
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 108,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBookCover(
                book,
                width: 104,
                height: 156,
                radius: 8,
                elevated: true,
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.primaryTextColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                book.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.secondaryTextColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyMiniStats() {
    final scheme = Theme.of(context).colorScheme;
    final palette = _palette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openStats,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          key: const ValueKey('home-weekly-mini-stats-card'),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _glassBorderColor(), width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 14,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '近7天阅读节奏',
                    style: TextStyle(
                      color: palette.primaryTextColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildWeeklyRhythm(),
            ],
          ),
        ),
      ),
    );
  }

  /// 近 7 天阅读时间迷你柱状条：强化首页「阅读节奏」焦点。
  Widget _buildWeeklyRhythm() {
    final palette = _palette;
    final values = _weeklyData
        .take(7)
        .map((item) {
          final raw =
              item['readingTime'] ??
              item['duration'] ??
              item['minutes'] ??
              item['value'] ??
              0;
          return raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
        })
        .toList(growable: false);
    while (values.length < 7) {
      values.add(0);
    }
    final maxValue = values.fold<double>(0, (a, b) => a > b ? a : b);
    final hasData = maxValue > 0;
    const barWidth = 4.0, gap = 6.0;
    final rowWidth = 7 * barWidth + 6 * gap;
    final today = DateTime.now().weekday;

    return Row(
      children: [
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                context.l10n.homeWeeklyTotal,
                style: TextStyle(
                  color: palette.secondaryTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (hasData)
                Text(
                  '${_formatNumber(_weekMinutes)} ${context.l10n.unitMinute}',
                  style: TextStyle(
                    color: palette.secondaryTextColor,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: rowWidth,
          height: 26,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (index) {
              final current = index == today - 1;
              final height = hasData
                  ? 6 + (20 * (values[index] / maxValue)).clamp(0.0, 20.0)
                  : 6.0;
              return Container(
                width: barWidth,
                height: height,
                decoration: BoxDecoration(
                  color: current
                      ? const Color(0xFFE8503A)
                      : (hasData
                          ? const Color(0xFFE8503A).withValues(alpha: 0.35)
                          : palette.outlineColor),
                  borderRadius: BorderRadius.circular(99),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStat({
    required String value,
    required String unit,
    required String label,
  }) {
    final palette = _palette;
    return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: const TextStyle(
                    color: Color(0xFFE8503A),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  unit,
                  style: TextStyle(
                    color: palette.secondaryTextColor,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.secondaryTextColor,
              fontSize: 12,
            ),
          ),
        ],
      );
  }

  Widget _buildSectionLabel(String title, {VoidCallback? onMore}) {
    final palette = _palette;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: palette.primaryTextColor,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (onMore != null)
          InkWell(
            onTap: onMore,
            borderRadius: BorderRadius.circular(99),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                '更多 ›',
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _navigateToSearch() async {
    try {
      final sources = await BookSourceRegistry().loadRunnable();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SourceSearchPage(
            sources: sources,
            client: _sourceClient,
            shelfService: _sourceShelfService,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        showSideToast(context, '$error', kind: SideToastKind.error);
      }
    }
  }

  Future<void> _navigateToDiscover() async {
    // 米读：优先用回调切换底栏到发现页 tab，避免 push 新实例造成双页面。
    final callback = widget.controller?.onNavigateToDiscover;
    if (callback != null) {
      callback();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BookSourcesPage(),
      ),
    );
  }

  Widget _buildBookCover(
    Book book, {
    required double width,
    required double height,
    required double radius,
    bool elevated = false,
  }) {
    final fallback = GeneratedBookCover(title: book.title, author: book.author);
    final coverPath = book.coverImagePath?.trim() ?? '';
    final cover = !kIsWeb && coverPath.isNotEmpty
        ? Image.file(
            File(coverPath),
            fit: LayoutHelper.bookCoverFit,
            cacheWidth: width.isFinite
                ? (width * MediaQuery.devicePixelRatioOf(context)).round()
                : null,
            errorBuilder: (_, _, _) => fallback,
          )
        : fallback;

    return Container(
      width: width,
      height: height,
      decoration: elevated
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                  color: _palette.shadowColor.withValues(alpha: 0.9),
                  blurRadius: 18,
                  offset: const Offset(0, 9),
                ),
              ],
            )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: cover,
      ),
    );
  }
}
