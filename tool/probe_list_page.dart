// 抓取 新御宅屋 列表页 /novel/list/xxx/1.html 并持久化，观察目录结构。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe tool/probe_list_page.dart
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty
      ? args[0]
      : 'https://mm.xyuzhaiwu.xyz/novel/list/76899/1.html';
  final outFile = args.length > 1
      ? args[1]
      : 'D:/gz/日志/toc/xyw_list.html';
  final c = HttpClient();
  c.connectionTimeout = const Duration(seconds: 15);
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36');
  final res = await req.close();
  print('status=${res.statusCode}');
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  c.close(force: true);
  final html = utf8.decode(bytes, allowMalformed: true);
  File(outFile).writeAsStringSync(html);
  print('saved(${html.length}) -> $outFile');
  // 打印分页/章节相关片段
  final idx = html.indexOf('章节');
  print('--- 章节上下文 ---');
  print(html.substring(idx < 0 ? 0 : idx > 60 ? idx - 60 : 0,
      (idx > 0 ? idx : 0) + 800));
}