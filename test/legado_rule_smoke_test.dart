// 真实书源规则冒烟测试：对 D:\gz\完美书源.json 全部 296 个源的非 JS 规则，
// 在仿真 HTML/JSON 文档上逐条真实执行，断言引擎不抛异常、不产生未展开的
// 模板残留（{{...}} / {$....} / @js: / <js>）。
//
// 该文件不在仓库内时跳过文件扫描部分；硬编码的真实规则逐字断言始终运行，
// 防止引擎回归。JS 规则（@js:/<js>/java./source.）在无 fjs 沙箱时返回空，
// 由 legado_js_sandbox_test.dart 负责验证。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' show Element;
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';

/// 仿真「搜索页」：class.grid 表格 + class.even/odd 单元格 + pc_list 目录列表。
const _searchHtml = '''
<!DOCTYPE html><html><head><title>搜索</title></head><body>
<div class="grid"><table>
  <tr><th>书名</th><th>作者</th><th>最新章节</th></tr>
  <tr>
    <td class="even"><a href="/book/1.html">斗破苍穹</a></td>
    <td class="odd">天蚕土豆</td><td class="odd"><a href="/book/1-999.html">第一章 陨落的天才</a></td>
  </tr>
  <tr>
    <td class="even"><a href="/book/2.html">完美世界</a></td>
    <td class="odd">辰东</td><td class="odd"><a href="/book/2-999.html">第一章 石村</a></td>
  </tr>
</table></div>
<div class="pc_list"><ul><li><a href="/nav.html">网站导航</a></li></ul></div>
<div class="pc_list"><ul>
  <li><a href="/book/1.html">第一章 陨落的天才</a></li>
  <li><a href="/book/2.html">第二章 斗之气</a></li>
</ul></div>
</body></html>
''';

/// 仿真「目录页」：id.list 的 dl/dd + id.lbks + id.listmain（多索引排除）。
final _tocHtml = '''
<!DOCTYPE html><html><head><title>目录</title></head><body>
<div class="box_con">
  <div id="list"><dl><dd><a href="/b1.html">第一章</a></dd><dd><a href="/b2.html">第二章</a></dd></dl></div>
  <div id="lbks"><dd><a href="/b3.html">第三章</a></dd><dd><a href="/b4.html">第四章</a></dd></div>
  <dl class="listmain">${List.generate(14, (i) => '<dd><a href="/c$i.html">第$i章</a></dd>').join()}</dl>
</div>
</body></html>
''';

/// 仿真「正文页」：id.content1 / .content 段落 + 声明文本。
const _contentHtml = '''
<!DOCTYPE html><html><head><title>正文</title></head><body>
<div id="content1">
  <p>声明：本书版权归作者所有。欢迎广大书友前来支持正版。</p>
  <p>斗破苍穹第一段正文。</p>
  <p>第二段正文。</p>
</div>
<div class="content"><p>第一段正文</p><p>第二段正文</p><p>第三段正文</p><p>本章未完待续。</p></div>
</body></html>
''';

/// 仿真「详情页」：detail_right/small + meta property 属性。
const _infoHtml = '''
<!DOCTYPE html><html><head><title>详情</title>
<meta property="og:novel:author" content="天蚕土豆">
<meta property="og:image" content="https://cdn.example.com/cover.jpg">
<meta property="book_name" content="斗破苍穹">
</head><body>
<div class="detail_right"><h1>斗破苍穹</h1></div>
<div class="small"><span>书籍作者：</span><a href="/author/1.html">天蚕土豆</a></div>
<div class="small"><span>最新章节：</span><a href="/book/9.html">第一章 陨落的天才</a></div>
<div class="detail_pic"><img src="/cover.jpg"></div>
<div class="showInfo"><p>这里是简介内容。</p></div>
</body></html>
''';

