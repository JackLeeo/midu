// 书源网络验证脚本（配合代理使用）。
//
// 对 `完美书源.json` 里用户报告的 18 条问题(书源, 书名)，走真实链路
//   search → getBook → getChapters → getChapterContent，
// 逐条抓取并分类真实失败原因（目录空/正文空/HTTP 404/FormatException scheme/
// 一直加载/被墙不可达），并输出目录前若干章标题以便核对顺序。
//
// 支持传入「修复后的书源副本」(VERIFY_PATCH_JSON)，对每条同时跑原版与补丁比对；
// 仅当补丁跑通，才把改动回写仓库/导入源 → 满足“脚本验证完美修复后再改代码”。
//
// 联网/代理：默认 dart:io HttpClient 会读 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 环境
// 变量；或用 TUN+fake-ip 透明接管。被墙源会被分类为 blocked 展示，供后续跳过。
//
// 用法（默认关闭，避免污染常规单测；三选一启用）：
//   1) 环境变量  VERIFY_SOURCES=1
//   2) --dart-define=VERIFY_SOURCES=true
//   3) 设置 VERIFY_SOURCES=1 且 VERIFY_PATCH_JSON=D:/gz/完美书源.已修复.json
//
// 完整示例：
//   $env:VERIFY_SOURCES=1
//   $env:VERIFY_BOOK_SOURCES_JSON='D:/gz/完美书源.json'
//   $env:VERIFY_PATCH_JSON='D:/gz/完美书源.已修复.json'   # 可选
//   flutter test test/verify_book_sources_network_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_chapter_text.dart';

import 'helpers/flutter_js_sandbox.dart';

// ---- 用户报告清单：(源名子串, 书名, 预期问题) ----
const kManifest = <(String, String, String)>[
  ('书满屋网', '在虐文颠大勺成为国宝级厨神', '正文每段多行空白'),
  ('就去看网', '影视猎魔人', '目录空'),
  ('果文学网', '诡异游戏：开局觉醒Bug级天赋', 'FormatException scheme'),
  ('群小说网', '被厌弃的男妻', '目录空'),
  ('书旗小说', '神盗特工', '目录空'),
  ('圣墟小说', '全职高手番外之巅峰荣耀', '目录顺序错'),
  ('宜搜小说', '极品老师俏校花', '目录空'),
  ('得间小说', '石榴花开', '目录空'),
  ('花生小说', '女神的上门豪婿', '一直加载'),
  ('阅友小说', '神医毒妃不好惹', 'HTTP 404'),
  ('中文书城', '权力法则', '目录空'),
  ('五六中文', '萌宝速递：总裁爹地快认领', '目录空'),
  ('企鹅读书', '武魂冥王剑，开局斩杀马小桃', 'HTTP 404'),
  ('天地中文', '官场：从一等功臣到政坛巅峰', '目录顺序错'),
  ('小说三千', '我的投资时代', '正文空'),
  ('灯读文学', '傲世灵神', '目录空'),
  ('爱下网书', '丑雌一胎七崽？兽夫们跪求复合', 'FormatException scheme'),
  ('猫眼看书', '深空彼岸', 'HTTP 404'),
];

enum Stage { search, detail, toc, content }

final class Verdict {
  Verdict({
    required this.ok,
    required this.stage,
    required this.kind,
    this.sample = '',
    this.snippet = '',
    this.debug = '',
  });

  final bool ok;
  final Stage stage;
  final String kind; // searchEmpty/noChapters/noContent/http404/formatScheme/loading/blocked/ok
  final String sample; // 目录前若干章标题，用于核对顺序
  final String snippet; // 正文前 120 字，用于核对多行空白等
  final String debug; // 原始异常消息原文，用于定位根因

  @override
  String toString() {
    final s = ok ? 'PASS' : 'FAIL';
    return '$s @${stage.name} kind=$kind'
        '${debug.isEmpty ? '' : '\n      异常: $debug'}'
        '${sample.isEmpty ? '' : '\n      目录样本: $sample'}'
        '${snippet.isEmpty ? '' : '\n      正文样本: ${snippet.replaceAll('\n', '▏')}'}';
  }
}

String _stripEmoji(String s) => s.replaceFirst(
  RegExp(r'^[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\s]+', unicode: true),
  '',
);

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

bool _looksHtmlRaw(String s) => RegExp(r'</?[a-z][a-z0-9]*', caseSensitive: false).hasMatch(s);

Verdict _fail(Stage stage, String kind, [Object? error]) =>
    Verdict(ok: false, stage: stage, kind: kind, debug: error?.toString() ?? '');

Verdict _classify(Stage stage, Object error) {
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
        return _fail(stage, code == 404 ? 'http404' : 'http$code', error);
      default:
        return _fail(stage, 'http(${error.type.name})', error);
    }
  }
  if (msg.contains('SocketException') || msg.contains('Connection refused')) {
    return _fail(stage, 'blocked', error);
  }
  if (msg.contains('timed out') || msg.toLowerCase().contains('timeout')) {
    return _fail(stage, 'loading', error);
  }
  return _fail(stage, 'other', error);
}

