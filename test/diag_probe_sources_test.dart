// 诊断 probe：打印指定书源的 searchUrl / ruleSearch / ruleToc / ruleContent 原始定义，
// 并尝试展开 searchUrl 模板以定位「URL empty / scheme 异常」。断言恒真，仅打印诊断信息。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';

const _needles = <String>[
  '爱下网书',
  '小说三千',
  '五六中文',
  '书旗',
  '得间',
  '中文书城',
  '花生',
  '圣墟',
  '宜搜',
  '天地',
  '灯读',
  '猫眼',
  '企鹅',
  '就去看',
  '果文',
  '群搜',
  '阅友',
  '书满屋',
];

void main() {
  test('书源定义诊断', () {
    final jsonPath = Platform.environment['VERIFY_BOOK_SOURCES_JSON'] ??
        const String.fromEnvironment('VERIFY_BOOK_SOURCES_JSON');
    if (jsonPath.isEmpty) {
      markTestSkipped('缺 VERIFY_BOOK_SOURCES_JSON');
      return;
    }
    final raw = File(jsonPath).readAsStringSync();
    final decoded = jsonDecode(raw);
    final list = decoded is List
        ? decoded.cast<Map<String, dynamic>>()
        : decoded['bookSourceList'] as List;
    for (final m in list.cast<Map<String, dynamic>>()) {
      final name = '${m['bookSourceName'] ?? ''}';
      if (!_needles.any(name.contains)) continue;
      final src = LegadoBookSource.fromJson(m);
      print('== 源: $name | bookSourceUrl: ${src.url} ===========');
      print('  searchUrl: ${src.searchUrl}');
      for (final rn in ['ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent']) {
        final rule = src.rule(rn);
        if (rule.isEmpty) continue;
        print('  -- $rn --');
        rule.forEach((k, v) {
          var s = '$v';
          if (s.length > 400) s = '${s.substring(0, 400)}...';
          print('     $k: $s');
        });
      }
      print('  -- searchUrl 展开测试 --');
      for (final vars in [
        <String, String>{'key': '神|测试', 'page': '1'},
        <String, String>{'key': '都市|', 'page': '1'},
      ]) {
        try {
          final tpl = LegadoRequestTemplate.parse(
            src.searchUrl,
            baseUri: src.baseUri,
            variables: vars,
            sourceHeaders: const {},
          );
          print('     展开(${vars['key']}) -> ${tpl.url}');
        } catch (e) {
          print('     展开(${vars['key']}) 失败: $e');
        }
      }
      print('');
    }
  });
}