/// 仿真 JSON API 响应（风都小说 / 推书君风格）。
final _jsonBody = {
  'data': {
    'books': [
      {
        'bookId': 2,
        'bookTitle': '完美世界',
        'bookAuthor': '辰东',
        'bookCoverImage': 'https://x/2.jpg',
        'bookDesc': '简介二',
        'book_words_num': 12345,
        'crazy_rating': 88,
      },
    ],
    'searchList': [
      {
        'bookId': 1,
        'bookName': '斗破苍穹',
        'author': '天蚕土豆',
        'coverWap': 'https://x/1.jpg',
        'introduction': '简介一',
        'status': '1',
        'tag': '玄幻',
      },
    ],
    'data': [
      {'book_id': 7, 'title': '凡人修仙传', 'author_nickname': '忘语', 'word_number_name': '300万字'},
    ],
  },
  'book': {'author': '天蚕土豆', 'bookName': '斗破苍穹', 'totalWordSize': '500万'},
  'detailedBookInfo': {
    'bookChapterAllInfo': [
      {'chapterId': 100, 'chapterTitle': '第一章 青石镇'},
      {'chapterId': 101, 'chapterTitle': '第二章 测试'},
    ],
  },
  'chapterContent': '正文第一段。\n正文第二段。',
};

Uri get _base => Uri.parse('https://books.example.com/');
final _jsonDoc = LegadoRuleDocument.parse(jsonEncode(_jsonBody), _base);

LegadoRuleDocument docFor(String html) =>
    LegadoRuleDocument.parse(html, _base);

final _engine = LegadoRuleEngine();

String _text(Object? value) =>
    value is Element ? value.text.trim() : value.toString();

/// 判定一条规则是否依赖 JS 沙箱（无 fjs 时无法本地验证）。
/// 注意：`@js:` / `<js>` 可能出现在规则中段（##替换@js:后处理），同样视为 JS。
bool _isJsRule(String rule) {
  final lower = rule.toLowerCase();
  return lower.contains('@js:') ||
      lower.contains('<js>') ||
      lower.contains('java.') ||
      lower.contains('source.') ||
      lower.startsWith('@xpath:') ||
      lower.startsWith('//');
}

