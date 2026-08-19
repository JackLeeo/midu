// 文件说明：发现页，聚合展示已启用书源的推荐、分类与最新书籍。
// 技术要点：Flutter UI、按 Tab 缓存的书源请求、下拉刷新。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';
import 'package:midu/book_sources/services/book_source_shelf_service.dart';
import 'package:midu/pages/home/home_mobile_chrome.dart';
import 'package:midu/pages/home/home_shell_page.dart';
import 'package:midu/utils/localization_extension.dart';
import 'package:midu/utils/page_style_helper.dart';
import 'package:midu/widgets/generated_book_cover.dart';
import 'package:midu/widgets/source_cover_image.dart';

import 'book_source_management_page.dart';
import 'discovery_cache_service.dart';
import 'source_search_page.dart';
import 'widgets/sourced_book_widgets.dart';

/// 发现页：只负责展示书籍内容。
///
/// 搜索收纳在顶栏的搜索按钮里（独立页面），书源配置收纳在管理页。
class BookSourcesPage extends StatefulWidget {
  final BookSourceClient? client;

  static const int maxLatestItemsPerSource = 12;

  const BookSourcesPage({super.key, this.client});

  @visibleForTesting
  static List<RegisteredBookSource> searchTargets(
    Iterable<RegisteredBookSource> sources,
    String? selectedSourceId,
  ) => SourceSearchPage.searchTargets(sources, selectedSourceId);

  /// 保留每个书源自己的 latest 顺序，再按来源轮流穿插。
  ///
  /// 首轮优先展示头部更新时间较新的书源；随后每轮每源最多贡献一本，
  /// 避免单一书源依靠时间戳或返回数量占满聚合列表。
  @visibleForTesting
  static List<SourcedBook> interleaveLatestBatches(
    Iterable<List<SourcedBook>> batches, {
    int maxItemsPerSource = maxLatestItemsPerSource,
  }) {
    if (maxItemsPerSource <= 0) return const [];
    final queues = batches
        .where((batch) => batch.isNotEmpty)
        .map((batch) => batch.take(maxItemsPerSource).toList(growable: false))
        .toList();
    queues.sort((left, right) {
      final leftTime = left.first.book.updatedAt;
      final rightTime = right.first.book.updatedAt;
      if (leftTime != null && rightTime != null) {
        final byTime = rightTime.compareTo(leftTime);
        if (byTime != 0) return byTime;
      } else if (leftTime != null) {
        return -1;
      } else if (rightTime != null) {
        return 1;
      }
      return left.first.source.name.compareTo(right.first.source.name);
    });

    final results = <SourcedBook>[];
    for (var index = 0; index < maxItemsPerSource; index++) {
      var added = false;
      for (final queue in queues) {
        if (index >= queue.length) continue;
        results.add(queue[index]);
        added = true;
      }
      if (!added) break;
    }
    return results;
  }

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  final BookSourceRegistry _registry = BookSourceRegistry();
  late final BookSourceClient _client;
  late final BookSourceShelfService _shelfService = BookSourceShelfService(
    client: _client,
  );
  late final SourcedBookActions _actions = SourcedBookActions(
    context: context,
    client: _client,
    shelfService: _shelfService,
  );
  StreamSubscription<void>? _registrySubscription;

  List<RegisteredBookSource> _sources = const [];
  bool _loadingSources = true;
  String? _selectedSourceId;

  // 书城聚合数据：一次性拉取 推荐(书源书架) / 分类频道 / 最新榜单，
  // 渲染成单一滚动 feed（横幅轮播 + 分类条 + 排行榜 + 书源书架 + 最新更新）。
  List<_DiscoveryShelf> _shelves = const [];
  List<_SourcedCategory> _categories = const [];
  List<SourcedBook> _latest = const [];
  bool _loadingBookStore = true;
  Object? _bookStoreError;

  _SourcedCategory? _selectedCategory;
  List<SourcedBook> _categoryBooks = const [];
  bool _loadingCategoryBooks = false;

  // 当前展开的分类栏目 key（参考番茄/七猫：先选二级栏目，再选该栏目下的细分分类）。
  String? _selectedSectionKey;

