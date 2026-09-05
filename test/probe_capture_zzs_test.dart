// 抓取 猪猪书网/久久小说 《我师兄实在太稳健了》的详情页与目录页 HTML 落盘，
// 供 verify_toc_selector 离线验证。运行: flutter test test/probe_capture_zzs_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  copyQuickJsDllIfNeeded();

  test('capture zzs 我师兄实在太稳健了 详情/目录 HTML', () async {
    HttpOverrides.global = null;
    final file = File(r'D:\gz\完美书源.已修复.json');
    final decoded = jsonDecode(file.readAsStringSync());
    final list = (decoded is List) ? decoded : (decoded as Map)['sources'] as List;
    const want = ['猪猪书网', '久久小说'];
    for (final m in list.cast<Map<String, dynamic>>()) {
      final name = '${m['bookSourceName']}';
      if (!want.any((w) => name.contains(w))) continue;
      print('\n===== $name =====');
      final src = LegadoBookSource.fromJson(m);
      final report = const LegadoCompatibilityScanner().scan(src);
      if (!report.canRun) {
        print('  SKIP not runnable');
        continue;
      }
      final sandbox = FlutterLegadoJsSandbox();
      final transport = LegadoHttpTransport(
        requestTimeout: const Duration(seconds: 25),
      );
      final runtime = LegadoRuntime(sandbox: sandbox, transport: transport);
      try {
        final reg = src.toRegisteredSource();
        final page = await runtime.search(reg, '我师兄实在太稳健了');
        print('  search n=${page.items.length}');
        if (page.items.isEmpty) continue;
        for (final b in page.items.take(3)) {
          print('    - "${b.title}" id=${b.id}');
        }
        final chosen = page.items.firstWhere(
          (b) => b.title.contains('稳健'),
          orElse: () => page.items.first,
        );
        final detail = await runtime.getBook(reg, chosen.id, seedBook: chosen);
        print('  detail name="${detail.title}" id=${detail.id}');
        // 直接抓详情页原文（bookId）
        final detailResp = await transport.send(
          LegadoRequestTemplate.parse(
            detail.id,
            baseUri: src.baseUri,
          ),
        );
        File(
          r'D:\gz\日志\toc\zzs5_detail_37326.html',
        ).writeAsStringSync(detailResp.body);
        print('  saved detail len=${detailResp.body.length}');
        // 抓目录页（tocUrl 规则求值结果）
        final chapters = await runtime.getChapters(reg, detail.id);
        print('  toc n=${chapters.length}');
        if (chapters.isEmpty) continue;
        for (final c in chapters.take(5)) {
          print('     - "${c.title}" id=${c.id}');
        }
        final last = chapters.last;
        print('     last "${last.title}" id=${last.id}');
        // 保存目录页原文：以 toc 首章 id 请求（详情页域名同源）
        File(
          r'D:\gz\日志\toc\zzs5_toc_page_37326.html',
        ).writeAsStringSync(
          'id=${chapters.length}\nfirst=${chapters.first.title}\nlast=${last.title}\n',
        );
        print('  summary saved');
      } catch (e) {
        print('  ERR: $e');
      } finally {
        runtime.close();
        await sandbox.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}