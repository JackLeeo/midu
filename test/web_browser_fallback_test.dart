// M7 `@webBrowser:`/`@webView:` 浏览器兜底专项测试：
// 1. WebBrowserRoute 前缀识别与剥离
// 2. LegadoRequestTemplate 的 webView/webBrowser 选项 → useWebView
// 3. WebBrowserPool：并发上限 / 空闲复用 / 超时销毁补位 / closeAll
// 4. UnavailableWebBrowserGateway 平台降级文案
// 5. LegadoRuntime 路由：@webBrowser 前缀与 webView:true 选项都走池而非传输层
// 6. SSRF：WebView 出站 URL 先过 BookSourceNetworkPolicy.validate，私网目标被拒

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/services/webview_guard/web_browser_fallback.dart';

import 'helpers/flutter_js_sandbox.dart';

/// 公共测试主机（公网 IP 字面量，避免 DNS 真实解析造成的网络依赖）。
const String _publicHost = '93.184.216.34';

LegadoBookSource _legadoSource(String searchUrl) {
  return LegadoBookSource.fromJson({
    'bookSourceName': '浏览器兜底源',
    'bookSourceUrl': 'https://$_publicHost',
    'bookSourceType': 0,
    'searchUrl': searchUrl,
    'ruleSearch': {
      'bookList': '.book-list>.book',
      'name': 'h3 a@text',
      'author': 'p@text',
      'bookUrl': 'h3 a@href',
    },
    'ruleToc': {
      'chapterList': 'dd a',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
    'ruleContent': {'content': '.content@textNodes'},
  });
}

const String _searchPage = '''
<!DOCTYPE html><html><body>
<div class="book-list">
  <div class="book"><h3><a href="https://$_publicHost/book/1">浏览器结果书A</a></h3><p>作者甲</p></div>
  <div class="book"><h3><a href="https://$_publicHost/book/2">浏览器结果书B</a></h3><p>作者乙</p></div>
</div>
</body></html>
''';

/// 记录被打开 URL 的假网关。
class _RecordingGateway implements WebBrowserGateway {
  _RecordingGateway({this.body});

  final String? body;
  final List<Uri> opened = [];
  int disposed = 0;
  int openCount = 0;

  @override
  Future<WebBrowserDocument> open(WebBrowserRequest request) async {
    openCount++;
    opened.add(request.url);
    return WebBrowserDocument(
      finalUri: request.url,
      body: body ?? _searchPage,
    );
  }

  @override
  Future<void> dispose() async {
    disposed++;
  }
}

/// 永不完成的网关（超时测试用）。
class _HangingGateway implements WebBrowserGateway {
  _HangingGateway(this.disposed);

  final _RecordingGateway disposed;

  @override
  Future<WebBrowserDocument> open(WebBrowserRequest request) {
    return Completer<WebBrowserDocument>().future;
  }

  @override
  Future<void> dispose() async {
    disposed.disposed++;
  }
}

/// 记录是否收到请求的内存传输（浏览器路由测试断言它不该被触达）。
class _RecordingTransport implements LegadoTransport {
  final List<Uri> sent = [];

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    sent.add(request.url);
    return LegadoResponse(body: '', finalUri: request.url);
  }

  @override
  Future<Uint8List> sendBytes(LegadoRequestTemplate request) async {
    return Uint8List(0);
  }
}

