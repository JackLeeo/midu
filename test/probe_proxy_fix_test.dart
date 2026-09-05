// 代理环境的引擎修复聚焦探针：验证内置 baseUrl 注入后的多个源真实链路。
// 运行：flutter test test/probe_proxy_fix_test.dart -j 1
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

const _targets = ['品如漫画', '菠萝漫画'];

void main() {
  copyQuickJsDllIfNeeded();
  test('proxy engine fix: baseUrl 相关源', () async {
    HttpOverrides.global = null;
    final sources = parseLegadoSources(
            File(r'D:\gz\完美书源.已修复.json').readAsStringSync())
        .sources
        .toList();
    for (final s in sources.where((s) => s.name.contains('品如漫画')).take(1)) {
      final sandbox = FlutterLegadoJsSandbox();
      final rt = LegadoRuntime(sandbox: sandbox);
      try {
        print('== ${s.name} ==');
        final reg = s.toRegisteredSource();
        final page = await rt.search(reg, '斗破苍穹');
        print('   search items=${page.items.length}');
        for (final b in page.items.take(3)) {
          print('   - "${b.title}" id=${b.id}');
        }
      } catch (e) {
        print('   ERR $e');
      } finally {
        try {
          rt.close();
        } catch (_) {}
        await sandbox.dispose();
      }
    }
    print('done');
  }, timeout: const Timeout(Duration(minutes: 3)));
}