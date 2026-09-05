// 诊断 noChapters 类源：search→detail→tocUrl链，打印目录页HTML中和章节选择器相关的片段。
// 运行：flutter test test/probe_toc_diag_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const _targets = ['猪猪书网'];

Future<String> _rawGet(String url, {String post = ''}) async {
  final client = HttpClient();
  final isPost = post.isNotEmpty;
  final uri = Uri.parse(url);
  final req = isPost
      ? await client.postUrl(uri)
      : await client.getUrl(uri);
  req.headers.set(
    HttpHeaders.userAgentHeader,
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36',
  );
  if (isPost) req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  if (isPost) req.add(utf8.encode(post));
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  client.close(force: true);
  return utf8.decode(bytes, allowMalformed: true);
}

void _ctx(String label, String body, String needle) {
  final idx = body.indexOf(needle);
  if (idx < 0) {
    print('  [$label] 未找到 "$needle" (len=${body.length})');
    return;
  }
  final start = (idx - 120).clamp(0, body.length);
  final end = (idx + 300).clamp(0, body.length);
  print('  [$label] >>> ${body.substring(start as int, end as int)}');
}

Future<void> _probe(LegadoRuntime rt, RegisteredBookSource src) async {
  final page = await rt.search(src, '斗破苍穹');
  if (page.items.isEmpty) {
    print('  searchEmpty');
    return;
  }
  final b = page.items.firstWhere((x) => x.title.contains('斗破苍穹'), orElse: () => page.items.first);
  print('  book=${b.title} url=${b.id}');
  final detail = await rt.getBook(src, b.id, seedBook: b);
  print('  detailId=${detail.id}');
  // 拿 tocUrl：详情页 HTML 里提取 downlink
  final detailHtml = await _rawGet(detail.id);
  _ctx('detail', detailHtml, 'downlink');
  _ctx('detail-list', detailHtml, '.list');
}

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('toc diagnostic', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    for (final needle in _targets) {
      for (final s in sources.where((s) => s.name.contains(needle)).take(1)) {
        final reg = s.toRegisteredSource();
        final sandbox = FlutterLegadoJsSandbox();
        final rt = LegadoRuntime(sandbox: sandbox);
        try {
          print('== ${s.name} :');
          try {
            await _probe(rt, reg);
          } catch (e) {
            print('  probeErr=$e');
          }
        } finally {
          try {
            rt.close();
          } catch (_) {}
          await sandbox.dispose();
        }
      }
    }
    print('done');
  }, timeout: const Timeout(Duration(minutes: 3)));
}