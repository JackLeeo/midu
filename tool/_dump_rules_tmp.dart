import 'dart:convert';
import 'dart:io';

void main() {
  final raw = File('D:/gz/完美书源.已修复.json').readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = (decoded is List) ? decoded : (decoded as Map)['sources'] as List;
  const want = ['久久小说', '猪猪书网', '随心看网'];
  for (final s in list) {
    final m = s as Map<String, dynamic>;
    final name = '${m['bookSourceName']}';
    if (want.any((w) => name.contains(w))) {
      // ignore: avoid_print
      print('==================== $name ====================');
      for (final k in ['bookSourceUrl', 'searchUrl', 'ruleBookInfo', 'ruleToc']) {
        final v = m[k];
        if (v != null) print('[$k] ${jsonEncode(v)}');
      }
      print('');
    }
  }
}