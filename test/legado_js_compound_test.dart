// 验证「<js>…</js>\n<尾部选择器>」复合规则 + 动态 java.ajax 参数求值。
// 覆盖灯读章节目录：chapterList = "<js>java.ajax(JSON.parse(result).data.chapter_list_link)</js>\n$.chapter_list"
// 不依赖真实网络，用桩 AjaxFetcher 返回假 chapter_list JSON。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('复合规则：<js>java.ajax(JSON.parse(result)...)</js><newline>chapter_list', () async {
    final sandbox = FlutterLegadoJsSandbox();
    await sandbox.init();
    const tocJson = '{"code":10000,"data":{"chapter_list_link":'
        '"https://cdn.example.com/front/chapter_list/abc.js"}}';
    const chapterJs = '{"chapter_list":['
        '{"id":"119696","name":"第一章 天才的陨落","num":0},'
        '{"id":"119697","name":"第二章 逆袭之路","num":1}]}';

    sandbox.setAjaxFetcher((url, {method = 'GET', headers = const {}, body}) async {
      expect(url, 'https://cdn.example.com/front/chapter_list/abc.js');
      return chapterJs;
    });

    final engine = LegadoRuleEngine(sandbox: sandbox);
    final doc = LegadoRuleDocument.parse(
      tocJson,
      Uri.parse('https://s30007.example.com/chapter/index?bid=1234'),
    );
    const rule = '<js>java.ajax(JSON.parse(result).data.chapter_list_link)</js>\n\$.chapter_list';

    final items = await engine.evaluateList(doc, null, rule);
    await sandbox.dispose();

    expect(items, hasLength(2));
    expect(items.first, isA<Map>());
    final first = items.first as Map;
    expect(first['name'], '第一章 天才的陨落');
    expect(first['num'], 0);
  });
}