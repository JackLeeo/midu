// 规则引擎专项测试：验证 Legado 常见规则模式在 HTML/JSON 上的解析正确性。
// 覆盖：CSS 选择器、索引/排除、text. 匹配、@put/@get 变量、$.. 深扫描、
//       - 前缀、JSON path、正则替换、URL resolve、||/&& 组合。
// JS 规则（@js / <js>）不依赖 fjs 沙箱执行，仅验证非 JS 语法。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' show Element;
import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';

const _html = '''
<!DOCTYPE html>
<html>
<head><title>小说站</title></head>
<body>
  <div class="grid">
    <table>
      <tr>
        <td class="even"><a href="/book/1.html">斗破苍穹</a></td>
        <td class="s1">[玄幻]</td><td class="s2"><a href="/book/1.html">斗破苍穹</a></td>
        <td class="s3"><a href="/book/1-1.html">第一章 陨落的天才</a></td><td class="s4">天蚕土豆</td>
      </tr>
      <tr>
        <td class="even"><a href="/book/2.html">完美世界</a></td>
        <td class="s1">[玄幻]</td><td class="s2"><a href="/book/2.html">完美世界</a></td>
        <td class="s3"><a href="/book/2-1.html">第一章 石村</a></td><td class="s4">辰东</td>
      </tr>
      <tr>
        <td class="even"><a href="/book/3.html">诡秘之主</a></td>
        <td class="s1">[西幻]</td><td class="s2"><a href="/book/3.html">诡秘之主</a></td>
        <td class="s3"><a href="/book/3-1.html">第一章 序章</a></td><td class="s4">爱潜水的乌贼</td>
      </tr>
    </table>
  </div>
  <div id="content" class="content">
    <p>萧炎，斗气大陆萧家之子。</p>
    <p>他缓缓抬起头，目光坚毅。</p>
  </div>
</body>
</html>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const engine = LegadoRuleEngine();
  final document = LegadoRuleDocument.parse(
    _html,
    Uri.parse('https://books.example.com/'),
  );

  Future<List<Object?>> list(String rule) =>
      engine.evaluateList(document, null, rule);
  Future<String> string(String rule, {bool resolveUrl = false}) =>
      engine.evaluateString(document, null, rule, resolveUrl: resolveUrl);

  group('bookList 基础', () {
    test('class.grid@tr matches 3 rows', () async {
      final items = await list('class.grid@tr');
      expect(items, hasLength(3));
    });

    test('tag. 前缀与 !0 排除（class.grid@tag.tr!0）', () async {
      final items = await list('class.grid@tag.tr!0');
      expect(items, hasLength(2)); // 去掉表头行
    });

    test('tbody@tr!0 排除首行', () async {
      final items = await list('tbody@tr!0');
      expect(items, hasLength(2));
    });

    test('- 前缀被忽略（-class.grid@tr == class.grid@tr）', () async {
      final items = await list('-class.grid@tr');
      expect(items, hasLength(3));
    });
  });

  group('字段提取', () {
    test('a.2@text 取第三个链接（Legado 语义：索引 .2）', () async {
      final contexts = await list('class.grid@tr');
      final title = await engine.evaluateString(
        document,
        contexts.first,
        'a.2@text',
      );
      // 第三个 <a> 是章节目录链接
      expect(title, '第一章 陨落的天才');
    });

    test('a.2@href resolve 后为章节 URL', () async {
      final contexts = await list('class.grid@tr');
      final url = await engine.evaluateString(
        document,
        contexts.first,
        'a.2@href',
        resolveUrl: true,
      );
      expect(url, 'https://books.example.com/book/1-1.html');
    });

    test('class.s4@text 提取作者', () async {
      final contexts = await list('class.grid@tr');
      final author = await engine.evaluateString(
        document,
        contexts[1],
        'class.s4@text',
      );
      expect(author, '辰东');
    });

    test('text. 按文本定位链接（text.第一章 陨落的天才@href）', () async {
      final url = await string('text.第一章 陨落的天才@href', resolveUrl: true);
      expect(url, 'https://books.example.com/book/1-1.html');
    });

    test('text. 匹配不到时返回空', () async {
      final missing = await string('text.不存在的章节@href');
      expect(missing, '');
    });
  });

  group('正文提取', () {
    test('id.content@textNodes 保留段落文本', () async {
      final content = await string('id.content@textNodes');
      expect(content, contains('萧炎'));
      expect(content, contains('目光坚毅'));
    });

    test('id.content@text 返回完整文本', () async {
      final content = await string('id.content@text');
      expect(content, contains('萧炎'));
      expect(content, contains('目光坚毅'));
    });

    test('id.content@html 返回 outerHtml（含自身标签）', () async {
      final htmlText = await string('id.content@html');
      expect(htmlText, startsWith('<div id="content"'));
      expect(htmlText, contains('<p>萧炎'));
    });

    test('.content!0@html 排除首个匹配后取 outerHtml', () async {
      final htmlText = await string('.content!0@html');
      expect(htmlText, isEmpty); // 页面只有一个 .content，排除后为空
    });

    test('ownText 只取直接子文本', () async {
      final boxDoc = LegadoRuleDocument.parse(
        '<div id="box">外层文本<span>内层文本</span></div>',
        Uri.parse('https://books.example.com/'),
      );
      final own = await engine.evaluateString(boxDoc, null, 'id.box@ownText');
      expect(own, '外层文本'); // 不含 span 内文本
      final full = await engine.evaluateString(boxDoc, null, 'id.box@text');
      expect(full, '外层文本内层文本');
    });
  });

  group('正则与组合', () {
    test('## 正则替换去除换行', () async {
      final content = await string('id.content@text##\n');
      expect(content, isNot(contains('\n')));
    });

    test('索引区间 .0:1 与排除 !0', () async {
      final range = await list('class.grid@tr.0:1');
      expect(range, hasLength(2));
      final excluding = await list('class.grid@tr!0');
      expect(excluding, hasLength(2));
    });

    test('|| 回退到第二个选择器', () async {
      final missing = await string('class.not-exist@text||class.s4@text');
      expect(missing, '天蚕土豆\n辰东\n爱潜水的乌贼');
    });

    test('&& 拼接多个结果（文档级匹配全部元素）', () async {
      final combined = await string('class.s1@text&&class.s4@text');
      expect(
        combined,
        '[玄幻]\n[玄幻]\n[西幻]\n天蚕土豆\n辰东\n爱潜水的乌贼',
      );
    });
  });

  group('URL 处理', () {
    test('绝对 URL 直接返回不二次 resolve', () async {
      // 引号字面量：与 Legado 一致，URL 规则提取到绝对地址时不再 resolve
      final abs = await string('"https://other.example/a.png"', resolveUrl: true);
      expect(abs, 'https://other.example/a.png');
    });

    test('协议相对 URL 补全 scheme', () async {
      final rel = await string('"//cdn.example/b.png"', resolveUrl: true);
      expect(rel, 'https://cdn.example/b.png');
    });

    test('相对 URL 基于文档 baseUri resolve', () async {
      final rel = await string('class.s2@a@href', resolveUrl: true);
      expect(rel, 'https://books.example.com/book/1.html');
    });
  });

  group('JSON 规则', () {
    final jsonDoc = LegadoRuleDocument.parse(
      jsonEncode({
        'data': [
          {'title': '甲', 'url': '/a', 'info': {'articleid': 1001}},
          {'title': '乙', 'url': '/b', 'info': {'articleid': 1002}},
        ],
        'nested': {'books': [{'name': '深一'}, {'name': '深二'}]},
      }),
      Uri.parse('https://json.example/api'),
    );

    test(r'$.data[*].title 展开全部标题', () async {
      final titles = await engine.evaluateList(
        jsonDoc,
        null,
        r'$.data[*].title',
      );
      expect(titles.map((e) => '$e').toList(), ['甲', '乙']);
    });

    test(r'$.data.0.url 下标 key 访问', () async {
      final first = await engine.evaluateString(
        jsonDoc,
        null,
        r'$.data.0.url',
        resolveUrl: true,
      );
      expect(first, 'https://json.example/a');
    });

    test(r'$..books[*].name 深扫描', () async {
      final names = await engine.evaluateList(
        jsonDoc,
        null,
        r'$..books[*].name',
      );
      expect(names.map((e) => '$e').toList(), ['深一', '深二']);
    });

    test(r'$..content 深扫描取深层字段', () async {
      final deep = LegadoRuleDocument.parse(
        jsonEncode({
          'code': 0,
          'data': {
            'book': {
              'detail': {'content': '第一段正文'},
            },
          },
        }),
        Uri.parse('https://json.example/api'),
      );
      final content = await engine.evaluateString(deep, null, r'$..content');
      expect(content, '第一段正文');
    });

    test(r'- 前缀的 JSON 章节列表（-$.data.[*]）', () async {
      final chapters = await engine.evaluateList(
        jsonDoc,
        null,
        r'-$.data.[*]',
      );
      expect(chapters, hasLength(2));
    });

    test('裸路径 book_name 直接访问', () async {
      final bare = LegadoRuleDocument.parse(
        jsonEncode({'book_name': '斗破苍穹'}),
        Uri.parse('https://json.example/api'),
      );
      final name = await engine.evaluateString(bare, null, 'book_name');
      expect(name, '斗破苍穹');
    });
  });

  group('@put / @get 变量', () {
    late LegadoFjsSandbox sandbox;
    late LegadoRuleEngine storedEngine;

    setUp(() {
      sandbox = LegadoFjsSandbox(); // 不 init，仅用变量存储
      storedEngine = LegadoRuleEngine(sandbox: sandbox);
    });

    tearDown(() {
      sandbox.dispose();
    });

    test('@get 读未存的变量返回空（不回落 HTML）', () async {
      final value = await storedEngine.evaluateString(document, null, '@get:{n}');
      expect(value, '');
    });

    test('@put 后 @get 可取回（init 存 n → name 取 n）', () async {
      final metaDoc = LegadoRuleDocument.parse(
        '<html><head><meta property="book_name" content="遮天"></head></html>',
        Uri.parse('https://books.example.com/'),
      );
      final initRule = r'@put:{n:"[property$=book_name]@content"}';
      await storedEngine.evaluateString(metaDoc, null, initRule);
      final name = await storedEngine.evaluateString(metaDoc, null, '@get:{n}');
      expect(name, '遮天');
    });

    test('@put 存 JSON 字段并用于 chapterUrl 模板', () async {
      final jsonDoc = LegadoRuleDocument.parse(
        jsonEncode({
          'book_name': '斗破苍穹',
          'book_id': 'abc123',
          'list': [
            {'chapter_id': 'c1', 'title': '第一章'},
            {'chapter_id': 'c2', 'title': '第二章'},
          ],
        }),
        Uri.parse('https://json.example/api'),
      );
      // 搜索/详情阶段：name 规则带 @put，把 book_id 存入 bid
      final name = await storedEngine.evaluateString(
        jsonDoc,
        null,
        r'$.book_name@put:{bid:$.book_id}',
      );
      expect(name, '斗破苍穹');
      // 目录阶段：chapterUrl 用 @get:{bid} + {{$.chapter_id}}
      final chapter = await engine.evaluateList(jsonDoc, null, r'$.list[*]');
      expect(chapter, hasLength(2));
      final url = await storedEngine.evaluateString(
        jsonDoc,
        chapter.first,
        r'https://api.example.com/c?bid=@get:{bid}&cid={{$.chapter_id}}',
        resolveUrl: true,
      );
      expect(url, 'https://api.example.com/c?bid=abc123&cid=c1');
    });

    test('列表规则中的 @put 对每个元素求值', () async {
      final jsonDoc = LegadoRuleDocument.parse(
        jsonEncode({
          'data': [
            {'info': {'articleid': 1001}},
            {'info': {'articleid': 1002}},
          ],
        }),
        Uri.parse('https://json.example/api'),
      );
      await storedEngine.evaluateList(
        jsonDoc,
        null,
        r'$.data[*]@put:{last_bid:$.info.articleid}',
      );
      expect(sandbox.getSourceVar('last_bid'), '1002'); // 最后一个元素覆盖
    });
  });

  group('插值表达式', () {
    test(r'单花括号 {$.path} 插值（推书君 tocUrl 形式）', () async {
      final jsonDoc = LegadoRuleDocument.parse(
        jsonEncode({'book': {'book_id': 7, 'totalWordSize': '500万'}}),
        Uri.parse('https://json.example/api'),
      );
      final url = await engine.evaluateString(
        jsonDoc,
        null,
        r'https://api.example.com/listBookScoreByBook?book_id={$.book.book_id}&page=1',
        resolveUrl: true,
      );
      expect(url, 'https://api.example.com/listBookScoreByBook?book_id=7&page=1');
      final wordCount = await engine.evaluateString(
        jsonDoc,
        null,
        r'{$.book.totalWordSize}字',
      );
      expect(wordCount, '500万字');
    });

    test(r'{{$.path##pattern##replacement}} 表达式内嵌正则转换', () async {
      final jsonDoc = LegadoRuleDocument.parse(
        jsonEncode({'introduction': '简介内容', 'copyright': '版权方'}),
        Uri.parse('https://json.example/api'),
      );
      final intro = await engine.evaluateString(
        jsonDoc,
        null,
        r'{{$..introduction##[\u0020]+##<br>}} 📍版权来自{{$..copyright}}',
      );
      expect(intro, '简介内容 📍版权来自版权方');
    });

    test(r'@{{$.author}} 前导 @ 剥离（推书君 author 形式）', () async {
      final jsonDoc = LegadoRuleDocument.parse(
        jsonEncode({'author_nickname': '忘语'}),
        Uri.parse('https://json.example/api'),
      );
      final author = await engine.evaluateString(
        jsonDoc,
        null,
        r'@{{$.author_nickname}}',
      );
      expect(author, '忘语');
    });

    test('{{@@htmlRule}} 整页 HTML 规则插值 + ## 转换（intro 形式）', () async {
      final htmlDoc = LegadoRuleDocument.parse(
        '''
        <html><body>
        <div class="novelintro"><p>简介第一句。</p><p>简介第二句。</p></div>
        </body></html>
        ''',
        Uri.parse('https://books.example.com/'),
      );
      final intro = await engine.evaluateString(
        htmlDoc,
        null,
        r'{{@@.novelintro@text##\s*}}##^##<br>',
      );
      expect(intro, startsWith('<br>'));
      expect(intro, contains('简介第一句'));
      expect(intro, contains('简介第二句'));
    });

    test('{{@rule}} 当前上下文 HTML 规则插值', () async {
      final htmlDoc = LegadoRuleDocument.parse(
        '''
        <html><body>
        <div class="small"><span>书籍作者：</span><a href="/a/1.html">天蚕土豆</a></div>
        </body></html>
        ''',
        Uri.parse('https://books.example.com/'),
      );
      // {{@text.书籍作者：@text##书籍作者：}} → 取含"书籍作者："元素的文本并去除前缀
      final author = await engine.evaluateString(
        htmlDoc,
        null,
        r'{{@text.书籍作者：@text##书籍作者：}}',
      );
      expect(author, isNot(contains('书籍作者：')));
      expect(author, contains('天蚕土豆'));
    });

    test('{{...##...}} 内嵌 ## 不被外层 _splitTransform 误拆', () async {
      final htmlDoc = LegadoRuleDocument.parse(
        '''
        <html><body>
        <div class="count"><p>a</p></div>
        </body></html>
        ''',
        Uri.parse('https://books.example.com/'),
      );
      // 若 ## 被提前拆分会崩；此规则必须正常求值（命中不到元素返回空即可，不抛异常）
      final value = await engine.evaluateString(
        htmlDoc,
        null,
        r'{{@@.novelintro@text##\s*}}##^##<br>',
      );
      expect(value, '<br>'); // 无 .novelintro → 空文本，^ 前置 <br>
    });
  });

  group('真实书源规则模式', () {
    test('ruleContent 常见的 .content>p!-1@textNodes（排除末段）', () async {
      final content = await string('.content>p!-1@textNodes');
      expect(content, contains('萧炎'));
      expect(content, isNot(contains('目光坚毅'))); // !-1 去掉最后一个 <p>
    });

    test('id.list@tag.dd / id.list@dd@a 章节列表', () async {
      final html = '''
        <div class="catalog"><dl id="list"><dd><a href="/b1.html">第一章</a></dd>
        <dd><a href="/b2.html">第二章</a></dd></dl></div>
      ''';
      final doc = LegadoRuleDocument.parse(
        html,
        Uri.parse('https://books.example.com/'),
      );
      final items = await engine.evaluateList(doc, null, 'id.list@tag.dd');
      expect(items, hasLength(2));
      final links = await engine.evaluateList(doc, null, 'id.list@dd@a');
      expect(links, hasLength(2));
      final firstUrl = await engine.evaluateString(
        doc,
        links.first,
        'a@href',
        resolveUrl: true,
      );
      expect(firstUrl, 'https://books.example.com/b1.html');
    });

    test(r'ruleBookInfo 的 [property$=xxx]@content 取 meta 属性', () async {
      final html = '''
        <html><head>
        <meta property="book_name" content="遮天">
        <meta property="author" content="辰东">
        </head></html>
      ''';
      final doc = LegadoRuleDocument.parse(
        html,
        Uri.parse('https://books.example.com/'),
      );
      final name = await engine.evaluateString(
        doc,
        null,
        r'[property$=book_name]@content',
      );
      expect(name, '遮天');
    });

    test('replaceRegex 净化 ## 模式', () async {
      final content = await string(
        'id.content@text##\n|萧炎',
      );
      expect(content, isNot(contains('\n')));
      expect(content, isNot(contains('萧炎')));
    });

    test('id.content@all 返回 outerHtml', () async {
      final content = await string('id.content@all');
      expect(content, startsWith('<div id="content"'));
    });

    test('多索引排除 !0:1:2 移除指定位置元素', () async {
      final html = '''
        <dl class="listmain">${List.generate(14, (i) => '<dd>第$i章</dd>').join()}</dl>
      ''';
      final doc = LegadoRuleDocument.parse(
        html,
        Uri.parse('https://books.example.com/'),
      );
      // 真实规则：class.listmain@dd!0:1:2:3:4:5:6:7:8:9:10:11 → 排除前 12 项，剩余末尾
      final items = await engine.evaluateList(
        doc,
        null,
        'class.listmain@dd!0:1:2:3:4:5:6:7:8:9:10:11',
      );
      expect(items, hasLength(2));
      expect(_asText(items.first), contains('第12章'));
      expect(_asText(items.last), contains('第13章'));
    });

    test('多索引排除支持负索引 !0:-1:-2（tag.li.!0:1:2 形式）', () async {
      final html = '''
        <ul><li>首</li><li>甲</li><li>乙</li><li>丙</li><li>尾</li></ul>
      ''';
      final doc = LegadoRuleDocument.parse(
        html,
        Uri.parse('https://books.example.com/'),
      );
      // 真实规则：tag.li.!0:1:2 → 排除索引 0/1/2，剩余末尾
      final items = await engine.evaluateList(
        doc,
        null,
        'tag.li.!0:1:2',
      );
      expect(items.map(_asText), ['丙', '尾']);
      // 真实规则：tag.dl@tag.dd.!0:1:2:3:4:5 尾部带点的排除形式
      final html2 = '''
        <dl><dd>a</dd><dd>b</dd><dd>c</dd></dl>
      ''';
      final doc2 = LegadoRuleDocument.parse(
        html2,
        Uri.parse('https://books.example.com/'),
      );
      final items2 = await engine.evaluateList(doc2, null, 'tag.dl@tag.dd.!0:1:2:3:4:5');
      expect(items2, isEmpty);
    });

    test('tbody@tr!1:2 段内多索引排除', () async {
      final html = '''
        <table><tbody><tr><td>a</td></tr><tr><td>b</td></tr><tr><td>c</td></tr></tbody></table>
      ''';
      final doc = LegadoRuleDocument.parse(
        html,
        Uri.parse('https://books.example.com/'),
      );
      final items = await engine.evaluateList(doc, null, 'tbody@tr!1:2');
      expect(items.map(_asText), ['a']);
    });
  });
}

String _asText(Object? value) =>
    value is Element ? value.text.trim() : value.toString();
