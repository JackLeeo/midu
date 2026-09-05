// 实测 ruleBookInfo.tocUrl 在详情页上的提取结果（新御宅屋/荏染柔木）。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe tool/probe_tocurl.dart
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_rule_engine.dart';

Future<String> _get(String url) async {
  final c = HttpClient();
  c.connectionTimeout = const Duration(seconds: 15);
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36');
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  c.close(force: true);
  return utf8.decode(bytes, allowMalformed: true);
}

Future<void> main() async {
  const cases = [
    {
      'url': 'https://mm.xyuzhaiwu.xyz/novel/76899.html',
      'tocRule': r'class.lb_mulu chapterList@tag.li.0@a@href##/novel/(\d+)/(\d+).html##https://mm.xyuzhaiwu.xyz/novel/list/$1/1.html',
    },
    {
      'url': 'https://m.po18.xyz/novel/64730.html',
      'tocRule': '//*[@style="color:red;"]/@href',
    },
  ];
  for (final c in cases) {
    print('==== ${c['url']} ====');
    final html = await _get('${c['url']}');
    final doc = LegadoRuleDocument.parse(html, Uri.parse('${c['url']}'));
    final engine = LegadoRuleEngine(sandbox: null);
    // 原 tocUrl 规则
    try {
      final v = await engine.evaluateString(doc, null, '${c['tocRule']}', resolveUrl: true);
      print('  tocRule 原样 => "$v"');
    } catch (e) {
      print('  tocRule ERR=> $e');
    }
    // 用 lb_mulu 非复合类
    if (c['tocRule']!.contains(' ')) {
      final alt = r'class.lb_mulu@tag.li.0@a@href##/novel/(\d+)/(\d+).html##https://mm.xyuzhaiwu.xyz/novel/list/$1/1.html';
      try {
        final v = await engine.evaluateString(doc, null, alt, resolveUrl: true);
        print('  alt(lb_mulu@) => "$v"');
      } catch (e) { print('  alt ERR=> $e'); }
    }
  }
}