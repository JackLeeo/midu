import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  test('书旗 tocUrl 求值调试', () async {
    final raw = File('D:/gz/完美书源.json').readAsStringSync();
    final decoded = jsonDecode(raw) is List
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>()
        : ((jsonDecode(raw) as Map)['bookSourceList'] as List)
            .cast<Map<String, dynamic>>();
    final src = decoded.firstWhere((m) => '${m['bookSourceName'] ?? ''}'.contains('书旗'));
    final source = LegadoBookSource.fromJson(src).toRegisteredSource();
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox);
    try {
      final page = await runtime.search(source, '神盗特工');
      print('SEARCH items=${page.items.length}');
      if (page.items.isEmpty) return;
      final chosen = page.items.first;
      print('bookUrl=${chosen.id}');

      // fetch book detail page then evaluate tocUrl
      final inner = LegadoHttpTransport();
      final resp = await inner.send(LegadoRequestTemplate(
        url: Uri.parse(chosen.id),
        method: LegadoRequestMethod.get,
        headers: const {},
        charset: 'utf-8',
      ));
      print('detail bytes=${resp.body.length}');
      final document = LegadoRuleDocument.parse(resp.body, resp.finalUri);
      final engine = LegadoRuleEngine(sandbox: sandbox);
      final tocRule =
          LegadoBookSource.fromJson(src).rule('ruleBookInfo')['tocUrl'] as String? ?? '';
      print('tocRule<<<BEGIN>>>');
      print(tocRule);
      print('tocRule<<<END>>>');
      // 直接跑 JS 块（去尾部选择器）看完成值
      final jsEnd = tocRule.toLowerCase().indexOf('</js>');
      final jsBlock = jsEnd >= 0 ? tocRule.substring(0, jsEnd + 5) : tocRule;
      final jsOnly = await sandbox.evalJs(jsBlock, docHtml: resp.body, baseUri: resp.finalUri);
      print('=== JS-ONLY RESULT: $jsOnly');
      print('=== sandbox lastError: ${sandbox.lastError}');
      final tocValue = await engine.evaluateString(document, null, tocRule, resolveUrl: true);
      print('=== TOC VALUE: $tocValue');
      inner.close();
    } finally {
      runtime.close();
    }
  });
}