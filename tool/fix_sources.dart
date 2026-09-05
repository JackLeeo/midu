// 书源规则批量修复（完美书源.json 轮转直改，避免手改大段转义串）。
// 用法:
//   dart tool/fix_sources.dart
import 'dart:convert';
import 'dart:io';

const _path = 'D:/gz/完美书源.json';

List<Map<String, dynamic>> load() {
  final raw = File(_path).readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is List) return decoded.cast<Map<String, dynamic>>();
  return ((decoded as Map)['bookSourceList'] as List).cast<Map<String, dynamic>>();
}

void save(List<Map<String, dynamic>> list, Object? envelope) {
  final data = envelope is Map ? (envelope..['bookSourceList'] = list) : list;
  File(_path).writeAsStringSync(jsonEncode(data), flush: true);
  print('[saved] ${list.length} sources');
}

void main() {
  final rawJson = File(_path).readAsStringSync();
  final decoded = jsonDecode(rawJson);
  final list = load();
  var changed = false;

  // ---- 书旗小说：tocUrl 用 baseUrl 推导 bookId，摆脱 java.put('bid') 被整页
  // JSON 污染的问题（搜索 bookUrl 复合规则在 bid 缺失上下文会把整页 JSON 存入 bid）。
  for (final src in list) {
    final name = '${src['bookSourceName'] ?? ''}';
    if (!name.contains('书旗')) continue;
    final info = src['ruleBookInfo'];
    if (info is! Map) continue;
    final toc = info['tocUrl'] as String? ?? '';
    if (toc.contains("var bookId=java.get('bid');")) {
      final fixed = toc.replaceFirst(
        "var bookId=java.get('bid');",
        "var bookId=(baseUrl.match(/book\\/(\\d+)\\.html/)||baseUrl.match(/(\\d{3,})/)||[0,''])[1];",
      );
      info['tocUrl'] = fixed;
      changed = true;
      print('[书旗] tocUrl bookId now derived from baseUrl');
    }
  }

  if (changed) {
    save(list, decoded);
  } else {
    print('(no change)');
  }
}