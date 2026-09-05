import 'dart:convert';
import 'dart:io';

// 扫描所有书源中形如 `url,{options}` 的 URL 尾随请求选项块，定位受
// _resolveUrlString 修复影响的源。
void main() {
  final raw = File(_path).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : (decoded as Map)['bookSourceList'] as List;

  for (final s in list) {
    final m = s as Map<String, dynamic>;
    final name = '${m['bookSourceName'] ?? ''}';
    final url = '${m['bookSourceUrl'] ?? ''}';
    final hits = <String, List<String>>{};
    for (final key in const ['ruleToc', 'ruleContent', 'ruleBookInfo', 'ruleSearch']) {
      final v = m[key];
      if (v == null) continue;
      final str = v is String ? v : jsonEncode(v);
      if (RegExp(r",\s*\{").hasMatch(str)) {
        hits[key] = _fields(v);
      }
    }
    if (hits.isEmpty) continue;
    print('=== $name [$url]');
    hits.forEach((k, v) {
      print('  $k: $v');
    });
    print('');
  }
  print('done');
}

List<String> _fields(Object? v) {
  final out = <String>[];
  if (v is Map) {
    for (final key in const ['chapterUrl', 'content', 'nextContentUrl', 'bookUrl']) {
      if (v[key] != null) out.add('$key=${v[key]}');
    }
  } else {
    out.add('$v');
  }
  return out;
}

const _path = r'D:\gz\完美书源.已修复.json';