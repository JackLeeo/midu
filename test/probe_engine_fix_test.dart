// 临时探针：对候选“引擎可修复”类书源快速跑 search→content，输出当前真实结果。
// 运行：flutter test test/probe_engine_fix_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const _needles = [
  '纵横中文', '爱看小说', '书趣阁网', '字码小说', '读趣网站', '小书本网',
  '企鹅阅读', '菠萝漫画', '溜达小说', '贼吧网站', '西方奇幻', '松鹤庭沐',
  '品如漫画', '天天看书', '书趣阁网',
];

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

Future<String> _probe(LegadoRuntime rt, dynamic src) async {
  try {
    final page = await rt.search(src, '斗破苍穹');
    if (page.items.isEmpty) return 'searchEmpty';
    final chosen = page.items.firstWhere(
      (b) => b.title.contains('斗破苍穹'),
      orElse: () => page.items.first,
    );
    final detail = await rt.getBook(src, chosen.id, seedBook: chosen);
    final chapters = await rt.getChapters(src, detail.id);
    if (chapters.isEmpty) return 'noChapters';
    final content = await rt.getChapterContent(
      src,
      bookId: detail.id,
      chapterId: chapters.first.id,
    );
    return content.content.trim().isEmpty ? 'noContent' : 'OK';
  } catch (e) {
    return _clip('$e', 140);
  }
}

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('probe engine-fix candidates', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    for (final needle in _needles) {
      final matched = sources.where((s) {
        final n = s.name;
        return n.contains(needle);
      }).toList();
      if (matched.isEmpty) {
        // ignore: avoid_print
        print('MISS  $needle');
        continue;
      }
      for (final s in matched) {
        final sandbox = FlutterLegadoJsSandbox();
        final rt = LegadoRuntime(sandbox: sandbox);
        try {
          // ignore: avoid_print
          print('${s.name} :: ${await _probe(rt, s.toRegisteredSource())}');
        } finally {
          rt.close();
          await sandbox.dispose();
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}