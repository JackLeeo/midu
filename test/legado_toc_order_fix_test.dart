// 目录顺序修复回归测试（离线，不触网）：
//  1) zzs5「公告置顶+正序主体+尾部回跳第33章」混合目录 → 稳定按序号升序恢复；
//  2) 常见「正序」目录不变；
//  3) 整表倒序目录整体反转；
//  4) getChapters 对「空翻页/无新章节页」提前终止（不再空转 20 跳，修复卡顿）。
// 运行: flutter test test/legado_toc_order_fix_test.dart -j 1
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

import 'helpers/flutter_js_sandbox.dart';

/// 离线 transport：按 URL 返回预设 HTML，模拟分页目录。
class _FakeTransport implements LegadoTransport {
  final Map<String, String> byUrl;
  int requestCount = 0;

  _FakeTransport(this.byUrl);

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    requestCount++;
    final url = request.url.toString();
    final body = byUrl[url] ?? byUrl.values.first;
    return LegadoResponse(body: body, finalUri: request.url);
  }

  @override
  Future<Uint8List> sendBytes(LegadoRequestTemplate request) async {
    final url = request.url.toString();
    final body = byUrl[url] ?? byUrl.values.first;
    return Uint8List.fromList(utf8.encode(body));
  }
}

LegadoBookSource _src() => LegadoBookSource.fromJson({
      'bookSourceUrl': 'https://www.zzs5.net',
      'bookSourceName': '测试猪猪',
      'searchUrl': 'https://www.zzs5.net/index.php?q={{key}}',
      'ruleSearch': {
        'bookList': '.bookd@li',
        'bookUrl': 'a@href',
        'name': 'a@text',
      },
      'ruleBookInfo': {
        'name': 'h1@text',
        'tocUrl': '', // 关键：目录页即详情页（bookId）
      },
      'ruleToc': {
        'chapterList': '.list@dd@a',
        'chapterName': 'text',
        'chapterUrl': 'href',
      },
      'ruleContent': {'content': '#content@html'},
    });

/// 章节页 HTML 无法提供时用详情页作为目录页（tocUrl 为空 → bookId）。
String _detailHtml(String bookId) {
  final chapters = <String>[];
  // 观察到的 zzs5 混合形态：公告置顶 → 正序主体(34..N) → 尾部回跳第33章。
  chapters.add('''<dd><a href="$bookId/11326899.html">关于一点细节！（临时公告，下午删除）</a></dd>''');
  for (var i = 34; i <= 40; i++) {
    chapters.add('''<dd><a href="$bookId/${11337962 + (i - 34) * 11061}.html">第${_cn(i)}章 模拟仙生${i}</a></dd>''');
  }
  chapters.add('''<dd><a href="$bookId/11313439.html">第三十三章 本师伯毕竟不是什么大恶人</a></dd>''');
  return '''
<html><body>
<div class="bookd"><h1>我师兄实在太稳健了</h1></div>
<div class="list"><dl>${chapters.join('\n')}</dl></div>
</body></html>''';
}

/// 生成「第三十四章 / 第四十章」形式的中文章节号（34..40 → 三十四..四十）。
String _cn(int i) {
  const units = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
  if (i < 10) return units[i];
  final tens = i ~/ 10;
  final one = i % 10;
  final tensWord = tens == 1 ? '十' : '${units[tens]}十';
  return one == 0 ? tensWord : '$tensWord${units[one]}';
}

