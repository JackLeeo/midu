// 实时管线诊断：对指定源跑 search→getBook→getChapters→getChapterContent，
// 用日志型 transport 抓取每一阶段发出的真实请求与响应 body，用于定位规则问题。
//
// 用法：
//   $env:VERIFY_BOOK_SOURCES_JSON='D:/gz/完美书源.json'
//   flutter test test/diag_live_pipeline_test.dart -j 1
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

/// (源名子串, 书名) —— 待抓取的源。
const _targets = <(String, String)>[
  ('书旗小说', '神盗特工'),
];

String _stripEmoji(String s) => s.replaceFirst(
  RegExp(r'^[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\s]+', unicode: true),
  '',
);

String _clip(String s, int n) {
  final c = s.replaceAll(RegExp(r'\s+'), ' ');
  return c.length <= n ? c : '${c.substring(0, n)}…';
}

/// 日志型 transport：打印每一请求的 URL/方法与响应概况，命中标记词时打印 body。
class _LoggingTransport implements LegadoTransport {
  _LoggingTransport(this._inner);

  final LegadoHttpTransport _inner;

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    final method = request.method == LegadoRequestMethod.post ? 'POST' : 'GET';
    final marker = method == 'POST' ? request.body?.trim() ?? '' : '';
    // ignore: avoid_print
    print('\n>>> $method ${request.url}');
    if (marker.isNotEmpty) {
      // ignore: avoid_print
      print('    BODY: $marker');
    }
    try {
      final r = await _inner.send(request);
      // ignore: avoid_print
      print('<<< ${r.finalUri}  bytes=${r.body.length}');
      // ignore: avoid_print
      print('    HEAD: ${_clip(r.body, 500)}');
      return r;
    } catch (e) {
      // ignore: avoid_print
      print('    ERROR: $e');
      rethrow;
    }
  }

  @override
  Future<Uint8List> sendBytes(LegadoRequestTemplate request) {
    return _inner.sendBytes(request);
  }
}

List<RegisteredBookSource> _loadSources(String path) {
  final raw = File(path).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : decoded is Map && decoded['bookSourceList'] is List
          ? (decoded['bookSourceList'] as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
  final out = <RegisteredBookSource>[];
  for (final m in list) {
    try {
      out.add(LegadoBookSource.fromJson(m).toRegisteredSource());
    } catch (_) {}
  }
  return out;
}

RegisteredBookSource? _find(List<RegisteredBookSource> list, String needle) {
  for (final s in list) {
    if (_stripEmoji(s.name).contains(needle)) return s;
  }
  return null;
}

Future<void> _run(RegisteredBookSource source, String title) async {
  // ignore: avoid_print
  print('\n\n######## 源=${source.name} | 《$title》 ########');
  final inner = LegadoHttpTransport();
  final runtime = LegadoRuntime(
    sandbox: FlutterLegadoJsSandbox(),
    transport: _LoggingTransport(inner),
  );
  try {
    final page = await runtime.search(source, title);
    // ignore: avoid_print
    print('== SEARCH items=${page.items.length}');
    if (page.items.isEmpty) return;
    final chosen = page.items.firstWhere(
      (b) => b.title.contains(title),
      orElse: () => page.items.first,
    );
    // ignore: avoid_print
    print('== chosen: ${chosen.title} id=${chosen.id}');
    final detail = await runtime.getBook(source, chosen.id, seedBook: chosen);
    // ignore: avoid_print
    print('== DETAIL: ${detail.title} id=${detail.id}');
    final chapters = await runtime.getChapters(source, detail.id);
    // ignore: avoid_print
    print('== TOC chapters=${chapters.length} first5=${chapters.take(5).map((c)=>c.title).toList()}');
    if (chapters.isEmpty) return;
    final content = await runtime.getChapterContent(
      source,
      bookId: detail.id,
      chapterId: chapters.first.id,
    );
    // ignore: avoid_print
    print('== CONTENT bytes=${content.content.length}');
    // ignore: avoid_print
    print('== CONTENT HEAD: ${_clip(content.content, 300)}');
  } catch (e) {
    // ignore: avoid_print
    print('== PIPELINE ERROR: $e');
  } finally {
    runtime.close();
    inner.close();
  }
}

void main() {
  copyQuickJsDllIfNeeded();
  test('实时管线诊断', () async {
    HttpOverrides.global = null;
    final jsonPath = Platform.environment['VERIFY_BOOK_SOURCES_JSON'] ??
        const String.fromEnvironment('VERIFY_BOOK_SOURCES_JSON');
    if (jsonPath.isEmpty) {
      markTestSkipped('缺 VERIFY_BOOK_SOURCES_JSON');
      return;
    }
    final sources = _loadSources(jsonPath);
    for (final (needle, title) in _targets) {
      final src = _find(sources, needle);
      if (src == null) {
        // ignore: avoid_print
        print('SKIP $needle 未找到');
        continue;
      }
      await _run(src, title);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}