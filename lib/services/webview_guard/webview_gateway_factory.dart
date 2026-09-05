// 文件说明：WebView 网关工厂 —— 按平台分发真实/降级网关。
// 技术要点：Android/iOS → FlutterWebBrowserGateway；Web/桌面 → Unavailable 占位。
import 'web_browser_fallback.dart';
import 'webview_flutter_gateway.dart';
import 'webview_platform.dart';

/// 默认网关：平台支持时返回真实 WebView 网关，否则返回不可用占位网关。
WebBrowserGateway defaultWebBrowserGateway() {
  if (platformSupportsWebView()) return FlutterWebBrowserGateway();
  return const UnavailableWebBrowserGateway();
}