/// 单个源单个书：search→detail→toc→第一章正文。
Future<Verdict> _runOne(
  LegadoRuntime runtime,
  RegisteredBookSource registered,
  String title,
) async {
  BookSourceBook? chosen;
  try {
    final page = await runtime.search(registered, title);
    if (page.items.isEmpty) return _fail(Stage.search, 'searchEmpty');
    chosen = page.items.firstWhere(
      (b) => b.title.contains(title),
      orElse: () => page.items.first,
    );
  } catch (e) {
    return _classify(Stage.search, e);
  }

  var bookId = chosen.id;
  try {
    final detail = await runtime.getBook(registered, chosen.id, seedBook: chosen);
    bookId = detail.id;
  } catch (e) {
    return _classify(Stage.detail, e);
  }

  final List<BookSourceChapter> chapters;
  try {
    chapters = await runtime.getChapters(registered, bookId);
  } catch (e) {
    return _classify(Stage.toc, e);
  }
  if (chapters.isEmpty) return _fail(Stage.toc, 'noChapters');

  final sample = chapters.take(12).map((c) => c.title).join(' | ');

  try {
    final content = await runtime.getChapterContent(
      registered,
      bookId: bookId,
      chapterId: chapters.first.id,
    );
    // 米读：正文需套用真实阅读管线清理（HTML 标签剥离 + 连续空行折叠），
    // 仅判原始 content 会把「已剥离」误报成「HTML 未剥离 / 多行空白」。
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: chapters.first.title,
    );
    final hadHtml = _looksHtmlRaw(content.content);
    if (text.trim().isEmpty) {
      return Verdict(
        ok: false,
        stage: Stage.content,
        kind: 'noContent',
        sample: '$sample || 首章URL=${chapters.first.id}',
      );
    }
    // 统计连续空行，提示“多行空白”。段间保留的 1 个空行（\n\n）属正常排版，
    // 故用 \n{3,}（≥2 个空行）判定折叠是否真正生效。
    final blankRuns = RegExp(r'\n{3,}').allMatches(text).length;
    final extra = hadHtml ? 'clean$blankRuns空行' : '$blankRuns空行';
    final kind = blankRuns == 0 ? 'ok($extra)' : 'ok(残$blankRuns处连续空行 $extra)';
    return Verdict(
      ok: true,
      stage: Stage.content,
      kind: kind,
      sample: sample,
      snippet: _clip(text.trim().replaceAll(RegExp(r'\s+'), ' '), 120),
    );
  } catch (e) {
    return _classify(Stage.content, e);
  }
}

/// 按源隔离：每次给源一个新 runtime + 新沙箱（与生产 BookSourceClient 一致）。
Future<Verdict> _runFresh(RegisteredBookSource source, String title) async {
  final sandbox = FlutterLegadoJsSandbox();
  final runtime = LegadoRuntime(sandbox: sandbox);
  try {
    return await _runOne(runtime, source, title);
  } finally {
    runtime.close();
    await sandbox.dispose();
  }
}

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
    } catch (_) {
      // 跳过损坏源
    }
  }
  // ignore: avoid_print
  print('载入 ${path.split(Platform.pathSeparator).last}: 解析 ${list.length} 笔，注册 ${out.length}');
  return out;
}

void main() {
  copyQuickJsDllIfNeeded();

  final enabled =
      (Platform.environment['VERIFY_SOURCES'] ?? '').isNotEmpty ||
      const bool.fromEnvironment('VERIFY_SOURCES');

  test(
    '书源网络验证（原始 vs 修复补丁对照）',
    () async {
      if (!enabled) {
        markTestSkipped('未设置 VERIFY_SOURCES，跳过网络验证。');
        return;
      }
      HttpOverrides.global = null;

      final jsonPath = Platform.environment['VERIFY_BOOK_SOURCES_JSON'] ??
          const String.fromEnvironment('VERIFY_BOOK_SOURCES_JSON');
      if (jsonPath.isEmpty) {
        fail('缺书源 JSON 路径：请设 VERIFY_BOOK_SOURCES_JSON。');
      }
      final sources = _loadSources(jsonPath);
      final patchPath = Platform.environment['VERIFY_PATCH_JSON'] ??
          const String.fromEnvironment('VERIFY_PATCH_JSON');
      final patches = patchPath.isEmpty ? null : _loadSources(patchPath);

      final lines = <String>[];
      for (final (needle, title, issue) in kManifest) {
        final src = _findSource(sources, needle);
        if (src == null) {
          lines.add('SKIP [$needle] 源未找到');
          continue;
        }
        lines.add('== 源=${src.name} | 《$title》 | 期望:$issue ==========');
        lines.add('  原版 -> ${await _runFresh(src, title)}');
        final patch = patches == null ? null : _findSource(patches, needle);
        if (patch != null) {
          lines.add('  补丁 -> ${await _runFresh(patch, title)}');
        } else {
          lines.add('  补丁 -> (未设置 VERIFY_PATCH_JSON 或无同名源)');
        }
      }
      // ignore: avoid_print
      print('\n==== 验证报告 ====\n${lines.join('\n')}\n==== 报告结束 ====');
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}