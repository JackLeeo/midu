Set-Location -Path 'd:\gz\midu'
$env:DART_JSON = '1'
$tmp = 'd:\gz\midu\tool\_dump_rules_tmp.dart'
$src = @'
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
      print('==================== $name ====================');
      for (final k in ['bookSourceUrl', 'searchUrl', 'ruleBookInfo', 'ruleToc']) {
        final v = m[k];
        if (v != null) print('[$k] ${jsonEncode(v)}');
      }
      print('');
    }
  }
}
'@
Set-Content -Path $tmp -Value $src -Encoding UTF8
D:\flutter\bin\flutter.bat pub run tool/_dump_rules_tmp.dart 2>&1
Remove-Item $tmp -ErrorAction SilentlyContinue