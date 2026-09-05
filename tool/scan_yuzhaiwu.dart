// 离线排查：找出与已修复新御宅屋同模板（御宅屋系）或其他可离线修复的 noChapters 源。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/scan_yuzhaiwu.dart
import 'dart:convert';
import 'dart:io';

const _path = 'D:/gz/完美书源.已修复.json';

void main() {
  final raw = File(_path).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : (decoded as Map)['bookSourceList'] as List;

  final patterns = <String>[
    'xyuzhaiwu',
    'po18',
    '御宅',
    'hyzw',
    '2wink',
    'rssz',
    'quanben',
  ];
  for (final s in list) {
    final m = s as Map<String, dynamic>;
    final name = '${m['bookSourceName'] ?? ''}';
    final url = '${m['bookSourceUrl'] ?? ''}';
    final toc = m['ruleToc'];
    final tocStr = toc is String ? toc : jsonEncode(toc ?? {});
    final info = m['ruleBookInfo'];
    final infoStr = info is String ? info : jsonEncode(info ?? {});
    final lbMulu = infoStr.contains('lb_mulu') || tocStr.contains('lb_mulu');
    final domainHit = patterns.any((p) =>
        url.toLowerCase().contains(p) ||
        name.toLowerCase().contains(p));
    final navPollution = tocStr.contains('ul@li!-1@a');
    if (lbMulu || domainHit || navPollution) {
      print('=== $name [$url]');
      print('  toc.chapterList=${_field(m, 'ruleToc', 'chapterList')}');
      print('  toc.chapterUrl=${_field(m, 'ruleToc', 'chapterUrl')}');
      print('  info.tocUrl=${_field(m, 'ruleBookInfo', 'tocUrl')}');
      print('  matches: lbMulu=$lbMulu domain=$domainHit navPollution=$navPollution');
      print('');
    }
  }
}

String _field(Map<String, dynamic> src, String group, String key) {
  final g = src[group];
  if (g is! Map) return '';
  final v = g[key];
  return v == null ? '' : '$v';
}