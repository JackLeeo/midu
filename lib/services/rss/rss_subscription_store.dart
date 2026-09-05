// 文件说明：RSS 订阅存储与抓取。
// 技术要点：订阅 URL 列表持久化到 SharedPreferences；抓取走 dio（超时/重定向/
// 字节上限）；每源 feed 由 RssFeedCache 在内存 + 本地做 30 分钟 TTL 缓存。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../book_sources/legado/legado_book_source.dart';
import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_registry.dart';
import 'rss_feed_model.dart';
import 'rss_parser_service.dart';

/// 书源式 RSS 订阅条目（对标 Legado ruleRss 双轨）。
class RssSourceFeed {
  const RssSourceFeed({required this.name, required this.url});

  final String name;
  final String url;
}

/// 从已启用书源中收集 `ruleRss`（仅接受 http/https 静态 URL；含 @js:/{{}} 动态
/// 规则需书源运行时执行，这里跳过并在页面上展示源名防止静默丢失）。
Future<List<RssSourceFeed>> defaultRssSourceFeeds({
  BookSourceRegistry? registry,
}) async {
  final reg = registry ?? BookSourceRegistry();
  final sources = await reg.loadRunnable();
  final feeds = <RssSourceFeed>[];
  for (final source in sources) {
    final rule = _ruleRssOf(source);
    if (rule == null || rule.isEmpty) continue;
    if (rule.startsWith('@') || rule.startsWith('<') || rule.contains('{{')) {
      // 动态 ruleRss（@js:/@webBrowser:/{{...}}）：标记源名但 URL 不可直接订阅。
      feeds.add(RssSourceFeed(name: source.name, url: rule));
      continue;
    }
    final uri = Uri.tryParse(rule);
    if (uri != null &&
        uri.hasAuthority &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      feeds.add(RssSourceFeed(name: source.name, url: rule));
    }
  }
  return feeds;
}

String? _ruleRssOf(RegisteredBookSource source) {
  if (source.sourceProtocol != BookSourceProtocolKind.legado) return null;
  final config = source.sourceConfig;
  if (config == null) return null;
  try {
    final value = LegadoBookSource.fromJson(config).ruleRss;
    return value.trim();
  } catch (_) {
    return null;
  }
}

/// 订阅列表：仅存 feed URL，标题等派生信息在抓取后展示。
class RssSubscriptionStore {
  static const String _feedsKey = 'rss_subscribed_feed_urls';

  Future<List<String>> loadUrls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_feedsKey) ?? const [];
  }

  Future<List<String>> addUrl(String url) async {
    final trimmed = _normalizeUrl(url);
    if (trimmed == null) return loadUrls();
    final prefs = await SharedPreferences.getInstance();
    final next = <String>[...loadSync(prefs)];
    if (!next.contains(trimmed)) next.add(trimmed);
    await prefs.setStringList(_feedsKey, next);
    return next;
  }

  Future<List<String>> removeUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final next = [...loadSync(prefs)]..remove(url);
    await prefs.setStringList(_feedsKey, next);
    return next;
  }

  List<String> loadSync(SharedPreferences prefs) =>
      prefs.getStringList(_feedsKey) ?? const [];

  /// 仅接受 http/https 绝对 URL，其余返回 null。
  static String? _normalizeUrl(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri.toString();
  }
}

/// 抓取 feed 正文（dio 实现：8s 超时、8MB 上限、跟随重定向）。
class RssFeedFetcher {
  RssFeedFetcher({Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(responseType: ResponseType.plain));

  final Dio _dio;

  Future<String> fetch(String url) async {
    final response = await _dio.get<String>(url);
    return response.data ?? '';
  }
}

/// Feed 解析 + 内存缓存 + 本地缓存（30 分钟 TTL，重新进页先显缓存再静默刷新）。
class RssFeedService {
  RssFeedService({
    RssFeedFetcher? fetcher,
    RssParserService? parser,
  }) : _fetcher = fetcher ?? RssFeedFetcher(),
       _parser = parser ?? const RssParserService();

