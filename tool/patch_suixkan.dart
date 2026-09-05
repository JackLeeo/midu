// 修复随心看网（m.suixkan.com）：搜索 URL 带 `\n@js:` 尾巴被引擎 URL 编码导致
// 关键字查询被污染；bookUrl 正则取不到 onclick 里的 /b/xxx.html。均已离线验证。
//   searchUrl: drop "\n@js:java.put('key',key);result"（服务端已按 keyword 过滤）
//   bookUrl:  "@onclick##^[^']*'([^']+)'.*$##$1"   -> https://m.suixkan.com/b/xxx.html
//   bookList: "class.v-list-item"（去掉依赖 java.get('key') 的 JS 过滤）
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/patch_suixkan.dart
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
    if ('${s['bookSourceName'] ?? ''}'.contains('随心看')) {
      src = s;
      break;
    }
  }
  if (src == null) {
    print('未找到随心看');
    return;
  }

  // 1) searchUrl 去掉 @js 尾巴
  final oldUrl = '${src['searchUrl'] ?? ''}';
  final newUrl = 'https://m.suixkan.com/s/1.html?keyword={{key}}';
  if (oldUrl.contains('@js:')) {
    src['searchUrl'] = newUrl;
    print('[ok] searchUrl: ${oldUrl.replaceAll(RegExp(r'\s+'), ' ')}');
    print('    -> $newUrl');
  } else {
    print('searchUrl 无需修改: $oldUrl');
  }

  // 2) ruleSearch.bookUrl / bookList
  final rs = (src['ruleSearch'] ?? {}) as Map<String, dynamic>;
  final oldUrlR = '${rs['bookUrl'] ?? ''}';
  final newUrlR = r"@onclick##^[^']*'([^']+)'.*$##$1";
  if (oldUrlR.startsWith('##')) {
    rs['bookUrl'] = newUrlR;
    print('[ok] bookUrl: ${oldUrlR.replaceAll(RegExp(r'\s+'), ' ')}');
    print('    -> $newUrlR');
  } else {
    print('bookUrl 无需修改: $oldUrlR');
  }
  final oldList = '${rs['bookList'] ?? ''}';
  if (oldList.contains('java.get') || oldList.contains('@js')) {
    rs['bookList'] = 'class.v-list-item';
    print('[ok] bookList: ${oldList.replaceAll(RegExp(r'\s+'), ' ')}');
    print('    -> class.v-list-item');
  } else {
    print('bookList 无需修改');
  }

  File(_path).writeAsStringSync(jsonEncode(decoded), flush: true);
  print('[done]');
}