// 文件说明：WebView 平台能力探测 —— 条件导出入口。
// 技术要点：Web 目标不 import dart:io，通过 `dart.library.io` 条件分支选择实现。
export 'webview_platform_stub.dart'
    if (dart.library.io) 'webview_platform_io.dart';