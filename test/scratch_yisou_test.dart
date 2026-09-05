import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_rule_engine.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  copyQuickJsDllIfNeeded();
  test('宜搜 chapterList JS 沙箱执行', () async {
    const chapterListJs = r'''<js>
  //showjname设置章节名显示卷名true or false
  let obj = {showjname: false}
  let $ = JSON.parse(String(result))
  let array = []
  $.volumes.forEach((booklet) => {
  	  java.put('jname',booklet.name)
    array.push({ 
    	   name:'◆◇'+String(booklet.name)+'◇◆',
    	   voltype:true
    	 })
    booklet.chapters.forEach((chapter) => {
href='http://api.ieasou.com/api/bookapp/chargeChapter.m?a=1&autoBuy=0&cid=eef_easou_book&version=002&os=android&udid=1c5b2618a57a0848e2510649dc1e03896f462284&appverion=1122&ch=blf1298_12337_001&session_id=-nEvkqSq_9ZyORN5OoVOOzJ&dzh=1&scp=0&appid=10001&utype=0&rtype=3&pushid=f97b7f81a269472c07708277b7c40b4f&ptype=5&gender=0&userInitPay=3&birt=1658424532472&instime=1658424529924&instId=1658424529924&chType=3&bidType=0&recSw=1&appType=0&gid='+java.get('gid')+'&nid='+chapter.nid+'&sort='+chapter.sort+'&gsort=0&sgsort=0&sequence=4&chapter_name='+chapter.chapter_name
  array.push({
        name: !java.get('jname')?chapter.chapter_name:((obj.showjname?'※'+java.get('jname')+'※ ':'').padStart(3,''))+chapter.chapter_name,
        url: href,
        time:"本章字数:"+String(chapter.wordCount)+"字",
        voltype:false
      })
    })
  })
  array
</js>''';

    // 构造简化的 toc 响应 JSON（含一个卷几章即可）
    final tocJson = jsonEncode({
      'novelName': '',
      'chapters': <Object?>[],
      'volumes': [
        {
          'name': '第一卷',
          'chapters': [
            {
              'chapter_name': '第1章 野外奇遇',
              'wordCount': 1596,
              'nid': 51235,
              'sort': 1,
            },
            {
              'chapter_name': '第2章 死人变活',
              'wordCount': 3394,
              'nid': 51235,
              'sort': 2,
            },
          ],
        },
      ],
    });

    // 复用生产规则引擎：sandbox 共享，注入 gid 变量
    final sb = FlutterLegadoJsSandbox();
    final rt = LegadoRuntime(sandbox: sb);
    sb.putSourceVar('gid', '100051235');
    await sb.init();
    final engine = LegadoRuleEngine(sandbox: sb);
    final doc = LegadoRuleDocument.parse(tocJson, Uri.parse('http://api.ieasou.com'));
    // ignore: avoid_print
    print('document.rawBody len = ${doc.rawBody.length}');
    final list = await engine.evaluateList(doc, null, chapterListJs);
    // ignore: avoid_print
    print('章节条目数 = ${list?.length}');
    for (final it in list == null ? const <Object>[] : (list as List).take(4)) {
      // ignore: avoid_print
      print('  item keys=${(it as Map).keys.toList()}');
    }
    rt.close();
    await sb.dispose();
  });
}