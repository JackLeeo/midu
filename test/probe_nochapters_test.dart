// 针对 noChapters / 强JS 失败源的在线目录页抓取诊断。
// 用法：FILTER_SRC=猪猪书网,随心看网 flutter test test/probe_nochapters_test.dart -j 1
// 行为：对每个匹配源跑 search→detail→catalog；记录实际请求的 URL 链；
//       目录失败时把最近的详情页/列表页 HTML 落盘到 D:\gz\日志\dump\<源名>.html，
//       供离线修选择器（tocUrl / chapterList / chapterUrl）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

class _RecTransport implements LegadoTransport {
  final _inner = LegadoHttpTransport();
  final requests = <String>[];
  final bodies = <String, String>{};

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    final url = request.url.toString();
    requests.add(url);
    final resp = await _inner.send(request);
    bodies[url] = resp.body;
    return resp;
  }

  @override
  Future<Uint8List> sendBytes(LegadoRequestTemplate request) async {
    requests.add(request.url.toString());
    return _inner.sendBytes(request);
  }

  int responseBytes(String url) => bodies[url]?.length ?? 0;
}

Future<void> _probe(
  _RecTransport transport,
  LegadoRuntime runtime,
  RegisteredBookSource source,
) async {
  final page = await runtime.search(source, '斗破苍穹');
  if (page.items.isEmpty) return;
  final chosen = page.items.firstWhere(
    (b) => b.title.contains('斗破苍穹'),
    orElse: () => page.items.first,
  );
  await runtime.getBook(source, chosen.id, seedBook: chosen);
  await runtime.getChapters(source, chosen.id);
}

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';

  test('目录页抓取诊断（search→detail→catalog + 落盘）', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    if (!file.existsSync()) {
      fail('未找到 ' + rawPath);
      return;
    }
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    final filterSrc = Platform.environment['FILTER_SRC']?.trim() ?? '';
    final filters = filterSrc
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final outDir = Directory(r'D:\gz\日志\dump')..createSync(recursive: true);

    for (final s in sources) {
      if (filters.isNotEmpty && !filters.any((f) => '${s.name}'.contains(f))) {
        continue;
      }
      final registered = s.toRegisteredSource();
      final transport = _RecTransport();
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(transport: transport, sandbox: sandbox);
      final tag = s.name;
      // ignore: avoid_print
      print('\n===== $tag [${s.url}] =====');
      try {
        await _probe(transport, runtime, registered);
        // ignore: avoid_print
        print('  ${transport.requests.length} 次请求；未抛错（目录可能成功或空）');
      } catch (e) {
        // ignore: avoid_print
        print('  EXC: ${e.toString().replaceAll(RegExp(r'\s+'), ' ')}');
      }
      for (var i = 0; i < transport.requests.length; i++) {
        final u = transport.requests[i];
        // ignore: avoid_print
        print('  [$i] ${transport.responseBytes(u)}B $u');
      }
      // 落盘最近一次目录/详情页请求（tocUrl 解析目标，通常是最后一个请求），
      // 便于离线分析 chapterList 选择器匹配情况。
      final lastUrl = transport.requests.lastOrNull;
      final best = lastUrl != null && transport.bodies[lastUrl] != null
          ? transport.bodies[lastUrl]!
          : (transport.bodies.entries.toList()
                    ..sort((a, b) => a.value.length.compareTo(b.value.length)))
              .lastOrNull
              ?.value ??
              '';
      if (best.isNotEmpty) {
        final safe = tag.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final host = Uri.tryParse(s.url)?.host ?? '';
        final f = File('${outDir.path}\\$safe@$host.html');
        f.writeAsStringSync(_truncate(best, 400000));
        // ignore: avoid_print
        print('  -> dumped ${f.path} (${best.length}B)  last=$lastUrl');
      }
      runtime.close();
      await sandbox.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

String _truncate(String s, int n) => s.length <= n ? s : s.substring(0, n);