import 'dart:convert';
import 'dart:io';

void main() {
  final raw = File(r'D:\gz\完美书源.已修复.json').readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = (decoded is List) ? decoded : (decoded as Map<String, dynamic>)['sources'] as List;
  final f0 = list.first as Map<String, dynamic>;
  print('total=${list.length} firstKeys=${f0.keys.toList()}');
  var c = 0;
  for (final s in list) {
    final m = s as Map<String, dynamic>;
    c++;
    if (c <= 5) print('sample[$c] name="${m['name']}" url="${m['bookSourceUrl']}"');
  }
  final want = ['漫画', '猫眼', '看书', '追书', '溜达', '图书', '虫虫', '一米', '四零'];
  for (final s in list) {
    final m = s as Map<String, dynamic>;
    final name = '${m['bookSourceName'] ?? m['name'] ?? ''}';
    if (want.any((w) => name.contains(w))) {
      final url = '${m['bookSourceUrl'] ?? m['sourceUrl'] ?? ''}';
      final host = Uri.tryParse(url)?.host ?? '';
      print('$name :: $url  host=$host');
    }
  }
}