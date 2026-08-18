// 取证脚本：针对用户报告的错误样本，抓取真实目录与正文。
// 目录样本：饿狼小说/五二书库/五六中文/爱思路克线路《斗破苍穹》
// 正文样本：书海阁/UC书库《斗破苍穹》、望书阁《夜无疆》
//
// 运行：flutter test tool/diagnose_catalog_content_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/utils/debug_logger.dart';
import 'package:midu/utils/fast_gbk_decoder.dart';

import '../test/helpers/flutter_js_sandbox.dart';

import 'package:test/test.dart';

const _sourceFile = r'D:\gz\完美书源.json';

/// 目录取证目标：线路名关键字 → 书名（用于 search）
const _catalogTargets = <Map<String, String>>[
  {'name': '饿狼小说', 'query': '斗破苍穹'},
  {'name': '五二书库', 'query': '斗破苍穹'},
  {'name': '五六中文', 'query': '斗破苍穹'},
  {'name': '爱思路客', 'query': '斗破苍穹'},
];

/// 正文取证目标
const _contentTargets = <Map<String, String>>[
  {'name': '书海阁', 'query': '斗破苍穹'},
  {'name': 'ＵＣ书库', 'query': '斗破苍穹'},
  {'name': '望书阁网', 'query': '夜无疆'},
];

void main() {
  test('取证：目录顺序与正文分页',
      () async {
        await _run();
      },
      timeout: const Timeout(Duration(minutes: 15)));
}

Future<void> _run() async {
  copyQuickJsDllIfNeeded();
  final file = File(_sourceFile);
  if (!file.existsSync()) {
    fail('未找到书源文件');
  }
  final sources = parseLegadoSources(file.readAsStringSync()).sources;
  print('total=${sources.length}');

  final sb = StringBuffer();
  sb.writeln('===== 目录取证 =====');
  for (final target in _catalogTargets) {
    final src = sources
        .where((s) => s.name.contains(target['name']!))
        .toList();
    if (src.isEmpty) {
      sb.writeln('\n[@目录] 未找到源: ${target['name']}');
      continue;
    }
    for (final s in src) {
      await _dumpCatalog(s, target['query']!, target['name']!, sb);
    }
  }

  sb.writeln('\n\n===== 正文取证 =====');
  for (final target in _contentTargets) {
    final src = sources
        .where((s) => s.name.contains(target['name']!))
        .toList();
    if (src.isEmpty) {
      sb.writeln('\n[@正文] 未找到源: ${target['name']}');
      continue;
    }
    for (final s in src) {
      await _dumpContent(s, target['query']!, target['name']!, sb);
    }
  }

  File(r'D:\gz\日志\_catalog_content_diag.txt')
      .parent
      .createSync(recursive: true);
  File(r'D:\gz\日志\_catalog_content_diag.txt').writeAsStringSync(sb.toString());
  // ignore: avoid_print
  print(sb.toString());
}

Future<void> _dumpCatalog(
  LegadoBookSource s,
  String query,
  String tag,
  StringBuffer sb,
) async {
  sb.writeln('\n---------- [@目录 ${s.name}] ----------');
  LegadoRuntime? rt;
  try {
    rt = LegadoRuntime(sandbox: FlutterLegadoJsSandbox());
    final registered = s.toRegisteredSource();
    try {
      final page = await rt.search(registered, query, pageSize: 20);
      if (page.items.isEmpty) {
        sb.writeln('  (搜索无结果)');
        return;
      }
      final book = page.items.first;
      sb.writeln('  命中书名: ${book.title} / ${book.author} / id=${book.id}');

      // 1) 原始目录（关归一化）
      final raw = await rt.getChapters(
        registered,
        book.id,
        normalizeChapterOrder: false,
      );
      sb.writeln('  原始目录 count=${raw.length}');
      _dumpHeadTailTitles(sb, raw, 'raw');

      // 2) 当前归一化结果
      final norm = await rt.getChapters(registered, book.id);
      sb.writeln('  归一化目录 count=${norm.length}');
      _dumpHeadTailTitles(sb, norm, 'norm');
    } on Exception catch (e) {
      sb.writeln('  (目录失败）${e.toString().replaceAll('\n', ' | ')}');
    }
  } finally {
    rt?.close();
  }
}

