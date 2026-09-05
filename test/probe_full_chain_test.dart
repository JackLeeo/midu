// 针对「代理可达」的强 JS 源，逐阶段（search→detail→catalog→content）跑全链路，
// 打印每个阶段的原始信息用于定位失败点。transport 用 30s 超时容忍隧道延迟。
// 运行: flutter test test/probe_full_chain_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_chapter_text.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

Future<void> main() async {
  copyQuickJsDllIfNeeded();

  test('强 JS 源全链路（代理+长超时）', () async {
    HttpOverrides.global = null;
    final file = File(r'D:\gz\完美书源.已修复.json');
    final decoded = jsonDecode(file.readAsStringSync());
    final list = (decoded is List) ? decoded : (decoded as Map)['sources'] as List;
    const want = ['品如漫画', '一米小说', '图书迷网'];
    for (final m in (list as List).cast<Map<String, dynamic>>()) {
      final name = '${m['bookSourceName']}';
      if (!want.any((w) => name.contains(w))) continue;
      final report = const LegadoCompatibilityScanner().scan(_toSource(m));
      print('\n==================== $name (canRun=${report.canRun}) ====================');
      if (!report.canRun) {
        print('  SKIP: not runnable');
        continue;
      }
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(
        sandbox: sandbox,
        transport: LegadoHttpTransport(requestTimeout: const Duration(seconds: 30)),
      );
      try {
        final src = _toSource(m).toRegisteredSource();
        // search
        BookSourceBook? book;
        try {
          final page = await runtime.search(src, '斗破苍穹');
          print('  search: n=${page.items.length}');
          for (final b in page.items.take(3)) {
            print('    - title="${b.title}" id=${b.id}');
          }
          if (page.items.isEmpty) { print('  ==> SEARCH_EMPTY'); continue; }
          book = page.items.firstWhere(
            (b) => b.title.contains('斗破苍穹'),
            orElse: () => page.items.first,
          );
        } catch (e) {
          print('  search ERR: $e'); continue;
        }
        // detail
        var bookId = (book as dynamic).id;
        try {
          final detail = await runtime.getBook(src, book.id, seedBook: book);
          bookId = detail.id;
          print('  detail: id=$bookId name="${detail.title}"');
        } catch (e) {
          print('  detail ERR: $e'); continue;
        }
        // toc
        List<BookSourceChapter> chapters;
        try {
          chapters = await runtime.getChapters(src, bookId);
        } catch (e) {
          print('  toc ERR: $e'); continue;
        }
        print('  toc: n=${chapters.length}');
        if (chapters.isEmpty) { print('  ==> NO_CHAPTERS'); continue; }
        print('    first="${chapters.first.title}" contentUrl=${chapters.first.id}');
        print('    last="${chapters.last.title}" contentUrl=${chapters.last.id}');
        // content
        try {
          final content = await runtime.getChapterContent(
            src,
            bookId: bookId,
            chapterId: chapters.first.id,
          );
          final text = readableBookSourceChapterText(content, fallbackTitle: chapters.first.title);
          print('  content: ${text.length} chars :: ${text.substring(0, text.length > 60 ? 60 : text.length)}');
        } catch (e) {
          print('  content ERR: $e');
        }
      } finally {
        runtime.close();
        await sandbox.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

LegadoBookSource _toSource(Map<String, dynamic> m) {
  final src = LegadoBookSource.fromJson(m);
  return src;
}