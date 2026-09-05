// 扫描所有书源中强 JS 依赖（java.post / java.ajax / java.connect）的调用形态，
// 区分「字面量 URL 可 rewrite 内联」「动态表达式需 evalArg」「Kotlin 链式 .raw()/.body() 不可修」，
// 供决策哪些强 JS 源可在引擎层离线改进。
import 'dart:convert';
import 'dart:io';

const _kMethods = ['java.post', 'java.ajax', 'java.connect'];

void main() {
  final decoded = jsonDecode(File(r'D:\gz\完美书源.已修复.json').readAsStringSync());
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : (decoded as Map)['bookSourceList'] as List;
  for (final s in list.cast<Map<String, dynamic>>()) {
    final name = '${s['bookSourceName'] ?? ''}';
    final url = '${s['bookSourceUrl'] ?? ''}';
    final hits = <String>{};
    for (final key in const ['searchUrl', 'ruleSearch', 'ruleToc', 'ruleContent', 'ruleBookInfo']) {
      final v = s[key];
      if (v == null) continue;
      final str = v is String ? v : jsonEncode(v);
      for (final m in _kMethods) {
        if (str.contains(m)) {
          _classify(str, m, name, url, key, hits);
        }
      }
    }
  }
}

void _classify(String str, String method, String name, String url, String field, Set<String> seen) {
  final tag = '$name|$method|$field';
  if (seen.contains(tag)) return;
  seen.add(tag);
  final re = RegExp('$method\\s*\\(', caseSensitive: false);
  final issues = <String>{
    if (str.contains('.raw(')) '.raw()',
    if (str.contains('.body(')) '.body()',
    if (str.contains('.request()')) '.request()',
    if (str.contains('org.jsoup')) 'org.jsoup',
    if (str.contains('java.connect(source')) 'java.connect(source',
    if (str.contains('JSON.parse(')) 'JSON.parse',
  };
  final firstArg = _firstArgKind(str, method);
  final stat = issues.isEmpty ? firstArg : '${firstArg} + ${issues.join(',')}';
  print('$method\t$field\t$stat\t$name [$url]');
}

String _firstArgKind(String str, String method) {
  final re = RegExp('$method\\s*\\(', caseSensitive: false);
  final m = re.firstMatch(str);
  if (m == null) return '?';
  var i = m.end;
  while (i < str.length && (str[i] == ' ')) i++;
  if (i >= str.length) return 'noarg';
  final c = str[i];
  if (c == '"' || c == "'" || c == '`') return 'literal';
  if (c == '\\') return 'escaped';
  // 动态表达式：含 source.* / result / 函数调用 视为 dynamic
  return 'dynamic';
}