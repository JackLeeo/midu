// 文件说明：发现页，聚合展示已启用书源的推荐、分类与最新书籍。
// 技术要点：Flutter UI、按 Tab 缓存的书源请求、下拉刷新。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';
import 'package:midu/book_sources/services/book_source_shelf_service.dart';
import 'package:midu/models/home_navigation_destination.dart';
import 'package:midu/pages/home/home_mobile_chrome.dart';
import 'package:midu/pages/home/home_shell_page.dart';
import 'package:midu/pages/home/widgets/home_page_wrappers.dart';
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

  /// 最新版块聚合后保留的总量上限，避免源数量多时列表无限膨胀卡顿。
  static const int maxLatestTotal = 20;

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

  /// 发现页当前是否处于「打开中」状态（即底部导航选中了发现 tab）。
  ///
  /// 用于把加载/推送/预热等网络活动限制在页面可见时执行，避免切走后
  /// 后台仍在无谓地聚合刷新、占用网络与主线程造成卡顿。
  bool _isPageActive = false;

  /// 页面尚不可见时收到待预热栏目标记；等到 [didChangeDependencies]
  /// 观察到 active 后再补跑。
  bool _pendingWarmUp = false;

  // 书城聚合数据：一次性拉取 推荐(书源书架) / 分类频道 / 最新榜单，
  // 渲染成单一滚动 feed（横幅轮播 + 分类条 + 排行榜 + 书源书架 + 最新更新）。
  List<_DiscoveryShelf> _shelves = const [];
  List<_SourcedCategory> _categories = const [];
  List<SourcedBook> _latest = const [];
  bool _loadingBookStore = true;
  Object? _bookStoreError;

  // 当前展开的分类栏目 key（参考番茄/七猫：选一级栏目后，下方直接聚合展示该栏目书籍）。
  String? _selectedSectionKey;

  // 当前栏目聚合到的书籍（跨来源、按书名去重），以列表形式展示。
  List<SourcedBook> _sectionBooks = const [];
  bool _loadingSectionBooks = false;

  // 各栏目的书籍内存缓存（key 为栏目 key）。命中后秒出旧数据，后台静默刷新替换。
  final Map<String, List<SourcedBook>> _sectionCache = {};

  // 各栏目最近一次成功拉取的时间，用于判断缓存是否新鲜，避免刚预热完又重复请求。
  final Map<String, DateTime> _sectionFetchedAt = {};

  // 栏目缓存的新鲜窗口：窗口内命中缓存不重复拉取，直接使用。
  static const Duration sectionCacheFreshness = Duration(minutes: 10);

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 底部导航切页会重建 HomeTabFocusScope，这里据此同步「发现页是否打开中」。
    final active = HomeTabFocusScope.maybeActiveOf(context);
    final nowActive = active == HomeNavigationDestination.discover;
    if (nowActive == _isPageActive) return;
    _isPageActive = nowActive;
    if (nowActive && _pendingWarmUp) {
      _pendingWarmUp = false;
      // 页面重新可见时，补跑尚未完成的栏目预热。
      unawaited(_warmUpAllSections());
    }
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
    // 分类数据就绪后，默认选中第一个栏目并聚合其书籍。
    await _autoSelectSection();
    // 后台静默预热其余栏目并缓存，使切换分类可无感秒出。
    unawaited(_warmUpAllSections());
  }

  Future<void> _reloadAll() async {
    _shelves = const [];
    _categories = const [];
    _latest = const [];
    _bookStoreError = null;
    _selectedSectionKey = null;
    _sectionBooks = const [];
    _loadingSectionBooks = false;
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
    // 流式聚合：三路各自在所有源返回后才做最终合并，但每个源一完成就通过
    // onBatch 增量写入 state，让用户先看到先返回的内容，而不是等全部源完成。
    final shelvesAcc = <_DiscoveryShelf>[];
    final categoriesAcc = <_SourcedCategory>[];
    final latestAcc = <SourcedBook>[];
    void update(Set<String> changed) {
      if (!mounted) return;
      setState(() {
        if (changed.contains('shelves')) _shelves = List.of(shelvesAcc);
        if (changed.contains('categories')) _categories = List.of(categoriesAcc);
        if (changed.contains('latest')) _latest = List.of(latestAcc);
      });
    }
    try {
      final results = await Future.wait<Object>([
        _safelyFetchShelves(onBatch: (items) {
          shelvesAcc.addAll(items);
          update({'shelves'});
        }),
        _safelyFetchCategories(onBatch: (items) {
          categoriesAcc.addAll(items);
          update({'categories'});
        }),
        _safelyFetchLatest(onBatch: (items) {
          if (latestAcc.length >= BookSourcesPage.maxLatestTotal) return;
          latestAcc.addAll(items);
          // 流式截断：与 _fetchLatest 的最终 take 保持一致，避免 onBatch 期间
          // latestAcc 膨胀到上千条再一次性截断，降低中间状态内存与渲染压力。
          if (latestAcc.length > BookSourcesPage.maxLatestTotal) {
            latestAcc.removeRange(
              BookSourcesPage.maxLatestTotal,
              latestAcc.length,
            );
          }
          update({'latest'});
        }),
      ]);
      if (!mounted) return;
      final shelves = results[0] as List<_DiscoveryShelf>;
      final categories = results[1] as List<_SourcedCategory>;
      final latest = results[2] as List<SourcedBook>;
      setState(() {
        // 最新榜单总量已截断到 maxLatestTotal，全部展示，不再分页展开。
        _latestVisibleCount = latest.length;
        _loadingBookStore = false;
      });
      // 有栏目缓存的默认栏目，后台静默刷新替换，保证与「最新」一样新鲜。
      final groupedFresh = _groupCategorySections(_aggregatedCategories);
      if (groupedFresh.isNotEmpty) {
        final activeKey = (_selectedSectionKey != null &&
                groupedFresh.any((s) => s.key == _selectedSectionKey))
            ? _selectedSectionKey!
            : groupedFresh.first.key;
        if (_sectionCache[activeKey]?.isNotEmpty ?? false) {
          unawaited(_refreshSectionBooks(activeKey));
        }
      }
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
      // 各栏目聚合书籍同样缓存，重启后秒出、后台刷新替换。
      final sectionsJson = <String, List<Map<String, dynamic>>>{};
      _sectionCache.forEach((key, books) {
        if (books.isEmpty) return;
        sectionsJson[key] = books.map((r) {
          note(r.source);
          return <String, dynamic>{
            'sourceId': r.source.id,
            'book': r.book.toJson(),
          };
        }).toList();
      });
      return jsonEncode(<String, dynamic>{
        'version': 1,
        'sources': sources,
        'shelves': shelfJson,
        'categories': categoryJson,
        'latest': latestJson,
        'sections': sectionsJson,
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

      // 还原各栏目聚合书籍缓存（内存），并预填默认栏目的展示列表。
      final rawSections = root['sections'];
      if (rawSections is Map) {
        _sectionCache.clear();
        rawSections.forEach((key, list) {
          final books = <SourcedBook>[];
          if (list is List) {
            for (final entry in list) {
              if (entry is! Map<String, dynamic>) continue;
              final source = sourceOf(entry['sourceId']);
              final book = entry['book'];
              if (source == null || book is! Map<String, dynamic>) continue;
              try {
                books.add(
                  SourcedBook(source: source, book: BookSourceBook.fromJson(book)),
                );
              } catch (_) {}
            }
          }
          if (books.isNotEmpty) _sectionCache['$key'] = books;
        });
      }
      final grouped = _groupCategorySections(_aggregatedCategories);
      if (grouped.isNotEmpty) {
        final defaultCache = _sectionCache[grouped.first.key];
        if (defaultCache != null && defaultCache.isNotEmpty) {
          _selectedSectionKey = grouped.first.key;
          _sectionBooks = defaultCache;
        }
      }
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

  Future<List<_DiscoveryShelf>> _safelyFetchShelves({
    void Function(List<_DiscoveryShelf> items)? onBatch,
  }) async {
    try {
      return await _fetchShelves(onBatch: onBatch);
    } catch (_) {
      return const [];
    }
  }

  Future<List<_SourcedCategory>> _safelyFetchCategories({
    void Function(List<_SourcedCategory> items)? onBatch,
  }) async {
    try {
      return await _fetchCategories(onBatch: onBatch);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SourcedBook>> _safelyFetchLatest({
    void Function(List<SourcedBook> items)? onBatch,
  }) async {
    try {
      return await _fetchLatest(onBatch: onBatch);
    } catch (_) {
      return const [];
    }
  }

  Future<List<_DiscoveryShelf>> _fetchShelves({
    void Function(List<_DiscoveryShelf> items)? onBatch,
  }) async {
    final batches = await _fetchSourceBatches(
      _targets('discover'),
      (
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
      },
      onBatch: onBatch,
    );
    return batches.expand((items) => items).toList(growable: false);
  }

  Future<List<_SourcedCategory>> _fetchCategories({
    void Function(List<_SourcedCategory> items)? onBatch,
  }) async {
    final batches = await _fetchSourceBatches(
      _targets('discover'),
      (
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
      },
      onBatch: onBatch,
    );
    return batches.expand((items) => items).toList(growable: false);
  }

  Future<List<SourcedBook>> _fetchLatest({
    void Function(List<SourcedBook> items)? onBatch,
  }) async {
    final batches = await _fetchSourceBatches(
      _targets('discover'),
      (
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
      },
      onBatch: onBatch,
    );
    final interleaved = BookSourcesPage.interleaveLatestBatches(batches);
    // 总量截断：源数量多时交错结果仍可能上千条，只保留前 maxLatestTotal 本。
    return interleaved.take(BookSourcesPage.maxLatestTotal).toList(growable: false);
  }

  Future<List<List<T>>> _fetchSourceBatches<T>(
    List<RegisteredBookSource> sources,
    Future<List<T>> Function(RegisteredBookSource source) fetch, {
    void Function(List<T> items)? onBatch,
  }) async {
    // 每个源完成后立即回调 onBatch，供发现页流式实时上屏（不必等全部源完成）。
    final futures = sources.map((source) async {
      try {
        final items = await fetch(source);
        if (onBatch != null && items.isNotEmpty) onBatch(items);
        return _SourceFetchResult<T>.success(source, items);
      } catch (error) {
        return _SourceFetchResult<T>.failure(source, error);
      }
    });
    final results = await Future.wait(futures);
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

  /// 自动加载默认栏目（数据未加载或栏目切换后调用），保证分类区下方立刻有书可看。
  Future<void> _autoSelectSection() async {
    final sections = _groupCategorySections(_aggregatedCategories);
    if (sections.isEmpty) return;
    final key = (_selectedSectionKey != null &&
            sections.any((s) => s.key == _selectedSectionKey))
        ? _selectedSectionKey!
        : sections.first.key;
    // 已加载过同一栏目则跳过，避免重复请求。
    if (_selectedSectionKey == key && _sectionBooks.isNotEmpty) return;
    await _loadSectionBooks(key);
  }

  /// 切换到指定栏目并展示书籍。
  ///
  /// 流程：内存缓存命中 → 秒出旧数据 → 后台静默刷新替换缓存；
  /// 未命中 → 显示加载态 → 拉取成功后写入内存与磁盘缓存。
  Future<void> _loadSectionBooks(String key) async {
    final sections = _groupCategorySections(_aggregatedCategories);
    if (sections.isEmpty) return;
    final active = sections.firstWhere(
      (s) => s.key == key,
      orElse: () => sections.first,
    );
    final cached = _sectionCache[key];
    if (cached != null && cached.isNotEmpty) {
      // 命中缓存：避免闪烁，直接复用旧数据。
      final isSwitch = _selectedSectionKey != key || _sectionBooks.isEmpty;
      if (isSwitch) {
        setState(() {
          _selectedSectionKey = key;
          _sectionBooks = cached;
          _loadingSectionBooks = false;
        });
      }
      // 缓存足够新鲜则不再请求，否则后台静默刷新替换。
      final fetchedAt = _sectionFetchedAt[key];
      final stale =
          fetchedAt == null ||
          DateTime.now().difference(fetchedAt) > sectionCacheFreshness;
      if (stale) unawaited(_refreshSectionBooks(key));
      return;
    }
    setState(() {
      _selectedSectionKey = key;
      _loadingSectionBooks = true;
      // 清空旧栏目数据，避免切换后残留上一栏目的书。
      _sectionBooks = const [];
    });
    try {
      // 流式加载：每返回一批分类结果就增量上屏，用户无需等所有资源归位才能看到内容。
      final books = await _fetchSectionBooks(
        active,
        onBatch: (items) {
          if (!mounted || _selectedSectionKey != key) return;
          setState(() {
            _sectionBooks = List.of(_sectionBooks)..addAll(items);
            // 流式期间同样截断到 20 本，避免中间态膨胀。
            const int maxBooksPerSection = 20;
            if (_sectionBooks.length > maxBooksPerSection) {
              _sectionBooks = _sectionBooks.take(maxBooksPerSection).toList();
            }
            // 首批到达即切出"加载中"占位，展示已有内容并继续追加。
            _loadingSectionBooks = false;
          });
        },
      );
      if (!mounted || _selectedSectionKey != key) return;
      _sectionCache[key] = books;
      _sectionFetchedAt[key] = DateTime.now();
      _persistDiscoveryCache();
      setState(() {
        _sectionBooks = books;
        _loadingSectionBooks = false;
      });
    } catch (_) {
      if (!mounted || _selectedSectionKey != key) return;
      setState(() => _loadingSectionBooks = false);
    }
  }

  /// 后台静默预热所有尚未缓存的栏目，把它们的数据拉取并写入缓存，
  /// 用户切换栏目时可无感秒出（不需要再等待网络）。并发 2 个栏目并行。
  ///
  /// 仅在发现页处于打开中时执行；页面不可见时挂起，待 [didChangeDependencies]
  /// 观察到回到前台再补跑，避免切走后仍在后台聚合占用网络与主线程。
  Future<void> _warmUpAllSections() async {
    if (!_isPageActive) {
      _pendingWarmUp = true;
      return;
    }
    final sections = _groupCategorySections(_aggregatedCategories);
    if (sections.isEmpty) return;
    // 只补还没缓存的栏目；已命中缓存的不重复请求。
    final pending = sections
        .where(
          (s) => (_sectionCache[s.key] ?? const []).isEmpty,
        )
        .toList(growable: false);
    if (pending.isEmpty) return;
    const int parallelism = 2;
    for (var i = 0; i < pending.length; i += parallelism) {
      // 预热中途切走了页面：立即暂停剩余栏目，留待回到前台再续。
      if (!_isPageActive) {
        _pendingWarmUp = true;
        return;
      }
      final end = math.min(i + parallelism, pending.length);
      final chunk = pending.sublist(i, end);
      await Future.wait<Object?>(
        chunk.map((section) async {
          if (!_isPageActive) return null;
          try {
            final books = await _fetchSectionBooks(section);
            if (!mounted || !_isPageActive) return null;
            _sectionCache[section.key] = books;
            _sectionFetchedAt[section.key] = DateTime.now();
            _persistDiscoveryCache();
          } catch (_) {}
          return null;
        }),
      );
      if (!mounted) return;
    }
  }

  /// 后台静默刷新某个栏目：拉新数据替换缓存与当前展示（不显示加载态）。
  ///
  /// 仅在发现页打开中执行；页面不可见时跳过，避免离开页面后仍在后台
  /// 聚合拉取网络数据。用户切换栏目时页面必然可见，不受影响。
  Future<void> _refreshSectionBooks(String key) async {
    if (!_isPageActive) return;
    final sections = _groupCategorySections(_aggregatedCategories);
    if (sections.isEmpty) return;
    final active = sections.firstWhere(
      (s) => s.key == key,
      orElse: () => sections.first,
    );
    try {
      final books = await _fetchSectionBooks(active);
      if (!mounted) return;
      _sectionCache[key] = books;
      _sectionFetchedAt[key] = DateTime.now();
      _persistDiscoveryCache();
      // 仍停留在该栏目，或当前无数据时，用新数据替换展示。
      if (_selectedSectionKey == key || _sectionBooks.isEmpty) {
        setState(() {
          _sectionBooks = books;
          _loadingSectionBooks = false;
        });
      }
    } catch (_) {
      // 刷新失败保留旧数据即可。
    }
  }

  /// 把发现页（含已缓存的各栏目书籍）静默写回本地缓存。
  void _persistDiscoveryCache() {
    final freshCache = _encodeDiscoveryCache(
      shelves: _shelves,
      categories: _categories,
      latest: _latest,
    );
    if (freshCache != null) {
      unawaited(DiscoveryCacheService.instance.write(freshCache));
    }
  }

  /// 聚合一个栏目里所有细分分类的书籍：与最新版块一致，收集所有「源+分类」
  /// 对后一次性全发起请求，每个完成后流式回调 [onBatch] 实时上屏；最终跨来源
  /// 交错混排并截断到 [maxBooksPerSection] 本，避免列表无限膨胀。
  Future<List<SourcedBook>> _fetchSectionBooks(
    _CategorySection section, {
    void Function(List<SourcedBook> items)? onBatch,
  }) async {
    // 收集所有「源+分类」对（按分类名去重，最多 maxCategories 个子分类）。
    final byName = <String, _SourcedCategory>{};
    for (final c in section.cats) {
      final name = c.name.trim();
      if (name.isEmpty) continue;
      byName.putIfAbsent(name, () => c);
    }
    final unique = byName.values.toList(growable: false);
    const int maxCategories = 12;
    const int maxBooksPerSection = 20;
    final take = math.min(unique.length, maxCategories);

    // 展开成 (source, category) 对列表，供无界并发拉取。
    final pairs = <(RegisteredBookSource, _SourcedCategory)>[];
    for (var i = 0; i < take; i++) {
      final cat = unique[i];
      final name = cat.name.trim();
      final candidates =
          _categories.where((c) => c.name.trim() == name).toList(growable: false);
      for (final c in candidates) {
        pairs.add((c.source, c));
      }
    }
    if (pairs.isEmpty) return const [];

    // 与 _fetchLatest 一致：所有对同时发起，每个完成即流式回调上屏。
    final futures = pairs.map((pair) async {
      try {
        final page = await _client.getDiscovery(
          pair.$1,
          exploreUrlOverride: pair.$2.id,
        );
        final books = <SourcedBook>[];
        for (final section in page.sections) {
          for (final item in section.items) {
            if (item.book != null) {
              books.add(SourcedBook(source: pair.$1, book: item.book!));
            }
          }
        }
        // 流式回调：每个对完成后立即把原始结果推给 UI，不等全部完成。
        if (onBatch != null && books.isNotEmpty) onBatch(books);
        return (source: pair.$1, books: books);
      } catch (_) {
        return (source: pair.$1, books: const <SourcedBook>[]);
      }
    });
    final results = await Future.wait(futures);

    // 全部完成后：跨来源交错混排（与最新版块一致），再按书名去重截断。
    final batches = results
        .where((r) => r.books.isNotEmpty)
        .map((r) => r.books)
        .toList(growable: false);
    final interleaved = BookSourcesPage.interleaveLatestBatches(batches);
    final seen = <String>{};
    final merged = <SourcedBook>[];
    for (final r in interleaved) {
      final title = r.book.title.trim();
      if (title.isNotEmpty && seen.add(title)) {
        merged.add(r);
        if (merged.length >= maxBooksPerSection) break;
      }
    }
    return merged;
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
      slivers.addAll(_buildCategorySlivers());
    }
    if (latest.isNotEmpty) {
      slivers.addAll(_buildLatestSectionSlivers(latest));
    }
    slivers.addAll(_buildShelfSlivers(shelves));
    // 页面底部安全留白统一放在 feed 最末段，避免它在分类/最新等非末节里出现，
    // 造成版块之间割裂的大空档。
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: bottomPadding)));
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

  List<Widget> _buildCategorySlivers() {
    final cats = _aggregatedCategories;
    if (cats.isEmpty) return const [SliverToBoxAdapter(child: SizedBox.shrink())];
    final sections = _groupCategorySections(cats);
    // 展开的栏目：优先用户上次选择，失效则回落到第一个非空栏目。
    final activeKey = (_selectedSectionKey != null &&
            sections.any((s) => s.key == _selectedSectionKey))
        ? _selectedSectionKey!
        : sections.first.key;
    return [
      SliverToBoxAdapter(
        child: _centerSectionChild(
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: _buildSectionHeader(
              context.l10n.discoverCategories,
              Icons.category_rounded,
            ),
          ),
        ),
      ),
      // 一级栏目条（参考番茄/七猫：榜单/玄幻仙侠/都市/言情/…），选中后下方
      // 直接展示该栏目聚合书籍列表，不再重复展示二级分类选项。
      _categorySectionBar(
        sections: sections,
        activeKey: activeKey,
        onSelect: (key) {
          if (key == activeKey) return;
          unawaited(_loadSectionBooks(key));
        },
        scheme: Theme.of(context).colorScheme,
      ),
      if (_loadingSectionBooks && _sectionBooks.isEmpty)
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Center(child: CircularProgressIndicator()),
          ),
          topPadding: 16,
          bottomPadding: 24,
        )
      else if (_sectionBooks.isNotEmpty)
        // 横向封面书架（仅前 N 本）+「查看全部」入口，压缩高度避免遮挡下方「最新」版块。
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
          sliver: SliverToBoxAdapter(
            child: _CategoryBookShelf(
              books: _sectionBooks,
              onTapBook: (result) => _actions.showBookDetails(result),
              onViewAll: _showSectionAllBooks,
            ),
          ),
        )
      else if (_selectedSectionKey != null && !_loadingSectionBooks)
        _paddedSectionSliver(
          _centerSectionChild(
            Padding(
              padding: const EdgeInsets.only(top: 26, bottom: 26),
              child: Text(
                context.l10n.bookSourcesNoResults,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          bottomPadding: 24,
        ),
    ];
  }

  /// 「查看全部」：以底部抽屉展示当前分类栏目的完整书籍列表。
  void _showSectionAllBooks() {
    final books = _sectionBooks;
    if (books.isEmpty) return;
    final sections = _groupCategorySections(_aggregatedCategories);
    final activeKey = _selectedSectionKey ??
        (sections.isEmpty ? null : sections.first.key);
    final activeSection = sections.where((s) => s.key == activeKey).firstOrNull;
    final sheetTitle = activeSection != null
        ? '${activeSection.title} · ${books.length} 本书'
        : '${books.length} 本书';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.94,
        builder: (context, scrollController) => Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(sheetContext).colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(sheetContext).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      sheetTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(sheetContext).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: books.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final result = books[index];
                    return SourcedBookListTile(
                      result: result,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _actions.showBookDetails(result);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  List<Widget> _buildLatestSectionSlivers(List<SourcedBook> latest) {
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
                      '$shown/${latest.length}',
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
                          '展开更多 $remain 条',
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
          bottomPadding: 24,
        ),
    ];
  }

  List<Widget> _buildShelfSlivers(List<_DiscoveryShelf> shelves) {
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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

/// 栏目书架：横向滚动的竖版封面卡片（前 [_maxShown] 本）+ 末尾「查看全部」入口。
/// 压缩为单行书架，避免长列表遮挡下方「最新」版块。
class _CategoryBookShelf extends StatelessWidget {
  static const int _maxShown = 20;

  final List<SourcedBook> books;
  final ValueChanged<SourcedBook> onTapBook;
  final VoidCallback onViewAll;

  const _CategoryBookShelf({
    required this.books,
    required this.onTapBook,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final shown = books.take(_maxShown).toList();
    final hasMore = books.length > _maxShown;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 256,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: shown.length + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          if (index >= shown.length) {
            return _ViewAllTile(
              count: books.length,
              scheme: scheme,
              onTap: onViewAll,
            );
          }
          final result = shown[index];
          return SourcedBookCard(
            result: result,
            onTap: () => onTapBook(result),
          );
        },
      ),
    );
  }
}

/// 书架末尾的「查看全部」瓦片：点击展开当前分类的完整书籍列表。
class _ViewAllTile extends StatelessWidget {
  final int count;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _ViewAllTile({
    required this.count,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.grid_view_rounded, size: 22, color: scheme.primary),
              const SizedBox(height: 6),
              const Text('查看全部', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              const SizedBox(height: 2),
              Text(
                '$count 本',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
            ],
          ),
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