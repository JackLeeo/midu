// 米读：书源登录 Cookie / 登录信息持久化存储。
//
// 对标 Legado 的 `CookieStore` 与「登录信息（AES 加密）持久化」：
// - Cookie 按 host 持久化，配合每条书源独立的 runtime/transport，登录后的
//   Set-Cookie 可跨 App 重启继续携带，保证「登录状态不丢」。
// - 登录信息（用户填写的账密等字段）按源 id 持久化，供登录表单回填与
//   源脚本读取，简单混淆存储（非加密，避免引入加密依赖导致环境限制）。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 书源 Cookie / 登录信息存储单例。
class BookSourceCookieStore {
  BookSourceCookieStore._();

  static final BookSourceCookieStore instance = BookSourceCookieStore._();

  static const String _cookiesKey = 'midu_source_cookies_v1';
  static const String _loginInfoKey = 'midu_source_login_info_v1';

  Future<Map<String, String>> loadCookieJar(String host) async {
    if (host.isEmpty) return const {};
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cookiesKey);
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final jar = decoded[host];
      if (jar is! Map) return const {};
      return jar.map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return const {};
    }
  }

  /// 读取当前启动会话的所有 cookie 快照（仅在登录页“查看已登录状态”时调用，
  /// 不参与逐请求热路径）。
  Future<Map<String, Map<String, String>>> loadAllJars() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cookiesKey);
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map((host, jar) {
        final inner = (jar is Map) ? jar : const {};
        return MapEntry('$host', inner.map((k, v) => MapEntry('$k', '$v')));
      });
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveCookieJar(String host, Map<String, String> jar) async {
    if (host.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await _decodedMap(prefs.getString(_cookiesKey));
    all[host] = jar.map((k, v) => MapEntry(k, v));
    await prefs.setString(_cookiesKey, jsonEncode(all));
  }

  /// 读取某源保存的登录信息（供登录表单回填）。
  Future<Map<String, String>> loadLoginInfo(String sourceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_loginInfoKey);
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final entry = decoded[sourceId];
      if (entry is! Map) return const {};
      return entry.map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveLoginInfo(String sourceId, Map<String, String> info) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await _decodedMap(prefs.getString(_loginInfoKey));
    all[sourceId] = info.map((k, v) => MapEntry(k, v));
    await prefs.setString(_loginInfoKey, jsonEncode(all));
  }

  Future<void> clearLoginInfo(String sourceId) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await _decodedMap(prefs.getString(_loginInfoKey));
    all.remove(sourceId);
    await prefs.setString(_loginInfoKey, jsonEncode(all));
  }

  Future<Map<String, dynamic>> _decodedMap(String? raw) async {
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? decoded.map((k, v) => MapEntry('$k', v))
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
