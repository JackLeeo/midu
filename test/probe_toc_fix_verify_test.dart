// 走 runtime.getChapters 真实链路，验证修复后的目录选择器能返回完整章节。
// 运行：flutter test test/probe_toc_fix_verify_test.dart -j 1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

import 'helpers/flutter_js_sandbox.dart';

const targets = ['新御宅屋', '全本同人', '荏染柔木'];

void main() {
  copyQuickJsDllIfNeeded();
  test('verify getChapters real path', () async {
    HttpOverrides.global = null;
    final sources = parseLegadoSources(
            File(r'D:\gz\完美书源.已修复.json').readAsStringSync())
        .sources
        .toList();
    for (final needle in targets) {
      for (final s in sources.where((s) => s.name.contains(needle)).take(1)) {
        final sandbox = FlutterLegadoJsSandbox();
        final rt = LegadoRuntime(sandbox: sandbox);
        try {
          print('== ${s.name} ==');
          final reg = s.toRegisteredSource();
          final page = await rt.search(reg, '斗破苍穹');
          if (page.items.isEmpty) { print('   searchEmpty'); continue; }
          final b = page.items.firstWhere(
              (x) => x.title.contains('斗破苍穹'),
              orElse: () => page.items.first);
          final detail = await rt.getBook(reg, b.id, seedBook: b);
          print('   detail=${detail.id}');
          final chapters = await rt.getChapters(reg, detail.id);
          print('   chapters=${chapters.length}');
          if (chapters.isNotEmpty) {
            print('   first="${chapters.first.title}" last="${chapters.last.title}"');
            print('   firstUrl=${chapters.first.id}');
          }
        } catch (e) {
          print('   ERR $e');
        } finally {
          try { rt.close(); } catch (_) {}
          await sandbox.dispose();
        }
      }
    }
    print('done');
  }, timeout: const Timeout(Duration(minutes: 5)));
}