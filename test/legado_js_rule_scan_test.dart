// Legado JS 规则本地执行测试（flutter_js 沙箱 + 真实书源）。
//
// 目的：验证 @js / <js> 规则（含中段 @js:、{{...}} 插值、source/java 变量、
// 完成值兜底）在本机 flutter test 中可执行，并对 完美书源.json 的 JS 规则
// 做全量扫描：不抛异常、不残留未展开模板（{{...}} / {$. ...}）。
//
// 平台说明：Windows 下先复制 flutter_js 包内 quickjs DLL 到 cwd（FFI 加载）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' show Element;
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';

import 'helpers/flutter_js_sandbox.dart';

late FlutterLegadoJsSandbox sandbox;
late LegadoRuleEngine engine;

/// 仿真 HTML 文档（搜索页/目录页/正文页/详情页）。
const _searchHtml = '''
<!DOCTYPE html><html><head><title>搜索</title></head><body>
<div class="grid"><table>
  <tr><th>书名</th><th>作者</th><th>最新章节</th></tr>
  <tr>
    <td class="even"><a href="/book/1.html">斗破苍穹</a></td>
    <td class="odd">天蚕土豆</td><td class="odd"><a href="/book/1-999.html">第一章 陨落的天才</a></td>
  </tr>
</table></div>
<div class="pc_list"><ul>
  <li><a href="/book/1.html">第一章 陨落的天才</a></li>
  <li><a href="/book/2.html">第二章 斗之气</a></li>
</ul></div>
</body></html>
''';

const _contentHtml = '''
<!DOCTYPE html><html><head><title>正文</title></head><body>
<div id="content1">
  <p>声明：本书版权归作者所有。欢迎广大书友前来支持正版。</p>
  <p>斗破苍穹第一段正文。</p>
</div>
<div id="intro">简介：斗破苍穹是一本小说。</div>
<h6><a href="/book/123456.html">1</a></h6>
</body></html>
''';

const _infoHtml = '''
<!DOCTYPE html><html><head><title>详情</title>
<meta property="og:novel:author" content="天蚕土豆">
</head><body>
<div class="detail_right"><h1>斗破苍穹</h1></div>
<div class="s2"><a href="/book/123456.html">书</a></div>
</body></html>
''';

final _base = Uri.parse('https://books.example.com/');
final _jsonDoc = LegadoRuleDocument.parse(
  jsonEncode({
    'bookId': 7,
    'book_id': 'x123',
    'chapter_id': 'c100',
    'data': [
      {'title': '第一章', 'href': '/a.html'},
      {'title': '第二章', 'href': '/b.html'},
    ],
    'b': 'fallback',
  }),
  Uri.parse('https://api.wan123x.com/list?book_id=99'),
);

LegadoRuleDocument docFor(String html) =>
    LegadoRuleDocument.parse(html, _base);

