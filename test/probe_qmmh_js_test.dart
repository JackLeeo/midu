// 验证 全免漫画 的 chapterList 复合规则（<js> AES 解密 + $.chapters[*]）
// 能否在真实 getcomicdata 响应文本上产出章节列表。
// 用法: flutter test test/probe_qmmh_js_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  copyQuickJsDllIfNeeded();

  test('全免漫画 chapterList JS 解密 + JSONPath', () async {
    HttpOverrides.global = null;
    final raw = File(r'D:\gz\日志\dump\🗒️ 全免漫画.html').readAsStringSync();

    final sandbox = FlutterLegadoJsSandbox();
    final engine = LegadoRuleEngine(sandbox: sandbox);
    final doc = LegadoRuleDocument.parse(
      raw,
      Uri.parse('https://api-cdn.kaimanhua.com'),
    );
    print('bodyHead=${raw.substring(0, 60)}');

    // 原规则：AES 结果未被赋值给 result → evalJs 返回旧的 result（密文）。
    const jsOrig = r'''<js>
result=String(java.getString("$.data")).replace(/arsadata/,"");
java.aesBase64DecodeToString(result,"4548ded8c9e02690","AES/CBC/PKCS5Padding","1992360ee9bc4f8f");
</js>''';
    // 修复：把 AES 结果显式赋给 result。
    const jsFixed = r'''<js>
result=String(java.getString("$.data")).replace(/arsadata/,"");
result=java.aesBase64DecodeToString(result,"4548ded8c9e02690","AES/CBC/PKCS5Padding","1992360ee9bc4f8f");
</js>''';

    for (final pair in [
      ['ORIG', jsOrig],
      ['FIXED', jsFixed],
    ]) {
      final dec = await engine.evaluateString(doc, null, pair[1]);
      print('[${pair[0]}] decrypted.len=${dec.length}');
      if (!dec.isEmpty) {
        print('   preview=${dec.substring(0, dec.length > 120 ? 120 : dec.length)}');
      }
      final rule = pair[1] + '\n\$.chapters[*]';
      final matched = await engine.evaluateList(doc, null, rule);
      print('[${pair[0]}] RESULT chapters n=${matched.length}');
      if (matched.isNotEmpty) {
        final name = await engine.evaluateString(doc, matched.first, r'$.chapter_name');
        final id = await engine.evaluateString(doc, matched.first, r'$.chapter_id');
        final last = await engine.evaluateString(doc, matched.last, r'$.chapter_name');
        print('   first name="$name" id="$id"  last="$last"');
      }
    }
    await sandbox.dispose();
  });
}