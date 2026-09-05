// 用 Dart HttpClient（与米读同栈）抓取 zzs5 本书详情页/目录页并落盘，
// 供 verify_toc_selector 离线验证 猪猪书网/久久小说 等 zzs5 系源的目录选择器。
// 运行: flutter test test/probe_dump_zzs5_test.dart -j 1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_request.dart';

void main() {
  test('dump zzs5 37326 详情页', () async {
    HttpOverrides.global = null;
    final transport = LegadoHttpTransport(
      requestTimeout: const Duration(seconds: 25),
    );
    try {
      final req = LegadoRequestTemplate.parse(
        'https://www.zzs5.net/book/37326/',
        baseUri: Uri.parse('https://www.zzs5.net'),
      );
      final resp = await transport.send(req);
      final out = File(r'D:\gz\日志\toc\zzs5_37326_detail.html');
      out.writeAsStringSync(resp.body);
      print('OK detail len=${resp.body.length} -> ${out.path}');
      // 摘要：匹配 .list dd a 与章节号
      final body = resp.body;
      final chIds = RegExp(r'/book/37326/(\d+)\.html').allMatches(body).length;
      print('chapter-link count(37326/*.html)=$chIds');
    } finally {
      transport.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}