void main() {
  group('WebBrowserRoute 前缀识别', () {
    test('大小写不敏感的 @webBrowser:/@webView: 前缀剥离', () {
      expect(
        WebBrowserRoute.isBrowserUrl('@webBrowser:https://$_publicHost/a'),
        isTrue,
      );
      expect(
        WebBrowserRoute.isBrowserUrl(' @webbrowser: https://$_publicHost/a '),
        isTrue,
      );
      expect(
        WebBrowserRoute.isBrowserUrl('@WEBVIEW:https://$_publicHost/a'),
        isTrue,
      );
      expect(WebBrowserRoute.isBrowserUrl('https://$_publicHost/a'), isFalse);

      expect(
        WebBrowserRoute.stripBrowserPrefix('@webBrowser:https://a.test/x'),
        'https://a.test/x',
      );
      expect(
        WebBrowserRoute.stripBrowserPrefix('@webView:https://a.test/x'),
        'https://a.test/x',
      );
      expect(WebBrowserRoute.stripBrowserPrefix('https://a.test/x'), isNull);
    });
  });

  group('LegadoRequestTemplate 浏览器选项', () {
    test('webView:true / webBrowser:true（bool 与字符串）→ useWebView', () {
      Uri base() => Uri.parse('https://$_publicHost');

      final boolFlag = LegadoRequestTemplate.parse(
        'https://$_publicHost/a,{"webView":true}',
        baseUri: base(),
      );
      expect(boolFlag.useWebView, isTrue);

      final stringFlag = LegadoRequestTemplate.parse(
        'https://$_publicHost/a,{"webBrowser":"true"}',
        baseUri: base(),
      );
      expect(stringFlag.useWebView, isTrue);

      final off = LegadoRequestTemplate.parse(
        'https://$_publicHost/a,{"webView":false}',
        baseUri: base(),
      );
      expect(off.useWebView, isFalse);

      final plain = LegadoRequestTemplate.parse(
        'https://$_publicHost/a',
        baseUri: base(),
      );
      expect(plain.useWebView, isFalse);

      final forced = LegadoRequestTemplate.parse(
        'https://$_publicHost/a',
        baseUri: base(),
        forceWebView: true,
      );
      expect(forced.useWebView, isTrue);
    });
  });

  group('WebBrowserPool', () {
    test('并发上限：同时存活实例不超过 maxConcurrent 且全部完成', () async {
      var created = 0;
      final pool = WebBrowserPool(
        createGateway: () {
          created++;
          return _RecordingGateway();
        },
        maxConcurrent: 2,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(pool.closeAll);

      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          pool.open(
            WebBrowserRequest(url: Uri.parse('https://$_publicHost/$i')),
          ),
      ]);
      expect(results, hasLength(4));
      expect(created, 2, reason: '4 并发、上限 2 时应只有 2 个实例被创建');
    });

    test('空闲复用：顺序请求复用同一网关', () async {
      var created = 0;
      final pool = WebBrowserPool(
        createGateway: () {
          created++;
          return _RecordingGateway();
        },
        maxConcurrent: 2,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(pool.closeAll);

      await pool.open(WebBrowserRequest(url: Uri.parse('https://$_publicHost/a')));
      await pool.open(WebBrowserRequest(url: Uri.parse('https://$_publicHost/b')));
      expect(created, 1, reason: '顺序请求应复用空闲网关');
    });

    test('超时：销毁卡死网关并补位，不把坏实例留在池里复用', () async {
      final holder = _RecordingGateway();
      var created = 0;
      final pool = WebBrowserPool(
        createGateway: () {
          created++;
          return _HangingGateway(holder);
        },
        maxConcurrent: 1,
        timeout: const Duration(milliseconds: 60),
      );
      addTearDown(pool.closeAll);

      await expectLater(
        pool.open(
          WebBrowserRequest(url: Uri.parse('https://$_publicHost/slow')),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(holder.disposed, 1, reason: '超时网关应被销毁');

      // 下一次 open 应创建全新网关并成功。
      final pool2 = WebBrowserPool(
        createGateway: () {
          created++;
          return _RecordingGateway();
        },
        maxConcurrent: 1,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(pool2.closeAll);
      final doc = await pool2.open(
        WebBrowserRequest(url: Uri.parse('https://$_publicHost/ok')),
      );
      expect(doc.body, _searchPage);
      expect(created, 2, reason: '首池 1 个卡死实例被销毁后，二次请求创建全新实例');
    });

    test('closeAll：归还空闲网关全部销毁，等待者收到关闭异常', () async {
      final pool = WebBrowserPool(
        createGateway: _RecordingGateway.new,
        maxConcurrent: 1,
        timeout: const Duration(seconds: 5),
      );
      await pool.open(WebBrowserRequest(url: Uri.parse('https://$_publicHost/a')));
      await pool.closeAll();

      await expectLater(
        pool.open(WebBrowserRequest(url: Uri.parse('https://$_publicHost/b'))),
        throwsA(isA<WebBrowserUnavailableException>()),
      );
    });
  });

  group('UnavailableWebBrowserGateway', () {
    test('无 WebView 平台返回明确降级文案', () async {
      const gateway = UnavailableWebBrowserGateway();
      await expectLater(
        gateway.open(WebBrowserRequest(url: Uri.parse('https://$_publicHost/a'))),
        throwsA(
          isA<WebBrowserUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('不支持 @webBrowser'),
          ),
        ),
      );
    });
  });

  group('LegadoRuntime 浏览器兜底路由', () {
    setUpAll(copyQuickJsDllIfNeeded);

    test('@webBrowser: 前缀走 WebView 池，HTTP 传输层不被触达', () async {
      final transport = _RecordingTransport();
      final webview = _RecordingGateway();
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(
        transport: transport,
        sandbox: sandbox,
        webBrowserPool: WebBrowserPool(
          createGateway: () => webview,
          timeout: const Duration(seconds: 5),
        ),
      );
      addTearDown(() => runtime.close());

      final source = _legadoSource('@webBrowser:https://$_publicHost/search?q={{key}}');
      final page = await runtime.search(source.toRegisteredSource(), '小说');
      expect(page.items, hasLength(2));
      expect(page.items.first.title, contains('浏览器结果书A'));
      expect(page.items.first.author, contains('作者甲'));

      expect(webview.opened, hasLength(1));
      expect(webview.opened.single.path, '/search');
      expect(transport.sent, isEmpty, reason: '浏览器路由不得走 HTTP 传输层');
    });

    test('请求选项 webView:true 同样走 WebView 池', () async {
      final transport = _RecordingTransport();
      final webview = _RecordingGateway();
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(
        transport: transport,
        sandbox: sandbox,
        webBrowserPool: WebBrowserPool(
          createGateway: () => webview,
          timeout: const Duration(seconds: 5),
        ),
      );
      addTearDown(() => runtime.close());

      final source = _legadoSource(
        'https://$_publicHost/search?q={{key}},{"webView":true}',
      );
      final page = await runtime.search(source.toRegisteredSource(), '漫画');
      expect(page.items, isNotEmpty);
      expect(webview.opened, hasLength(1));
      expect(transport.sent, isEmpty);
    });

    test('SSRF：私网目标在校验阶段被拒，WebView 网关不被触达', () async {
      final transport = _RecordingTransport();
      final webview = _RecordingGateway();
      final sandbox = FlutterLegadoJsSandbox();
      final runtime = LegadoRuntime(
        transport: transport,
        sandbox: sandbox,
        webBrowserPool: WebBrowserPool(
          createGateway: () => webview,
          timeout: const Duration(seconds: 5),
        ),
      );
      addTearDown(() => runtime.close());

      final source = _legadoSource('@webBrowser:http://127.0.0.1/evil?q={{key}}');
      await expectLater(
        runtime.search(source.toRegisteredSource(), 'x'),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect(webview.openCount, 0, reason: 'SSRF 拒绝后不得触碰 WebView');
      expect(transport.sent, isEmpty);
    });
  });
}