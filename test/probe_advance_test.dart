// 聚焦探针：对「确定性可修」类目标书源逐个跑 search→detail→toc→content，
// 输出每阶段的简短结果，用于在当前（可能已开代理）网络下诊断单站点规则缺陷。
// 运行：flutter test test/probe_advance_test.dart -j 1
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const _targets = [
  // formatScheme：验证引擎内嵌URL提取修复
  '菠萝漫画', 'U C 小说', '红叶书斋', '武道文学', '一米小说',
  // noChapters：detail 可达但目录空
  '猪猪书网', '新御宅屋', '猫眼看书', '全本同人', '久久小说', '荏染柔木',
  '溜达小说', '追书神器', '四零二零', '刺猬猫网',
  // noContent：content 阶段正文空
  '读趣网站', '果文学网', '看书吧网', '玄幻阁网', '爱下网书',
  // content http404
  '新御书屋', '海普文学', '搜读中文',
  // toc 规则产物非 URL
  '抖音小说',
];

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

Future<String> _probe(LegadoRuntime rt, RegisteredBookSource src) async {
  try {
    final page = await rt.search(src, '斗破苍穹');
    if (page.items.isEmpty) return '◇ searchEmpty';
    final chosen = page.items.firstWhere(
      (b) => b.title.contains('斗破苍穹'),
      orElse: () => page.items.first,
    );
    final detail = await rt.getBook(src, chosen.id, seedBook: chosen);
    final chapters = await rt.getChapters(src, detail.id);
    if (chapters.isEmpty) return '◇ noChapters';
    final content = await rt.getChapterContent(
      src,
      bookId: detail.id,
      chapterId: chapters.first.id,
    );
    if (content.content.trim().isEmpty) return '◇ noContent';
    return '◆ OK';
  } catch (e) {
    var msg = _clip('$e', 140).replaceAll(RegExp(r'\s+'), ' ');
    if (msg.contains('Could not connect')) msg = '✗ conn';
    else if (msg.contains('HTTP ')) msg = '✗ ' + msg.substring(0, msg.indexOf('legado') < 0 ? msg.length : msg.length);
    return '✗ ${_clip(msg, 130)}';
  }
}

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('focused advance probe', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    if (!file.existsSync()) {
      fail('file missing');
      return;
    }
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    for (final needle in _targets) {
      final matched = sources.where((s) => s.name.contains(needle)).toList();
      if (matched.isEmpty) {
        // ignore: avoid_print
        print('MISS $needle');
        continue;
      }
      // 同名源取第一个，避免重复探
      final s = matched.first.toRegisteredSource();
      final sandbox = FlutterLegadoJsSandbox();
      final rt = LegadoRuntime(sandbox: sandbox);
      try {
        // ignore: avoid_print
        print('${s.name} :: ${await _probe(rt, s)}');
      } finally {
        try {
          rt.close();
        } catch (_) {}
        await sandbox.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}