// 文件说明：跨书源聚合搜索页，由发现页右上角搜索按钮进入。
// 技术要点：调用 BookSourceAggregatedSearch 三级相关性排序、紫色玻璃拟态 UI、按 tier 分组展示。

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_aggregated_search.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_shelf_service.dart';
import 'package:midu/utils/localization_extension.dart';
import 'package:midu/utils/glass_config.dart';
import 'package:midu/widgets/generated_book_cover.dart';
import 'package:midu/widgets/source_cover_image.dart';

import 'widgets/sourced_book_widgets.dart';

/// 跨已启用书源的聚合搜索页。
///
/// 搜索范围与结果状态都在本页内维护；结果按相关性 tier 分组展示。
class SourceSearchPage extends StatefulWidget {
  final List<RegisteredBookSource> sources;
  final BookSourceClient client;
  final BookSourceShelfService shelfService;

  const SourceSearchPage({
    super.key,
    required this.sources,
    required this.client,
    required this.shelfService,
  });

  /// 解析实际参与搜索的书源集合；发现页与测试也复用这份规则。
  static List<RegisteredBookSource> searchTargets(
    Iterable<RegisteredBookSource> sources,
    String? selectedSourceId,
  ) {
    final enabled = sources.where((source) => source.enabled);
    if (selectedSourceId == null) return enabled.toList(growable: false);
    return enabled
        .where((source) => source.id == selectedSourceId)
        .toList(growable: false);
  }

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  // 米读品牌紫
  static const Color _brandPurple = Color(0xFFE8503A);
  static const Color _brandPurpleLight = Color(0xFF9B7CF7);

  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  late final BookSourceAggregatedSearch _aggregated =
      BookSourceAggregatedSearch(widget.client);
  late final SourcedBookActions _actions = SourcedBookActions(
    context: context,
    client: widget.client,
    shelfService: widget.shelfService,
  );

