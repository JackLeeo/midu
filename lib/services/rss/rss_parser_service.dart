// 文件说明：RSS 解析器 —— 支持 RSS 2.0 / Atom / JSON Feed 三种格式。
// 技术要点：XML 分支用 `package:xml`（HTML 解析器会把 `<link>` 当 void 元素、
// 会把 CDATA 切坏，不适合解析 XML）；字符串 token 提取统一做空白折叠。
import 'dart:convert';

import 'package:xml/xml.dart';

import 'rss_feed_model.dart';

class RssParseException implements Exception {
  const RssParseException(this.message);

  final String message;

  @override
  String toString() => 'RssParseException: $message';
}

class RssParserService {
  const RssParserService();

  /// 自动识别入参格式（JSON Feed 有 `version` 字段；否则按 XML 解析）。
  RssFeed parse(String body, {Uri? baseUri}) {
    if (body.trimLeft().startsWith('{')) return parseJson(body);
    return parseXml(body, baseUri: baseUri);
  }

  /// 解析 RSS 2.0 / Atom XML。
  RssFeed parseXml(String xml, {Uri? baseUri}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } catch (_) {
      throw const RssParseException('RSS document is not valid XML.');
    }
    final root = document.rootElement;
    final local = root.name.local.toLowerCase();
    if (local == 'rss' || local == 'rdf') {
      return _parseRss2(root, baseUri);
    }
    if (local == 'feed') {
      return _parseAtom(root, baseUri);
    }
    throw RssParseException(
      'Unsupported RSS document root: ${root.name.qualified}.',
    );
  }

  /// 解析 JSON Feed（https://www.jsonfeed.org/version/1.1）。
  RssFeed parseJson(String body, {Uri? baseUri}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const RssParseException('JSON Feed is not valid JSON.');
    }
    if (decoded is! Map) {
      throw const RssParseException('JSON Feed must be an object.');
    }
    final items = <RssItem>[];
    final rawItems = decoded['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final rssItem = _jsonItem(raw, baseUri);
        if (rssItem != null) items.add(rssItem);
      }
    }
    return RssFeed(
      title: _string(decoded['title']),
      link: _resolve(_string(decoded['home_page_url']), baseUri),
      description: _string(decoded['description']),
      language: null,
      updatedAt: _parseDate(_string(decoded['date_modified'])),
      items: items,
    );
  }

  RssFeed _parseRss2(XmlElement root, Uri? baseUri) {
    final channel = _child(root, 'channel') ?? root;
    final items = <RssItem>[];
    for (final itemNode in _childrenOf(channel, 'item')) {
      final rssItem = _rss2Item(itemNode, baseUri);
      if (rssItem != null) items.add(rssItem);
    }
    return RssFeed(
      title: _childText(channel, 'title'),
      link: _resolve(_childText(channel, 'link'), baseUri),
      description: _childText(channel, 'description'),
      language: _childText(channel, 'language'),
      updatedAt: _parseDate(_childText(channel, 'lastBuildDate')),
      items: items,
    );
  }

  RssItem? _rss2Item(XmlElement node, Uri? baseUri) {
    final guid = _childText(node, 'guid') ?? '';
    final link = _resolve(_childText(node, 'link'), baseUri);
    final title = _childText(node, 'title') ?? '';
    final id = guid.isNotEmpty ? guid : (link.isNotEmpty ? link : title);
    if (id.isEmpty) return null;
    return RssItem(
      id: id,
      title: title.isEmpty ? null : title,
      link: link,
      author: _childText(node, 'author'),
      publishedAt: _parseDate(_childText(node, 'pubDate')),
      summary: _childText(node, 'description'),
      content: _childXml(node, 'content:encoded'),
    );
  }

  RssFeed _parseAtom(XmlElement feed, Uri? baseUri) {
    final items = <RssItem>[];
    for (final entry in _childrenOf(feed, 'entry')) {
      final rssItem = _atomEntry(entry, baseUri);
      if (rssItem != null) items.add(rssItem);
    }
    return RssFeed(
      title: _childText(feed, 'title'),
      link: _atomAlternateLink(feed, baseUri),
      description: _childText(feed, 'subtitle'),
      language: _attr(feed, 'xml:lang'),
      updatedAt: _parseDate(_childText(feed, 'updated')),
      items: items,
    );
  }

  RssItem? _atomEntry(XmlElement entry, Uri? baseUri) {
    final id = _childText(entry, 'id') ?? '';
    final link = _atomAlternateLink(entry, baseUri) ?? '';
    final title = _childText(entry, 'title') ?? '';
    final authorElement = _child(entry, 'author');
    final author = authorElement == null
        ? null
        : _childText(authorElement, 'name');
    final resolvedId = id.isNotEmpty ? id : (link.isNotEmpty ? link : title);
    if (resolvedId.isEmpty) return null;
    return RssItem(
      id: resolvedId,
      title: title.isEmpty ? null : title,
      link: link,
      author: author,
      publishedAt: _parseDate(_childText(entry, 'published') ??
          _childText(entry, 'updated')),
      summary: _childText(entry, 'summary'),
      content: _childXml(entry, 'content'),
    );
  }

  String? _atomAlternateLink(XmlElement node, Uri? baseUri) {
    for (final link in _childrenOf(node, 'link')) {
      final rel = _attr(link, 'rel').toLowerCase();
      if (rel.isEmpty || rel == 'alternate') {
        final href = _attr(link, 'href');
        if (href.isNotEmpty) return _resolve(href, baseUri);
      }
    }
    return null;
  }

  RssItem? _jsonItem(Map<dynamic, dynamic> raw, Uri? baseUri) {
    final id = _string(raw['id']);
    final link = _resolve(_string(raw['url']), baseUri);
    final title = _string(raw['title']);
    final resolvedId = (id?.isNotEmpty ?? false)
        ? id!
        : (link.isNotEmpty ? link : title ?? '');
    if (resolvedId.isEmpty) return null;
    String? author;
    final rawAuthor = raw['author'];
    if (rawAuthor is Map && rawAuthor['name'] != null) {
      author = _string(rawAuthor['name']);
    } else if (rawAuthor is String) {
      author = rawAuthor;
    }
    return RssItem(
      id: resolvedId,
      title: title,
      link: link,
      author: author,
      publishedAt: _parseDate(_string(raw['date_published'])),
      summary: _string(raw['summary']),
      content: _nonEmpty(_string(raw['content_html'])),
    );
  }

  // ===== 小工具 =====

  static final RegExp _whitespace = RegExp(r'\s+');

  /// 元素名匹配：大小写不敏感；兼容冒号前缀（`<content:encoded>` 的
  /// qualifiedName 原样保留前缀，只比较 localName 时允许省略前缀）。
  static bool _matches(XmlElement element, String name) {
    final n = name.toLowerCase();
    return element.name.qualified.toLowerCase() == n ||
        element.name.local.toLowerCase() == n;
  }

  static XmlElement? _child(XmlElement parent, String name) {
    for (final child in parent.childElements) {
      if (_matches(child, name)) return child;
    }
    return null;
  }

  static Iterable<XmlElement> _childrenOf(XmlElement parent, String name) {
    return parent.childElements.where((e) => _matches(e, name));
  }

  static String? _childText(XmlElement parent, String name) {
    final element = _child(parent, name);
    if (element == null) return null;
    final text = _collapse(element.innerText);
    return text.isEmpty ? null : text;
  }

  /// 提取子元素原始 innerXml（正文类字段，保留段落结构供阅读页分段）。
  /// CDATA 节点 serializing 时会带 `<![CDATA[...]]>` 标记，纯 CDATA 内容取其值。
  static String? _childXml(XmlElement parent, String name) {
    final element = _child(parent, name);
    if (element == null) return null;
    final children = element.children;
    if (children.isNotEmpty && children.every((n) => n is XmlCDATA)) {
      final value = children
          .map((n) => (n as XmlCDATA).value)
          .join()
          .trim();
      return value.isEmpty ? null : value;
    }
    return _nonEmpty(element.innerXml);
  }

  static String _attr(XmlElement element, String name) {
    final n = name.toLowerCase();
    for (final attribute in element.attributes) {
      final key = attribute.name.qualified.toLowerCase();
      final local = attribute.name.local.toLowerCase();
      if (key == n || local == n) return attribute.value.trim();
    }
    return '';
  }

  static String _collapse(String raw) => raw.replaceAll(_whitespace, ' ').trim();

  static String? _nonEmpty(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _string(Object? value) {
    if (value == null) return null;
    final s = '$value'.trim();
    return s.isEmpty ? null : s;
  }

  static String _resolve(String? url, Uri? baseUri) {
    final value = url ?? '';
    if (value.isEmpty || baseUri == null) return value;
    try {
      return baseUri.resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  /// 解析 RFC822（RSS pubDate）与 ISO8601（Atom/JSONFeed）日期，失败返回 null。
  static DateTime? _parseDate(String? raw) {
    final trimmed = (raw ?? '').trim();
    if (trimmed.isEmpty) return null;
    final iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso.toLocal();
    // RFC822: "Wed, 02 Oct 2002 13:00:00 GMT" / "Wed, 02 Oct 2002 08:00:00 EST"
    final match = RegExp(
      r'(?:\w+,\s*)?(\d{1,2})\s+(\w{3})\s+(\d{4})\s+'
      r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]?\d{4}|[A-Za-z]+)?',
    ).firstMatch(trimmed);
    if (match == null) return null;
    const months = {
      'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
      'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
    };
    final month = months[match.group(2)];
    if (month == null) return null;
    final zone = match.group(7);
    var offsetMinutes = 0;
    if (zone != null) {
      const zones = {
        'UT': 0, 'GMT': 0, 'UTC': 0, 'Z': 0, 'EST': -300, 'EDT': -240,
        'CST': -360, 'CDT': -300, 'MST': -420, 'MDT': -360,
        'PST': -480, 'PDT': -420,
      };
      final named = zones[zone.toUpperCase()];
      if (named != null) {
        offsetMinutes = named;
      } else if (RegExp(r'^[+-]?\d{4}$').hasMatch(zone)) {
        var hours = int.parse(zone.substring(
          zone.length - 4,
          zone.length - 2,
        ));
        var minutes = int.parse(zone.substring(zone.length - 2));
        if (zone.startsWith('-')) {
          hours = -hours;
          minutes = -minutes;
        }
        offsetMinutes = hours * 60 + minutes;
      }
    }
    final utc = DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6) ?? '0'),
    ).subtract(Duration(minutes: offsetMinutes));
    return utc.toLocal();
  }
}