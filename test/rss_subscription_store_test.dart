// M8 RSS 订阅存储与抓取缓存专项测试：
// 1. URL 列表增删与持久化（仅接受 http/https）
// 2. RssFeedService：抓取→解析→内存缓存命中
// 3. refresh 强制刷新绕过缓存
// 4. 磁盘缓存跨实例命中（新实例不重复抓取）
// 5. invalidate 失效后重新抓取

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/services/rss/rss_feed_model.dart';
import 'package:midu/services/rss/rss_parser_service.dart';
import 'package:midu/services/rss/rss_subscription_store.dart';

const String _feedUrl = 'https://example.com/feed.xml';

const String _rssXml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>缓存测试源</title>
    <link>https://example.com/</link>
    <item>
      <guid>item-1</guid>
      <title>条目一</title>
      <description>摘要</description>
    </item>
  </channel>
</rss>
''';

class _FakeFetcher extends RssFeedFetcher {
  String body = _rssXml;
  int fetchCount = 0;
  final List<String> urls = [];

  @override
  Future<String> fetch(String url) async {
    fetchCount++;
    urls.add(url);
    return body;
  }
}

void main() {
  group('RssSubscriptionStore URL 订阅', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('新增订阅并持久化到 prefs', () async {
      final store = RssSubscriptionStore();
      expect(await store.loadUrls(), isEmpty);

      final urls = await store.addUrl(_feedUrl);
      expect(urls, [_feedUrl]);
      // 重复添加幂等
      expect(await store.addUrl(_feedUrl), [_feedUrl]);
      expect(await store.loadUrls(), [_feedUrl]);
    });

    test('非 http/https 地址被拒绝', () async {
      final store = RssSubscriptionStore();
      expect(await store.addUrl('ftp://example.com/x'), isEmpty);
      expect(await store.addUrl('not a url'), isEmpty);
      expect(await store.addUrl(''), isEmpty);
    });

    test('移除订阅', () async {
      final store = RssSubscriptionStore();
      await store.addUrl(_feedUrl);
      await store.addUrl('https://b.example/2');
      final urls = await store.removeUrl(_feedUrl);
      expect(urls, ['https://b.example/2']);
    });
  });

  group('RssFeedService 缓存', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('首次抓取+解析，二次内存缓存命中不重复抓取', () async {
      final fetcher = _FakeFetcher();
      final service = RssFeedService(
        fetcher: fetcher,
        parser: const RssParserService(),
      );

      final first = await service.loadFeed(_feedUrl);
      expect(fetcher.fetchCount, 1);
      expect(first.title, '缓存测试源');
      expect(first.items.single.title, '条目一');

      final second = await service.loadFeed(_feedUrl);
      expect(fetcher.fetchCount, 1, reason: '内存缓存命中不重复抓取');
      expect(second.items, hasLength(1));
    });

    test('refresh:true 强制重新抓取并更新', () async {
      final fetcher = _FakeFetcher();
      final service = RssFeedService(
        fetcher: fetcher,
        parser: const RssParserService(),
      );
      await service.loadFeed(_feedUrl);

      fetcher.body = _rssXml.replaceFirst('条目一', '更新后条目');
      final refreshed = await service.loadFeed(_feedUrl, refresh: true);
      expect(fetcher.fetchCount, 2);
      expect(refreshed.items.single.title, '更新后条目');
    });

    test('磁盘缓存：新服务实例命中本地缓存不重复抓取', () async {
      final fetcher = _FakeFetcher();
      final serviceA = RssFeedService(
        fetcher: fetcher,
        parser: const RssParserService(),
      );
      await serviceA.loadFeed(_feedUrl);
      expect(fetcher.fetchCount, 1);

      // 新实例：内存为空，应走磁盘缓存
      final serviceB = RssFeedService(
        fetcher: fetcher,
        parser: const RssParserService(),
      );
      final cached = await serviceB.loadFeed(_feedUrl);
      expect(fetcher.fetchCount, 1, reason: '磁盘缓存命中');
      expect(cached.title, '缓存测试源');
    });

    test('invalidate 清除内存+磁盘缓存后重新抓取', () async {
      final fetcher = _FakeFetcher();
      final service = RssFeedService(
        fetcher: fetcher,
        parser: const RssParserService(),
      );
      await service.loadFeed(_feedUrl);
      expect(fetcher.fetchCount, 1);

      await service.invalidate(_feedUrl);
      final again = RssFeedService(
        fetcher: fetcher,
        parser: const RssParserService(),
      );
      final feed = await again.loadFeed(_feedUrl);
      expect(fetcher.fetchCount, 2);
      expect(feed.title, '缓存测试源');
    });
  });

  group('RssCacheEntry 编码往返', () {
    test('encode/decode 保真字段', () {
      final entry = RssCacheEntry(
        feed: RssFeed(
          title: '标题',
          link: 'https://example.com/',
          items: [
            RssItem(
              id: 'i1',
              title: '条目',
              author: '作者',
              content: '<p>正文</p>',
            ),
          ],
        ),
        cachedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final decoded = RssCacheEntry.decode(entry.encode());
      expect(decoded.feed.title, '标题');
      expect(decoded.feed.items.single.id, 'i1');
      expect(decoded.feed.items.single.content, '<p>正文</p>');
    });
  });
}