  String? _selectedSourceId;
  List<AggregatedSearchHit> _results = const [];
  bool _searching = false;
  bool _hasSearched = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  int _failedSourceCount = 0;
  int _respondedSourceCount = 0;
  String _activeQuery = '';
  int _searchGeneration = 0;
  int _nextPage = 2;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    // 进入搜索页直接聚焦输入框，用户可立即输入。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_loadMoreFailed ||
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter > 600) {
      return;
    }
    unawaited(_loadMore());
  }

  List<RegisteredBookSource> get _targets =>
      SourceSearchPage.searchTargets(widget.sources, _selectedSourceId);

  Future<void> _search() async {
    final query = _queryController.text.trim();
    final targetSources = _targets;
    if (query.isEmpty || targetSources.isEmpty) {
      if (_searching && mounted) setState(() => _searching = false);
      return;
    }
    final generation = ++_searchGeneration;

    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _hasSearched = true;
      _failedSourceCount = 0;
      _respondedSourceCount = 0;
      _activeQuery = query;
      _results = const [];
      _loadingMore = false;
      _loadMoreFailed = false;
      _hasMore = false;
      _nextPage = 2;
    });

    AggregatedSearchPage page;
    try {
      page = await _aggregated.search(targetSources, query, page: 1);
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searching = false;
        _results = const [];
        _failedSourceCount = targetSources.length;
      });
      return;
    }

    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _results = page.hits;
      _failedSourceCount = page.perSourceErrors.length;
      _respondedSourceCount = page.respondedSourceCount;
      _hasMore = page.hasMore;
      _nextPage = 2;
      _searching = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleScroll());
  }

  Future<void> _loadMore() async {
    if (_searching || _loadingMore || !_hasSearched || _activeQuery.isEmpty) {
      return;
    }
    if (!_hasMore) return;
    final targets = _targets;
    final query = _activeQuery;
    final generation = _searchGeneration;
    final pageToFetch = _nextPage;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });

    AggregatedSearchPage page;
    try {
      page = await _aggregated.search(targets, query, page: pageToFetch);
    } catch (_) {
      if (!mounted || generation != _searchGeneration || query != _activeQuery) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
      return;
    }

    if (!mounted || generation != _searchGeneration || query != _activeQuery) {
      return;
    }
    // 跨页去重：以 (canonicalTitle, canonicalAuthor) 为 key
    final seen = _results
        .map((h) => '${h.canonicalTitle}\u0000${h.canonicalAuthor}')
        .toSet();
    final appended = <AggregatedSearchHit>[];
    for (final hit in page.hits) {
      final key = '${hit.canonicalTitle}\u0000${hit.canonicalAuthor}';
      if (seen.add(key)) appended.add(hit);
    }

    setState(() {
      _results = [..._results, ...appended];
      _hasMore = page.hasMore && appended.isNotEmpty;
      _nextPage = pageToFetch + 1;
      _loadingMore = false;
      _loadMoreFailed = false;
    });
  }

  void _clearSearch() {
    _searchGeneration++;
    _queryController.clear();
    setState(() {
      _results = const [];
      _hasSearched = false;
      _failedSourceCount = 0;
      _respondedSourceCount = 0;
      _activeQuery = '';
      _searching = false;
      _loadingMore = false;
      _loadMoreFailed = false;
      _hasMore = false;
      _nextPage = 2;
    });
    _queryFocus.requestFocus();
  }

  void _changeScope(String? sourceId) {
    if (_selectedSourceId == sourceId) return;
    _searchGeneration++;
    setState(() {
      _selectedSourceId = sourceId;
      if (_hasSearched) {
        _searching = true;
        _results = const [];
        _hasMore = false;
      }
    });
    if (_hasSearched && _activeQuery.isNotEmpty) {
      _queryController.text = _activeQuery;
      unawaited(_search());
    }
  }

  /// 将聚合 hit 还原为 SourcedBook 以复用既有详情/阅读/加入书架流程。
  SourcedBook _resolveSourcedBook(
    AggregatedSearchHit hit, {
    SourcedBookPointer? pointer,
  }) {
    final selected = pointer ?? hit.primary;
    RegisteredBookSource? source;
    for (final s in widget.sources) {
      if (s.id == selected.sourceId) {
        source = s;
        break;
      }
    }
    source ??= widget.sources.first;
    final book = selected.book ??
        BookSourceBook(
          id: selected.bookId,
          title: hit.canonicalTitle,
          author: hit.canonicalAuthor,
          coverUrl: hit.coverUrl,
          description: hit.description,
          latestChapter: hit.latestChapter,
          categories: hit.categories,
        );
    return SourcedBook(source: source, book: book);
  }

  /// 点击搜索结果：弹出源选择面板，让读者挑选具体书源后进入详情。
  void _openSourcePicker(AggregatedSearchHit hit) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => _SourcePickerSheet(
        margin: MediaQuery.viewInsetsOf(context),
        sources: widget.sources,
        hit: hit,
        onPick: (pointer) {
          Navigator.of(sheetContext).pop();
          if (!mounted) return;
          _actions.showBookDetails(
            _resolveSourcedBook(hit, pointer: pointer),
            alternativeSources: hit.sources,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabledSources = widget.sources
        .where((source) => source.enabled)
        .toList(growable: false);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: _buildBackgroundGradient(context)),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(enabledSources),
              if (enabledSources.isNotEmpty) _buildScopeChips(enabledSources),
              Expanded(child: _buildBody(enabledSources)),
            ],
          ),
        ),
      ),
    );
  }

  LinearGradient _buildBackgroundGradient(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      return const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1C1633), Color(0xFF13111C), Color(0xFF0E0D14)],
      );
    }
    return const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFECE6FF), Color(0xFFF6F2FF), Color(0xFFFBFAFF)],
    );
  }

  Widget _buildHeader(List<RegisteredBookSource> enabledSources) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () {
              final nav = Navigator.maybeOf(context);
              if (nav != null && nav.canPop()) nav.pop();
            },
          ),
          const SizedBox(width: 2),
          Expanded(child: _buildSearchBar(enabledSources)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(List<RegisteredBookSource> enabledSources) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canSearch = enabledSources.isNotEmpty && !_searching;
    return _GlassContainer(
      radius: 16,
      blur: 14,
      tint: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.62),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_brandPurple, _brandPurpleLight],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.search_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('bookSourceQueryControl'),
                controller: _queryController,
                focusNode: _queryFocus,
                enabled: canSearch,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: context.l10n.bookSourcesSearchHint,
                  hintStyle: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _brandPurple,
                  ),
                ),
              )
            else if (_queryController.text.isNotEmpty)
              IconButton(
                key: const Key('bookSourceSearchClearButton'),
                tooltip: MaterialLocalizations.of(
                  context,
                ).deleteButtonTooltip,
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: _clearSearch,
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildScopeChips(List<RegisteredBookSource> enabledSources) {
    return SizedBox(
      key: const Key('bookSourceScopeControl'),
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        children: [
          _buildScopeChip(
            label: context.l10n.statsRangeAll,
            selected: _selectedSourceId == null,
            onSelected: (_) => _changeScope(null),
          ),
          const SizedBox(width: 8),
          for (final source in enabledSources) ...[
            _buildScopeChip(
              label: source.name,
              selected: _selectedSourceId == source.id,
              onSelected: (_) => _changeScope(source.id),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildScopeChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return GestureDetector(
      onTap: () => onSelected(true),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(colors: [_brandPurple, _brandPurpleLight])
              : null,
          color: selected
              ? null
              : Colors.white.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.08
                      : 0.6,
                ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : _brandPurple.withValues(alpha: 0.25),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? Colors.white
                : (Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.85)
                      : const Color(0xFF4A4458)),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(List<RegisteredBookSource> enabledSources) {
    if (enabledSources.isEmpty) {
      return _buildMessage(
        icon: Icons.travel_explore_outlined,
        title: context.l10n.bookSourcesNoSourcesTitle,
        message: context.l10n.bookSourcesNoSourcesDescription,
      );
    }
    if (_searching) {
      return _buildLoadingView();
    }
    if (!_hasSearched) {
      return _buildEmptyInitial();
    }
    if (_results.isEmpty) {
      return _buildMessage(
        icon: Icons.search_off_rounded,
        title: context.l10n.bookSourcesNoResults,
        message: _failedSourceCount > 0
            ? context.l10n.bookSourcesFailedCount(_failedSourceCount)
            : '换一个关键词试试吧',
      );
    }
    return _buildResults();
  }

  Widget _buildResults() {
    final groups = _tierGroups();
    final scheme = Theme.of(context).colorScheme;
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '为「$_activeQuery」找到 ${_results.length} 本'
                    '${_respondedSourceCount > 0 ? ' · $_respondedSourceCount 个源响应' : ''}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_failedSourceCount > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.bookSourcesFailedCount(_failedSourceCount),
                style: TextStyle(color: scheme.error, fontSize: 11),
              ),
            ),
          ),
        for (var i = 0; i < groups.length; i++) ...[
          if (groups[i].isNotEmpty) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              sliver: SliverToBoxAdapter(
                child: _buildTierHeader(i, groups[i].length),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              sliver: SliverList.builder(
                itemCount: groups[i].length,
                itemBuilder: (context, index) =>
                    _buildResultCard(groups[i][index]),
              ),
            ),
          ],
        ],
        if (_hasMore || _loadingMore || _loadMoreFailed)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: _brandPurple,
                        ),
                      )
                    : _buildLoadMoreButton(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLoadMoreButton() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [_brandPurple, _brandPurpleLight]),
        borderRadius: BorderRadius.circular(24),
      ),
      child: TextButton.icon(
        key: const Key('bookSourceLoadMoreButton'),
        onPressed: _loadMore,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
        icon: Icon(
          _loadMoreFailed ? Icons.refresh_rounded : Icons.expand_more_rounded,
        ),
        label: Text(
          _loadMoreFailed
              ? context.l10n.retry
              : context.l10n.bookSourcesLoadMore,
        ),
      ),
    );
  }

  /// 按 tier 分组：0 完全匹配 / 1 书名匹配 / 2 相关结果
  List<List<AggregatedSearchHit>> _tierGroups() {
    final g0 = <AggregatedSearchHit>[];
    final g1 = <AggregatedSearchHit>[];
    final g2 = <AggregatedSearchHit>[];
    for (final hit in _results) {
      switch (hit.tier) {
        case 0:
          g0.add(hit);
          break;
        case 1:
          g1.add(hit);
          break;
        default:
          g2.add(hit);
      }
    }
    return [g0, g1, g2];
  }

  Widget _buildTierHeader(int tier, int count) {
    final (label, color) = switch (tier) {
      0 => ('完全匹配', const Color(0xFF22C55E)),
      1 => ('书名匹配', const Color(0xFFF59E0B)),
      _ => ('相关结果', const Color(0xFF6B7280)),
    };
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count 本',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard(AggregatedSearchHit hit) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _GlassContainer(
        radius: 20,
        blur: 10,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openSourcePicker(hit),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HitCoverThumb(hit: hit),
                  const SizedBox(width: 12),
                  Expanded(child: _buildCardText(hit)),
                  const SizedBox(width: 8),
                  _buildCardMeta(hit),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardText(AggregatedSearchHit hit) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hit.canonicalTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          hit.canonicalAuthor.isEmpty ? '未知作者' : hit.canonicalAuthor,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
        if ((hit.description ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            hit.description!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              height: 1.3,
            ),
          ),
        ],
        if (hit.latestChapter != null && hit.latestChapter!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '最新 : ${hit.latestChapter}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: _brandPurple,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (hit.lastUpdateTime != null) ...[
          const SizedBox(height: 2),
          Text(
            '更新 : ${_formatUpdateTime(hit.lastUpdateTime!)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  /// 更新时间格式化为 "YYYY-MM-DD"；距今时间短时显示相对时间（今天/昨天）。
  String _formatUpdateTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '$diff 天前';
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  Widget _buildCardMeta(AggregatedSearchHit hit) {
    final count = hit.sources.length;
    final multi = count > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            gradient: multi
                ? const LinearGradient(
                    colors: [_brandPurple, _brandPurpleLight],
                  )
                : null,
            color: multi
                ? null
                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count个源',
            style: TextStyle(
              color: multi
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (hit.tier == 2 && hit.score > 0) ...[
          const SizedBox(height: 6),
          _buildRelevanceIndicator(hit.score),
        ],
        const SizedBox(height: 4),
        Icon(
          Icons.chevron_right_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 20,
        ),
      ],
    );
  }

  Widget _buildRelevanceIndicator(double score) {
    final pct = (score * 100).clamp(0, 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '相关度 $pct%',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            width: 44,
            height: 4,
            child: LinearProgressIndicator(
              value: score.clamp(0.0, 1.0),
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .outline
                  .withValues(alpha: 0.2),
              color: _brandPurple,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyInitial() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GlassContainer(
              radius: 64,
              blur: 16,
              tint: _brandPurple.withValues(
                alpha: isDark ? 0.18 : 0.12,
              ),
              child: SizedBox(
                width: 104,
                height: 104,
                child: const Icon(
                  Icons.auto_stories_rounded,
                  size: 46,
                  color: _brandPurple,
                ),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              '搜索你的下一本好书',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '跨多个书源聚合，按相关性排序',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const _SearchLoadingView();
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String message,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 42,
              color: _brandPurple.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
//  玻璃拟态容器
// ============================================================

class _GlassContainer extends StatelessWidget {
  const _GlassContainer({
    required this.child,
    this.radius = 16,
    this.blur = 12,
    this.tint,
  });

  final Widget child;
  final double radius;
  final double blur;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseTint = tint ??
        (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.55));
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        enabled: !GlassEffectConfig.shouldDisableBlur,
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: baseTint,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(
                alpha: isDark ? 0.12 : 0.4,
              ),
              width: 0.8,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ============================================================
//  结果卡片封面缩略图
// ============================================================

class _HitCoverThumb extends StatelessWidget {
  const _HitCoverThumb({required this.hit});

  final AggregatedSearchHit hit;

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: 50,
      height: 70,
      child: GeneratedBookCover(
        title: hit.canonicalTitle,
        author: hit.canonicalAuthor,
      ),
    );
    if (hit.coverUrl == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: fallback,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SourceCoverImage(
        url: hit.coverUrl!,
        width: 50,
        height: 70,
        fit: BoxFit.cover,
        cacheWidth: (50 * MediaQuery.devicePixelRatioOf(context)).round(),
        fallback: fallback,
      ),
    );
  }
}

// ============================================================
//  搜索中：紫色 shimmer 占位
// ============================================================

class _SearchLoadingView extends StatefulWidget {
  const _SearchLoadingView();

  @override
  State<_SearchLoadingView> createState() => _SearchLoadingViewState();
}

class _SearchLoadingViewState extends State<_SearchLoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: const CircularProgressIndicator(
                strokeWidth: 1.8,
                color: _SourceSearchPageState._brandPurple,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '正在跨源搜索…',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ShimmerCard(animation: _ctrl),
          ),
      ],
    );
  }
}

