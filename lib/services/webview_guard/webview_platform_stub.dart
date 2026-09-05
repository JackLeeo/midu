// 文件说明：WebView 平台能力探测 —— Web 目标桩实现（无 dart:io）。
// 技术要点：Web 平台无持续 WebView 运行时，恒为不可用。

bool platformSupportsWebView() => false;