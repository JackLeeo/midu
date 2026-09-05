// 对候选 noChapters 源直接跑 getChapters，打印匹配数、错误与详情 URL。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

const targets = ['溜达小说', '免费小说', '刺猬猫网'];

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('probe getChapters', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    for (final needle in targets) {
      for (final s in sources.where((s) => s.name.contains(needle))) {
        final sandbox = FlutterLegadoJsSandbox();
        final rt = LegadoRuntime(sandbox: sandbox);
        try {
          print('== ${s.name} (${s.url})');
          final reg = s.toRegisteredSource();
          final page = await rt.search(reg, '斗破苍穹');
          if (page.items.isEmpty) {
            print('   searchEmpty');
            continue;
          }
          final b = page.items.firstWhere(
            (x) => x.title.contains('斗破苍穹'),
            orElse: () => page.items.first,
          );
          print('   bookTitle=${b.title}');
          final detail = await rt.getBook(reg, b.id, seedBook: b);
          print('   detail=${detail.id}');
          final infoRule = s.rule('ruleBookInfo');
          final toc = (infoRule is Map) ? infoRule['tocUrl'] : null;
          print('   tocUrlRule=$toc');
          final chapters = await rt.getChapters(reg, detail.id);
          print('   chapters=${chapters.length} first=${chapters.isEmpty ? null : chapters.first.title}');
        } catch (e) {
          print('   ERR $e');
        } finally {
          try {
            rt.close();
          } catch (_) {}
          await sandbox.dispose();
        }
      }
    }
    print('done');
  }, timeout: const Timeout(Duration(minutes: 5)));
}