/// 判定结果是否残留未展开的模板/规则语法。
bool _hasTemplateResidue(String result) {
  return result.contains('{{') ||
      result.contains('<js>') ||
      result.contains('@js:') ||
      RegExp(r'\{\.?\$[^{}]*\}').hasMatch(result);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('真实书源规则逐字断言（来自 完美书源.json）', () {
    test('奇书网站：搜索表格 class.grid@tag.tr!0 排除表头', () async {
      final doc = docFor(_searchHtml);
      final rows = await _engine.evaluateList(doc, null, 'class.grid@tag.tr!0');
      expect(rows, hasLength(2));
      final firstUrl = await _engine.evaluateString(
        doc,
        rows.first,
        'class.even@tag.a.0@href',
        resolveUrl: true,
      );
      expect(firstUrl, 'https://books.example.com/book/1.html');
      final firstName = await _engine.evaluateString(
        doc,
        rows.first,
        'class.even@tag.a.0@text',
      );
      expect(firstName, '斗破苍穹');
    });

    test('奇书网站：目录 class.pc_list.1@tag.li（取第 2 个 pc_list）', () async {
      final doc = docFor(_searchHtml);
      final items = await _engine.evaluateList(doc, null, 'class.pc_list.1@tag.li');
      expect(items, hasLength(2));
      final name = await _engine.evaluateString(
        doc,
        items.first,
        'tag.a.0@text',
      );
      expect(name, '第一章 陨落的天才');
      final url = await _engine.evaluateString(
        doc,
        items.first,
        'tag.a.0@href',
        resolveUrl: true,
      );
      expect(url, 'https://books.example.com/book/1.html');
    });

    test('奇书网站：正文 id.content1@textNodes##声明.*正版.|欢迎广大书友.*', () async {
      final doc = docFor(_contentHtml);
      final content = await _engine.evaluateString(
        doc,
        null,
        r'id.content1@textNodes##声明.*正版.|欢迎广大书友.*',
      );
      expect(content, contains('第一段正文'));
      expect(content, isNot(contains('声明')));
    });

    test(r'风都小说：JSON 深扫描 $..books[*] + 字段提取', () async {
      final books = await _engine.evaluateList(_jsonDoc, null, r'$..books[*]');
      expect(books, hasLength(1));
      final name = await _engine.evaluateString(
        _jsonDoc,
        books.first,
        r'$.bookTitle##（+.*|.*最新章节|\(+.*',
      );
      expect(name, '完美世界');
      final author = await _engine.evaluateString(_jsonDoc, books.first, r'$.bookAuthor');
      expect(author, '辰东');
    });

    test(r'风都小说：$..detailedBookInfo.bookChapterAllInfo[*] 章节列表', () async {
      final chapters = await _engine.evaluateList(
        _jsonDoc,
        null,
        r'$..detailedBookInfo.bookChapterAllInfo[*]',
      );
      expect(chapters, hasLength(2));
      final title = await _engine.evaluateString(
        _jsonDoc,
        chapters.first,
        r'$.chapterTitle##[\(（].*[求更谢乐发推].*[）\)]',
      );
      expect(title, '第一章 青石镇');
    });

    test(r'风都小说：ruleContent $..chapterContent 深扫描正文', () async {
      final content = await _engine.evaluateString(_jsonDoc, null, r'$..chapterContent');
      expect(content, contains('正文第一段'));
    });

    test(r'风都小说：ruleBookInfo 插值 $.book.bookName + {$.book.totalWordSize}字', () async {
      final name = await _engine.evaluateString(_jsonDoc, null, r'$.book.bookName');
      expect(name, '斗破苍穹');
      final wordCount = await _engine.evaluateString(
        _jsonDoc,
        null,
        r'{$.book.totalWordSize}字',
      );
      expect(wordCount, '500万字');
    });

    test('醉读小说：[property="og:novel:author"]@content 取 meta', () async {
      final doc = docFor(_infoHtml);
      final author = await _engine.evaluateString(
        doc,
        null,
        r'[property="og:novel:author"]@content',
      );
      expect(author, '天蚕土豆');
      final cover = await _engine.evaluateString(
        doc,
        null,
        r'[property="og:image"]@content',
      );
      expect(cover, 'https://cdn.example.com/cover.jpg');
    });

    test(r'推书君：data.data 裸 JSON 路径 + {{$.book_id}} 插值', () async {
      final books = await _engine.evaluateList(_jsonDoc, null, 'data.data');
      expect(books, hasLength(1));
      final name = await _engine.evaluateString(_jsonDoc, books.first, 'title');
      expect(name, '凡人修仙传');
      final author = await _engine.evaluateString(
        _jsonDoc,
        books.first,
        r'@{{$.author_nickname}}',
      );
      expect(author, endsWith('忘语'));
      final tocUrl = await _engine.evaluateString(
        _jsonDoc,
        books.first,
        r'https://api.example.com/listBookScoreByBook?book_id={$.book_id}&page=1',
        resolveUrl: true,
      );
      expect(tocUrl, contains('book_id=7'));
    });

    test('多索引排除：id.list@tag.dd!0:1:2:3:4:5:6:7:8:9:10:11', () async {
      final doc = docFor(_tocHtml);
      final items = await _engine.evaluateList(
        doc,
        null,
        'class.listmain@dd!0:1:2:3:4:5:6:7:8:9:10:11',
      );
      expect(items, hasLength(2));
      expect(_text(items.first), contains('第12章'));
    });
  });

  final file = File(r'D:\gz\完美书源.json');
  if (!file.existsSync()) {
    test('真实书源全量规则扫描（跳过：未找到 D:\\gz\\完美书源.json）', () {
      markTestSkipped('书源文件不在本机');
    });
    return;
  }

  final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
  final searchDoc = docFor(_searchHtml);
  final tocDoc = docFor(_tocHtml);
  final contentDoc = docFor(_contentHtml);
  final infoDoc = docFor(_infoHtml);

  group('真实书源全量规则扫描（296 源 × 非 JS 规则）', () {
    test('非 JS 规则全部可执行且无模板残留', () async {
      var nonJsRules = 0;
      var failures = <String>[];
      var garbage = <String>[];

      // JSON 风格的规则（$. / data. / $.. / [?()]）路由到 JSON 文档求值
      LegadoRuleDocument docForRule(String rule, LegadoRuleDocument htmlDoc) {
        final t = rule.trim();
        if (t.startsWith(r'$.') ||
            t.startsWith(r'$..') ||
            t.startsWith(r'$[') ||
            t.startsWith('data.') ||
            t.contains('[?(')) {
          return _jsonDoc;
        }
        return htmlDoc;
      }

      for (final source in sources) {
        Future<void> checkString(String field, String rule, LegadoRuleDocument doc,
            Object? context) async {
          if (rule.trim().isEmpty || _isJsRule(rule)) return;
          nonJsRules++;
          try {
            final result = await _engine.evaluateString(doc, context, rule);
            if (_hasTemplateResidue(result)) {
              garbage.add('${source.name} [$field] $rule → "$result"');
            }
          } catch (error) {
            failures.add('${source.name} [$field] $rule → $error');
          }
        }

        Future<void> checkList(
            String field, String rule, LegadoRuleDocument doc) async {
          if (rule.trim().isEmpty || _isJsRule(rule)) return;
          nonJsRules++;
          try {
            final items = await _engine.evaluateList(doc, null, rule);
            // 取前 3 个元素对字段子规则做二次求值（模拟真实流水线）
            for (final item in items.take(3)) {
              final itemDoc = item is Element ? doc : _jsonDoc;
              for (final sub in ['name', 'author', 'bookUrl', 'chapterName', 'chapterUrl']) {
                final subRule = (field == 'chapterList'
                        ? source.rule('ruleToc')[sub]
                        : source.rule('ruleSearch')[sub]) as String?;
                if (subRule == null || subRule.trim().isEmpty || _isJsRule(subRule)) {
                  continue;
                }
                nonJsRules++;
                try {
                  final r = await _engine.evaluateString(itemDoc, item, subRule,
                      resolveUrl: sub == 'bookUrl' || sub == 'chapterUrl');
                  if (_hasTemplateResidue(r)) {
                    garbage.add(
                        '${source.name} [$field>$sub] $subRule → "$r"');
                  }
                } catch (error) {
                  failures.add(
                      '${source.name} [$field>$sub] $subRule → $error');
                }
              }
            }
          } catch (error) {
            failures.add('${source.name} [$field] $rule → $error');
          }
        }

        final rs = source.rule('ruleSearch');
        for (final field in const ['bookList', 'name', 'author', 'bookUrl', 'coverUrl', 'intro', 'kind', 'lastChapter']) {
          final rule = rs[field] as String? ?? '';
          final doc = docForRule(rule, searchDoc);
          if (field == 'bookList') {
            await checkList('ruleSearch.$field', rule, doc);
          } else {
            await checkString('ruleSearch.$field', rule, doc, null);
          }
        }

        final rt = source.rule('ruleToc');
        for (final field in const ['chapterList', 'chapterName', 'chapterUrl']) {
          final rule = rt[field] as String? ?? '';
          final doc = docForRule(rule, tocDoc);
          if (field == 'chapterList') {
            await checkList('ruleToc.$field', rule, doc);
          } else {
            await checkString('ruleToc.$field', rule, doc, null);
          }
        }

        final rb = source.rule('ruleBookInfo');
        for (final field in const ['name', 'author', 'intro', 'kind', 'coverUrl', 'lastChapter']) {
          final rule = rb[field] as String? ?? '';
          await checkString('ruleBookInfo.$field', rule, docForRule(rule, infoDoc), null);
        }

        final contentRule = source.rule('ruleContent')['content'] as String? ?? '';
        await checkString('ruleContent.content', contentRule, docForRule(contentRule, contentDoc), null);
      }

      // ignore: avoid_print
      print('扫描非 JS 规则总数: $nonJsRules');
      // ignore: avoid_print
      print('执行失败（异常）: ${failures.length}');
      // ignore: avoid_print
      print('模板残留: ${garbage.length}');
      if (failures.isNotEmpty) {
        // ignore: avoid_print
        print('--- 失败明细（前 30 条） ---');
        for (final line in failures.take(30)) {
          // ignore: avoid_print
          print(line);
        }
      }
      if (garbage.isNotEmpty) {
        // ignore: avoid_print
        print('--- 残留明细（前 30 条） ---');
        for (final line in garbage.take(30)) {
          // ignore: avoid_print
          print(line);
        }
      }
      expect(failures, isEmpty,
          reason: '${failures.length} 条非 JS 规则执行异常，见上文明细');
      expect(garbage, isEmpty,
          reason: '${garbage.length} 条非 JS 规则产生模板残留，见上文明细');
    });
  });
}
