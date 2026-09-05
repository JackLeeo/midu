// 离线验证：两源（新御宅屋 / 荏染柔木）的 ruleBookInfo.tocUrl 修改后，
// 在真实详情页 HTML 上能否解析出正确的列表页 URL。不联网。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/scratch_tocurl_fix.dart
import 'dart:io';

import 'package:midu/book_sources/legado/legado_rule_engine.dart';

Future<void> main() async {
  final engine = LegadoRuleEngine(sandbox: null);

  // 新御宅屋：tocUrl 由 `class.lb_mulu chapterList@...` 修正为 `class.lb_mulu@...`
  final xywDoc = LegadoRuleDocument.parse(
    File(r'D:\gz\日志\toc\新御宅屋.html').readAsStringSync(),
    Uri.parse('https://mm.xyuzhaiwu.xyz/novel/76899.html'),
  );
  const xywTocUrl =
      r'class.lb_mulu@tag.li.0@a@href##/novel/(\d+)/(\d+).html##https://mm.xyuzhaiwu.xyz/novel/list/$1/1.html';
  final xywList = await engine.evaluateString(xywDoc, null, xywTocUrl,
      resolveUrl: true);
  print('新御宅屋 tocUrl => $xywList');
  // 在列表页验证 chapterList 提取数
  final xywListDoc = LegadoRuleDocument.parse(
    File(r'D:\gz\日志\toc\xyw_list.html').readAsStringSync(),
    Uri.parse(xywList),
  );
  final xywChaps =
      await engine.evaluateList(xywListDoc, null, r'ul@li!-1@a');
  print('新御宅屋 list chapterList n=${xywChaps.length}');

  // 荏染柔木：tocUrl 保持 XPath `//*[@style="color:red;"]/@href`
  final po18Doc = LegadoRuleDocument.parse(
    File(r'D:\gz\日志\toc\荏染柔木.html').readAsStringSync(),
    Uri.parse('https://m.po18.xyz/novel/64730.html'),
  );
  const po18TocUrl = r'//*[@style="color:red;"]/@href';
  final po18List = await engine.evaluateString(po18Doc, null, po18TocUrl,
      resolveUrl: true);
  print('荏染柔木 tocUrl => $po18List');
  final po18ListDoc = LegadoRuleDocument.parse(
    File(r'D:\gz\日志\toc\po18_list.html').readAsStringSync(),
    Uri.parse(po18List),
  );
  final po18Chaps =
      await engine.evaluateList(po18ListDoc, null, r'ul@li!-1@a');
  print('荏染柔木 list chapterList n=${po18Chaps.length}');
}