void main() {
  copyQuickJsDllIfNeeded();

  test('目录顺序归一：公告置顶+正序+尾部回跳 → 升序恢复', () async {
    final src = _src();
    final detail = 'https://www.zzs5.net/book/37326/';
    final fake = _FakeTransport({
      detail: _detailHtml(detail),
    });
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox, transport: fake);
    try {
      final reg = src.toRegisteredSource();
      final chapters = await runtime.getChapters(reg, detail);
      // ignore: avoid_print
      print('  实际章节顺序: ${chapters.map((c) => c.title).join(' | ')}');
      expect(chapters.length, 9, reason: '公告+34..40+33 = 9 章');
      // 序号升序：公告(无序号，保持置顶) → 33 → 34 → 35 → 36 → 37 → 38 → 39 → 40
      expect(chapters.first.title, contains('公告'));
      expect(chapters[1].title, contains('第三十三章'));
      expect(chapters[2].title, contains('第三十四章'));
      expect(chapters.last.title, contains('第四十章'));
      // 全部 id 递增且无重复
      for (var i = 1; i < chapters.length; i++) {
        expect(chapters[i].id != chapters[i - 1].id, isTrue);
      }
    } finally {
      runtime.close();
      await sandbox.dispose();
    }
  });

  test('正序目录不变（公告在页首属正常源，不误伤）', () async {
    final src = LegadoBookSource.fromJson({
      'bookSourceUrl': 'https://a.example.com',
      'bookSourceName': '正序源',
      'searchUrl': 'https://a.example.com/s?q={{key}}',
      'ruleSearch': {'bookList': '.r@li', 'bookUrl': 'a@href', 'name': 'a@text'},
      'ruleBookInfo': {'name': 'h1@text'},
      'ruleToc': {
        'chapterList': '.list@dd@a',
        'chapterName': 'text',
        'chapterUrl': 'href',
      },
      'ruleContent': {'content': '#c@html'},
    });
    final body = (String base) => '''
<html><body>
<div class="list"><dl>
<dd><a href="$base/1.html">序章 楔子</a></dd>
<dd><a href="$base/2.html">第一章 开始</a></dd>
<dd><a href="$base/3.html">第二章 出发</a></dd>
<dd><a href="$base/4.html">第三章 抵达</a></dd>
</dl></div></body></html>''';
    final fake = _FakeTransport({'https://a.example.com/book/1/': body('https://a.example.com/book/1/')});
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox, transport: fake);
    try {
      final chapters = await runtime.getChapters(src.toRegisteredSource(), 'https://a.example.com/book/1/');
      expect(chapters.length, 4);
      expect(chapters[0].title, contains('序章'));
      expect(chapters[3].title, contains('第三章'));
    } finally {
      runtime.close();
      await sandbox.dispose();
    }
  });

  test('整表倒序目录整体反转', () async {
    final src = _src();
    final base = 'https://www.zzs5.net/book/37326/';
    final body = '''
<html><body><div class="list"><dl>
<dd><a href="$base/40.html">第四十章 末</a></dd>
      <dd><a href="$base/39.html">第三十九章</a></dd>
      <dd><a href="$base/38.html">第三十八章</a></dd>
      <dd><a href="$base/37.html">第三十七章</a></dd>
      <dd><a href="$base/36.html">第三十六章</a></dd>
      <dd><a href="$base/35.html">第三十五章</a></dd>
      <dd><a href="$base/34.html">第三十四章</a></dd>
</dl></div></body></html>''';
    final fake = _FakeTransport({base: body});
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox, transport: fake);
    try {
      final chapters = await runtime.getChapters(src.toRegisteredSource(), base);
      expect(chapters.length, 7);
      expect(chapters.first.title, contains('第三十四章'));
      expect(chapters.last.title, contains('第四十章'));
    } finally {
      runtime.close();
      await sandbox.dispose();
    }
  });

  test('空翻页提前终止（不再空转 20 跳）', () async {
    final src = LegadoBookSource.fromJson({
      'bookSourceUrl': 'https://p.example.com',
      'bookSourceName': '分页源',
      'searchUrl': 'https://p.example.com/s?q={{key}}',
      'ruleSearch': {'bookList': '.r@li', 'bookUrl': 'a@href', 'name': 'a@text'},
      'ruleBookInfo': {'name': 'h1@text'},
      'ruleToc': {
        'chapterList': '.list@dd@a',
        'chapterName': 'text',
        'chapterUrl': 'href',
        'nextTocUrl': 'a.next@href',
      },
      'ruleContent': {'content': '#c@html'},
    });
    final base = 'https://p.example.com/book/1/';
    final body = (String url) => '''
<html><body><div class="list"><dl>
<dd><a href="$base/1.html">第一章</a></dd>
<dd><a href="$base/2.html">第二章</a></dd>
</dl><a class="next" href="$base/page2">下一页</a></div></body></html>''';
    // page2 与之后页面：无新章节（空翻页占位）
    final fake = _FakeTransport({
      base: body(base),
      '$base' 'page2': '<html><body><div class="list"><dl></dl><a class="next" href="$base/page2">下一页</a></div></body></html>',
    });
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(sandbox: sandbox, transport: fake);
    try {
      final chapters = await runtime.getChapters(src.toRegisteredSource(), base);
      expect(chapters.length, 2);
      expect(fake.requestCount, lessThanOrEqualTo(2), reason: '空翻页页应提前结束，不再请求第 2 页后的空页');
    } finally {
      runtime.close();
      await sandbox.dispose();
    }
  });
}