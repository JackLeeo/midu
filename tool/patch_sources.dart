// 对《完美书源.已修复.json》按 名称+URL 精确匹配，打补丁修正规则字段。
// 用法: dart tool/patch_sources.dart   （D:\flutter\bin\cache\dart-sdk 不可用，故用 flutter test 包装）
import 'dart:convert';
import 'dart:io';

void main() {
  final path = 'D:/gz/完美书源.已修复.json';
  final raw = File(path).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = (decoded is List)
      ? decoded as List<dynamic>
      : ((decoded as Map)['bookSourceList'] as List<dynamic>);

  var patched = 0;
  void tryPatch(String nameNeedle, String urlContains, void Function(Map<String, dynamic> s) fn) {
    for (final e in list) {
      final s = e as Map<String, dynamic>;
      final name = '${s['bookSourceName'] ?? ''}';
      final url = '${s['bookSourceUrl'] ?? ''}';
      if (name.contains(nameNeedle) && url.contains(urlContains)) {
        fn(s);
        patched++;
      }
    }
  }

  // 1) 梧桐中文 普通变体：chapterList 改用可用选择器
  tryPatch('梧桐中文', 'www.wtzw.com', (s) {
    (s['ruleToc'] as Map)['chapterList'] = '.w_ulTxt li a';
    print('patched 梧桐中文(${s['bookSourceUrl']}) chapterList=.w_ulTxt li a');
  });

  // 2) 笔趣小说：XPath following-sibling 引擎不支持，改用 id.list->dd->a
  tryPatch('笔趣小说', 'biqusa', (s) {
    (s['ruleToc'] as Map)['chapterList'] = 'id.list@tag.dd@tag.a';
    print('patched 笔趣小说(${s['bookSourceUrl']}) chapterList=id.list@tag.dd@tag.a');
  });

  // 3) 新御宅屋 目录最终来自 tocUrl 生成的 列表页 /novel/list/x/1.html：
  //    <ul><li><a>章名</a></li>...</ul>，末尾含一个隐藏的"书名返回"链接需排除。
  //    chapterList 用列表页选择器 ul@li!-1@a，章节名取 a 文本。
  tryPatch('新御宅屋', 'xyuzhaiwu', (s) {
    final toc = s['ruleToc'] as Map;
    toc['chapterList'] = 'ul@li!-1@a';
    toc['chapterName'] = 'text';
    print('patched 新御宅屋(${s['bookSourceUrl']}) chapterList=ul@li!-1@a chapterName=text');
  });

  // 4) 全本同人 http 变体：复合类选择器 class.book_list clearfix 引擎无法解析
  //    导致 n=0，改用 class.book_list@ul@li@a。
  tryPatch('全本同人', 'http://qbtr.cc', (s) {
    (s['ruleToc'] as Map)['chapterList'] = 'class.book_list@ul@li@a';
    print('patched 全本同人(${s['bookSourceUrl']}) chapterList=class.book_list@ul@li@a');
  });

  // 5) 荏染柔木：目录同样经 tocUrl 跳 列表页 /novel/list/x/1.html，
  //    结构同新御宅屋模板，chapterList 用 ul@li!-1@a，章节名取 a 文本。
  tryPatch('荏染柔木', 'po18', (s) {
    final toc = s['ruleToc'] as Map;
    toc['chapterList'] = 'ul@li!-1@a';
    toc['chapterName'] = 'text';
    print('patched 荏染柔木(${s['bookSourceUrl']}) chapterList=ul@li!-1@a chapterName=text');
  });

  print('total patched=$patched');
  File(path).writeAsStringSync(jsonEncode(list));
}