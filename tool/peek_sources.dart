// 只打印指定书源的关键规则字段，便于快速定位规则缺陷。
// 用法: dart tool/peek_sources.dart "菠萝漫画" "闪舞" ...
import 'dart:convert';
import 'dart:io';

const _path = 'D:/gz/完美书源.已修复.json';
const _fields = [
  'bookSourceName',
  'searchUrl',
  'exploreUrl',
];

String _p(Object e) {
  try {
    final s = jsonEncode(e);
    return s.length <= 600 ? s : s.substring(0, 600) + ' ...[truncated]';
  } catch (_) {
    return '$e';
  }
}

void main(List<String> needles) {
  final raw = File(_path).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = (decoded is List)
      ? decoded as List
      : ((decoded as Map)['bookSourceList'] as List);
  for (final e in list) {
    final s = e as Map;
    final name = '${s['bookSourceName'] ?? ''}';
    for (final needle in needles) {
      if (name.contains(needle)) {
        print('========== $name ==========');
        for (final f in _fields) {
          final v = s[f];
          if (v == null || (v is String && v.isEmpty)) continue;
          print('--- $f ---');
          print(_p(v));
        }
        print('');
        break;
      }
    }
  }
}