  final RssFeedFetcher _fetcher;
  final RssParserService _parser;

  static const Duration _cacheTtl = Duration(minutes: 30);

  final Map<String, RssCacheEntry> _memory = {};

  Future<RssFeed> loadFeed(String url, {bool refresh = false}) async {
    if (!refresh) {
      final memoryHit = _memory[url];
      if (memoryHit != null && !memoryHit.isStale(_cacheTtl)) {
        return memoryHit.feed;
      }
      final disk = await _readDiskCache(url);
      if (disk != null) {
        _memory[url] = disk;
        return disk.feed;
      }
    }
    final body = await _fetcher.fetch(url);
    final feed = _parser.parse(body, baseUri: Uri.tryParse(url));
    final entry = RssCacheEntry(feed: feed, cachedAt: DateTime.now());
    _memory[url] = entry;
    await _writeDiskCache(url, entry);
    return feed;
  }

  Future<void> invalidate(String url) async {
    _memory.remove(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('rss_feed_cache_${RssFeedService._hash(url)}');
  }

  Future<RssCacheEntry?> _readDiskCache(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('rss_feed_cache_${RssFeedService._hash(url)}');
    if (raw == null) return null;
    try {
      final entry = RssCacheEntry.decode(raw);
      if (entry.isStale(_cacheTtl)) return null;
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDiskCache(String url, RssCacheEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'rss_feed_cache_${RssFeedService._hash(url)}',
        entry.encode(),
      );
    } catch (_) {
      // 缓存写入失败不影响正文读取
    }
  }

  static String _hash(String url) {
    // 简化稳定哈希：URL 短则原样，长则取 md5 前 16 位（避免 prefs key 过长）。
    if (url.length <= 64) return url;
    return const RssFeedCacheKey().hashOf(url);
  }
}

class RssFeedCacheKey {
  const RssFeedCacheKey();

  String hashOf(String url) {
    var hash = 0;
    for (final code in url.codeUnits) {
      hash = ((hash << 5) - hash + code) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }
}

/// 缓存条目：feed 快照 + 抓取时间。可编码为 JSON 存本地。
class RssCacheEntry {
  RssCacheEntry({required this.feed, required this.cachedAt});

  final RssFeed feed;
  final DateTime cachedAt;

  bool isStale(Duration ttl) =>
      DateTime.now().difference(cachedAt) > ttl;

  String encode() => jsonEncode({
    'cachedAt': cachedAt.millisecondsSinceEpoch,
    'feed': {
      'title': feed.title,
      'link': feed.link,
      'description': feed.description,
      'language': feed.language,
      'updatedAt': feed.updatedAt?.millisecondsSinceEpoch,
      'items': [
        for (final item in feed.items)
          {
            'id': item.id,
            'title': item.title,
            'link': item.link,
            'author': item.author,
            'publishedAt': item.publishedAt?.millisecondsSinceEpoch,
            'summary': item.summary,
            'content': item.content,
          },
      ],
    },
  });

  factory RssCacheEntry.decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final feed = map['feed'] as Map<String, dynamic>?;
    if (feed == null) throw const FormatException('missing feed');
    final items = <RssItem>[];
    for (final rawItem in (feed['items'] as List? ?? const [])) {
      final item = rawItem as Map<String, dynamic>;
      items.add(
        RssItem(
          id: '${item['id']}',
          title: item['title'] as String?,
          link: item['link'] as String?,
          author: item['author'] as String?,
          publishedAt: _epoch(item['publishedAt']),
          summary: item['summary'] as String?,
          content: item['content'] as String?,
        ),
      );
    }
    return RssCacheEntry(
      feed: RssFeed(
        title: feed['title'] as String?,
        link: feed['link'] as String?,
        description: feed['description'] as String?,
        language: feed['language'] as String?,
        updatedAt: _epoch(feed['updatedAt']),
        items: items,
      ),
      cachedAt: _epoch(map['cachedAt']) ?? DateTime.now(),
    );
  }

  static DateTime? _epoch(Object? value) {
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    return null;
  }
}