class _ShimmerCard extends StatelessWidget {
  const _ShimmerCard({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final baseAlpha = isDark ? 0.06 : 0.5;
        final peakAlpha = isDark ? 0.14 : 0.78;
        final alpha = baseAlpha + (peakAlpha - baseAlpha) * t;
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            enabled: !GlassEffectConfig.shouldDisableBlur,
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              height: 94,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: alpha),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(
                    alpha: isDark ? 0.1 : 0.35,
                  ),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 70,
                    decoration: BoxDecoration(
                      color: _SourceSearchPageState._brandPurple.withValues(
                        alpha: 0.16 + 0.1 * t,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 14,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: _SourceSearchPageState._brandPurple
                                .withValues(alpha: 0.14 + 0.1 * t),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 10,
                          width: 130,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: isDark ? 0.1 : 0.5,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 8,
                          width: 90,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: isDark ? 0.06 : 0.4,
                            ),
                            borderRadius: BorderRadius.circular(4),
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
      },
    );
  }
}

// ============================================================
//  结果点击后的源选择面板
// ============================================================

class _SourcePickerSheet extends StatelessWidget {
  const _SourcePickerSheet({
    required this.margin,
    required this.sources,
    required this.hit,
    required this.onPick,
  });

  final EdgeInsets margin;
  final List<RegisteredBookSource> sources;
  final AggregatedSearchHit hit;
  final ValueChanged<SourcedBookPointer> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sourceMap = <String, RegisteredBookSource>{
      for (final s in sources) s.id: s,
    };
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择书源（${hit.sources.length} 个）',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    hit.canonicalTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Flexible(
              child: DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.6,
                minChildSize: 0.35,
                maxChildSize: 0.9,
                builder: (context, scrollController) => ListView.separated(
                  controller: scrollController,
                  itemCount: hit.sources.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final pointer = hit.sources[index];
                    final source = sourceMap[pointer.sourceId];
                    final book = pointer.book;
                    return _SourcePickerTile(
                      pointer: pointer,
                      sourceName: source?.name ?? pointer.sourceName,
                      enabled: source?.enabled ?? true,
                      latestChapter: book?.latestChapter,
                      lastUpdateTime: book?.lastUpdateTime,
                      onTap: () => onPick(pointer),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourcePickerTile extends StatelessWidget {
  const _SourcePickerTile({
    required this.pointer,
    required this.sourceName,
    required this.enabled,
    required this.onTap,
    this.latestChapter,
    this.lastUpdateTime,
  });

  final SourcedBookPointer pointer;
  final String sourceName;
  final bool enabled;
  final String? latestChapter;
  final DateTime? lastUpdateTime;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFE8503A),
                      Color(0xFF9B7CF7),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size: 16,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sourceName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (latestChapter != null && latestChapter!.isNotEmpty)
                      Text(
                        latestChapter!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (lastUpdateTime != null)
                      Text(
                        '更新 : ${_searchDateFormat(lastUpdateTime!)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _searchDateFormat(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}
