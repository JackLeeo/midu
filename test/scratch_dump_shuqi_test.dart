import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dump 书旗 search rule', () {
    final decoded = jsonDecode(File('D:/gz/完美书源.json').readAsStringSync());
    final list = decoded is List
        ? (decoded as List).whereType<Map<String, dynamic>>().toList()
        : ((decoded as Map)['bookSourceList'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
    final src = list.firstWhere((m) => '${m['bookSourceName'] ?? ''}'.contains('书旗'));
    print('=== ruleSearch ===');
    print(jsonEncode(src['ruleSearch']));
    // 把完整响应拉下来看 key
  });
}