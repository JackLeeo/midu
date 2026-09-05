// 修复新御宅屋：ruleBookInfo.tocUrl 选择器带空格的 `class.lb_mulu chapterList`
// 无法匹配，改为 `class.lb_mulu`（离线已验证可正确导航到列表页，提取 22 章）。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/patch_xyw.dart
import 'dart:convert';
import 'dart:io';

const _path = 'D:/gz/完美书源.已修复.json';

void main() {
  final raw = File(_path).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : (decoded as Map)['bookSourceList'] as List;

  Map<String, dynamic>? src;
  for (final e in list) {
    final s = e as Map<String, dynamic>;
    if ('${s['bookSourceName'] ?? ''}'.contains('新御宅屋')) {
      src = s;
      break;
    }
  }
  if (src == null) {
    print('未找到新御宅屋');
    return;
  }
  final info = src['ruleBookInfo'] as Map<String, dynamic>;
  final toc = '${info['tocUrl'] ?? ''}';
  if (!toc.contains('class.lb_mulu chapterList@')) {
    print('tocUrl 无需修改 (当前=$toc)');
    return;
  }
  final fixed = toc.replaceFirst(
    'class.lb_mulu chapterList@',
    'class.lb_mulu@',
  );
  info['tocUrl'] = fixed;
  File(_path).writeAsStringSync(jsonEncode(decoded), flush: true);
  print('[ok] 新御宅屋 tocUrl 已修复 => $fixed');
}