Future<void> _dumpContent(
  LegadoBookSource s,
  String query,
  String tag,
  StringBuffer sb,
) async {
  sb.writeln('\n---------- [@正文 ${s.name}] ----------');
  LegadoRuntime? rt;
  try {
    rt = LegadoRuntime(sandbox: FlutterLegadoJsSandbox());
    final registered = s.toRegisteredSource();
    try {
      final page = await rt.search(registered, query, pageSize: 20);
      if (page.items.isEmpty) {
        sb.writeln('  (搜索无结果)');
        return;
      }
      final book = page.items.first;
      sb.writeln('  命中书名: ${book.title} / ${book.author} / id=${book.id}');

      final catalog = await rt.getChapters(registered, book.id);
      if (catalog.isEmpty) {
        sb.writeln('  (目录为空)');
        return;
      }
      sb.writeln('  目录 count=${catalog.length}');
      sb.writeln('  前6章标题:');
      for (var i = 0; i < catalog.length && i < 6; i++) {
        final c = catalog[i];
        sb.writeln('    [${c.order}] ${c.title}  url=${_short(c.id)}');
      }

      // 加载前 3 章，检查正文唯一性（是否第一页内容重叠到第二页）
      final seen = <String>{};
      DebugLogger.instance.enabled = true;
      for (var i = 0; i < catalog.length && i < 3; i++) {
        final c = catalog[i];
        try {
          final before = DebugLogger.instance.entries.length;
          final content = await rt.getChapterContent(
            registered,
            bookId: book.id,
            chapterId: c.id,
          );
          // 提取本章节的分页 hop 流水（net/content 类目）
          final hops = <String>[];
          for (final e in DebugLogger.instance.entries.skip(before)) {
            final d = e.details ?? const {};
            if (e.category == 'content') {
              if (d.containsKey('totalLength')) {
                hops.add('** 章节加载成功 total=${d['totalLength']} parts=${d['parts']}');
              } else if (d['url'] != null ||
                  d['bodyLength'] != null ||
                  d['contentLength'] != null ||
                  d['replaceLength'] != null) {
                hops.add('${d['hopText'] ?? ''}${e.message}'
                    ' url=${d['url'] ?? d['finalUri'] ?? ''}'
                    ' body=${d['bodyLength'] ?? ''}'
                    ' ext=${d['contentLength'] ?? ''}'
                    ' aft=${d['replaceLength'] ?? ''}');
              }
            }
          }
          final body = content.content.trim();
          final first40 = body.replaceAll('\n', ' ').substring(
                0,
                body.length > 40 ? 40 : body.length,
              );
          final dup = seen.add('${c.id}|${body.length}');
          sb.writeln(
            '  [第${i + 1}章] ${c.title}  len=${body.length}  head="$first40"'
            '  title=${_short(content.title)}',
          );
          if (hops.isNotEmpty) {
            sb.writeln('    分页: ${hops.join('  ->  ')}');
          }
          if (!dup) sb.writeln('    !! 该正文与之前章节同 id+len 重复');
          if (i == 0) {
            sb.writeln('    [probe] contentRule=${_short(s.rule('ruleContent')['content'] ?? '')}');
            await _probeContentRule(c.id, '${s.rule('ruleContent')['content']}', sb);
          }
        } on Exception catch (e) {
          sb.writeln('  [第${i + 1}章] 失败: ${e.toString().replaceAll('\n', ' | ')}');
        }
      }
    } on Exception catch (e) {
      sb.writeln('  (正文取证失败）${e.toString().replaceAll('\n', ' | ')}');
    }
  } finally {
    rt?.close();
  }
}

/// 绕过 getChapterContent，直接用规则引擎对原始页面求值，定位抽取丢内容的原因。
Future<void> _probeContentRule(
  String url,
  String contentRule,
  StringBuffer sb,
) async {
  final sandbox = FlutterLegadoJsSandbox();
  try {
    await sandbox.init();
    final engine = LegadoRuleEngine(sandbox: sandbox);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36');
      req.headers.set('Accept',
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8');
      req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      final res = await req.close();
      final raw = await res.expand((x) => x).toList();
      final body = _adaptiveDecode(raw);
      final doc = LegadoRuleDocument.parse(body, Uri.parse(url));
      final v = await engine.evaluateString(doc, null, contentRule);
      sb.writeln('    [probe] url=$url rawBody=${body.length} ext=${v.length} newlines=${RegExp(r'\n').allMatches(body).length}');
      if (v.isNotEmpty) {
        final compact = v.replaceAll(RegExp(r'\s+'), ' ');
        sb.writeln('      head="${compact.substring(0, compact.length > 90 ? 90 : compact.length)}"');
        sb.writeln('      tail="${compact.substring(compact.length > 90 ? compact.length - 90 : 0)}"');
        // 原始页面结尾 20 行（含换行显示），用于确认 footer 广告结构
        final lines = body.split('\n');
        final tailLines = lines.length > 20 ? lines.skip(lines.length - 20).toList() : lines;
        sb.writeln('      raw tail lines:\n${tailLines.map((l) => '      | ${l.replaceAll(RegExp(r'\s+'), ' ')}').join('\n')}');
      }
    } finally {
      client.close(force: true);
    }
  } finally {
    await sandbox.dispose();
  }
}

void _dumpHeadTailTitles(
  StringBuffer sb,
  List<BookSourceChapter> chapters,
  String tag,
) {
  final n = chapters.length;
  final show = 14;
  final head = chapters.take(show).toList();
  sb.writeln('  $tag 头部 ${head.length} 章:');
  for (var i = 0; i < head.length; i++) {
    sb.writeln('    [$i] ${head[i].title}');
  }
  if (n > show * 2) {
    final tail = chapters.skip(n - show).toList();
    sb.writeln('  $tag 尾部 ${tail.length} 章:');
    for (var i = 0; i < tail.length; i++) {
      sb.writeln('    [${n - show + i}] ${tail[i].title}');
    }
  }
}

String _short(String s) => s.length > 60 ? '${s.substring(0, 60)}…' : s;

/// 对齐 runtime 的内容自适应解码：UTF-8 严格（无 U+FFFD）优先，否则 GBK。
String _adaptiveDecode(List<int> bytes) {
  final raw = Uint8List.fromList(bytes);
  try {
    return utf8.decode(raw);
  } on FormatException {
    return decodeGbkFast(raw, lenient: true);
  }
}