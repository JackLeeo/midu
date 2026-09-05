$g = 'C:\Program Files\Git\bin\git.exe'
$env:DART_TARGET = 'json'
Set-Location 'd:\gz\midu'
# 复用 tool/dump_rules.dart 思路：直接读书源 JSON 打印指定源 ruleToc/ruleBookInfo
$dartScript = @'
import 'dart:convert';
import 'dart:io';
void main() {
  final raw = File(r'D:\gz\完美书源.已修复.json').readAsStringSync();
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
Set-Content -Path 'D:\gz\midu\tool\_dump_rules_tmp.dart' -Value $dartScript -Encoding UTF8
D:\flutter\bin\flutter.bat pub run tool/_dump_rules_tmp.dart
Remove-Item 'D:\gz\midu\tool\_dump_rules_tmp.dart' -ErrorAction SilentlyContinue