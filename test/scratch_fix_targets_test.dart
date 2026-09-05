// 针对引擎修复的定向验证：加载 完美书源.已修复.json，仅跑受本次引擎改动
// 影响的书源，确认修复前失败的阶段已改善。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';

import 'helpers/flutter_js_sandbox.dart';

const _targets = <String>[
  '铁血读书',
  '佩蒲斐榕',
  '同人圈网',
  '择日飞升',
  '零零小说',
  '七七书库',
];

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

Future<String> _probe(LegadoRuntime runtime, RegisteredBookSource src) async {
  try {
    final page = await runtime.search(src, '斗破苍穹');
    if (page.items.isEmpty) return 'searchEmpty';
    final chosen = page.items.firstWhere(
      (b) => b.title.contains('斗破苍穹'),
      orElse: () => page.items.first,
    );
    final detail = await runtime.getBook(src, chosen.id, seedBook: chosen);
    final chapters = await runtime.getChapters(src, detail.id);
    if (chapters.isEmpty) return 'noChapters';
    final content = await runtime.getChapterContent(
      src,
      bookId: detail.id,
      chapterId: chapters.first.id,
    );
    return content.content.trim().isNotEmpty ? 'OK' : 'noContent';
  } catch (e) {
    return _clip('$e', 160);
  }
}

void main() {
  copyQuickJsDllIfNeeded();
  test('引擎修复定向验证', () async {
    HttpOverrides.global = null;
    final file = File(r'D:\gz\完美书源.已修复.json');
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    final out = <String>[];
    for (final s in sources) {
      if (!_targets.any((t) => s.name.contains(t))) continue;
      out.add('SCAN name=${s.name}');
      final report = const LegadoCompatibilityScanner().scan(s);
      if (!report.canRun) {
        out.add('SKIP ${s.name} (not runnable)');
        continue;
      }
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(sandbox: sandbox);
      try {
        out.add('RESULT ${s.name} :: ${await _probe(runtime, s.toRegisteredSource())}');
      } finally {
        runtime.close();
        await sandbox.dispose();
      }
    }
    final log = File(r'D:\gz\日志\_fix_targets.txt');
    log.parent.createSync(recursive: true);
    log.writeAsStringSync(out.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}