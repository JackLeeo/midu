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
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.backgroundStart, palette.backgroundEnd],
          stops: const [0, 0.58],
        ),
      ),
      child: _isInitialLoading
          ? Center(
              child: CircularProgressIndicator(
                color: const Color(0xFFE8503A),
                strokeWidth: 2.4,
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadAllStats,
              edgeOffset: metrics.refreshEdgeOffset,
              color: const Color(0xFFE8503A),
              backgroundColor: palette.cardColor,
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  SliverPersistentHeader(
                    pinned: false,
                    delegate: _HeroHeaderDelegate(
                      greeting: _greetingForTime(DateTime.now()),
                      bookCount: _recentBooks.length,
                      todayMinutes: _todayMinutes,
                      topInset: mediaQuery.padding.top,
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildListDelegate([
                      const SizedBox(height: 16),
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
                      const SizedBox(height: 20),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildQuickActions(),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildSectionLabel(
                            context.l10n.homeRecentReading,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: _buildRecentBooksCarousel(carouselBooks),
                      ),
                      const SizedBox(height: 24),
                      _buildMaxWidthBox(
                        maxWidth: maxWidth,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: metrics.horizontalPadding,
                          ),
                          child: _buildWeeklyMiniStats(),
                        ),
                      ),
                      SizedBox(height: metrics.contentBottomPadding + 16),
                    ]),
                  ),
                ],
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
    final progress = book.progress;
    final percent = (progress * 100).round();
    final coverWidth = spacious ? 110.0 : 100.0;
    final coverHeight = spacious ? 154.0 : 140.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openBook(book),
        borderRadius: BorderRadius.circular(24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              key: const ValueKey('home-continue-reading-card'),
              padding: EdgeInsets.all(spacious ? 22 : 18),
              decoration: BoxDecoration(
                color: _glassBackgroundColor(),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _glassBorderColor(), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8503A).withValues(alpha: 0.18),
                    blurRadius: 26,
                    offset: const Offset(0, 12),
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
                    radius: 12,
                    elevated: true,
                  ),
                  SizedBox(width: spacious ? 24 : 20),
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
                            color:
                                const Color(0xFFE8503A).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: const Text(
                            '继续阅读',
                            style: TextStyle(
                              color: Color(0xFFE8503A),
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
                                  valueColor: const AlwaysStoppedAnimation<Color>(
                                    Color(0xFFE8503A),
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
                          style: const TextStyle(
                            color: Color(0xFFE8503A),
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
        ),
      ),
    );
  }

  Widget _buildContinueReadingEmptyCard() {
    final palette = _palette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _navigateToSearch,
        borderRadius: BorderRadius.circular(24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              key: const ValueKey('home-continue-reading-empty-card'),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _glassBackgroundColor(),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _glassBorderColor(), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8503A).withValues(alpha: 0.12),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color:
                          const Color(0xFFE8503A).withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.search_rounded,
                      color: Color(0xFFE8503A),
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
                            fontSize: 18,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _buildQuickActionButton(
            icon: Icons.search_rounded,
            label: context.l10n.search,
            onTap: _navigateToSearch,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuickActionButton(
            icon: Icons.explore_rounded,
            label: context.l10n.discover,
            onTap: _navigateToDiscover,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuickActionButton(
            icon: Icons.dns_rounded,
            label: context.l10n.bookSources,
            onTap: _navigateToBookSources,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final palette = _palette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: _glassBackgroundColor(),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _glassBorderColor(), width: 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: const Color(0xFFE8503A), size: 22),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: palette.primaryTextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
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
      height: 200,
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
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 130,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBookCover(
                book,
                width: 120,
                height: 168,
                radius: 10,
                elevated: true,
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.primaryTextColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyMiniStats() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openStats,
        borderRadius: BorderRadius.circular(20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              key: const ValueKey('home-weekly-mini-stats-card'),
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              decoration: BoxDecoration(
                color: _glassBackgroundColor(),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _glassBorderColor(), width: 1),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      _buildMiniStat(
                        value: _formatNumber(_todayMinutes),
                        unit: context.l10n.unitMinute,
                        label: context.l10n.statsToday,
                      ),
                      _buildMiniStatDivider(),
                      _buildMiniStat(
                        value: _formatNumber((_weekMinutes / 60).round()),
                        unit: 'h',
                        label: context.l10n.homeWeeklyTotal,
                      ),
                      _buildMiniStatDivider(),
                      _buildMiniStat(
                        value: _formatNumber((_totalMinutes / 60).round()),
                        unit: 'h',
                        label: context.l10n.homeTotalReading,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _buildWeeklyRhythm(),
                ],
              ),
            ),
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
    return Expanded(
      child: Column(
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
      ),
    );
  }

  Widget _buildMiniStatDivider() {
    return Container(
      width: 1,
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: _palette.outlineColor,
    );
  }

  Widget _buildSectionLabel(String title) {
    final palette = _palette;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          title,
          style: TextStyle(
            color: palette.primaryTextColor,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
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

  Future<void> _navigateToBookSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BookSourceManagementPage(),
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

class _HeroHeaderDelegate extends SliverPersistentHeaderDelegate {
  _HeroHeaderDelegate({
    required this.greeting,
    required this.bookCount,
    required this.todayMinutes,
    required this.topInset,
  });

  final String greeting;
  final int bookCount;
  final int todayMinutes;
  final double topInset;

  @override
  double get minExtent => 180;

  @override
  double get maxExtent => 200;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(28),
        bottomRight: Radius.circular(28),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE8503A), Color(0xFFE8503A)],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            top: topInset + 18,
            left: 20,
            right: 20,
            bottom: 26,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '米读',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Row(
                    children: [
                      _buildHeroBadge('📖 $bookCount本'),
                      const SizedBox(width: 12),
                      _buildHeroBadge('⏱ $todayMinutes分'),
                    ],
                  ),
                ],
              ),
              Text(
                greeting,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroBadge(String text) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _HeroHeaderDelegate oldDelegate) {
    return greeting != oldDelegate.greeting ||
        bookCount != oldDelegate.bookCount ||
        todayMinutes != oldDelegate.todayMinutes ||
        topInset != oldDelegate.topInset;
  }
}
