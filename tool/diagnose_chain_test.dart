// 真实链路诊断 v2（flutter_js 沙箱 + 真实 HTTP）：
// 打印失败源的 searchUrl 模板、展开后的请求 URL/method/headers/body，
// 并用原始 HttpClient 直接请求同一 URL 对照，定位 HTTP 400 根因。
//
// 运行：flutter test tool/diagnose_chain_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

import '../test/helpers/flutter_js_sandbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实链路：search→detail→catalog→content + 请求对照', () async {
    copyQuickJsDllIfNeeded();
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox);
    final sb = StringBuffer();
    try {
      final file = File(r'D:\gz\完美书源.json');
      if (!file.existsSync()) {
        fail('未找到书源文件');
        return;
      }
      final sources = parseLegadoSources(file.readAsStringSync()).sources
          .toList()
        ..sort((l, r) => r.lastUpdateTime.compareTo(l.lastUpdateTime));
      final targets = <String>[
        '爱笔楼',
        '奇书网站',
        '笔趣阁网',
        '顶点中文',
        '书趣阁网',
      ];
      var matched = 0;
      for (final source in sources) {
        final name = '${source.name}';
        if (!targets.any((t) => name.contains(t))) continue;
        matched++;
        final report = const LegadoCompatibilityScanner().scan(source);
        if (!report.canRun) {
          sb.writeln('[$name] SKIP(unsupported)');
          continue;
        }
        final registered = source.toRegisteredSource();
        sb.writeln('');
        sb.writeln('===== $name =====');
        sb.writeln('searchUrl=${source.searchUrl}');
        sb.writeln('header=${source.raw['header']}');
        try {
          final page = await runtime
              .search(registered, '斗破苍穹')
              .timeout(const Duration(seconds: 20));
          sb.writeln('  SEARCH-OK books=${page.items.length}');
          if (page.items.isNotEmpty) {
            final book = page.items.first;
            sb.writeln('  book=${book.title} id=${book.id}');
            try {
              final detail = await runtime
                  .getBook(registered, book.id)
                  .timeout(const Duration(seconds: 20));
              sb.writeln('  DETAIL-OK title=${detail.title}');
              try {
                final chapters = await runtime
                    .getChapters(registered, detail.id)
                    .timeout(const Duration(seconds: 25));
                sb.writeln('  CATALOG-OK chapters=${chapters.length}');
                if (chapters.isNotEmpty) {
                  final idx = chapters.length < 10 ? 0 : 3;
                  try {
                    final content = await runtime
                        .getChapterContent(
                          registered,
                          bookId: detail.id,
                          chapterId: chapters[idx].id,
                        )
                        .timeout(const Duration(seconds: 20));
                    sb.writeln('  CONTENT-OK len=${content.content.trim().length}');
                    sb.writeln('  preview=${_sub(content.content.trim().replaceAll('\n', ' '), 0, 100)}');
                  } catch (e) {
                    sb.writeln('  CONTENT-FAIL :: ${_short(e)}');
                  }
                }
              } catch (e) {
                sb.writeln('  CATALOG-FAIL :: ${_short(e)}');
              }
            } catch (e) {
              sb.writeln('  DETAIL-FAIL :: ${_short(e)}');
            }
          }
        } catch (e) {
          sb.writeln('  SEARCH-FAIL :: ${_short(e)}');
          await _rawProbe(source, sb);
        }
      }
      sb.writeln('');
      sb.writeln('matched=$matched');
    } catch (e, st) {
      sb.writeln('FATAL $e\n$st');
    } finally {
      runtime.close();
      await sandbox.dispose();
    }
    final out = File(r'D:\gz\日志\_chain_diag.txt');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(sb.toString());
    // ignore: avoid_print
    print(sb.toString());
  });
}

/// 展开 searchUrl 模板（{{key}}→斗破苍穹，忽略 JS 预处理），打印并用原始 HttpClient 请求。
Future<void> _rawProbe(LegadoBookSource source, StringBuffer sb) async {
  try {
    var template = source.searchUrl;
    final lower = template.toLowerCase();
    if (lower.contains('@js:') || lower.contains('<js>')) {
      sb.writeln('  [raw-probe] searchUrl 含 JS，跳过对照');
      return;
    }
    template = template
        .replaceAll('{{key}}', '斗破苍穹')
        .replaceAll('{{page}}', '1');
    final req = LegadoRequestTemplate.parse(
      template,
      baseUri: source.baseUri,
      variables: const {'key': '斗破苍穹', 'page': '1'},
      sourceHeaders: const {},
    );
    sb.writeln('  [raw-probe] url=${req.url}');
    sb.writeln(
        '  [raw-probe] method=${req.method} headers=${req.headers} body=${req.body}');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final rq = req.method == LegadoRequestMethod.post
        ? await client.postUrl(req.url)
        : await client.getUrl(req.url);
    for (final e in req.headers.entries) {
      if (e.key.toLowerCase() == 'host') continue;
      rq.headers.set(e.key, e.value);
    }
    if (req.method == LegadoRequestMethod.post && req.body != null) {
      rq.add(utf8.encode(req.body!));
    }
    final rs = await rq.close().timeout(const Duration(seconds: 15));
    sb.writeln('  [raw-probe] status=${rs.statusCode} length=${await _readAll(rs)}');
    client.close(force: true);
  } catch (e) {
    sb.writeln('  [raw-probe] ERROR :: ${_short(e)}');
  }
}

Future<int> _readAll(HttpClientResponse rs) async {
  var n = 0;
  await for (final chunk in rs) {
    n += chunk.length;
    if (n > 4096) break;
  }
  return n;
}

String _short(Object? e) {
  final s = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 200 ? s.substring(0, 200) : s;
}

String _sub(Object? v, int start, int end) {
  final s = '$v';
  if (s.isEmpty) return s;
  final a = start < 0 ? 0 : start;
  final b = end > s.length ? s.length : end;
  if (a >= b) return '';
  return s.substring(a, b);
}
