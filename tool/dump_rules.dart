import 'dart:convert';
import 'dart:io';

void main() {
  final raw = File(r'D:\gz\完美书源.已修复.json').readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = (decoded is List) ? decoded : (decoded as Map)['sources'] as List;
  const want = ['全免漫画', '品如漫画', '猫眼看书'];
  for (final s in list) {
    final m = s as Map<String, dynamic>;
    final name = '${m['bookSourceName']}';
    if (want.any((w) => name.contains(w))) {
      print('==================== $name ====================');
      final keys = ['bookSourceUrl', 'searchUrl', 'ruleSearch', 'ruleToc', 'ruleBookInfo', 'ruleContent', 'loginUrl'];
      for (final k in keys) {
        final v = m[k];
        if (v != null && (v is Map || '${v}'.isNotEmpty)) {
          print('[$k] ${jsonEncode(v)}');
        }
      }
      print('');
    }
  }
}