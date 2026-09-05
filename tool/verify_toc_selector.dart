// 离线验证：在已抓取的 toc HTML 上用若干候选 chapterList 规则评估匹配数，
// 选出能正确命中章节列表的选择器。不联网。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe tool/verify_toc_selector.dart
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_rule_engine.dart';

Future<void> main() async {
  const cases = <Map<String, Object>>[
    {
      'html': r'D:\gz\日志\toc\zzs_detail.html',
      'base': 'http://www.zzs5.net/book/18966/',
      'candidates': [
        '.list@dd@a',
        'div.list@dd@a',
        'id.downlink@a.0@href',
        'id.downlink@a.0@text',
      ],
    },
    {
      'html': r'D:\gz\日志\toc\新御宅屋.html',
      'base': 'https://www.51nw.com/novel/76899/11870090.html',
      'candidates': ['class.lb_mulu@ul@li@a', 'class.chapterList@ul@li@a'],
    },
    {
      'html': r'D:\gz\日志\toc\全本同人.html',
      'base': 'http://qbtr.cc/tongren/8595/1.html',
      'candidates': [
        'class.book_list clearfix@class.clearfix@tag.a',
        'class.book_list@ul@li@a',
        'class.book_list@tag.a',
        'class.book_list clearfix@ul@li@a',
      ],
    },
    {
      'html': r'D:\gz\日志\toc\荏染柔木.html',
      'base': 'https://m.po18.xyz/novel/76899/11870090.html',
      'candidates': ['tag.div.0@tag.ul@tag.li!-1@a', 'class.lb_mulu@ul@li@a'],
    },
    {
      'html': r'D:\gz\日志\toc\新御宅屋.html',
      'base': 'https://mm.xyuzhaiwu.xyz/novel/76899.html',
      'candidates': ['ul@li!-1@a', 'class.lb_mulu@ul@li@a', 'class.article_info_td@tag.a'],
    },
    {
      'html': r'D:\gz\日志\toc\新御宅屋_list.html',
      'base': 'https://mm.xyuzhaiwu.xyz/novel/list/76899/1.html',
      'candidates': ['ul@li!-1@a', 'class.lb_mulu@ul@li@a'],
    },
    {
      'html': r'D:\gz\日志\toc\久久小说.html',
      'base': 'http://m.9191net.com/soft/3/2886.html',
      'candidates': [
        'class.ablum_read',
        'class.ablum_read@tag.a',
        'class.downButton@title&&class.downButton@href',
        'id.down_div@a',
      ],
    },
    {
      'html': r'D:\gz\日志\toc\xyw_list.html',
      'base': 'https://mm.xyuzhaiwu.xyz/novel/list/76899/1.html',
      'candidates': ['ul@li!-1@a', 'ul@li@a'],
    },
    {
      'html': r'D:\gz\日志\toc\po18_list.html',
      'base': 'https://m.po18.xyz/novel/list/64730/1.html',
      'candidates': ['ul@li!-1@a', 'ul@li@a!-1', 'ul@li@a'],
    },
    {
      'html': r'D:\gz\日志\dump\🌐 随心看网.html',
      'base': 'https://m.suixkan.com/b/28504.html',
      'candidates': [
        'class.sumchapter@a@href',
        'class.sumchapter@a',
        'class.catalog_ls@li@a',
        'class.catalog_ls@li',
      ],
    },
    {
      'html': r'D:\gz\日志\suixkan_catalog.html',
      'base': 'https://m.suixkan.com/c/28504.html',
      'candidates': [
        'class.catalog_ls@li@a',
        'class.catalog_ls@li',
        'class.sumchapter@a@href',
        'class.catalog_ls@li@a@href',
        'class.catalog_ls@li@a@text',
      ],
    },
    {
      'html': r'D:\gz\日志\suixkan_search.html',
      'base': 'https://m.suixkan.com/s/1.html',
      'candidates': [
        'class.v-list-item',
        'class.v-list-item@onclick',
        '##="newWebView\\((.?[\'])([^\']+)[\'][]*###',
        'class.v-title@text',
        'class.v-cover@img@src',
      ],
    },
  ];

  for (final c in cases) {
    final doc = LegadoRuleDocument.parse(
      File('${c['html']}').readAsStringSync(),
      Uri.parse('${c['base']}'),
    );
    final engine = LegadoRuleEngine(sandbox: null);
    print('==== ${c['html'].toString().split('\\').last} ====');
    for (final r in (c['candidates'] as List)) {
      try {
        final matched = await engine.evaluateList(doc, null, '$r');
        var firstName = '';
        var titleAttr = '';
        if (matched.isNotEmpty) {
          firstName = await engine.evaluateString(doc, matched.first, 'text');
          titleAttr = await engine.evaluateString(doc, matched.first, 'title');
        }
        var lastName = '';
        if (matched.isNotEmpty) {
          lastName =
              await engine.evaluateString(doc, matched.last, 'text');
        }
        print('  [$r] n=${matched.length} first="$firstName" title="$titleAttr" last="$lastName"');
      } catch (e) {
        print('  [$r] ERR=$e');
      }
    }
    print('');
  }
}