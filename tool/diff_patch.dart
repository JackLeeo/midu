// 对比 完美书源.json 与 完美书源.已修复.json 的差异（针对 manifest 问题源）。
// 用法: dart tool/diff_patch.dart
import 'dart:convert';
import 'dart:io';

const _orig = 'D:/gz/完美书源.json';
const _patch = 'D:/gz/完美书源.已修复.json';

List<Map<String, dynamic>> load(String path) {
  final raw = File(path).readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is List) return decoded.cast<Map<String, dynamic>>();
  return ((decoded as Map)['bookSourceList'] as List).cast<Map<String, dynamic>>();
}

String stripEmoji(String s) =>
    s.replaceFirst(RegExp(r'^[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\s]+', unicode: true), '');

void main() {
  final orig = load(_orig);
  final patch = load(_patch);
  final fields = [
    'bookSourceUrl', 'searchUrl', 'ruleSearch', 'ruleBookInfo', 'ruleToc',
    'ruleContent', 'header', 'enabledCookieJar', 'bookUrlPattern',
  ];
  for (final o in orig) {
    final name = '${o['bookSourceName'] ?? ''}';
    final key = stripEmoji(name);
    if (!['群小说', '小说三千', '爱下', '天地', '就去看', '企鹅', '猫眼', '得间', '花生', '书满屋', '果文', '书旗', '圣墟', '宜搜', '阅友', '中文书城', '五六', '灯读']
        .any(key.contains)) continue;
    Map<String, dynamic>? p;
    for (final x in patch) {
      if (stripEmoji('${x['bookSourceName'] ?? ''}') == key) { p = x; break; }
    }
    if (p == null) { print('## $name: 补丁缺失'); continue; }
    final fieldsAll = {...o.keys, ...p.keys}.toList()..sort();
    final diffs = <String>[];
    for (final f in fieldsAll) {
      final ov = o[f];
      final pv = p[f];
      if (jsonEncode(ov) == jsonEncode(pv)) continue;
      diffs.add(f);
    }
    if (diffs.isEmpty) continue;
    print('\n################ $name (差异字段: $diffs) ################');
    for (final f in fields) {
      final ov = o[f];
      final pv = p[f];
      final oj = jsonEncode(ov);
      final pj = jsonEncode(pv);
      if (oj == pj) continue;
      print('  [$f] 原版: $oj');
      print('  [$f] 补丁: $pj');
    }
  }
}
