// 复现《我师兄实在太稳健了》搜索结果目录不正确 + 应用卡顿。
// 逐源 search→detail→toc，打印首尾章标题/URL 与各阶段耗时，用于定位回归点。
// 运行: flutter test test/probe_shixiong_test.dart -j 1
// 环境变量：FILTER_SRC 逗号分隔子串过滤；默认探候选健康源。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const _probeTitle = '我师兄实在太稳健了';

Future<void> _runOne(
  LegadoRuntime runtime,
  RegisteredBookSource reg,
) async {
  final swTotal = Stopwatch()..start();
  try {
    final swSearch = Stopwatch()..start();
    final page = await runtime.search(reg, _probeTitle);
    swSearch.stop();
    print('  search: n=${page.items.length} t=${swSearch.elapsedMilliseconds}ms');
    if (page.items.isEmpty) {
      print('  ==> SEARCH_EMPTY');
      return;
    }
    for (final b in page.items.take(5)) {
      final id = b.id.length > 90 ? '${b.id.substring(0, 90)}…' : b.id;
      print('    - "${b.title}" id=$id');
    }
    final chosen = page.items.firstWhere(
      (b) => b.title.contains('稳健') || b.title.contains('师兄'),
      orElse: () => page.items.first,
    );
    final swDetail = Stopwatch()..start();
    final detail = await runtime.getBook(reg, chosen.id, seedBook: chosen);
    swDetail.stop();
    print(
      '  detail: name="${detail.title}" t=${swDetail.elapsedMilliseconds}ms '
      'id=${detail.id.length > 90 ? '${detail.id.substring(0, 90)}…' : detail.id}',
    );
    final swToc = Stopwatch()..start();
    final chapters = await runtime.getChapters(reg, detail.id);
    swToc.stop();
    print('  toc: n=${chapters.length} t=${swToc.elapsedMilliseconds}ms');
    if (chapters.isEmpty) {
      print('  ==> NO_CHAPTERS');
      return;
    }
    for (final c in chapters.take(3)) {
      print(
        '    first: "${c.title}" id=${c.id.length > 80 ? '${c.id.substring(0, 80)}…' : c.id}',
      );
    }
    print('    last: "${chapters.last.title}" n=${chapters.length}');
    final firstTitle = chapters.first.title.trim();
    final expectTitleLike = RegExp(r'第|序|章|卷|楔子|01|1\b');
    print(
      '  sanity: firstTitleOK=${expectTitleLike.hasMatch(firstTitle)} '
      '["$firstTitle"]',
    );
  } catch (e) {
    print('  CHAIN ERR: $e');
  } finally {
    swTotal.stop();
    print('  total=${swTotal.elapsedMilliseconds}ms');
  }
}

void main() {
  copyQuickJsDllIfNeeded();

  test('我师兄实在是太稳健了 目录正确性 + 耗时', () async {
    HttpOverrides.global = null;
    final file = File(r'D:\gz\完美书源.已修复.json');
    final decoded = jsonDecode(file.readAsStringSync());
    final list = (decoded is List) ? decoded : (decoded as Map)['sources'] as List;
    final filterEnv = Platform.environment['FILTER_SRC']?.trim() ?? '';
    final filters = filterEnv
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final sources = (list as List).cast<Map<String, dynamic>>();
    final runnable = <LegadoBookSource>[];
    var skipped = 0;
    for (final m in sources) {
      final name = '${m['bookSourceName']}';
      if (filters.isNotEmpty && !filters.any((f) => name.contains(f))) {
        skipped++;
        continue;
      }
      final LegadoBookSource src;
      try {
        src = LegadoBookSource.fromJson(m);
      } catch (_) {
        continue;
      }
      final report = const LegadoCompatibilityScanner().scan(src);
      if (!report.canRun) continue;
      runnable.add(src);
    }
    print('runnable=${runnable.length} skippedByFilter=$skipped');

    var idx = 0;
    Future<void> worker() async {
      while (true) {
        final i = idx++;
        if (i >= runnable.length) return;
        final src = runnable[i];
        final sandbox = FlutterLegadoJsSandbox();
        final runtime = LegadoRuntime(
          sandbox: sandbox,
          transport: LegadoHttpTransport(
            requestTimeout: const Duration(seconds: 20),
          ),
        );
        try {
          print(
            '\n===== [${i + 1}/${runnable.length}] "${src.name}" =====',
          );
          await _runOne(runtime, src.toRegisteredSource());
        } finally {
          runtime.close();
          await sandbox.dispose();
        }
      }
    }

    final workers = List.generate(4, (_) => worker());
    await Future.wait(workers);
  }, timeout: const Timeout(Duration(minutes: 30)));
}