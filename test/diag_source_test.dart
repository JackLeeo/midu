// 诊断：对指定书源打印原始规则，并跳过已 PASS 的源。
// 用法：$env:VERIFY_BOOK_SOURCES_JSON='D:/gz/完美书源.json'; flutter test test/diag_source_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/utils/debug_logger.dart';

import 'helpers/flutter_js_sandbox.dart';

const kWant = <(String, String)>[
  ('爱下网书', '丑雌一胎七崽？兽夫们跪求复合'),
  ('猫眼看书', '深空彼岸'),
];

String _stripEmoji(String s) =>
    s.replaceFirst(RegExp(r'^[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\s]+', unicode: true), '');

RegisteredBookSource? _findSource(List<RegisteredBookSource> list, String needle) {
  for (final s in list) {
    if (_stripEmoji(s.name).contains(needle)) return s;
  }
  return null;
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

void dumpRules(RegisteredBookSource s) {
  final cfg = s.sourceConfig ?? const {};
  for (final key in const [
    'bookSourceUrl', 'searchUrl', 'ruleSearch', 'bookUrlPattern',
    'ruleBookInfo', 'ruleToc', 'ruleContent', 'loginUrl',
    'header', 'enabledCookieJar',
  ]) {
    final v = cfg[key];
    if (v is String && v.isNotEmpty) print('  $key=$v');
  }
}

Future<void> probe(LegadoRuntime runtime, RegisteredBookSource s, String title) async {
  DebugLogger.instance.enabled = true;
  DebugLogger.instance.clear();
  final before = DebugLogger.instance.entries.length;
  try {
    final page = await runtime.search(s, title);
    print('  [search] items=${page.items.length}');
    if (page.items.isNotEmpty) {
      final b = page.items.first;
      try {
        final d = await runtime.getBook(s, b.id, seedBook: b);
        print('  [detail] id=${d.id} title=${d.title}');
        final ch = await runtime.getChapters(s, d.id);
        print('  [toc] chapters=${ch.length}');
        if (ch.isNotEmpty) {
          final c = await runtime.getChapterContent(s, bookId: d.id, chapterId: ch.first.id);
          print('  [content] len=${c.content.length}');
        }
      } catch (e) {
        print('  [toc/content] ERR $e');
      }
    }
  } catch (e) {
    print('  [search] ERR $e');
  }
  final entries = DebugLogger.instance.entries;
  for (var i = before; i < entries.length; i++) {
    // 只打印请求/响应/规则相关，避免刷屏
    final line = entries[i];
    if (line.category == 'net' || line.category == 'http' ||
        line.category.contains('request') || line.category.contains('search') ||
        line.category.contains('toc') || line.category.contains('content') ||
        line.category.contains('rule') || line.category.contains('chapter') ||
        line.category.contains('dns') || line.category.contains('template') ||
        line.category.contains('seed')) {
      print('    [dbg:${line.category}] ${line.message} ${line.details ?? ''}');
    }
  }
  DebugLogger.instance.enabled = false;
}

void main() {
  copyQuickJsDllIfNeeded();
  test('诊断问题书源', () async {
    final jsonPath = Platform.environment['VERIFY_BOOK_SOURCES_JSON'] ?? 'D:/gz/完美书源.json';
    final sources = _loadSources(jsonPath);
    print('载入 ${sources.length} 源');
    for (final (needle, title) in kWant) {
      final s = _findSource(sources, needle);
      if (s == null) {
        print('== $needle: 未找到');
        continue;
      }
      print('\n========== $needle | 《$title》 (${s.name}) ==========');
      dumpRules(s);
      final sb = FlutterLegadoJsSandbox();
      final rt = LegadoRuntime(sandbox: sb);
      try {
        await probe(rt, s, title);
      } finally {
        rt.close();
        await sb.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}