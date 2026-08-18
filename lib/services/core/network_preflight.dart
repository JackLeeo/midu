// 文件说明：iOS 首次联网时会弹出「允许"米读"使用无线数据／连接本地网络」权限询问。
// 若不做任何处理，该询问会延迟到读者真正搜索/联网时才出现，打断操作。
// 本工具在进入主页后主动触发一次极轻量联网，让系统在启动早期完成权限授权，
// 后续搜索、换源、翻页便不再被权限弹窗打断。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

class NetworkPreflight {
  NetworkPreflight._();

  static bool _fired = false;

  /// 按顺序尝试的可达性探测地址，第一个连上即可让系统感知联网。
  static const List<String> _probeUrls = [
    'https://www.baidu.com',
    'https://www.qq.com',
    'https://www.bing.com',
  ];

  /// 进入主页后调用一次（幂等，仅首次触发）。
  static void fireOnHomeEntered() {
    if (_fired) return;
    _fired = true;
    _probe();
  }

  static void _probe() {
    if (kIsWeb) return; // dart:io HttpClient 不适用于 Web 平台
    for (final url in _probeUrls) {
      unawaited(_touch(url));
    }
  }

  /// 发起一次极轻量的 GET（关闭持久连接），仅用于触发系统联网授权。
  ///
  /// 只携带 User-Agent / Accept 头，遵守项目「最小化安全头」约定。
  /// 预检失败不阻塞、不报错：其目的只是让 iOS 感知联网并弹出权限询问。
  static Future<void> _touch(String urlString) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
      try {
        final request = await client.getUrl(Uri.parse(urlString));
        request.headers.set(HttpHeaders.userAgentHeader, 'Midu/1.0');
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        final response = await request.close();
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // 忽略：预检只用于触发授权，失败无副作用。
    }
  }
}