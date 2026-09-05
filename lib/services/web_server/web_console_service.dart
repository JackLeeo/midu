// 文件说明：Web 管理台应用级服务 —— 持有 WebManagementServer 生命周期。
// 技术要点：token 随机生成 + 端口持久化到 SharedPreferences；启动/停止幂等；
// dart:io 在 Flutter Web 目标为编译兼容/运行禁用 → start() 以 kIsWeb 短路并降级提示。
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../book_sources/services/book_source_registry.dart';
import 'web_server_service.dart';

class WebConsoleService extends ChangeNotifier {
  WebConsoleService();

  static const String _tokenKey = 'web_console_token_v1';
  static const String _portKey = 'web_console_port_v1';
  static const int defaultPort = 18181;
  static const int _tokenLength = 24;

  WebManagementServer? _server;
  bool _restored = false;
  String _token = '';
  int _port = defaultPort;
  String? _lastError;

  bool get restored => _restored;
  bool get isRunning => _server?.isRunning ?? false;
  int get port => _server?.port ?? _port;
  int get desiredPort => _port;
  String get token => _token;
  String? get lastError => _lastError;

  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    final storedToken = prefs.getString(_tokenKey);
    if (storedToken == null || storedToken.isEmpty) {
      _token = _newToken();
      await prefs.setString(_tokenKey, _token);
    } else {
      _token = storedToken;
    }
    _port = prefs.getInt(_portKey) ?? defaultPort;
    notifyListeners();
  }

  static String _newToken() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(_tokenLength, (_) => chars[random.nextInt(chars.length)])
        .join();
  }

  Future<void> setPort(int port) async {
    final clamped = port.clamp(1, 65535);
    _port = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_portKey, clamped);
    notifyListeners();
  }

  Future<void> regenerateToken() async {
    _token = _newToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _token);
    notifyListeners();
  }

  /// 启动本地 Web 管理服务器；Web 目标返回 false 并给出降级提示。
  Future<bool> start() async {
    if (!_restored) await restore();
    _lastError = null;
    if (kIsWeb) {
      _lastError = '当前平台不支持本地 Web 管理服务器';
      notifyListeners();
      return false;
    }
    try {
      var server = _server;
      if (server == null) {
        server = WebManagementServer(
          token: _token,
          sourceListProvider: _loadSourceNames,
        );
        _server = server;
      }
      if (!server.isRunning) {
        await server.start(port: _port);
      }
      notifyListeners();
      return true;
    } catch (error) {
      _lastError = '$error';
      notifyListeners();
      return false;
    }
  }

  Future<void> stop() async {
    await _server?.stop();
    notifyListeners();
  }

  static Future<List<String>> _loadSourceNames() async {
    final sources = await BookSourceRegistry().load();
    return sources.map((source) => source.name).toList();
  }

  @override
  void dispose() {
    unawaited(_server?.stop());
    super.dispose();
  }
}