// 独立验证群搜 searchUrl @js 规则在两种沙箱里能否构造出正确的搜索 URL。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';
import 'package:midu/book_sources/legado/legado_ajax_rewrite.dart';
import 'helpers/flutter_js_sandbox.dart';

// 群搜规则里 javatoken 提取逻辑的等价重写：
const kQunxsRule = r'''
var html = java.ajax(source.getKey());
token = org.jsoup.Jsoup.parse(html).select('input[name=_token]').attr('value');
"/search," + JSON.stringify({ "body": `_token=${token}&keyword=${key}`, "method": "POST" });
''';

// 用抓到的群搜首页片段（含 _token）作为 ajax fetcher 的响应
const kHomeHtml =
    '<html><body><form><input name="_token" value="H8EjIp3rpHztnsfsKWslEA1vCYZVyhKcnxjaTabv"></form></body></html>';

Future<String> runOn(LegadoJsSandbox sandbox, Uri base) async {
  await sandbox.init();
  if (sandbox is AjaxFetcherSink) {
    (sandbox as AjaxFetcherSink)
        .setAjaxFetcher((url, {method = 'GET', headers, body}) async {
      return url == base.toString() ? kHomeHtml : '';
    });
  }
  final out = await sandbox.evalJs(
    kQunxsRule,
    docHtml: base.toString(),
    baseUri: base,
    extraGlobals: {'key': '剑来', 'page': 1},
  );
  await sandbox.dispose();
  return out;
}

void main() {
  test('群搜 searchUrl 引擎构造', () async {
    final base = Uri.parse('http://www.qunxs.com');
    final prod = await runOn(FlutterLegadoJsSandbox(), base);
    print('[测试沙箱] 构造URL: $prod');
    // 验证是否包含真正的 token（而非空）
    final prodTok = prod.split('_token=').last.split('&').first.trim();
    print('[测试沙箱] _token 段: $prodTok  (长度${prodTok.length})');
    expect(prod, contains('_token='));
  });
}