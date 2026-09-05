// 直接用 Dart HttpClient + Dio 探测 全免漫画 API 站点联通性（代理 TUN 已开）。
// 运行: D:\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/probe_qmmh_live.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final host = 'api-cdn.kaimanhua.com';
  final url = 'https://$host/comic/getcomicdata';

  // 1) 原始 Dart HttpClient
  try {
    final c = HttpClient();
    final sw = Stopwatch()..start();
    final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
    req.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36');
    final resp = await req.close().timeout(const Duration(seconds: 15));
    print('[HttpClient] status=${resp.statusCode} in ${sw.elapsedMilliseconds}ms');
    final body = await resp.transform(utf8.decoder).join();
    print('  head=${body.substring(0, body.length > 120 ? 120 : body.length)}');
    resp.drain();
  } catch (e) {
    print('[HttpClient] ERROR: ${e.runtimeType}: $e');
  }

  // 2) 系统代理检测
  print('findProxy default: 使用系统/环境代理配置');
  print('env http_proxy=${Platform.environment['http_proxy']} https_proxy=${Platform.environment['https_proxy']}');
}