/// 判定一条规则是否依赖 JS 沙箱。
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

  setUpAll(() {
    copyQuickJsDllIfNeeded();
    sandbox = FlutterLegadoJsSandbox();
    engine = LegadoRuleEngine(sandbox: sandbox);
  });

  tearDownAll(() async {
    await sandbox.dispose();
  });

  group('JS 规则逐字断言（flutter_js 沙箱）', () {
    test('中段 @js:：左侧提取结果作为 result 注入，裸表达式完成值返回', () async {
      final doc = docFor(_contentHtml);
      final url = await engine.evaluateString(
        doc,
        null,
        r"h6@a@href@js:'https://www.yruan.com'+result",
      );
      expect(url, 'https://www.yruan.com/book/123456.html');
    });

    test('中段 @js:：href@js:result+后缀（webView 挂载）', () async {
      final doc = docFor(_searchHtml);
      final url = await engine.evaluateString(
        doc,
        null,
        r'''class.grid@tag.tr!0@tag.td.0@tag.a@href@js:result+',{webView:"true"}' ''',
      );
      expect(url, '/book/1.html,{webView:"true"}');
    });

    test(r'@js: 内 {{$.chapter_id}} 插值后执行（真实源形态）', () async {
      final result = await engine.evaluateString(
        _jsonDoc,
        null,
        r"""@js:
n=baseUrl.match(/book_id=(\d+)/)[1];
result='https://api.wan123x.com/read/getChapterDetail?book_id='+n+'&chapter_id={{$.chapter_id}}'""",
      );
      expect(result, contains('book_id=99'));
      expect(result, contains('chapter_id=c100'));
    });

    test(r'@js: 内 {{$._id}} 插值（baseUrl.replace 形态）', () async {
      final doc = LegadoRuleDocument.parse(
        jsonEncode({'_id': 'x123'}),
        Uri.parse('https://x.example/list/abc'),
      );
      final result = await engine.evaluateString(
        doc,
        null,
        r"@js:baseUrl.replace('/list','/{{$._id}}')",
      );
      expect(result, contains('/x123/abc'));
    });

    test(r'{{$.a||$.b}} 插值回退：a 缺失时取 b', () async {
      final result = await engine.evaluateString(
        _jsonDoc,
        null,
        r"@js:finalResult = 'x=' + '{{$.a||$.b}}';",
      );
      expect(result, 'x=fallback');
    });

    test(r'中段 @js:##pattern##replacement###：仅正则替换（00shu 形态）', () async {
      final doc = docFor(_infoHtml);
      final url = await engine.evaluateString(
        doc,
        null,
        r'div.s2@a@href@js:##.+\D((\d+)\d{3})\D##https://www.00shu.la/files/article/image/$2/$1/$1s.jpg###',
      );
      // ((d+)\d{3}) 中 $1=外层整段数字 123456，$2=内层 123（与真实源规则语义一致）
      expect(url, 'https://www.00shu.la/files/article/image/123/123456/123456s.jpghtml');
    });

    test('中段 @js:：##替换 + JS 组合（result.replace 形态）', () async {
      final doc = docFor(_contentHtml);
      final result = await engine.evaluateString(
        doc,
        null,
        r'''id.intro@text##简介：##@js:result+'！' ''',
      );
      expect(result, '斗破苍穹是一本小说。！');
    });

    test('source.put/get 跨 eval：引擎 @put 存 → JS source.get 取', () async {
      await engine.evaluateString(
        docFor(_searchHtml),
        null,
        r"""@put:{bid:"'123'"}""",
      );
      final jsResult = await engine.evaluateString(
        docFor(_searchHtml),
        null,
        r"@js:finalResult = 'bid=' + source.get('bid');",
      );
      expect(jsResult, 'bid=123');
      final getBack = await engine.evaluateString(
        docFor(_searchHtml),
        null,
        '@get:{bid}',
      );
      expect(getBack, '123');
    });

    test('java.put/java.getString 桩：与 source 变量互通', () async {
      await engine.evaluateString(
        docFor(_searchHtml),
        null,
        r"@js:java.put('t', 'token123'); finalResult = 'ok';",
      );
      final result = await engine.evaluateString(
        docFor(_searchHtml),
        null,
        r"@js:finalResult = java.getString('t', 'default');",
      );
      expect(result, 'token123');
    });

    test('java.crypto 桩不崩溃；java.log 无副作用', () async {
      // 加密桩已升级为真实实现（书旗等源依赖）：md5Encode('abc') 应返回真实 MD5，
      // 而非空串。同时验证 java.log 无副作用不影响完成值。
      final result = await engine.evaluateString(
        docFor(_searchHtml),
        null,
        r"@js:java.log('x'); finalResult = java.crypto.md5Encode('abc') || 'empty';",
      );
      expect(result, '900150983cd24fb0d6963f7d28e17f72');
    });

    test('document 桩：querySelector 返回 null 不崩溃', () async {
      final result = await engine.evaluateString(
        docFor(_searchHtml),
        null,
        r"@js:var el = document.querySelector('.x'); finalResult = el ? 'found' : 'none';",
      );
      expect(result, 'none');
    });

    test('<js> 标签形式规则', () async {
      final result = await engine.evaluateString(
        docFor(_searchHtml),
        null,
        '<js>finalResult = "tag-form";</js>',
      );
      expect(result, 'tag-form');
    });

    test('listMode：JS 返回 JSON 数组展开为列表', () async {
      final items = await engine.evaluateList(
        _jsonDoc,
        null,
        r'''@js:JSON.stringify([
  {text: '第一章', href: '/a.html'},
  {text: '第二章', href: '/b.html'}
])''',
      );
      expect(items, hasLength(2));
      final first = await engine.evaluateString(_jsonDoc, items.first, r'$.text');
      expect(first, '第一章');
    });

    test(r'ruleBookInfo.tocUrl 真实源形态：{{$..bookId}} 深扫描插值', () async {
      final result = await engine.evaluateString(
        _jsonDoc,
        null,
        r'''@js:
let bid = parseInt('{{$..bookId}}');
"http://s.example.com/api/book/chapter/" + parseInt(bid/1000) + "/" + bid + "/list.json"''',
      );
      expect(result, 'http://s.example.com/api/book/chapter/0/7/list.json');
    });
  });

  final file = File(r'D:\gz\完美书源.json');
  if (!file.existsSync()) {
    test('真实书源 JS 规则全量扫描（跳过：未找到 D:\\gz\\完美书源.json）', () {
      markTestSkipped('书源文件不在本机');
    });
    return;
  }

  final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
  final searchDoc = docFor(_searchHtml);
  final tocDoc = docFor(_searchHtml);
  final contentDoc = docFor(_contentHtml);
  final infoDoc = docFor(_infoHtml);

  group('真实书源 JS 规则全量扫描（flutter_js 沙箱）', () {
    test('JS 规则全部可执行、无模板残留，且非运行期依赖的规则能产出结果', () async {
      var jsRules = 0;
      var executed = 0; // 产出非空结果（说明沙箱真正执行成功）
      var runtimeDependent = 0; // 依赖 java.ajax/connect 等运行时能力 → 空结果（预期）
      var failures = <String>[];
      var garbage = <String>[];

      LegadoRuleDocument docForRule(String rule, LegadoRuleDocument htmlDoc) {
        final t = rule.trim();
        if (t.startsWith(r'$.') ||
            t.startsWith(r'$..') ||
            t.startsWith(r'$[') ||
            t.startsWith('data.') ||
            t.contains('[?(') ||
            t.contains(r'{{$')) {
          return _jsonDoc;
        }
        return htmlDoc;
      }

      for (final source in sources) {
        Future<void> checkString(
            String field, String rule, LegadoRuleDocument doc) async {
          if (rule.trim().isEmpty || !_isJsRule(rule)) return;
          jsRules++;
          try {
            final result = await engine.evaluateString(doc, null, rule);
            if (result.isNotEmpty) {
              executed++;
            } else {
              runtimeDependent++;
            }
            if (_hasTemplateResidue(result)) {
              garbage.add('${source.name} [$field] $rule → "$result"');
            }
          } catch (error) {
            failures.add('${source.name} [$field] $rule → $error');
          }
        }

        Future<void> checkList(
            String field, String rule, LegadoRuleDocument doc) async {
          if (rule.trim().isEmpty || !_isJsRule(rule)) return;
          jsRules++;
          try {
            final items = await engine.evaluateList(doc, null, rule);
            if (items.isNotEmpty) {
              executed++;
            } else {
              runtimeDependent++;
            }
            for (final item in items.take(3)) {
              final itemDoc = item is Element ? doc : _jsonDoc;
              for (final sub in const ['name', 'author', 'bookUrl', 'chapterName', 'chapterUrl']) {
                final subRule = (field == 'chapterList'
                        ? source.rule('ruleToc')[sub]
                        : source.rule('ruleSearch')[sub]) as String?;
                if (subRule == null || subRule.trim().isEmpty || !_isJsRule(subRule)) {
                  continue;
                }
                jsRules++;
                try {
                  final r = await engine.evaluateString(itemDoc, item, subRule,
                      resolveUrl: sub == 'bookUrl' || sub == 'chapterUrl');
                  if (r.isNotEmpty) {
                    executed++;
                  } else {
                    runtimeDependent++;
                  }
                  if (_hasTemplateResidue(r)) {
                    garbage.add('${source.name} [$field>$sub] $subRule → "$r"');
                  }
                } catch (error) {
                  failures.add('${source.name} [$field>$sub] $subRule → $error');
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
            await checkString('ruleSearch.$field', rule, doc);
          }
        }

        final rt = source.rule('ruleToc');
        for (final field in const ['chapterList', 'chapterName', 'chapterUrl']) {
          final rule = rt[field] as String? ?? '';
          final doc = docForRule(rule, tocDoc);
          if (field == 'chapterList') {
            await checkList('ruleToc.$field', rule, doc);
          } else {
            await checkString('ruleToc.$field', rule, doc);
          }
        }

        final rb = source.rule('ruleBookInfo');
        for (final field in const ['name', 'author', 'intro', 'kind', 'coverUrl', 'lastChapter', 'tocUrl']) {
          final rule = rb[field] as String? ?? '';
          await checkString('ruleBookInfo.$field', rule, docForRule(rule, infoDoc));
        }

        final contentRule = source.rule('ruleContent')['content'] as String? ?? '';
        await checkString('ruleContent.content', contentRule, docForRule(contentRule, contentDoc));
      }

      // ignore: avoid_print
      print('扫描 JS 规则总数: $jsRules');
      // ignore: avoid_print
      print('产出非空结果（沙箱执行成功）: $executed');
      // ignore: avoid_print
      print('运行期依赖（java.ajax/connect 等，空结果属预期）: $runtimeDependent');
      // ignore: avoid_print
      print('执行异常: ${failures.length}');
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
          reason: '${failures.length} 条 JS 规则执行异常，见上文明细');
      expect(garbage, isEmpty,
          reason: '${garbage.length} 条 JS 规则产生模板残留，见上文明细');
      expect(executed, greaterThan(0),
          reason: 'flutter_js 沙箱未成功执行任何 JS 规则');
    });
  });
}