  // 最新榜单分页：默认展示一页，点击"下一页"再展开，避免无限下滑。
  static const int latestPageSize = 10;
  int _latestVisibleCount = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? BookSourceClient.shared();
    _registrySubscription = _registry.changes.listen((_) => _reloadAll());
    unawaited(_loadSources());
  }

  @override
  void dispose() {
    _registrySubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadSources() async {
    final sources = await _registry.loadRunnable();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _loadingSources = false;
    });
    await _loadBookStore();
  }

  Future<void> _reloadAll() async {
    _shelves = const [];
    _categories = const [];
    _latest = const [];
    _bookStoreError = null;
    _selectedCategory = null;
    _categoryBooks = const [];
    _loadingCategoryBooks = false;
    _selectedSectionKey = null;
    _latestVisibleCount = 0;
    await _loadSources();
  }

  List<RegisteredBookSource> _targets(String capability) => _sources
      .where((source) => source.enabled)
      .where((source) => source.capabilities.contains(capability))
      .toList(growable: false);

  bool _matchesSelectedSource(RegisteredBookSource source) =>
      _selectedSourceId == null || source.id == _selectedSourceId;

  Future<void> _loadBookStore({bool force = false}) async {
    if (!force && !_loadingBookStore && _hasAnyBookStore()) return;
    setState(() {
      _loadingBookStore = true;
      _bookStoreError = null;
    });
    // 缓存优先：首次进入先渲染上次的发现页内容，避免空白页；
    // 网络数据随后在后台拉取并替换。
    if (!force && !_hasAnyBookStore()) {
      try {
        final cached = await DiscoveryCacheService.instance.read();
        if (cached != null && mounted && _applyDiscoveryCache(cached)) {
          setState(() => _loadingBookStore = false);
        }
      } catch (_) {}
    }
    try {
      final results = await Future.wait<Object>([
        _safelyFetchShelves(),
        _safelyFetchCategories(),
        _safelyFetchLatest(),
      ]);
      if (!mounted) return;
      final shelves = results[0] as List<_DiscoveryShelf>;
      final categories = results[1] as List<_SourcedCategory>;
      final latest = results[2] as List<SourcedBook>;
      setState(() {
        _shelves = shelves;
        _categories = categories;
        _latest = latest;
        // 最新榜单仅展示第一页，其余按"下一页"逐步展开。
        _latestVisibleCount = latest.isEmpty ? 0 : latestPageSize.clamp(1, latest.length);
        _loadingBookStore = false;
      });
      // 静默写回缓存，供下次启动秒出内容。
      final freshCache = _encodeDiscoveryCache(
        shelves: shelves,
        categories: categories,
        latest: latest,
      );
      if (freshCache != null) {
        unawaited(DiscoveryCacheService.instance.write(freshCache));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingBookStore = false;
        _bookStoreError = error;
      });
    }
  }

  bool _hasAnyBookStore() =>
      _shelves.any((shelf) => shelf.items.isNotEmpty) ||
      _categories.isNotEmpty ||
      _latest.isNotEmpty;

  /// 把当前的发现页数据编码成缓存 JSON（含书源快照，可离线还原）。
  String? _encodeDiscoveryCache({
    required List<_DiscoveryShelf> shelves,
    required List<_SourcedCategory> categories,
    required List<SourcedBook> latest,
  }) {
    try {
      final sources = <String, Map<String, dynamic>>{};
      void note(RegisteredBookSource source) {
        sources[source.id] ??= source.toJson();
      }

      final shelfJson = shelves.map((shelf) {
        note(shelf.source);
        return <String, dynamic>{
          'sourceId': shelf.source.id,
          'title': shelf.title,
          'items': shelf.items.map((book) => book.toJson()).toList(),
        };
      }).toList();
      final categoryJson = categories.map((c) {
        note(c.source);
        return <String, dynamic>{
          'sourceId': c.source.id,
          'id': c.id,
          'name': c.name,
        };
      }).toList();
      final latestJson = latest.map((r) {
        note(r.source);
        return <String, dynamic>{
          'sourceId': r.source.id,
          'book': r.book.toJson(),
        };
      }).toList();
      return jsonEncode(<String, dynamic>{
        'version': 1,
        'sources': sources,
        'shelves': shelfJson,
        'categories': categoryJson,
        'latest': latestJson,
      });
    } catch (_) {
      return null;
    }
  }

  /// 从缓存 JSON 还原发现页数据；失败返回 false（保持现状）。
  bool _applyDiscoveryCache(String raw) {
    try {
      final root = jsonDecode(raw);
      if (root is! Map<String, dynamic>) return false;
      final sources = <String, RegisteredBookSource>{};
      final rawSources = root['sources'];
      if (rawSources is Map) {
        rawSources.forEach((key, value) {
          if (key is String && value is Map<String, dynamic>) {
            try {
              sources[key] = RegisteredBookSource.fromJson(value);
            } catch (_) {}
          }
        });
      }
      RegisteredBookSource? sourceOf(dynamic sourceId) =>
          sources[sourceId is String ? sourceId : ''];

      final shelves = <_DiscoveryShelf>[];
      for (final entry in (root['shelves'] as List? ?? const [])) {
        if (entry is! Map<String, dynamic>) continue;
        final source = sourceOf(entry['sourceId']);
        if (source == null) continue;
        final items = (entry['items'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((e) => BookSourceBook.fromJson(e))
            .toList(growable: false);
        shelves.add(
          _DiscoveryShelf(
            source: source,
            title: entry['title'] is String ? entry['title'] as String : '',
            items: items,
          ),
        );
      }

      final categories = <_SourcedCategory>[];
      for (final entry in (root['categories'] as List? ?? const [])) {
        if (entry is! Map<String, dynamic>) continue;
        final source = sourceOf(entry['sourceId']);
        if (source == null) continue;
        categories.add(
          _SourcedCategory(
            source: source,
            id: entry['id'] is String ? entry['id'] as String : '',
            name: entry['name'] is String ? entry['name'] as String : '',
          ),
        );
      }

      final latest = <SourcedBook>[];
      for (final entry in (root['latest'] as List? ?? const [])) {
        if (entry is! Map<String, dynamic>) continue;
        final source = sourceOf(entry['sourceId']);
        final book = entry['book'];
        if (source == null || book is! Map<String, dynamic>) continue;
        try {
          latest.add(SourcedBook(source: source, book: BookSourceBook.fromJson(book)));
        } catch (_) {}
      }

      _shelves = shelves;
      _categories = categories;
      _latest = latest;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 分类频道聚合：按名称去重，避免同一分类跨多个源重复堆叠。
  List<_SourcedCategory> get _aggregatedCategories {
    final seen = <String>{};
    final out = <_SourcedCategory>[];
    for (final c in _categories) {
      final key = c.name.trim();
      if (key.isEmpty) continue;
      if (seen.add(key)) out.add(c);
    }
    return out;
  }

  /// 把聚合后的二级分类按「栏目」分组：关键词命中前优先，未命中的进 '更多分类'。
  /// 参照番茄/七猫：榜单、玄幻仙侠、都市、言情等各成栏目，再概括展示。
  List<_CategorySection> _groupCategorySections(List<_SourcedCategory> cats) {
    final sections = _categorySectionTemplates
        .map((template) => _CategorySection(template: template, cats: []))
        .toList(growable: false);
    final leftovers = <_SourcedCategory>[];
    outer:
    for (final c in cats) {
      final name = c.name.trim().toLowerCase();
      for (final section in sections) {
        if (section.key == 'other') continue;
        if (section.template.keywords
            .any((keyword) => name.contains(keyword.toLowerCase()))) {
          section.cats.add(c);
          continue outer;
        }
      }
      leftovers.add(c);
    }
    for (final section in sections) {
      if (section.key == 'other') {
        section.cats.addAll(leftovers);
      }
    }
    return sections.where((s) => s.cats.isNotEmpty).toList(growable: false);
  }

  /// 点击"下一页"后再展开一批最新榜单；到末尾后不再增长。
  void _openLatestMore() {
    if (_latest.isEmpty) return;
    setState(() {
      _latestVisibleCount =
          (_latestVisibleCount + latestPageSize).clamp(0, _latest.length);
    });
  }

  Future<List<_DiscoveryShelf>> _safelyFetchShelves() async {
    try {
      return await _fetchShelves();
    } catch (_) {
      return const [];
    }
  }

  Future<List<_SourcedCategory>> _safelyFetchCategories() async {
    try {
      return await _fetchCategories();
    } catch (_) {
      return const [];
    }
  }

  Future<List<SourcedBook>> _safelyFetchLatest() async {
    try {
      return await _fetchLatest();
    } catch (_) {
      return const [];
    }
  }

  Future<List<_DiscoveryShelf>> _fetchShelves() async {
    final batches = await _fetchSourceBatches(_targets('discover'), (
      source,
    ) async {
      final page = await _client.getDiscovery(source);
      final shelves = <_DiscoveryShelf>[];
      for (final section in page.sections) {
        if (section.items.isEmpty) continue;
        final isCategoryList = section.layout == 'categories' ||
            section.items.every((item) => item.kind == 'category');
        if (isCategoryList) {
          // Legado 分类入口：每个分类作为一个空 shelf 展示标题
          for (final item in section.items) {
            if (item.kind != 'category') continue;
            shelves.add(
              _DiscoveryShelf(
                source: source,
                title: item.title.isEmpty ? section.title : item.title,
                items: const <BookSourceBook>[],
              ),
            );
          }
        } else {
          shelves.add(
            _DiscoveryShelf(
              source: source,
              title: section.title,
              items: section.items
                  .map((item) => item.book)
                  .whereType<BookSourceBook>()
                  .toList(growable: false),
            ),
          );
        }
      }
      return shelves;
    });
    return batches.expand((items) => items).toList(growable: false);
  }

  Future<List<_SourcedCategory>> _fetchCategories() async {
    final batches = await _fetchSourceBatches(_targets('discover'), (
      source,
    ) async {
      final page = await _client.getDiscovery(source);
      final categories = <_SourcedCategory>[];
      for (final section in page.sections) {
        for (final item in section.items) {
          if (item.kind != 'category') continue;
          categories.add(
            _SourcedCategory(
              source: source,
              id: item.targetUrl ?? '',
              name: item.title.isEmpty ? section.title : item.title,
            ),
          );
        }
      }
      return categories;
    });
    return batches.expand((items) => items).toList(growable: false);
  }

  Future<List<SourcedBook>> _fetchLatest() async {
    final batches = await _fetchSourceBatches(_targets('discover'), (
      source,
    ) async {
      final categoryPage = await _client.getDiscovery(source);
      String? firstCategoryUrl;
      for (final section in categoryPage.sections) {
        for (final item in section.items) {
          if (item.kind == 'category' &&
              item.targetUrl != null &&
              item.targetUrl!.isNotEmpty) {
            firstCategoryUrl = item.targetUrl;
            break;
          }
        }
        if (firstCategoryUrl != null) break;
      }
      if (firstCategoryUrl == null) return const <SourcedBook>[];
      final page = await _client.getDiscovery(
        source,
        exploreUrlOverride: firstCategoryUrl,
      );
      final books = <SourcedBook>[];
      for (final section in page.sections) {
        for (final item in section.items) {
          if (item.book != null) {
            books.add(SourcedBook(source: source, book: item.book!));
          }
        }
      }
      return books;
    });
    return BookSourcesPage.interleaveLatestBatches(batches);
  }

  Future<List<List<T>>> _fetchSourceBatches<T>(
    List<RegisteredBookSource> sources,
    Future<List<T>> Function(RegisteredBookSource source) fetch,
  ) async {
    final results = await Future.wait(
      sources.map((source) async {
        try {
          return _SourceFetchResult<T>.success(source, await fetch(source));
        } catch (error) {
          return _SourceFetchResult<T>.failure(source, error);
        }
      }),
    );
    final batches = results
        .where((result) => result.error == null)
        .map((result) => result.items)
        .toList(growable: false);
    final hasContent = batches.any((items) => items.isNotEmpty);
    final failures = results.where((result) => result.error != null).toList();
    if (!hasContent && failures.isNotEmpty) {
      throw BookSourceProtocolException(
        failures
            .map((failure) => '${failure.source.name}: ${failure.error}')
            .join('\n'),
      );
    }
    return batches;
  }

  void _selectCategoryForBrowse(_SourcedCategory category) {
    if (category.source.id != _selectedCategory?.source.id ||
        category.id != _selectedCategory?.id) {
      unawaited(_selectCategory(category));
    }
  }

  Future<void> _selectCategory(_SourcedCategory category) async {
    setState(() {
      _selectedCategory = category;
      _categoryBooks = const [];
      _loadingCategoryBooks = true;
    });
    try {
      final books = await _fetchCategoryAcrossSources(category);
      if (!mounted || _selectedCategory != category) return;
      setState(() {
        _categoryBooks = books;
        _loadingCategoryBooks = false;
      });
    } catch (_) {
      if (!mounted || _selectedCategory != category) return;
      setState(() => _loadingCategoryBooks = false);
    }
  }

  /// 分类按名称跨来源聚合：与"最新"板块一致，不区分来源，把每个提供该分类的
  /// 书源结果合并穿插，而不是只返回某一书源的二级分类资源。
  Future<List<SourcedBook>> _fetchCategoryAcrossSources(
    _SourcedCategory category,
  ) async {
    final name = category.name.trim();
    final candidates =
        _categories.where((c) => c.name.trim() == name).toList(growable: false);
    if (candidates.isEmpty) return const [];
    final results = await Future.wait(
      candidates.map((c) async {
        try {
          final page = await _client.getDiscovery(
            c.source,
            exploreUrlOverride: c.id,
          );
          final books = <SourcedBook>[];
          for (final section in page.sections) {
            for (final item in section.items) {
              if (item.book != null) {
                books.add(SourcedBook(source: c.source, book: item.book!));
              }
            }
          }
          return (source: c.source, books: books);
        } catch (_) {
          return (source: c.source, books: const <SourcedBook>[]);
        }
      }),
    );
    final batches = results
        .where((result) => result.books.isNotEmpty)
        .map((result) => result.books)
        .toList(growable: false);
    return BookSourcesPage.interleaveLatestBatches(batches);
  }

  Future<void> _openCategoryPicker(List<_SourcedCategory> categories) async {
    final size = MediaQuery.sizeOf(context);
    final picker = _CategoryPickerPanel(
      categories: categories,
      selectedCategory: _selectedCategory,
      title: context.l10n.discoverCategories,
      searchLabel: context.l10n.search,
      noResultsLabel: context.l10n.bookSourcesNoResults,
    );
    final _SourcedCategory? selected;
    if (size.width >= 720) {
      selected = await showDialog<_SourcedCategory>(
        context: context,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: (size.width - 48).clamp(320, 520).toDouble(),
            height: (size.height - 48).clamp(320, 680).toDouble(),
            child: picker,
          ),
        ),
      );
    } else {
      selected = await showModalBottomSheet<_SourcedCategory>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        clipBehavior: Clip.antiAlias,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: picker,
          ),
        ),
      );
    }
    if (selected != null && mounted && selected != _selectedCategory) {
      await _selectCategory(selected);
    }
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSearchPage(
          sources: _sources,
          client: _client,
          shelfService: _shelfService,
        ),
      ),
    );
  }

  Future<void> _openSourceManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BookSourceManagementPage()),
    );
    if (mounted) await _reloadAll();
  }

  @override
  Widget build(BuildContext context) {
    final useRailNavigation =
        NavigationContext.of(context)?.useRailNavigation ?? false;
    final mobileChrome = HomeMobileChromeScope.of(context);
    final bottomPadding = useRailNavigation
        ? 32.0
        : mobileChrome.pageBottomPadding;

    return Container(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: SafeArea(
        top: useRailNavigation,
        bottom: false,
        child: RefreshIndicator(
          edgeOffset: useRailNavigation ? 90 : mobileChrome.topBarHeight,
          onRefresh: () => _loadBookStore(force: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        useRailNavigation ? 16 : mobileChrome.pageTopPadding,
                        16,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (useRailNavigation) _buildRailHeader(),
                          _buildBookStoreHeader(),
                          const SizedBox(height: 14),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ..._buildBookStoreSlivers(bottomPadding),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRailHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.l10n.discover,
              style: TextStyle(
                fontSize: 36,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          IconButton.filledTonal(
            key: const Key('bookSourceSearchEntry'),
            tooltip: context.l10n.bookSourcesSearch,
            onPressed: _openSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: context.l10n.bookSourceManagementTitle,
            onPressed: _openSourceManagement,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
  }

  /// 书城顶栏：醒目搜索条入口 + 管理按钮（对齐主流阅读 App 的首页）。
  Widget _buildBookStoreHeader() {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Expanded(
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: dark ? 0.4 : 0.6),
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('bookSourceSearchEntry'),
              onTap: _openSearch,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.l10n.bookSourcesSearch,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton.filledTonal(
          tooltip: context.l10n.bookSourceManagementTitle,
          onPressed: _openSourceManagement,
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    );
  }

  /// 选中书城的头部书籍，作为横幅轮播素材（跨源去重取前 8 本）。
  List<SourcedBook> get _brandBooks {
    final seen = <String>{};
    final list = <SourcedBook>[];
    for (final shelf in _shelves) {
      for (final book in shelf.items) {
        final key = '${shelf.source.id}/${book.id}';
        if (!seen.add(key)) continue;
        list.add(SourcedBook(source: shelf.source, book: book));
        if (list.length >= 8) return list;
      }
    }
    return list;
  }

  List<Widget> _buildBookStoreSlivers(double bottomPadding) {
    if (_loadingSources || (_loadingBookStore && !_hasAnyBookStore())) {
      return [
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 44),
            child: Center(child: CircularProgressIndicator()),
          ),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    if (_bookStoreError != null && !_hasAnyBookStore()) {
      return [
        _paddedSectionSliver(
          _buildMessageCard(
            icon: Icons.cloud_off_outlined,
            title: context.l10n.discoverLoadFailed,
            message: _bookStoreError.toString(),
            actionLabel: context.l10n.discoverRetry,
            onAction: () => _loadBookStore(force: true),
          ),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    final shelves = _shelves
        .where((shelf) => shelf.items.isNotEmpty)
        .where((shelf) => _matchesSelectedSource(shelf.source))
        .toList(growable: false);
    final latest = _latest
        .where((result) => _matchesSelectedSource(result.source))
        .toList(growable: false);
    if (shelves.isEmpty && latest.isEmpty && _categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _targets('discover').isEmpty
              ? _buildUnsupportedMessage('discover')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }

    final hero = _brandBooks;
    final slivers = <Widget>[
      if (hero.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: _centerSectionChild(
            SizedBox(
              height: 184,
              child: _BookstoreHero(
                books: hero,
                onTap: (result) => _actions.showBookDetails(result),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    ];

    // 分类频道 → 最新/热榜 → 书源书架
    if (_categories.isNotEmpty) {
      slivers.addAll(_buildCategorySlivers(bottomPadding));
    }
    if (latest.isNotEmpty) {
      slivers.addAll(_buildLatestSectionSlivers(latest, bottomPadding));
    }
    slivers.addAll(_buildShelfSlivers(shelves, bottomPadding));
    return slivers;
  }

  /// 统一设计语言的 Section 标题：左侧 brand 色竖条 + 加粗大标题 + 可选副标题/更多。
  Widget _buildSectionHeader(
    String title,
    IconData icon, {
    String? subtitle,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing,
        ],
      ],
    );
  }

  List<Widget> _buildCategorySlivers(double bottomPadding) {
    final cats = _aggregatedCategories;
    if (cats.isEmpty) return const [SliverToBoxAdapter(child: SizedBox.shrink())];
    final sections = _groupCategorySections(cats);
    // 展开的栏目：优先用户上次选择，失效则回落到第一个非空栏目。
    final activeKey = (_selectedSectionKey != null &&
            sections.any((s) => s.key == _selectedSectionKey))
        ? _selectedSectionKey!
        : sections.first.key;
    final activeSection = sections.firstWhere((s) => s.key == activeKey);
    final selected = _selectedCategory;
    final selectedInSection =
        selected != null &&
        activeSection.cats.any(
          (c) => c.source.id == selected.source.id && c.id == selected.id,
        );
    return [
      SliverToBoxAdapter(
        child: _centerSectionChild(
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: _buildSectionHeader(
              context.l10n.discoverCategories,
              Icons.category_rounded,
              subtitle: activeSection.cats.isEmpty
                  ? null
                  : '${activeSection.cats.length} 个分类 · 从 ${cats.length} 个总分类聚合',
            ),
          ),
        ),
      ),
      // 栏目条：参考番茄/七猫，先选「二级栏目」（玄幻仙侠/都市/言情/榜单…），
      // 再在该栏目下选更细分的分类，避免全部分类一次性堆叠。
      _categorySectionBar(
        sections: sections,
        activeKey: activeKey,
        onSelect: (key) => setState(() {
          _selectedSectionKey = key;
          // 若已选分类不属于新栏目，则清空，等待用户在新栏目内重新选择。
          if (selected != null &&
              !activeSection.cats.any(
                (c) => c.source.id == selected.source.id &&
                    c.id == selected.id,
              )) {
            _selectedCategory = null;
            _categoryBooks = const [];
            _loadingCategoryBooks = false;
          }
        }),
        scheme: Theme.of(context).colorScheme,
      ),
      // 当前栏目聚合到的细分分类，以紧凑胶囊整块展示。
      _categoryGridSliver(
        cats: activeSection.cats,
        selected: selected,
        hasMore: false,
        onSelect: _selectCategoryForBrowse,
        onMore: () => _openCategoryPicker(cats),
        bottomPadding: bottomPadding,
      ),
      if (selected != null && !selectedInSection)
        _paddedSectionSliver(
          _buildSectionHeader(
            selected.name,
            Icons.collections_bookmark_outlined,
          ),
          topPadding: 18,
          bottomPadding: 0,
        ),
      if (selected != null && _loadingCategoryBooks)
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Center(child: CircularProgressIndicator()),
          ),
          topPadding: 16,
          bottomPadding: bottomPadding,
        ),
      if (selected != null && _categoryBooks.isNotEmpty)
        _bookGridSliver(_categoryBooks, bottomPadding: bottomPadding),
    ];
  }

  /// 栏目横条：横向滚动的一级栏目（榜单/玄幻仙侠/都市/言情/…/更多分类）。
  static Widget _categorySectionBar({
    required List<_CategorySection> sections,
    required String activeKey,
    required ValueChanged<String> onSelect,
    required ColorScheme scheme,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 0, 4),
      sliver: SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in sections)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _CategorySectionChip(
                    section: s,
                    active: s.key == activeKey,
                    onTap: () => onSelect(s.key),
                    scheme: scheme,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分类聚合网格：去重后的分类以「分类卡片」整块展示，超出收纳进末尾的「更多」卡。
  _CategoryGridSliver _categoryGridSliver({
    required List<_SourcedCategory> cats,
    required _SourcedCategory? selected,
    required bool hasMore,
    required void Function(_SourcedCategory) onSelect,
    required VoidCallback onMore,
    required double bottomPadding,
  }) {
    return _CategoryGridSliver(
      cats: cats,
      selected: selected,
      hasMore: hasMore,
      onSelect: onSelect,
      onMore: onMore,
      bottomPadding: bottomPadding,
      scheme: Theme.of(context).colorScheme,
    );
  }

  List<Widget> _buildLatestSectionSlivers(
    List<SourcedBook> latest,
    double bottomPadding,
  ) {
    final shown = _latestVisibleCount.clamp(0, latest.length);
    final remain = latest.length - shown;
    return [
      SliverToBoxAdapter(
        child: _centerSectionChild(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _buildSectionHeader(
              context.l10n.discoverLatest,
              Icons.local_fire_department_rounded,
              trailing: remain > 0
                  ? Text(
                      '${shown}/${latest.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
        sliver: SliverList.builder(
          itemCount: shown,
          itemBuilder: (context, index) {
            final result = latest[index];
            return _centerSectionChild(
              _LatestRankRow(
                result: result,
                rank: index + 1,
                onTap: () => _actions.showBookDetails(result),
              ),
            );
          },
        ),
      ),
      if (remain > 0)
        _paddedSectionSliver(
          _centerSectionChild(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Material(
                color: Theme.of(context).colorScheme.primary.withValues(
                  alpha: 0.08,
                ),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _openLatestMore,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '展开更多 ${remain} 条',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          topPadding: 8,
          bottomPadding: bottomPadding,
        ),
    ];
  }

  List<Widget> _buildShelfSlivers(
    List<_DiscoveryShelf> shelves,
    double bottomPadding,
  ) {
    if (shelves.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: _centerSectionChild(
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: _buildSectionHeader(
              context.l10n.discoverRecommended,
              Icons.auto_awesome_rounded,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        sliver: SliverList.builder(
          itemCount: shelves.length,
          itemBuilder: (context, index) =>
              _centerSectionChild(_buildShelf(shelves[index])),
        ),
      ),
    ];
  }

  Widget _buildShelf(_DiscoveryShelf shelf) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shelf.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              _buildSourceBadge(shelf.source.name),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 226,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: shelf.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final result = SourcedBook(
                  source: shelf.source,
                  book: shelf.items[index],
                );
                return _ShelfBookCard(
                  result: result,
                  onTap: () => _actions.showBookDetails(result),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _bookGridSliver(
    List<SourcedBook> books, {
    required double bottomPadding,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          // 窄屏 2 列，宽屏 3 列（>=720），超宽屏 4 列（>=1080）
          final columns = switch (width) {
            >= 1080 => 4,
            >= 720 => 3,
            _ => 2,
          };
          const spacing = 12.0;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: 0.68, // 更接近书卡（封面高+标题短）
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final result = books[index];
                return _DiscoverGridBookCard(
                  result: result,
                  onTap: () => _actions.showBookDetails(result),
                );
              },
              childCount: books.length,
            ),
          );
        },
      ),
    );
  }

  Widget _paddedSectionSliver(
    Widget child, {
    double topPadding = 8,
    required double bottomPadding,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
      sliver: SliverToBoxAdapter(child: _centerSectionChild(child)),
    );
  }

  Widget _centerSectionChild(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1048),
      child: child,
    ),
  );

  Widget _buildUnsupportedMessage(String capability) {
    final hasEnabledSources = _sources.any((source) => source.enabled);
    return _buildMessageCard(
      icon: hasEnabledSources
          ? Icons.extension_off_outlined
          : Icons.travel_explore_outlined,
      title: hasEnabledSources
          ? context.l10n.discoverUnsupportedTitle
          : context.l10n.bookSourcesNoSourcesTitle,
      message: hasEnabledSources
          ? context.l10n.discoverUnsupportedMessage(capability)
          : context.l10n.bookSourcesNoSourcesDescription,
      actionLabel: context.l10n.bookSourceManagementTitle,
      onAction: _openSourceManagement,
    );
  }

  Widget _buildEmptyMessage() {
    return _buildMessageCard(
      icon: Icons.inbox_outlined,
      title: context.l10n.discoverEmptyTitle,
      message: context.l10n.discoverEmptyMessage,
    );
  }

  Widget _buildMessageCard({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    FutureOr<void> Function()? onAction,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: bookSourcePanelDecoration(context, radius: 16),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => onAction(),
              icon: const Icon(Icons.tune_rounded),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceBadge(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 书城横幅轮播：渐变卡片 + 封面缩略 + 圆点指示器，手动滑动切换。
class _BookstoreHero extends StatefulWidget {
  const _BookstoreHero({required this.books, required this.onTap});

  final List<SourcedBook> books;
  final void Function(SourcedBook) onTap;

  @override
  State<_BookstoreHero> createState() => _BookstoreHeroState();
}

class _BookstoreHeroState extends State<_BookstoreHero> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        PageView.builder(
          itemCount: widget.books.length,
          onPageChanged: (index) => setState(() => _page = index),
          itemBuilder: (context, index) =>
              _buildBanner(context, widget.books[index]),
        ),
        if (widget.books.length > 1)
          Positioned(
            bottom: 12,
            right: 16,
            child: Row(
              children: [
                for (var i = 0; i < widget.books.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(left: 5),
                    width: i == _page ? 14 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? Colors.white : Colors.white54,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBanner(BuildContext context, SourcedBook result) {
    final scheme = Theme.of(context).colorScheme;
    final book = result.book;
    final cover = book.coverUrl == null
        ? GeneratedBookCover(title: book.title, author: book.author)
        : SourceCoverImage(
            url: book.coverUrl!,
            fit: BoxFit.cover,
            fallback: GeneratedBookCover(title: book.title, author: book.author),
          );
    return Container(
      margin: const EdgeInsets.only(right: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.secondary],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => widget.onTap(result),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      if (book.author.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          result.source.name,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 96, height: 144, child: cover),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceFetchResult<T> {
  final List<T> items;
  final RegisteredBookSource source;
  final Object? error;

  const _SourceFetchResult.success(this.source, this.items) : error = null;

  const _SourceFetchResult.failure(this.source, this.error) : items = const [];
}

class _DiscoveryShelf {
  final RegisteredBookSource source;
  final String title;
  final List<BookSourceBook> items;

  const _DiscoveryShelf({
    required this.source,
    required this.title,
    required this.items,
  });
}

class _SourcedCategory {
  final RegisteredBookSource source;
  final String id;
  final String name;

  const _SourcedCategory({
    required this.source,
    required this.id,
    required this.name,
  });
}

/// 分类栏目的模板定义：一个栏目 = 一组同类型关键词 + 标题/图标。
/// 聚合各来源的二级分类后，按关键词归类到对应栏目，参考番茄/七猫的分类组织。
class _CategorySectionTemplate {
  final String key;
  final String title;
  final IconData icon;
  final List<String> keywords;

  const _CategorySectionTemplate({
    required this.key,
    required this.title,
    required this.icon,
    required this.keywords,
  });
}

/// 一个已填充分类的栏目实例（[cats] 为该栏目聚合到的二级分类）。
class _CategorySection {
  final _CategorySectionTemplate template;
  final List<_SourcedCategory> cats;

  _CategorySection({required this.template, required this.cats});

  String get title => template.title;
  String get key => template.key;
  IconData get icon => template.icon;
}

/// 分类栏目模板表：顺序决定匹配优先级，'other' 为兜底收纳所有未匹配分类。
const List<_CategorySectionTemplate> _categorySectionTemplates = [
  _CategorySectionTemplate(
    key: 'rank',
    title: '榜单排行',
    icon: Icons.emoji_events_outlined,
    keywords: ['榜单', '排行', '热读', '热门', '月票', '订阅', '点击', '人气', '新书榜', '完结榜'],
  ),
  _CategorySectionTemplate(
    key: 'xuanhuan',
    title: '玄幻仙侠',
    icon: Icons.auto_awesome_outlined,
    keywords: ['玄幻', '奇幻', '魔幻', '仙侠', '修真', '凡人'],
  ),
  _CategorySectionTemplate(
    key: 'wuxia',
    title: '武侠',
    icon: Icons.sports_martial_arts_outlined,
    keywords: ['武侠', '江湖', '武林'],
  ),
  _CategorySectionTemplate(
    key: 'dushi',
    title: '都市',
    icon: Icons.location_city_outlined,
    keywords: ['都市', '校园', '职场', '重生', '兵王', '医生', '律师', '总裁'],
  ),
  _CategorySectionTemplate(
    key: 'yanqing',
    title: '言情',
    icon: Icons.favorite_outline,
    keywords: ['言情', '甜宠', '婚恋', '古言', '现言', '豪门', '爱恋', '女频', '宠'],
  ),
  _CategorySectionTemplate(
    key: 'kehuan',
    title: '科幻末世',
    icon: Icons.science_outlined,
    keywords: ['科幻', '末世', '星际', '机甲', '末日', '丧尸', '未来', '赛博'],
  ),
  _CategorySectionTemplate(
    key: 'xanyi',
    title: '悬疑推理',
    icon: Icons.search_outlined,
    keywords: ['悬疑', '推理', '侦探', '刑侦', '灵异', '惊悚', '探险', '盗墓', '冒险'],
  ),
  _CategorySectionTemplate(
    key: 'lishi',
    title: '历史军事',
    icon: Icons.account_balance_outlined,
    keywords: ['历史', '穿越', '三国', '权谋', '帝王', '王朝', '军事', '战争'],
  ),
  _CategorySectionTemplate(
    key: 'youxi',
    title: '游戏竞技',
    icon: Icons.sports_esports_outlined,
    keywords: ['游戏', '电竞', '竞技', '体育', '足球', '篮球', '王者'],
  ),
  _CategorySectionTemplate(
    key: 'erciyuan',
    title: '二次元',
    icon: Icons.movie_filter_outlined,
    keywords: ['二次元', '动漫', '同人', '轻小说', '综漫', '番'],
  ),
  _CategorySectionTemplate(
    key: 'wenyi',
    title: '文艺',
    icon: Icons.article_outlined,
    keywords: ['文艺', '散文', '诗歌', '文学', '传记', '经典', '人生'],
  ),
  _CategorySectionTemplate(key: 'other', title: '更多分类', icon: Icons.category_outlined, keywords: []),
];

class _CategoryPickerPanel extends StatefulWidget {
  final List<_SourcedCategory> categories;
  final _SourcedCategory? selectedCategory;
  final String title;
  final String searchLabel;
  final String noResultsLabel;

  const _CategoryPickerPanel({
    required this.categories,
    required this.selectedCategory,
    required this.title,
    required this.searchLabel,
    required this.noResultsLabel,
  });

  @override
  State<_CategoryPickerPanel> createState() => _CategoryPickerPanelState();
}

class _CategoryPickerPanelState extends State<_CategoryPickerPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_CategoryPickerEntry> _entries() {
    final query = _query.trim().toLowerCase();
    final matches = widget.categories.where((category) {
      if (query.isEmpty) return true;
      return category.name.toLowerCase().contains(query) ||
          category.source.name.toLowerCase().contains(query);
    });
    final entries = <_CategoryPickerEntry>[];
    String? sourceId;
    for (final category in matches) {
      if (category.source.id != sourceId) {
        sourceId = category.source.id;
        entries.add(_CategoryPickerEntry.header(category.source.name));
      }
      entries.add(_CategoryPickerEntry.category(category));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              key: const Key('bookSourceCategorySearchField'),
              controller: _searchController,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: widget.searchLabel,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      widget.noResultsLabel,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    key: const Key('bookSourceCategoryLazyList'),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final category = entry.category;
                      if (category == null) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                          child: Text(
                            entry.header!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        );
                      }
                      final selected = category == widget.selectedCategory;
                      return ListTile(
                        key: Key(
                          'bookSourceCategory-${category.source.id}-${category.id}',
                        ),
                        selected: selected,
                        title: Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selected
                            ? Icon(Icons.check_rounded, color: scheme.primary)
                            : null,
                        onTap: () => Navigator.of(context).pop(category),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CategoryPickerEntry {
  final String? header;
  final _SourcedCategory? category;

  const _CategoryPickerEntry.header(this.header) : category = null;

  const _CategoryPickerEntry.category(this.category) : header = null;
}

/// 分类栏目芯片：一级栏目（榜单/玄幻仙侠/都市/言情/…），选中态高亮。
class _CategorySectionChip extends StatelessWidget {
  const _CategorySectionChip({
    required this.section,
    required this.active,
    required this.onTap,
    required this.scheme,
  });

  final _CategorySection section;
  final bool active;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final fg = active ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Material(
      color: active ? scheme.primary : scheme.surfaceContainerLow,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(section.icon, size: 15, color: fg),
              const SizedBox(width: 5),
              Text(
                section.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 发现页「分类」聚合网格：把去重后的分类像「最新」一样整块聚合展示。
///
/// 内部用 Wrap 按屏宽自适应列数渲染分类卡片；有更多分类时，末尾追加一张
/// 「更多分类」卡打开选择面板。点击卡片即加载该分类的书籍网格。
class _CategoryGridSliver extends StatelessWidget {
  const _CategoryGridSliver({
    required this.cats,
    required this.selected,
    required this.hasMore,
    required this.onSelect,
    required this.onMore,
    required this.bottomPadding,
    required this.scheme,
  });

  final List<_SourcedCategory> cats;
  final _SourcedCategory? selected;
  final bool hasMore;
  final void Function(_SourcedCategory) onSelect;
  final VoidCallback onMore;
  final double bottomPadding;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 10, 16, bottomPadding),
      sliver: SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1048),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in cats)
                  _CategoryGridTile(
                    category: c,
                    selected:
                        selected?.source.id == c.source.id &&
                        selected?.id == c.id,
                    onTap: () => onSelect(c),
                    scheme: scheme,
                  ),
                if (hasMore)
                  _CategoryGridTile(
                    category: null,
                    selected: false,
                    onTap: onMore,
                    scheme: scheme,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 分类聚合芯片；[category] 为 null 时渲染为「更多分类」入口。
/// 采用紧凑胶囊，聚合展示同类型分类，而非大尺寸卡片，避免占屏过大。
class _CategoryGridTile extends StatelessWidget {
  const _CategoryGridTile({
    required this.category,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  final _SourcedCategory? category;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final isMore = category == null;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerLow,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isMore ? '更多分类' : category!.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: fg,
                ),
              ),
              if (isMore) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 16, color: fg),
              ] else if (selected) ...[
                const SizedBox(width: 4),
                Icon(Icons.check_rounded, size: 16, color: fg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 发现页网格书卡（无外层 SizedBox 宽高，根据 SliverGrid 自适应）
class _DiscoverGridBookCard extends StatelessWidget {
  final SourcedBook result;
  final VoidCallback onTap;

  const _DiscoverGridBookCard({
    required this.result,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 7,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: result.book.coverUrl == null
                    ? GeneratedBookCover(
                        title: result.book.title,
                        author: result.book.author,
                      )
                    : SourceCoverImage(
                        url: result.book.coverUrl!,
                        fit: BoxFit.cover,
                        cacheWidth: (220 * dpr).round(),
                        fallback: GeneratedBookCover(
                          title: result.book.title,
                          author: result.book.author,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              result.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              result.book.author.isEmpty
                  ? result.source.name
                  : result.book.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书单/书架横排竖版卡片：2:3 封面（圆角 8）+ 加粗标题 + 灰色作者，对齐实体书书卡。
class _ShelfBookCard extends StatelessWidget {
  final SourcedBook result;
  final VoidCallback onTap;

  const _ShelfBookCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final book = result.book;
    return SizedBox(
      width: 120,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: book.coverUrl == null
                      ? GeneratedBookCover(title: book.title, author: book.author)
                      : SourceCoverImage(
                          url: book.coverUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: (140 * dpr).round(),
                          fallback: GeneratedBookCover(
                            title: book.title,
                            author: book.author,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                book.author.isEmpty ? result.source.name : book.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 榜单/热榜行：序号徽标（Top3 强调色渐变）+ 封面缩略 + 标题 + 作者/来源。
class _LatestRankRow extends StatelessWidget {
  final SourcedBook result;
  final int rank;
  final VoidCallback onTap;

  const _LatestRankRow({
    required this.result,
    required this.rank,
    required this.onTap,
  });

  static const _topGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE8503A), Color(0xFFC0392B)],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final book = result.book;
    final topThree = rank <= 3;
    final badge = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: topThree ? _topGradient : null,
        color: topThree ? null : scheme.surfaceContainerHighest,
      ),
      child: Text(
        '$rank',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w900,
          color: topThree ? Colors.white : scheme.onSurfaceVariant,
        ),
      ),
    );
    final fallback = SizedBox(
      width: 50,
      height: 75,
      child: GeneratedBookCover(title: book.title, author: book.author),
    );
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: book.coverUrl == null
          ? fallback
          : SourceCoverImage(
              url: book.coverUrl!,
              width: 50,
              height: 75,
              fit: BoxFit.cover,
              cacheWidth: (60 * dpr).round(),
              fallback: fallback,
            ),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          children: [
            badge,
            const SizedBox(width: 12),
            thumb,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (book.author.isNotEmpty) book.author,
                      result.source.name,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}