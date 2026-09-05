import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/flutter_js_sandbox.dart';

const kGuowenSearch = r'''
@js:

var url=source.getKey();

var html = java.ajax(url);

token = org.jsoup.Jsoup.parse(html).select('input[name=_token]').attr('value');

url+"/search,"+JSON.stringify({
  "body": `_token=${token}&keyword=${key}&searchtype=articlename`,
  "method": "post"
})''';

void main() {
  test('果文 searchUrl evaljs', () async {
    copyQuickJsDllIfNeeded();
    final sb = FlutterLegadoJsSandbox();
    await sb.init();
    // 用 raw 字符串保留 ${token} 模板表达式（普通 Dart 字符串会把 ${...} 插值掉）
    final tpl = await sb.evalJs(r'''@js: var token="abc"; var url="http://x"; url+"/search,"+JSON.stringify({"body": `_token=${token}&keyword=${key}`})''', baseUri: Uri.parse('http://www.guowx.com'), extraGlobals: const {'key': '诡异'});
    // ignore: avoid_print
    print('[模板隔离] tpl=$tpl err=${sb.lastError}');
    print('[模板隔离] compileFailed=${sb.debugCompileFailed}');
    print('[模板隔离] REWRITTEN=[${sb.debugLastRewritten}]');
    final wrapped = sb.debugLastWrapped ?? '';
    final lines = wrapped.split('\n');
    if (lines.length > 325) {
      print('[隔离 WRAP 320-334]:');
      for (var i = 320; i < 335 && i < lines.length; i++) {
        // ignore: avoid_print
        print('${i + 1}: ${lines[i]}');
      }
    }
    await sb.dispose();
  });
}