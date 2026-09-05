// 诊断探针：打印目标源的 searchUrl / ruleToc / tocUrl 规则并做变量展开，定位
//  'Legado request URL is empty' / 'options must be a JSON object' 与 noChapters 根因。
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:flutter_test/flutter_test.dart';

String _p(Object? e) {
  if (e == null) return '(null)';
  final s = jsonEncode(e);
  return s.length <= 500 ? s : s.substring(0, 500) + ' ...[trunc]';
}

void main() {
  final raw = File(r'D:\gz\完美书源.已修复.json').readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = (decoded is List)
      ? decoded as List
      : ((decoded as Map)['bookSourceList'] as List);
  // noChapters 组（纯 HTML 目录选择器可修）
  final noch = [
    '红叶书斋', 'U C 小说', '武道文学', '菠萝漫画',
  ];
  final rawList = (list as List).whereType<Map<String, dynamic>>().toList();
  final matched = rawList
      .where((s) => noch.any((n) => '${s['bookSourceName'] ?? ''}'.contains(n)))
      .toList();
  // ignore: avoid_print
  print('matched=${matched.length}');

  for (final s in matched) {
    final name = '${s['bookSourceName']}';
    final searchUrl = s['searchUrl'] as String? ?? '';
    final toc = s['ruleToc'] as Map? ?? {};
    final info = s['ruleBookInfo'] as Map? ?? {};
    // ignore: avoid_print
    print("===== $name =====");
    // ignore: avoid_print
    print("  searchUrl = ${_p(searchUrl)}");
    // ignore: avoid_print
    print("  toc.tocUrl = ${_p(info['tocUrl'])}");
    // ignore: avoid_print
    print("  toc.chapterList = ${_p(toc['chapterList'])}");
    // ignore: avoid_print
    print("  toc.chapterName = ${_p(toc['chapterName'])}");
    // ignore: avoid_print
    print("  toc.chapterUrl = ${_p(toc['chapterUrl'])}");
    // ignore: avoid_print
    print("  toc.nextTocUrl = ${_p(toc['nextTocUrl'])}");
    // ignore: avoid_print
    print("  toc.formatJs = ${_p(toc['formatJs'])}");
    print('');
  }
}