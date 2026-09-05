// 针对 D:\gz\完美书源.已修复.json 的全量健康排查（逐源隔离、逐阶段捕获，防崩溃）。
// 对每个源跑 search→detail→catalog→content，输出每个失败源 名称/阶段/错误分类，
// 便于筛选“除已修复与已知正常之外”的其他书源进行规则/引擎修复。
//
// 运行：flutter test test/scan_booksources_all_fix_test.dart -j 1
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_chapter_text.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

enum _Stage { search, detail, toc, content }

class _Verdict {
  _Verdict({
    required this.ok,
    required this.stage,
    required this.kind,
    this.snippet = '',
  });
  final bool ok;
  final _Stage stage;
  final String kind;
  final String snippet;

  @override
  String toString() {
    final s = ok ? 'PASS' : 'FAIL';
    return '$s @${stage.name} kind=$kind'
        '${snippet.isEmpty ? '' : ' :: $snippet'}';
  }
}

String _stripEmoji(String s) => s.replaceFirst(
  RegExp(r'^[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\s]+', unicode: true),
  '',
);

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

_Verdict _fail(_Stage stage, String kind, [Object? error]) => _Verdict(
  ok: false,
  stage: stage,
  kind: kind,
  snippet: error == null ? '' : _clip(error.toString().replaceAll(RegExp(r'\s+'), ' '), 160),
);

_Verdict _classify(_Stage stage, Object error) {
  final msg = error.toString();
  if (error is FormatException && msg.contains('Scheme not starting')) {
    return _fail(stage, 'formatScheme', error);
  }
  if (error is BookSourceProtocolException) {
    final kind = msg.contains('did not return any chapters')
        ? 'noChapters'
        : msg.contains('did not return chapter content')
        ? 'noContent'
        : msg.contains('HTTP 404')
        ? 'http404'
        : msg.contains('HTTP 400')
        ? 'http400'
        : msg.contains('HTTP 429') || msg.contains('HTTP 403')
        ? 'http${
            msg.contains('429') ? '429' : '403'
          }'
        : 'protocol';
    return _fail(stage, kind, error);
  }
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return _fail(stage, 'blocked', error);
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return _fail(stage, 'loading', error);
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        return _fail(stage, code == null ? 'http?' : 'http$code', error);
      default:
        return _fail(stage, 'http(${error.type.name})', error);
    }
  }
  if (msg.contains('SocketException') || msg.contains('Connection refused')) {
    return _fail(stage, 'blocked', error);
  }
  if (msg.toLowerCase().contains('timeout')) return _fail(stage, 'loading', error);
  return _fail(stage, 'other', error);
}

/// 单个源单本书：search→detail→toc→第一章正文，全阶段捕获。
Future<_Verdict> _runOne(
  LegadoRuntime runtime,
  RegisteredBookSource source,
  String title,
) async {
  BookSourceBook? chosen;
  try {
    final page = await runtime.search(source, title);
    if (page.items.isEmpty) return _fail(_Stage.search, 'searchEmpty');
    chosen = page.items.firstWhere(
      (b) => b.title.contains(title),
      orElse: () => page.items.first,
    );
  } catch (e) {
    return _classify(_Stage.search, e);
  }

  var bookId = chosen.id;
  try {
    final detail = await runtime.getBook(source, chosen.id, seedBook: chosen);
    bookId = detail.id;
  } catch (e) {
    return _classify(_Stage.detail, e);
  }

  final List<BookSourceChapter> chapters;
  try {
    chapters = await runtime.getChapters(source, bookId);
  } catch (e) {
    return _classify(_Stage.toc, e);
  }
  if (chapters.isEmpty) return _fail(_Stage.toc, 'noChapters');

  try {
    final content = await runtime.getChapterContent(
      source,
      bookId: bookId,
      chapterId: chapters.first.id,
    );
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: chapters.first.title,
    );
    if (text.trim().isEmpty) return _fail(_Stage.content, 'noContent');
    return _Verdict(ok: true, stage: _Stage.content, kind: 'ok');
  } catch (e) {
    return _classify(_Stage.content, e);
  }
}

Future<List<_Verdict>> _runAll(
  List<RegisteredBookSource> sources, {
  required int maxConcurrency,
}) async {
  // ignore: avoid_print
  print('probe=${_probeTitle} sources=${sources.length}');
  final results = <_Verdict?>[]..length = sources.length;
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final idx = next++;
      if (idx >= sources.length) return;
      final s = sources[idx];
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(sandbox: sandbox);
      try {
        results[idx] = await _runOne(runtime, s, _probeTitle);
      } catch (e) {
        results[idx] = _Verdict(
          ok: false,
          stage: _Stage.search,
          kind: 'uncaught',
          snippet: _clip('$e', 160),
        );
      } finally {
        try {
          runtime.close();
        } catch (_) {
          // ignore: 关闭时若有挂起的连接被取消（SocketException），不影响结果收集
        }
        await sandbox.dispose();
      }
    }
  }

  final workers = List.generate(
    sources.length.clamp(0, maxConcurrency),
    (_) => worker(),
  );
  await Future.wait(workers);
  return results.whereType<_Verdict>().toList();
}

const String _probeTitle = '斗破苍穹';

void main() {
  copyQuickJsDllIfNeeded();

  final rawPath = r'D:\gz\完美书源.已修复.json';

  test('全量健康排查（逐源 search→detail→catalog→content）', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    if (!file.existsSync()) {
      fail('未找到 ' + rawPath);
      return;
    }
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    // 可选单源/子串过滤：FILTER_SRC=新御宅屋 或 逗号分隔多源，仅扫描匹配源。
    final filterSrc = Platform.environment['FILTER_SRC']?.trim() ?? '';
    final filters = filterSrc
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final registered = <RegisteredBookSource>[];
    for (final s in sources) {
      final report = const LegadoCompatibilityScanner().scan(s);
      if (!report.canRun) continue;
      if (filters.isNotEmpty &&
          !filters.any((f) => '${s.name}'.contains(f))) {
        continue;
      }
      registered.add(s.toRegisteredSource());
    }
    // ignore: avoid_print
    print('total=${sources.length} runnable=${registered.length}');

    // 全量扫描网络开销大，个别源在 runtime.close() 取消挂起连接时会在后台异步
    // 抛出 SocketException，直接落到 flutter_test 的 zone 会判测试失败、中断汇总。
    // 用独立 zone 吸收这类 background socket 取消错误，保证始终打印 ok/fail 统计。
    final verdicts =
        (await (await runZonedGuarded(
          () => _runAll(registered, maxConcurrency: 6),
          (_, __) {},
        )))!;

    final lines = <String>[];
    var ok = 0;
    var failedCount = 0;
    for (int i = 0; i < registered.length; i++) {
      final v = verdicts[i];
      if (v.ok) {
        ok++;
      } else {
        failedCount++;
      }
    }
    lines.add('===== 全量健康排查汇总 =====');
    lines.add('ok=$ok failed=$failedCount total=${registered.length}');
    lines.add('');
    lines.add('===== 健康源 =====');
    for (int i = 0; i < registered.length; i++) {
      if (verdicts[i].ok) lines.add('  OK ${registered[i].name}');
    }
    lines.add('');
    lines.add('===== 失败源明细 =====');
    for (int i = 0; i < registered.length; i++) {
      if (!verdicts[i].ok) {
        lines.add('  FAIL ${registered[i].name} :: ${verdicts[i]}');
      }
    }
    final out = File(r'D:\gz\日志\_scan_all_fix.txt');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(lines.join('\n'));
    // ignore: avoid_print
    print('\n${lines.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 60)));
}