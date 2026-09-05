// M8 RSS 三种格式解析专项测试：
// Excel RSS 2.0 / Atom / JSON Feed 元数据与条目提取；
// content:encoded 保留原始 HTML；命名空间前缀标签匹配；
// RFC822 / ISO8601 日期解析；baseUri 相对链接解析；
// htmlToParagraphs 净化正文为纯文本段落。

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/pages/rss/rss_article_page.dart';
import 'package:midu/services/rss/rss_parser_service.dart';

void main() {
  const parser = RssParserService();

  group('RSS 2.0', () {
    const rss2 = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>示例源</title>
    <link>https://example.com/</link>
    <description>示例描述</description>
    <language>zh-cn</language>
    <lastBuildDate>Wed, 02 Oct 2002 13:00:00 GMT</lastBuildDate>
    <item>
      <guid>https://example.com/item/1</guid>
      <title>第一篇</title>
      <link>/item/1</link>
      <description>摘要一</description>
      <author>作者甲</author>
      <pubDate>Thu, 02 Oct 2002 21:00:00 +0800</pubDate>
      <content:encoded><![CDATA[<p>正文第一段。</p><p>正文第二段。</p>]]></content:encoded>
    </item>
    <item>
      <title>无 guid 无链接</title>
    </item>
  </channel>
</rss>
''';

    test('解析频道元数据与条目', () {
      final feed = parser.parseXml(
        rss2,
        baseUri: Uri.parse('https://example.com/feed.xml'),
      );
      expect(feed.title, '示例源');
      expect(feed.link, 'https://example.com/');
      expect(feed.description, '示例描述');
      expect(feed.language, 'zh-cn');
      expect(feed.updatedAt!.toUtc(), DateTime.utc(2002, 10, 2, 13, 0));
      expect(feed.items, hasLength(2));
    });

    test('条目字段：链接基于 baseUri 解析、content:encoded 保留 HTML', () {
      final items = parser
          .parseXml(rss2, baseUri: Uri.parse('https://example.com/feed.xml'))
          .items;
      final first = items.first;
      expect(first.id, 'https://example.com/item/1');
      expect(first.title, '第一篇');
      expect(first.link, 'https://example.com/item/1');
      expect(first.summary, '摘要一');
      expect(first.author, '作者甲');
      expect(
        first.publishedAt!.toUtc(),
        DateTime.utc(2002, 10, 2, 13, 0),
        reason: '+0800 21:00 等于 UTC 13:00',
      );
      expect(first.content, '<p>正文第一段。</p><p>正文第二段。</p>');
    });

    test('无 guid/无链接条目回退到 title 作为稳定 id', () {
      final second = parser
          .parseXml(rss2, baseUri: Uri.parse('https://example.com/feed.xml'))
          .items[1];
      expect(second.id, '无 guid 无链接');
      expect(second.link, isEmpty);
    });

    test('名称空间前缀 content:encoded 能被识别', () {
      // 直接验证 _named 兼容逻辑：带前缀标签的正文能提取。
      final item = parser
          .parseXml(
            '<rss version="2.0"><channel>'
            '<item><guid>g</guid>'
            '<content:encoded><![CDATA[<p>带前缀正文</p>]]></content:encoded>'
            '</item></channel></rss>',
          )
          .items
          .single;
      expect(item.content, isNotNull);
      expect(item.content, contains('带前缀正文'));
    });
  });

  group('Atom', () {
    const atom = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>原子源</title>
  <subtitle>原子描述</subtitle>
  <updated>2026-09-01T10:00:00Z</updated>
  <link rel="alternate" href="https://example.com/"/>
  <entry>
    <id>tag:example.com,2026:1</id>
    <title>原子条目</title>
    <link rel="alternate" href="/posts/1"/>
    <author><name>小编</name></author>
    <updated>2026-09-01T10:00:00Z</updated>
    <content type="html"><![CDATA[<p>原子正文</p>]]></content>
    <summary>原子摘要</summary>
  </entry>
</feed>
''';

    test('解析 Atom 条目与元数据', () {
      final feed = parser.parseXml(
        atom,
        baseUri: Uri.parse('https://example.com/feed.atom'),
      );
      expect(feed.title, '原子源');
      expect(feed.description, '原子描述');
      expect(feed.link, 'https://example.com/');
      expect(feed.updatedAt!.toUtc(), DateTime.utc(2026, 9, 1, 10, 0));
      expect(feed.items, hasLength(1));

      final entry = feed.items.single;
      expect(entry.id, 'tag:example.com,2026:1');
      expect(entry.title, '原子条目');
      expect(entry.link, 'https://example.com/posts/1');
      expect(entry.author, '小编');
      expect(entry.summary, '原子摘要');
      expect(entry.content, '<p>原子正文</p>');
      expect(entry.publishedAt!.toUtc(), DateTime.utc(2026, 9, 1, 10, 0));
    });
  });

  group('JSON Feed', () {
    const jsonFeed = '''
{
  "version": "https://jsonfeed.org/version/1.1",
  "title": "JSON 源",
  "home_page_url": "https://example.com/",
  "description": "JSON 描述",
  "date_modified": "2026-08-31T08:00:00+08:00",
  "items": [
    {
      "id": "jf-1",
      "title": "JSON 条目",
      "url": "/posts/jf1",
      "author": {"name": "作者Z"},
      "date_published": "2026-08-31T00:00:00Z",
      "summary": "JSON 摘要",
      "content_html": "<p>JSON 正文</p>"
    },
    {"title": "缺 id 缺 url"}
  ]
}
''';

    test('解析 JSON Feed 条目（标题回退与链接解析）', () {
      final feed = parser.parseJson(
        jsonFeed,
        baseUri: Uri.parse('https://example.com/feed.json'),
      );
      expect(feed.title, 'JSON 源');
      expect(feed.link, 'https://example.com/');
      expect(feed.items, hasLength(2));

      final first = feed.items.first;
      expect(first.id, 'jf-1');
      expect(first.title, 'JSON 条目');
      expect(first.link, 'https://example.com/posts/jf1');
      expect(first.author, '作者Z');
      expect(first.summary, 'JSON 摘要');
      expect(first.content, '<p>JSON 正文</p>');
      expect(
        first.publishedAt!.toUtc(),
        DateTime.utc(2026, 8, 31, 0, 0),
      );

      final fallback = feed.items[1];
      expect(fallback.id, '缺 id 缺 url');
    });
  });

  group('格式识别与异常', () {
    test('parse 自动识别 JSON 与 XML', () {
      final fromJson = parser.parse('{"title":"T","items":[]}');
      expect(fromJson.title, 'T');

      final fromXml = parser.parse('<rss version="2.0"><channel/></rss>');
      expect(fromXml.items, isEmpty);
    });

    test('未知根元素抛错', () {
      expect(
        () => parser.parseXml('<html><body/></html>'),
        throwsA(isA<RssParseException>()),
      );
      expect(
        () => parser.parseJson('not json'),
        throwsA(isA<RssParseException>()),
      );
    });
  });

  group('htmlToParagraphs', () {
    test('剔除 script/style，块级元素分段', () {
      const html = '''
<div>
  <script>alert(1)</script>
  <p>第一段。</p>
  <p>第二段。</p>
  <ul><li>列表一</li><li>列表二</li></ul>
  <style>.x{}</style>
</div>
''';
      final paragraphs = htmlToParagraphs(html);
      expect(paragraphs, ['第一段。', '第二段。', '列表一', '列表二']);
    });

    test('br 断行与纯文本单段', () {
      expect(htmlToParagraphs('一行<br>二行'), ['一行', '二行']);
      expect(htmlToParagraphs('  纯文本只有一段  '), ['纯文本只有一段']);
      expect(htmlToParagraphs(''), isEmpty);
      expect(htmlToParagraphs('  '), isEmpty);
    });
  });
}