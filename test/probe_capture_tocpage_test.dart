// 抓取 zzs5 章节页（tocUrl 实际指向的页面）并落盘原始 HTML，用于确认
// 《我师兄实在太稳健了》目录在源码页面的真实顺序。
// 运行: flutter test test/probe_capture_tocpage_test.dart -j 1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_request.dart';

void main() {
  test('capture zzs5 chapter page (toc 来源)', () async {
    HttpOverrides.global = null;
    final transport = LegadoHttpTransport(
      requestTimeout: const Duration(seconds: 25),
    );
    try {
      // tocUrl=id.downlink@a.0@href 指向的最新章节页
      for (final url in [
        'https://www.zzs5.net/book/37326/11326899.html',
        'https://www.zzs5.net/book/37326/',
      ]) {
        try {
          final resp = await transport.send(
            LegadoRequestTemplate.parse(
              url,
              baseUri: Uri.parse('https://www.zzs5.net'),
            ),
          );
          final out = File(
            'D:\\gz\\日志\\toc\\zzs5_${url.contains('11326899') ? 'chapter' : 'detail'}.html',
          );
          out.writeAsStringSync(resp.body);
          print('OK $url len=${resp.body.length} -> ${out.path}');
          // 统计 .listmain dd 章节链接 id 顺序
          final ids = RegExp(
            r'book/37326/(\d+)\.html',
          ).allMatches(resp.body).map((m) => m.group(1)!).toList();
          print('  章节链接数=${ids.length} 首=${ids.isEmpty ? '-' : ids.first} 尾=${ids.isEmpty ? '-' : ids.last}');
          if (ids.length > 1) {
            var desc = 0;
            for (var i = 0; i + 1 < ids.length; i++) {
              if (int.parse(ids[i]) > int.parse(ids[i + 1])) desc++;
            }
            print('  降序相邻对=$desc/${ids.length - 1}');
          }
        } catch (e) {
          print('FAIL $url :: $e');
        }
      }
    } finally {
      transport.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}