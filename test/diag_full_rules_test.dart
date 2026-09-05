// 全量诊断：输出指定源 searchUrl + 完整规则（不截断），落到 stdout 供分析。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';

const _needles = <String>[
  '群小说', '小说三千', '爱下',
];

void main() {
  test('全量规则诊断', () {
    final jsonPath = Platform.environment['VERIFY_BOOK_SOURCES_JSON'] ??
        const String.fromEnvironment('VERIFY_BOOK_SOURCES_JSON');
    final raw = File(jsonPath).readAsStringSync();
    final decoded = jsonDecode(raw);
    final list = decoded is List
        ? decoded.cast<Map<String, dynamic>>()
        : (decoded as Map)['bookSourceList'] as List;
    for (final m in list.cast<Map<String, dynamic>>()) {
      final name = '${m['bookSourceName'] ?? ''}';
      if (!_needles.any(name.contains)) continue;
      final src = LegadoBookSource.fromJson(m);
      print('################ 源: $name ################');
      print('searchUrl=${jsonEncode(src.searchUrl ?? '')}');
      for (final rn in ['ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent']) {
        final rule = src.rule(rn);
        if (rule.isEmpty) continue;
        print('### $rn ###');
        rule.forEach((k, v) => print('  $k:\n${jsonEncode('$v')}'));
      }
    }
  });
}