// LegadoRuntime 全链路端到端测试：用 mock transport 模拟真实书源页面，
// 验证 search → getBook → getChapters → getChapterContent 完整链路，
// 特别是正文（ruleContent.content）能否被正确提取。
import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

import 'helpers/flutter_js_sandbox.dart';

/// 内存 transport：按请求 URL 关键字返回预置 HTML。
class _FixtureTransport implements LegadoTransport {
  _FixtureTransport({required this.allowJsInHeaders});

  final bool allowJsInHeaders;
  final List<Uri> requested = [];

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    requested.add(request.url);
    final path = request.url.path;
    final String body;
    if (path.contains('search')) {
      body = _searchPage;
    } else if (path.contains('book/') && !path.contains('chapter')) {
      body = _detailPage;
    } else if (path.contains('toc')) {
      body = _tocPage;
    } else if (path.contains('chapter')) {
      body = _contentPage;
    } else {
      body = '<html><body>404</body></html>';
    }
    return LegadoResponse(body: body, finalUri: request.url);
  }

  static const _searchPage = '''
<!DOCTYPE html><html><head><title>搜索</title></head><body>
<div class="grid"><table>
  <tr><th>书名</th><th>作者</th></tr>
  <tr><td class="even"><a href="/book/1.html">斗破苍穹</a></td>
      <td class="odd">天蚕土豆</td></tr>
</table></div>
</body></html>
''';

  static const _detailPage = '''
<!DOCTYPE html><html><head><title>详情</title></head><body>
<div class="detail_right"><h1>斗破苍穹</h1></div>
<div class="small"><span>作者：</span><a href="/author/1.html">天蚕土豆</a></div>
<div class="showInfo"><p>这里是简介内容。</p></div>
<a class="toc" href="/toc.html">查看目录</a>
</body></html>
''';

  static const _tocPage = '''
<!DOCTYPE html><html><head><title>目录</title></head><body>
<div id="list"><dl><dd><a href="/chapter/1.html">第一章 陨落的天才</a></dd>
<dd><a href="/chapter/2.html">第二章 斗之气</a></dd></dl></div>
</body></html>
''';

  static const _contentPage = '''
<!DOCTYPE html><html><head><title>正文</title></head><body>
<div id="content1">
<p>斗破苍穹第一段正文内容。</p>
<p>第二段正文内容。</p>
<p>第三段正文内容。</p>
</div>
</body></html>
''';
}

Map<String, dynamic> _sourceJson() => {
  'bookSourceName': '端到端测试源',
  'bookSourceUrl': 'https://fixture.test',
  'bookSourceType': 0,
  'searchUrl': '/search?q={{key}}',
  'ruleSearch': {
    'bookList': '.grid@tr!0',
    'name': 'a@text',
    'author': '.odd@text',
    'bookUrl': 'a@href',
  },
  'ruleBookInfo': {
    'name': 'h1@text',
    'author': '.small a@text',
    'tocUrl': 'a.toc@href',
  },
  'ruleToc': {
    'chapterList': '#list dd@a',
    'chapterName': 'text',
    'chapterUrl': 'href',
  },
  'ruleContent': {'content': 'id.content1@textNodes'},
};

void main() {
  test('全链路：search→detail→toc→content 正文非空', () async {
    copyQuickJsDllIfNeeded();
    final sandbox = FlutterLegadoJsSandbox();
    final runtime = LegadoRuntime(
      transport: _FixtureTransport(allowJsInHeaders: false),
      sandbox: sandbox,
    );
    try {
      final source = LegadoBookSource.fromJson(_sourceJson());
      final registered = source.toRegisteredSource();
      final page = await runtime.search(registered, '斗破苍穹');
      expect(page.items, isNotEmpty);
      final book = page.items.first;
      expect(book.title, '斗破苍穹');
      expect(book.author, contains('天蚕土豆'));

      final detail = await runtime.getBook(registered, book.id);
      expect(detail.title, '斗破苍穹');

      final chapters = await runtime.getChapters(registered, detail.id);
      expect(chapters, hasLength(2));
      expect(chapters.first.title, contains('陨落的天才'));

      final content = await runtime.getChapterContent(
        registered,
        bookId: detail.id,
        chapterId: chapters.first.id,
      );
      expect(content.content.trim(), isNotEmpty);
      expect(content.content, contains('斗破苍穹第一段正文内容'));
      expect(content.content, contains('第三段正文内容'));
      // 不含 HTML 标签（textNodes 提取纯文本）
      expect(content.content, isNot(contains('<p>')));
    } finally {
      runtime.close();
      await sandbox.dispose();
    }
  });
}
