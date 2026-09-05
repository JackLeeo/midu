// 文件说明：`@webBrowser:` / `@webView:` 浏览器兜底执行器 —— 路由识别、WebView 池、
// 并发上限、会话保持与超时控制（对标 Legado WebView 池 + FakeNavigator）。
// 技术要点：真实 WebView 平台能力通过 [WebBrowserGateway] 抽象注入；桌面/Web 等
// 无 WebView 运行时的平台由 [UnavailableWebBrowserGateway] 给出明确降级提示。
// 池在 [WebBrowserPool] 内负责：按需创建网关、忙时排队、空闲复用、失败/超时
// 网关直接销毁（避免复用停留在已超时页面的上下文）。
import 'dart:async';

/// 浏览器兜底在无 WebView 运行时的平台异常（Web / 桌面）。
class WebBrowserUnavailableException implements Exception {
  const WebBrowserUnavailableException([
    this.message = '当前平台不支持 @webBrowser 浏览器兜底',
  ]);

  final String message;

  @override
  String toString() => 'WebBrowserUnavailableException: $message';
}

/// 一次浏览器兜底请求（对应一次 WebView 页面加载）。
class WebBrowserRequest {
  const WebBrowserRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final String? body;
}

/// 浏览器兜底加载完成后的页面结果（最终地址 + 渲染后 HTML）。
class WebBrowserDocument {
  const WebBrowserDocument({
    required this.finalUri,
    required this.body,
    this.statusCode,
  });

  final Uri finalUri;
  final String body;
  final int? statusCode;
}

/// WebView 网关抽象：一个网关代表一个持续存活的浏览器上下文（含 Cookie / JS 环境），
/// 与源级 runtime 隔离——每源独立 gateway/pool，避免跨源会话串扰（对齐 R1）。
abstract interface class WebBrowserGateway {
  Future<WebBrowserDocument> open(WebBrowserRequest request);

  Future<void> dispose();
}

/// 平台不支持时的占位网关：任何 open 都抛 [WebBrowserUnavailableException]。
class UnavailableWebBrowserGateway implements WebBrowserGateway {
  const UnavailableWebBrowserGateway();

  @override
  Future<WebBrowserDocument> open(WebBrowserRequest request) async {
    throw const WebBrowserUnavailableException();
  }

  @override
  Future<void> dispose() async {}
}

/// `@webBrowser:` / `@webView:` URL 前缀识别与剥离（大小写不敏感）。
class WebBrowserRoute {
  static const List<String> _prefixes = ['@webbrowser:', '@webview:'];

  static bool isBrowserUrl(String template) {
    final lower = template.trim().toLowerCase();
    return _prefixes.any(lower.startsWith);
  }

  /// 剥离浏览器前缀；非浏览器路由返回 null。
  static String? stripBrowserPrefix(String template) {
    final trimmed = template.trim();
    final lower = trimmed.toLowerCase();
    for (final prefix in _prefixes) {
      if (lower.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return null;
  }
}

/// WebView 池：按需创建网关、并发上限排队、空闲复用、统一超时。
///
/// 约束：同时存活的网关实例数不超过 [maxConcurrent]；超时/异常的网关立即销毁
/// 并（若有等待者）以新实例补位，保证池内无「伤病实例」。
class WebBrowserPool {
  WebBrowserPool({
    required this.createGateway,
    this.maxConcurrent = 4,
    this.timeout = const Duration(seconds: 25),
  }) : assert(maxConcurrent > 0, 'maxConcurrent must be positive');

  final WebBrowserGateway Function() createGateway;
  final int maxConcurrent;
  final Duration timeout;

  final List<WebBrowserGateway> _idle = [];
  final List<Completer<WebBrowserGateway>> _waiters = [];
  int _active = 0;
  bool _closed = false;

  Future<WebBrowserDocument> open(WebBrowserRequest request) async {
    if (_closed) throw _closedError;
    final gateway = await _acquire();
    try {
      final document = await gateway.open(request).timeout(timeout);
      _release(gateway);
      return document;
    } catch (error) {
      // 超时/异常：网关状态不可信，销毁而非复用。
      unawaited(gateway.dispose());
      _onGatewayFailed();
      rethrow;
    }
  }

  Future<WebBrowserGateway> _acquire() async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    if (_active < maxConcurrent) {
      _active++;
      try {
        return createGateway();
      } catch (_) {
        _active--;
        rethrow;
      }
    }
    final waiter = Completer<WebBrowserGateway>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release(WebBrowserGateway gateway) {
    if (_closed) {
      unawaited(gateway.dispose());
      return;
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(gateway);
    } else {
      _idle.add(gateway);
    }
  }

  void _onGatewayFailed() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      try {
        waiter.complete(createGateway());
      } catch (error, stackTrace) {
        waiter.completeError(error, stackTrace);
        _onGatewayFailed();
      }
    } else {
      _active--;
    }
  }

  WebBrowserUnavailableException get _closedError =>
      const WebBrowserUnavailableException('浏览器池已关闭');

  Future<void> closeAll() async {
    _closed = true;
    for (final waiter in _waiters) {
      waiter.completeError(WebBrowserUnavailableException('浏览器池已关闭'));
    }
    _waiters.clear();
    final disposed = _idle.toList(growable: false);
    _idle.clear();
    await Future.wait(disposed.map((gateway) => gateway.dispose()));
  }
}