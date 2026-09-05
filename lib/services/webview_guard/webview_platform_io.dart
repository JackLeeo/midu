// 文件说明：WebView 平台能力探测 —— IO（Android/iOS/桌面）实现。
// 技术要点：仅 Android/iOS 具备持续可用的 WebView 运行时；桌面/其他走降级提示。

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

bool platformSupportsWebView() =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);