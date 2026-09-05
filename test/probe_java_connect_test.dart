// 临时探针：对 {{java.connect(...)}} 内联模板源做全链路 search→detail→toc→content。
// 运行：flutter test test/probe_java_connect_test.dart -j 1
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/services/book_source_chapter_text.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const _needles = {
  '读趣网站', '小书本网', '爱看小说', '企鹅阅读', '天天看书', '西方奇幻',
  '松鹤庭沐', '贼吧网站', '品如漫画', '妙华台藏', '书趣阁网', '字码小说',
  '溜达小说', '菠萝漫画',
};

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
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: chapters.first.title,
    );
    return text.trim().isEmpty ? 'noContent' : 'OK';
  } catch (e) {
    return _clip('$e', 120);
  }
}

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('probe inline java.connect sources', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    for (final s in sources) {
      if (!_needles.any((n) => s.name.contains(n))) continue;
      final sandbox = FlutterLegadoJsSandbox();
      final rt = LegadoRuntime(sandbox: sandbox);
      try {
        // ignore: avoid_print
        print('${s.name} :: ${await _probe(rt, s.toRegisteredSource())}');
      } catch (e) {
        // ignore: avoid_print
        print('${s.name} :: uncaught :: ${_clip('$e', 120)}');
      } finally {
        try {
          rt.close();
        } catch (_) {}
        try {
          await sandbox.dispose();
        } catch (_) {}
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}