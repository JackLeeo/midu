// 临时诊断：复现 {{java.connect(source.getKey()).raw().request().url()}} 内联模式
// 在 _preprocessJsInString → LegadoRequestTemplate.parse 的中间产物，定位
// “unsupported template expression” 究竟卡在哪一步。运行：
//   flutter test test/probe_template_diag_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';

import 'package:flutter_test/flutter_test.dart';

// 读趣网站 的 searchUrl（全文照抄）
const _template = r'''{{java.connect(source.getKey()).raw().request().url()}}modules/article/search.php,{
"method": "POST",
"body": "searchtype=all&searchkey={{key}}"
}''';

void main() {
  test('template diag: inline {{java.connect}}', () async {
    HttpOverrides.global = null;
    const base = 'http://www.xduqu.com';
    final uri = Uri.parse(base);
    final variables = {'key': '斗破苍穹', 'page': '1'};

    // 模拟 _preprocessJsInString 的判定
    final value = _template;
    final lower = value.toLowerCase();
    // ignore: avoid_print
    print('hasJs=${lower.contains('@js:') || lower.contains('<js>')}');
    // ignore: avoid_print
    print('nested=${RegExp(r'\{\{[^{}]*\{\{').hasMatch(value)}');
    final jsTemplates = RegExp(r'\{\{\s*[^{}]+\s*\}\}')
        .allMatches(value)
        .map((m) => m.group(0)!)
        .toList();
    // ignore: avoid_print
    print('jsTemplateMatches=$jsTemplates');

    for (final raw in jsTemplates) {
      final inner = raw.replaceAll(RegExp(r'^\s*\{\{|\}\}\s*$'), '').trim();
      final isPlain = RegExp(r'[+\-*/%<>=!?:&|^~]|\w\.\w').hasMatch(inner);
      // ignore: avoid_print
      print('  inner=[$inner] isPlainJsTemplate=$isPlain');
    }

    // 直接试 parse（不经过 JS 求值，看是否残留 {{}}）
    try {
      final expanded = LegadoRequestTemplate.parse(
        value,
        baseUri: uri,
        variables: variables,
      );
      // ignore: avoid_print
      print('PARSE_OK url=${expanded.url}');
    } catch (e) {
      // ignore: avoid_print
      print('PARSE_ERR $e');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}