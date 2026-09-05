// 临时诊断：用真实 LegadoRuntime 对 {@code {{java.connect(source.getKey()...)} 内联模式
// 的源（读趣网站）跑 search，捕获其异常，并观察引擎内置 DBG 输出定位卡点。
// 运行：flutter test test/probe_real_search_test.dart -j 1
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const _needle = '读趣网站';

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('real search on java.connect inline source', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    for (final s in sources.where((s) => s.name.contains(_needle))) {
      // ignore: avoid_print
      print('==== ${s.name} ====');
      final sandbox = FlutterLegadoJsSandbox();
      final rt = LegadoRuntime(sandbox: sandbox);
      try {
        try {
          final page = await rt.search(s.toRegisteredSource(), '斗破苍穹');
          // ignore: avoid_print
          print('RESULT items=${page.items.length}');
        } catch (e, st) {
          // ignore: avoid_print
          print('ERROR $e');
          // ignore: avoid_print
          print('STACK $st');
        }
      } finally {
        rt.close();
        await sandbox.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}