// 书旗 ocean API 直接探测：动态求值 tocUrl，再请求并解析 chapterList 规则。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_request.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  test('书旗 ocean chapterlist 探测', () async {
    final sandbox = FlutterLegadoJsSandbox();
    await sandbox.init();
    // 动态求值 tocUrl（timestamp/sign 由沙箱 MD5 重新生成）
    const detail = 'https://t.shuqi.com/book/6087446.html';
    final tocJs = '<js>\n'
        'var bookId=(baseUrl.match(/book\\/(\\d+)\\.html/)||baseUrl.match(/(\\d{3,})/)||[0,\'\'])[1];\n'
        'var encryptKey="37e81a9d8f02596e1b895d07c171d5c9",user_id="8000000",timestamp=parseInt((new Date).getTime()/1e3);\n'
        'var o=bookId+timestamp+user_id+encryptKey;\n'
        'var sign=java.md5Encode(o);\n'
        'var list={\'turl\':\'https://ocean.shuqireader.com/api/bcspub/qswebapi/book/chapterlist?_=&bookId=\'+bookId+\'&user_id=8000000&sign=\'+sign+\'&timestamp=\'+timestamp};list\n'
        '</js>';
    final jsRes = await sandbox.evalJs(tocJs, baseUri: Uri.parse(detail));
    // 对象完成值已被 evalJs JSON 序列化为字符串
    print('jsRes=$jsRes');
    String url;
    try {
      url = (jsonDecode(jsRes) as Map)['turl'] as String;
    } catch (_) {
      url = jsRes;
    }
    print('oceanUrl=$url');

    final inner = LegadoHttpTransport();
    final resp = await inner.send(LegadoRequestTemplate(
      url: Uri.parse(url),
      method: LegadoRequestMethod.get,
      headers: const {},
      charset: 'utf-8',
    ));
    print('bytes=${resp.body.length}');
    print('body head: ${resp.body.length > 400 ? resp.body.substring(0, 400) : resp.body}');
    final document = LegadoRuleDocument.parse(resp.body, resp.finalUri);
    final engine = LegadoRuleEngine(sandbox: sandbox);
    // 完整 chapterList 规则（含尾随 JS：java.put + result 完成值）
    const fullCl = '''\$.data.chapterList[0].volumeList<js>java.put('freeUrlPre',java.getString('\$.data.freeContUrlPrefix'));java.put('shortUrlPre',java.getString('\$.data.shortContUrlPrefix'));result</js>''';
    try {
      final contexts = await engine.evaluateList(document, null, fullCl);
      print('fullChapterList contexts=${contexts.length}');
      if (contexts.isNotEmpty) {
        final first = contexts.first;
        final cname = await engine.evaluateString(document, first, '''\$.chapterName''');
        final cUrl = await engine.evaluateString(document, first, '''<js>var l=java.getString('\$.contUrlSuffix');if(l.indexOf('reqEncryptParam')==-1){java.get('freeUrlPre')+l}else{java.get('shortUrlPre')+java.getString('\$.shortContUrlSuffix')}</js>''');
        print('first cname=$cname');
        print('first cUrl=$cUrl');
      }
    } catch (e) {
      print('fullChapterList evaluateList error: $e');
    }
    await sandbox.dispose();
    inner.close();
  });
}