// 重建 完美书源.已修复.json：从原版复制，应用已知有效修复。
// 用法: dart tool/build_patch.dart
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
  final rawJson = File(_orig).readAsStringSync();
  final decoded = jsonDecode(rawJson);
  final list = load(_orig);
  var changed = false;

  // ---- 群小说网：正文分页 nextContentUrl 修复。
  // 原规则依赖 Legado 的全局 src + 注释掉的 next_page，产出垃圾 URL 导致 hop=1
  // 404。站点章节按 (1/4)..(4/4) 分页，URL 为 {chapterUrl 去 .html}_N.html。
  // 用标题中的 (当前页/总页) 推导下一页。
  for (final src in list) {
    final name = stripEmoji('${src['bookSourceName'] ?? ''}');
    if (!name.contains('群小说')) continue;
    final rule = src['ruleContent'];
    if (rule is! Map) continue;
    rule['nextContentUrl'] = r'''@js:
var t = document.outerHTML;
var m = t.match(/<h1[^>]*>([^<]*)<\/h1>/);
var p = m && m[1].match(/\((\d+)\/(\d+)\)/);
result = (p && parseInt(p[1], 10) < parseInt(p[2], 10))
  ? baseUrl.replace(/_\d+\.html$/, '.html').replace(/\.html$/, '_' + (parseInt(p[1], 10) + 1) + '.html')
  : '';
result;''';
    changed = true;
    print('[群小说网] nextContentUrl 分页规则已修复');
  }

  if (!changed) {
    print('(no change)');
    return;
  }
  final data = decoded is Map ? (decoded..['bookSourceList'] = list) : list;
  File(_patch).writeAsStringSync(jsonEncode(data), flush: true);
  print('[saved] $_patch (${list.length} sources)');
}
