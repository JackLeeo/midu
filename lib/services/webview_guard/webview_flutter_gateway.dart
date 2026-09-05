// 文件说明：真实 WebView 网关（Android/iOS，webview_flutter 4.x 实现）。
// 技术要点：单次 `loadRequest` → 等待渲染完成 → 用 JS 回读 DOM HTML；
// 会话（Cookie/JS 环境）由 WebViewController 生命周期保持。
// 说明：本文件仅在 `platformSupportsWebView()` 为真的平台被实例化，
// 其他平台由 UnavailableWebBrowserGateway 降级，不会走到这里。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:webview_flutter/webview_flutter.dart';

import 'web_browser_fallback.dart';

class FlutterWebBrowserGateway implements WebBrowserGateway {
  WebViewController? _controller;
  int _loadGeneration = 0;

  Future<WebViewController> _ensureController() async {
    final existing = _controller;
    if (existing != null) return existing;
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0xFFFFFFFF));
    _controller = controller;
    return controller;
  }

  @override
  Future<WebBrowserDocument> open(WebBrowserRequest request) async {
    final controller = await _ensureController();
    final generation = ++_loadGeneration;
    final finished = Completer<Uri>();
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (url) {
          // 仅接收本代导航完成事件，避免上一代页面残留事件误触发。
          if (generation == _loadGeneration && !finished.isCompleted) {
            finished.complete(Uri.parse(url));
          }
        },
      ),
    );
    final bodyBytes = (request.method == 'POST' && request.body != null)
        ? Uint8List.fromList(utf8.encode(request.body!))
        : null;
    controller.loadRequest(
      request.url,
      method: request.method == 'POST'
          ? LoadRequestMethod.post
          : LoadRequestMethod.get,
      headers: request.headers,
      body: bodyBytes,
    );
    // 池层会施加统一超时（timeout），此处不另设，避免竞态释放。
    final finalUri = await finished.future;
    final html = await controller.runJavaScriptReturningResult(
      'document.documentElement.outerHTML',
    );
    return WebBrowserDocument(
      finalUri: finalUri,
      body: html is String ? html : html.toString(),
    );
  }

  @override
  Future<void> dispose() async {
    // webview_flutter 无显式销毁 API；置空引用交由引擎回收，下次 open 重建。
    _controller = null;
  }
}