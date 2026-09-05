// 米读：书源登录执行服务（对标 Legado `SourceLoginDialog` + `SourceLoginV2Delegate`）。
//
// 职责：
// - 解析 loginUi 为表单字段（v1 数组 / v2 {"version":2,"rows":[...]} 两种形态）。
// - 通过 runtime 展开 loginUrl 发起登录请求，Set-Cookie 由传输层持久化，
//   使登录状态跨 App 重启保持。
// - 用 loginCheckJs 校验登录结果，并把用户填写的字段回填持久化为登录信息。
import 'dart:convert';

import '../legado/legado_book_source.dart';
import '../legado/legado_runtime.dart';
import '../legado/legado_request.dart';
import '../models/registered_book_source.dart';
import 'book_source_cookie_store.dart';

/// 登录表单上一个输入字段（对标 Legado `RowUi`）。
class BookSourceLoginField {
  const BookSourceLoginField({
    required this.name,
    required this.type,
    this.key,
    this.hint,
    this.value,
    this.options = const [],
  });

  final String name;

  /// text / password / select / toggle。
  final String type;

  /// 字段在登录信息里的键；缺省用 name 作为键。
  final String? key;

  final String? hint;
  final String? value;
  final List<String> options;

  bool get isInput => type == 'text' || type == 'password';
  bool get password => type == 'password';
}

/// 登录结果。
class BookSourceLoginResult {
  const BookSourceLoginResult({
    required this.success,
    this.message,
  });

  final bool success;
  final String? message;
}

/// 书源登录服务。
class BookSourceLoginService {
  const BookSourceLoginService();

  /// 源是否声明了登录能力（有 loginUrl 或 loginUi 之一即视为可登录）。
  static bool hasLogin(LegadoBookSource source) =>
      source.loginUrl.trim().isNotEmpty ||
      (source.loginUi.trim().isNotEmpty &&
          source.loginUi.trim().replaceAll(RegExp(r'\s'), '') != '[]');

  /// 解析 loginUi 为表单字段。v1 为 JSON 数组，v2 为 `{"version":2,"rows":[...]}`。
  /// 仅保留可输入的 text/password/select/toggle；button/label 为动作/提示不纳入。
  static List<BookSourceLoginField> parseFields(LegadoBookSource source) {
    final raw = source.loginUi.trim();
    if (raw.isEmpty) return const [];

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is String && decoded.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        return const [];
      }
    }
    List<dynamic> rows;
    if (decoded is Map) {
      final version = decoded['version'];
      final r = decoded['rows'];
      if (version is int && version >= 2 && r is List) {
        rows = r;
      } else {
        return const [];
      }
    } else if (decoded is List) {
      rows = decoded;
    } else {
      return const [];
    }

    final fields = <BookSourceLoginField>[];
    final seenKeys = <String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final type = '${row['type'] ?? 'text'}'.trim().toLowerCase();
      if (type == 'button' || type == 'label') continue;
      if (type != 'text' && type != 'password' && type != 'select' &&
          type != 'toggle') {
        continue;
      }
      final name = '${row['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final key = '${row['key'] ?? ''}'.trim().isEmpty
          ? name
          : '${row['key']}'.trim();
      if (!seenKeys.add(key)) continue;
      final rawOptions = row['options'];
      final options = <String>[
        if (rawOptions is List)
          ...rawOptions.whereType<String>(),
      ];
      final fieldValue = row['value'];
      fields.add(
        BookSourceLoginField(
          name: name,
          type: type,
          key: key,
          hint: '${row['hint'] ?? ''}'.trim().isEmpty
              ? null
              : '${row['hint']}'.trim(),
          value: fieldValue == null ? null : '$fieldValue',
          options: options,
        ),
      );
    }
    return List.unmodifiable(fields);
  }

  /// 发起登录：按表单值展开 loginUrl 请求，随后用 loginCheckJs 校验。
  ///
  /// [form] 为「字段 key -> 用户输入值」映射。请求产生的 Set-Cookie 由传输层
  /// 持久化进 [BookSourceCookieStore]，登录信息同时保存以便下次回填。
  Future<BookSourceLoginResult> performLogin({
    required LegadoRuntime runtime,
    required RegisteredBookSource registered,
    required Map<String, String> form,
  }) async {
    final source = LegadoBookSource.fromJson(registered.sourceConfig!);
    // 保存登录信息（供下次回填与源脚本读取）。
    if (form.isNotEmpty) {
      await BookSourceCookieStore.instance.saveLoginInfo(
        registered.id,
        Map<String, String>.from(form),
      );
    }
    if (source.loginUrl.trim().isEmpty) {
      // 仅有 loginUi 而无 loginUrl：视为本地信息已保存即可。
      return const BookSourceLoginResult(success: true);
    }
    try {
      final response = await runtime.requestForLogin(
        registered,
        variables: form,
      );
      final check = await _runLoginCheck(
        runtime,
        registered,
        source,
        response,
      );
      if (check != null && check.trim().isNotEmpty &&
          check.trim().toLowerCase() != 'true') {
        return BookSourceLoginResult(
          success: false,
          message: check,
        );
      }
      return const BookSourceLoginResult(success: true);
    } on Exception catch (error) {
      return BookSourceLoginResult(
        success: false,
        message: '$error',
      );
    }
  }

  /// 执行 loginCheckJs；未配置或结果为空/true 视为登录成功。
  Future<String?> _runLoginCheck(
    LegadoRuntime runtime,
    RegisteredBookSource registered,
    LegadoBookSource source,
    LegadoResponse response,
  ) async {
    final check = source.loginCheckJs.trim();
    if (check.isEmpty) return null;
    String code = check;
    if (!code.startsWith('@js:') && !code.contains('<js>')) {
      code = '@js:finalResult = $check;';
    }
    try {
      return await runtime.evalSourceScript(
        registered,
        code: code,
        docHtml: response.body,
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取某源保存的登录信息（用于登录表单回填）。
  Future<Map<String, String>> loadSavedInfo(String sourceId) =>
      BookSourceCookieStore.instance.loadLoginInfo(sourceId);

  /// 清除某源登录信息（对标 Legado `removeLoginInfo`）。
  Future<void> clearInfo(String sourceId) =>
      BookSourceCookieStore.instance.clearLoginInfo(sourceId);
}
