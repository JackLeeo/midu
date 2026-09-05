// 抓取单 URL 并打印与目录相关片段的 HTML（id=downlink / 列表 / dd），供离线修选择器。
import 'dart:io';

import 'package:dio/dio.dart';

void main(List<String> args) async {
  final url = args.isEmpty ? 'http://www.zzs5.net/book/18966/' : args[0];
  final dio = Dio(BaseOptions(followRedirects: true, maxRedirects: 5));
  final r = await dio.get<String>(url, options: Options(
    responseType: ResponseType.plain,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
    },
  ));
  final html = r.data ?? '';
  print('URL=$url status=${r.statusCode} len=${html.length}');
  File(r'D:\gz\日志\toc\zzs_detail.html').writeAsStringSync(html);
  print('saved -> D:\\gz\\日志\\toc\\zzs_detail.html');
  final keys = ['downlink', 'readerlist', 'listmain', 'catalog', 'chapter', 'list', 'dl id', 'download'];
  for (final k in keys) {
    final idx = html.indexOf(k, idxSafe(html, k, 0));
    if (idx < 0) continue;
    final start = idx - 200 < 0 ? 0 : idx - 200;
    final end = (idx + 1600) > html.length ? html.length : idx + 1600;
    print('\n----- "$k" @$idx -----');
    print(html.substring(start, end).replaceAll(RegExp(r'\s+'), ' '));
  }
}

int idxSafe(String s, String k, int from) {
  final i = s.indexOf(k, from);
  return i < 0 ? 0 : i;
}