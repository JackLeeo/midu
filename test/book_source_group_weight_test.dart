// M4 对标 Legado：书源分组 / 排序 / 加权增强测试。
// 覆盖：
//  1. registry 载入保留存储顺序（不再按名称强制重排）
//  2. sortSources 拖拽排序语义（未列出的源垫后保持相对顺序）
//  3. setGroup / setWeight 持久化与空值清除
//  4. 聚合搜索按权重选 canonical 源 / 源内排序 / weightSum 破平
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_aggregated_search.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookSourceRegistry.resetMutationTailForTest();
  });

  RegisteredBookSource _legado(
    String id, {
    String name = '',
    Map<String, dynamic>? config,
  }) {
    return RegisteredBookSource(
      id: id,
      name: name.isEmpty ? id : name,
      description: '$id desc',
      manifestUrl: Uri.parse('https://$id.example/manifest.json'),
      apiBaseUrl: Uri.parse('https://$id.example/api/'),
      protocolVersion: '3.0',
      languages: const ['zh'],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      addedAt: DateTime.utc(2026, 1, 1),
      sourceProtocol: BookSourceProtocolKind.legado,
      // Legado 源持久化后反序列化要求 sourceConfig 非空。
      sourceConfig: config ?? {'bookSourceUrl': 'https://$id.example/'},
    );
  }

  group('BookSourceRegistry 顺序', () {
    test('载入保留存储顺序，不再按名重排', () async {
      final registry = BookSourceRegistry();
      await registry.upsert(_legado('c', name: 'C源'));
      await registry.upsert(_legado('a', name: 'A源'));
      await registry.upsert(_legado('b', name: 'B源'));
      final loaded = await registry.load();
      expect(loaded.map((s) => s.id).toList(), ['c', 'a', 'b']);
    });

    test('sortSources 按给定顺序重排，未列出源垫后', () async {
      final registry = BookSourceRegistry();
      await registry.upsert(_legado('a'));
      await registry.upsert(_legado('b'));
      await registry.upsert(_legado('c'));
      final sorted = await registry.sortSources(['b', 'c']);
      expect(sorted.map((s) => s.id).toList(), ['b', 'c', 'a']);
    });
  });

  group('BookSourceRegistry 分组/权重', () {
    test('setGroup 持久化并在重载后保持；空值清除回退默认分组', () async {
      final registry = BookSourceRegistry();
      await registry.upsert(_legado('a'));
      await registry.setGroup('a', '玄幻');
      var reload = await registry.load();
      expect(reload.single.group, '玄幻');

      await registry.setGroup('a', '');
      reload = await BookSourceRegistry().load();
      expect(reload.single.group, '默认分组');
    });

    test('setWeight 持久化；<=0 清除回退 0', () async {
      final registry = BookSourceRegistry();
      await registry.upsert(_legado('a'));
      await registry.setWeight('a', 30);
      var reload = await registry.load();
      expect(reload.single.weight, 30);

      await registry.setWeight('a', 0);
      reload = await BookSourceRegistry().load();
      expect(reload.single.weight, 0);
    });

    test('group/weight getter 缺省回退', () {
      final source = _legado('a', config: {'bookSourceGroup': '都市'});
      expect(source.group, '都市');
      expect(source.weight, 0);
      expect(_legado('b').group, '默认分组');
    });
  });

  group('聚合搜索加权', () {
    test('同书多源命中：高权重源为 canonical 且源内排前', () async {
      final low = _legado('low', config: {'weight': 0});
      final high = _legado('high', config: {'weight': 10});
      final client = _FakeSearchClient({
        low.id: BookSourceSearchPage(
          items: const [
            BookSourceBook(id: 'b1', title: '测试之书', author: '作者'),
          ],
          page: 1,
          pageSize: 20,
          hasMore: false,
        ),
        high.id: BookSourceSearchPage(
          items: const [
            BookSourceBook(id: 'b1', title: '测试之书', author: '作者'),
          ],
          page: 1,
          pageSize: 20,
          hasMore: false,
        ),
      });
      final page = await BookSourceAggregatedSearch(client).search(
        [high, low],
        '测试之书',
      );
      final hit = page.hits.single;
      expect(hit.sources.first.sourceId, 'high'); // 高权重源排前
      expect(hit.primary.sourceId, 'high');
      expect(hit.canonicalTitle, '测试之书');
    });

    test('tier/score 相同时按 weightSum 破平（加权聚合）', () async {
      // 两个书名都与 query「测试」重合 2/4 字符，tier 2 + 相等 score；
      // 命中权重总和决定先后。
      final weak = _legado('weak', config: {'weight': 5});
      final strong = _legado('strong', config: {'weight': 20});
      final client = _FakeSearchClient({
        weak.id: BookSourceSearchPage(
          items: const [BookSourceBook(id: 'w1', title: '测试一号', author: '')],
          page: 1,
          pageSize: 20,
          hasMore: false,
        ),
        strong.id: BookSourceSearchPage(
          items: const [BookSourceBook(id: 's1', title: '测试二号', author: '')],
          page: 1,
          pageSize: 20,
          hasMore: false,
        ),
      });
      final page = await BookSourceAggregatedSearch(client).search(
        [weak, strong],
        '测试',
      );
      expect(page.hits, hasLength(2));
      expect(page.hits.first.canonicalTitle, '测试二号');
      expect(page.hits.first.weightSum, greaterThan(page.hits.last.weightSum));
    });
  });
}

/// 测试专用：直接返回预设搜索页，不发起任何网络请求。
class _FakeSearchClient extends BookSourceClient {
  _FakeSearchClient(this.responses);

  final Map<String, BookSourceSearchPage> responses;

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    return responses[source.id] ??
        const BookSourceSearchPage(
          items: [],
          page: 1,
          pageSize: 20,
          hasMore: false,
        );
  }
}