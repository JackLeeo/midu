import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  test('书旗 toc 探测', () async {
    final raw = File('D:/gz/完美书源.json').readAsStringSync();
    final decoded = jsonDecode(raw) is List
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>()
        : ((jsonDecode(raw) as Map)['bookSourceList'] as List).cast<Map<String, dynamic>>();
    final src = decoded
        .firstWhere((m) => '${m['bookSourceName'] ?? ''}'.contains('书旗'));
    final source = LegadoBookSource.fromJson(src).toRegisteredSource();
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox);
    try {
      final page = await runtime.search(source, '神盗特工');
      print('SEARCH items=${page.items.length}');
      if (page.items.isEmpty) return;
      final chosen = page.items.first;
      print('bookUrl=${chosen.id}');
      final tocRule = LegadoBookSource.fromJson(src).rule('ruleBookInfo')['tocUrl'] as String? ?? '';
      print('bid after search = "${sandbox.getSourceVar('bid')}"');
      print('tocRule head: ${tocRule.replaceAll(RegExp(r'\s+'), ' ').substring(0, 80)}...');
      final resp = await runtime.getChapters(source, chosen.id);
      print('getChapters=${resp.length}');
    } finally {
      runtime.close();
    }
  });
}