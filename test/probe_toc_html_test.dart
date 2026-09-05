// 诊断 noChapters 类源：search→detail→抓取目录页 HTML 落盘，
// 并用对应的 chapterList 规则联测匹配数，一次定位选择器问题。
// 运行：flutter test test/probe_toc_html_test.dart -j 1
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

const targets = [
  '猪猪书网',
  '新御宅屋',
  '猫眼看书',
  '全本同人',
  '久久小说',
  '荏染柔木',
  '追书神器',
  '四零二零',
];

String _slug(String name) =>
    name.replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]'), '');

Future<String> _rawGet(String url) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set(
    HttpHeaders.userAgentHeader,
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36',
  );
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  client.close(force: true);
  final utf8ok = utf8.decode(bytes, allowMalformed: true);
  if (!utf8ok.contains('\uFFFD')) return utf8ok;
  return utf8.decode(bytes, allowMalformed: true);
}

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('dump toc html + evaluate chapterList', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();
    Directory(r'D:\gz\日志\toc').createSync(recursive: true);
    for (final needle in targets) {
      for (final s in sources.where((s) => s.name.contains(needle)).take(1)) {
        final sandbox = FlutterLegadoJsSandbox();
        final rt = LegadoRuntime(sandbox: sandbox);
        try {
          final toc = s.rule('ruleToc') as Map? ?? const {};
          final listRule = '${toc['chapterList'] ?? ''}';
          print('== ${s.name} [${s.url}]');
          print('   chapterList=$listRule');
          final reg = s.toRegisteredSource();
          final page = await rt.search(reg, '斗破苍穹');
          if (page.items.isEmpty) {
            print('   searchEmpty');
            continue;
          }
          final b = page.items.firstWhere(
            (x) => x.title.contains('斗破苍穹'),
            orElse: () => page.items.first,
          );
          final detail = await rt.getBook(reg, b.id, seedBook: b);
          print('   detail=${detail.id}');
          final html = await _rawGet(detail.id);
          final slug = _slug(s.name);
          File('d:\\gz\\日志\\toc\\' + slug + '.html').writeAsStringSync(html);
          print('   saved(${html.length})');
          // 用真实规则联测 chapterList 匹配数
          try {
            final doc = LegadoRuleDocument.parse(html, Uri.parse(
                detail.id.startsWith('http') || detail.id.startsWith('//')
                    ? detail.id
                    : 'https://' + detail.id));
            final engine = LegadoRuleEngine(sandbox: sandbox);
            final matched = await engine.evaluateList(doc, null, listRule);
            print('   chapterList matches=${matched.length}');
            if (matched.isNotEmpty) {
              final name =
                  await engine.evaluateString(doc, matched.first, '${toc['chapterName'] ?? ''}');
              print('   first name=$name');
            }
          } catch (e) {
            print('   ruleErr=$e');
          }
        } catch (e) {
          print('   ERR $e');
        } finally {
          try {
            rt.close();
          } catch (_) {}
          await sandbox.dispose();
        }
      }
    }
    print('done');
  }, timeout: const Timeout(Duration(minutes: 6)));
}