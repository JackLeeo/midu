// HTTP TTS 引擎（在线朗读）：对标 Legado HttpTTS 实体 + HttpTtsEditDialog 字段
// + HttpReadAloudService 的请求行为。
//
// 与 Legado 一致，引擎配置包含 URL 模板（`{{speakText}}` 替换朗读文本、
// `{{speakSpeed}}` 替换语速）、Content-Type 校验正则、段落间停顿、登录地址/
// 登录检查 JS、请求头与 JS 库。音频抓取走与书源相同的
// [LegadoHttpTransport]（自带 SSRF 校验与会话 Cookie jar），`enabledCookieJar`
// 开启时先 GET loginUrl 建立会话再请求音频。
// 列表持久化到 SharedPreferences（与 ReplaceRuleService 同构），单例
// [HttpTtsEngineService.instance] 供朗读面板与设置页共享。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../book_sources/legado/legado_fjs_sandbox.dart';
import '../book_sources/legado/legado_request.dart';

/// 单条 HTTP TTS 引擎配置（字段与 Legado `HttpTTS` 表一一对应）。
class HttpTtsEngine {
  const HttpTtsEngine({
    required this.id,
    required this.name,
    required this.url,
    this.contentType,
    this.pauseDuration = 0,
    this.concurrentRate = '0',
    this.loginUrl,
    this.loginUi,
    this.header,
    this.jsLib,
    this.enabledCookieJar = false,
    this.loginCheckJs,
    this.lastUpdateTime,
  });

  final String id;
  final String name;

  /// 音频接口 URL 模板：`{{speakText}}` 替换朗读文本、`{{speakSpeed}}` 替换语速，
  /// 支持 `@js:` 动态生成与 `,{...}` 请求选项块。
  final String url;

  /// 音频响应 Content-Type 正则；为空不校验，非空不匹配即报错。
  final String? contentType;

  /// 段落间静音停顿毫秒数（0-10000）。
  final int pauseDuration;

  /// 并发请求数（朗读速率设置相关，保留字段）。
  final String? concurrentRate;

  /// 登录地址；`enabledCookieJar` 开启时先请求它建立会话 Cookie。
  final String? loginUrl;

  /// 登录 UI 配置（JSON 描述，当前仅存留展示）。
  final String? loginUi;

  /// 请求头：JSON 对象字符串，或 `键: 值` 换行队列（Legado headerQueue）。
  final String? header;

  /// JS 库（请求前后执行的公共脚本，保留字段）。
  final String? jsLib;

  /// 是否启用会话 Cookie jar（登录态跨请求保持）。
  final bool enabledCookieJar;

  /// 登录检查 JS：非空时在收到非音频响应后求值；返回「500」表示需要/仍然登录失败。
  final String? loginCheckJs;

  final int? lastUpdateTime;

  HttpTtsEngine copyWith({
    String? name,
    String? url,
    String? contentType,
    int? pauseDuration,
    String? concurrentRate,
    String? loginUrl,
    String? loginUi,
    String? header,
    String? jsLib,
    bool? enabledCookieJar,
    String? loginCheckJs,
    int? lastUpdateTime,
  }) => HttpTtsEngine(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    contentType: contentType ?? this.contentType,
    pauseDuration: pauseDuration ?? this.pauseDuration,
    concurrentRate: concurrentRate ?? this.concurrentRate,
    loginUrl: loginUrl ?? this.loginUrl,
    loginUi: loginUi ?? this.loginUi,
    header: header ?? this.header,
    jsLib: jsLib ?? this.jsLib,
    enabledCookieJar: enabledCookieJar ?? this.enabledCookieJar,
    loginCheckJs: loginCheckJs ?? this.loginCheckJs,
    lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
  );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'contentType': contentType,
        'pauseDuration': pauseDuration,
        'concurrentRate': concurrentRate,
        'loginUrl': loginUrl,
        'loginUi': loginUi,
        'header': header,
        'jsLib': jsLib,
        'enabledCookieJar': enabledCookieJar,
        'loginCheckJs': loginCheckJs,
        'lastUpdateTime': lastUpdateTime ?? DateTime.now().millisecondsSinceEpoch,
      };

  static HttpTtsEngine fromJson(Map<String, dynamic> json) {
    final rawPause = _parseInt(json['pauseDuration']);
    return HttpTtsEngine(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      url: '${json['url'] ?? ''}',
      contentType: json['contentType'] is String
          ? json['contentType'] as String
          : null,
      pauseDuration: rawPause == null ? 0 : rawPause.clamp(0, 10000),
      concurrentRate: json['concurrentRate'] is String
          ? json['concurrentRate'] as String
          : (json['concurrentRate'] == null ? '0' : '${json['concurrentRate']}'),
      loginUrl: json['loginUrl'] is String ? json['loginUrl'] as String : null,
      loginUi: json['loginUi'] is String ? json['loginUi'] as String : null,
      header: json['header'] is String ? json['header'] as String : null,
      jsLib: json['jsLib'] is String ? json['jsLib'] as String : null,
      enabledCookieJar: json['enabledCookieJar'] is bool
          ? json['enabledCookieJar'] as bool
          : false,
      loginCheckJs: json['loginCheckJs'] is String
          ? json['loginCheckJs'] as String
          : null,
      lastUpdateTime: _parseInt(json['lastUpdateTime']),
    );
  }

  bool equal(HttpTtsEngine other) =>
      name == other.name &&
      url == other.url &&
      contentType == other.contentType &&
      pauseDuration == other.pauseDuration &&
      concurrentRate == other.concurrentRate &&
      loginUrl == other.loginUrl &&
      loginUi == other.loginUi &&
      header == other.header &&
      jsLib == other.jsLib &&
      enabledCookieJar == other.enabledCookieJar &&
      loginCheckJs == other.loginCheckJs;

  static int? _parseInt(Object? value) {
    final text = '$value'.trim();
    if (text.isEmpty || text == 'null') return null;
    return int.tryParse(text);
  }
}

/// HTTP TTS 引擎仓库：列表 CRUD + 当前选中引擎，持久化到 SharedPreferences。
class HttpTtsEngineService extends ChangeNotifier {
  HttpTtsEngineService();

  static const String storageKey = 'http_tts_engines_v1';
  static const String activeKey = 'http_tts_active_engine_id';

  /// 全局共享实例（朗读面板与设置页共用同一份引擎配置）。
  static final HttpTtsEngineService instance = HttpTtsEngineService();

  List<HttpTtsEngine> _engines = const [];
  String? _activeEngineId;
  bool _loaded = false;

  /// 全部引擎（按新增顺序）。
  List<HttpTtsEngine> get engines => List.unmodifiable(_engines);

  /// 当前选中的引擎。
  HttpTtsEngine? get activeEngine {
    if (_activeEngineId == null) return null;
    for (final engine in _engines) {
      if (engine.id == _activeEngineId) return engine;
    }
    return null;
  }

  String? get activeEngineId => _activeEngineId;

  bool get hasEngines => _engines.isNotEmpty;

  HttpTtsEngine? engineById(String? id) {
    if (id == null) return null;
    for (final engine in _engines) {
      if (engine.id == id) return engine;
    }
    return null;
  }

  /// 确保已从存储加载（幂等）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _engines = decoded
              .whereType<Map>()
              .map((e) => HttpTtsEngine.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false);
        }
      } on FormatException {
        _engines = const [];
      }
    }
    _activeEngineId = prefs.getString(activeKey);
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode(_engines.map((engine) => engine.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> add(HttpTtsEngine engine) async {
    await ensureLoaded();
    _engines = [..._engines, engine];
    if (_activeEngineId == null) _activeEngineId = engine.id;
    await _persist();
    await _persistActive();
  }

  Future<void> update(String id, HttpTtsEngine engine) async {
    await ensureLoaded();
    _engines = [
      for (final existing in _engines)
        if (existing.id == id) engine else existing,
    ];
    await _persist();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _engines = _engines.where((engine) => engine.id != id).toList(growable: false);
    if (_activeEngineId == id) _activeEngineId = null;
    await _persist();
    await _persistActive();
  }

  Future<void> setActive(String? id) async {
    await ensureLoaded();
    _activeEngineId = id;
    await _persistActive();
  }

  Future<void> _persistActive() async {
    final prefs = await SharedPreferences.getInstance();
    if (_activeEngineId == null) {
      await prefs.remove(activeKey);
    } else {
      await prefs.setString(activeKey, _activeEngineId!);
    }
    notifyListeners();
  }

  static int _idCounter = 0;
  static String newId() {
    final seq = _idCounter++;
    return 'http_tts_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_$seq';
  }
}

/// HTTP TTS 音频抓取器：对标 HttpReadAloudService.getSpeakStream 的请求行为。
///
/// 每个实例持有独立的 fjs 沙箱与 HTTP 传输（携带 SSRF 校验与会话 Cookie jar），
/// 与书源运行时互相隔离。
class HttpTtsAudioFetcher {
  HttpTtsAudioFetcher({
    this.maxResponseBytes = 12 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 30),
    LegadoHttpTransport? transport,
  }) : _transportOverride = transport;

  final int maxResponseBytes;
  final Duration requestTimeout;
  final LegadoHttpTransport? _transportOverride;

  /// 测试注入：拦截请求层（生产环境走真实传输）。
  @visibleForTesting
  Future<LegadoRawResponse> Function(LegadoRequestTemplate request)?
  requestOverride;

  static const Map<String, String> _defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
    'Accept': 'audio/*, application/octet-stream;q=0.9, */*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  LegadoFjsSandbox? _sandbox;
  LegadoHttpTransport? _transport;
  final Set<String> _preloadedJsLib = {};

  Future<LegadoFjsSandbox> _ensureSandbox() async {
    final existing = _sandbox;
    if (existing != null) return existing;
    final sandbox = LegadoFjsSandbox();
    await sandbox.init();
    _sandbox = sandbox;
    return sandbox;
  }

  /// 预加载引擎公共 JS 库（jsLib）：首次遇到该引擎时执行一次，注册全局函数。
  Future<void> _preloadJsLibIfNeeded(HttpTtsEngine engine) async {
    final lib = engine.jsLib?.trim();
    if (lib == null || lib.isEmpty) return;
    if (!_preloadedJsLib.add(engine.id)) return;
    try {
      await (await _ensureSandbox()).preloadJsLib(lib);
    } catch (_) {
      // 公共库加载失败不阻断主流程
    }
  }

  LegadoHttpTransport get _ensureTransport =>
      _transport ??= _transportOverride ?? LegadoHttpTransport();

  void close() {
    _sandbox?.dispose();
    _transport?.close(force: true);
    _sandbox = null;
    _transport = null;
  }

  /// 测试注入的传输（生产环境仍懒初始化 [LegadoHttpTransport]）。
  @visibleForTesting
  void attachTransport(LegadoHttpTransport transport) {
    _transport = transport;
  }

  /// Legado 语速映射：`{{speakSpeed}}` 为整数，取 `rate*10+5`（0.1→6，1.0→15）。
  static int speakSpeedFor(double rate) =>
      (((rate.clamp(0.1, 1.0)) * 10) + 5).round();

  /// 抓取一段朗读音频。行为对标 HttpReadAloudService.getSpeakStream：
  /// 1. 解析 URL 模板（speakText/speakSpeed / @js: / ,{...} 选项块）
  /// 2. enabledCookieJar 且配置了 loginUrl 时先请求登录建立会话
  /// 3. 请求音频；响应为文本（登录页/错误页）时：
  ///    - 有 loginCheckJs 则对其求值（返回「500」视为登录失败）
  ///    - 有 loginUrl 则补一次登录后重试；仍失败抛错误
  ///    - 无登录配置则直接抛错（含响应正文片段）
  /// 4. contentType 正则校验音频响应；空音频报错。
  Future<Uint8List> fetchAudio({
    required HttpTtsEngine engine,
    required String text,
    required double rate,
  }) async {
    final speakText = text.trim();
    final speakSpeed = speakSpeedFor(rate);
    if (speakText.isEmpty) return Uint8List(0);
    await _preloadJsLibIfNeeded(engine);

    final template = engine.url.trim();
    if (template.isEmpty) {
      throw HttpTtsEngineException('missing_url', '引擎 URL 不能为空');
    }

    // 1. 登录预置：enabledCookieJar + loginUrl。
    final loginUrl = engine.loginUrl?.trim();
    if (engine.enabledCookieJar && (loginUrl?.isNotEmpty ?? false)) {
      await _sendLogin(engine, speakText, speakSpeed, loginUrl!);
    }

    final loginCheckJs = engine.loginCheckJs?.trim() ?? '';
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await _requestAudio(engine, speakText, speakSpeed);
      final contentType = result.contentType;
      final validAudio = _isAudioContent(contentType) &&
          _matchesContentType(engine.contentType, contentType);
      if (result.body.isNotEmpty && validAudio) {
        return result.body;
      }
      // 文本/不匹配响应：登录检查 / 重试 / 报错。
      final snippet = _snippet(
        utf8.decode(result.body, allowMalformed: true),
      );
      if (loginCheckJs.isNotEmpty) {
        final evalResult = await _evalLoginCheck(
          loginCheckJs,
          statusCode: result.statusCode,
          text: snippet,
        );
        if (evalResult.trim().toLowerCase() == '500') {
          throw HttpTtsEngineException(
            'login_failed',
            '音频接口返回非音频数据（可能是登录失效）：$snippet',
          );
        }
      }
      // 尝试登录后重试一次（无登录配置或已重试过则直接失败）。
      final canLogin =
          engine.enabledCookieJar && (loginUrl?.isNotEmpty ?? false);
      if (!canLogin || attempt >= 1) {
        throw HttpTtsEngineException(
          'non_audio_response',
          '音频接口未返回音频数据：$snippet',
        );
      }
      await _sendLogin(engine, speakText, speakSpeed, loginUrl!);
    }
    throw const HttpTtsEngineException('non_audio_response', '音频接口未返回音频数据');
  }

  Future<void> _sendLogin(
    HttpTtsEngine engine,
    String speakText,
    int speakSpeed,
    String loginUrl,
  ) async {
    final transport = _ensureTransport;
    final template = await _resolveUrlTemplate(
      loginUrl,
      speakText: speakText,
      speakSpeed: speakSpeed,
    );
    final request = _buildRequest(template, engine.header, speakText, speakSpeed);
    final override = requestOverride;
    if (override != null) {
      await override(request);
      return;
    }
    await transport.send(request).timeout(requestTimeout);
  }

  Future<_AudioRequestResult> _requestAudio(
    HttpTtsEngine engine,
    String speakText,
    int speakSpeed,
  ) async {
    final transport = _ensureTransport;
    final template = await _resolveUrlTemplate(
      engine.url,
      speakText: speakText,
      speakSpeed: speakSpeed,
    );
    if (template.isEmpty) {
      throw const HttpTtsEngineException('missing_url', '引擎 URL 为空');
    }
    final request = _buildRequest(template, engine.header, speakText, speakSpeed);
    final override = requestOverride;
    if (override != null) {
      final raw = await override(request);
      final headers = raw.headers ?? const <String, String>{};
      return _AudioRequestResult(
        body: raw.bytes,
        statusCode: raw.statusCode,
        contentType: _pickContentType(headers),
      );
    }
    final raw = await transport.sendRaw(request).timeout(requestTimeout);
    final headers = raw.headers ?? const <String, String>{};
    return _AudioRequestResult(
      body: raw.bytes,
      statusCode: raw.statusCode,
      contentType: _pickContentType(headers),
    );
  }

  static String? _pickContentType(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') {
        return entry.value;
      }
    }
    return null;
  }

  /// 复用 LegadoRequestTemplate.parse 的完整模板解析（变量展开 / options 块 /
  /// charset 感知的百分号编码 / header 合并），为朗读 URL 注入 speakText/speakSpeed。
  LegadoRequestTemplate _buildRequest(
    String template,
    String? headerText,
    String speakText,
    int speakSpeed,
  ) {
    final parsed = LegadoRequestTemplate.parse(
      template,
      baseUri: Uri.parse('https://tts.local'),
      variables: {
        'speakText': speakText,
        'speakSpeed': '$speakSpeed',
        'speakRate': '$speakSpeed',
      },
    );
    final headers = <String, String>{
      ..._defaultHeaders,
      ...parseHttpTtsHeaders(headerText),
      ...parsed.headers,
    };
    return LegadoRequestTemplate(
      url: parsed.url,
      method: parsed.method,
      headers: headers,
      charset: parsed.charset,
      body: parsed.body,
    );
  }

  /// URL 模板若以 `@js:`/`<js>` 开头则先经沙箱求值生成实际地址；
  /// 普通模板无需创建沙箱（沙箱依赖原生 fjs 库，按需懒加载）。
  Future<String> _resolveUrlTemplate(
    String template, {
    required String speakText,
    required int speakSpeed,
  }) async {
    final trimmed = template.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) {
      final sandbox = await _ensureSandbox();
      final result = await _evalJs(
        trimmed,
        sandbox,
        extraGlobals: {
          'speakText': speakText,
          'speakSpeed': speakSpeed,
        },
      );
      return result.trim();
    }
    return trimmed;
  }

  Future<String> _evalJs(
    String code,
    LegadoFjsSandbox sandbox, {
    Map<String, dynamic> extraGlobals = const {},
  }) async {
    try {
      return await sandbox.evalJs(
        code,
        extraGlobals: extraGlobals,
      );
    } catch (_) {
      return '';
    }
  }

  /// loginCheckJs：注入 response.status / response.body 后求值。
  Future<String> _evalLoginCheck(
    String code, {
    int? statusCode,
    required String text,
  }) async {
    try {
      final sandbox = await _ensureSandbox();
      return await sandbox.evalJs(
        code,
        docHtml: text,
        extraGlobals: {
          'status': statusCode ?? 0,
          'statusCode': statusCode ?? 0,
        },
      );
    } catch (_) {
      return '';
    }
  }

  static bool _isAudioContent(String? contentType) {
    if (contentType == null || contentType.isEmpty) return true;
    final lower = contentType.toLowerCase();
    if (lower.startsWith('text/') || lower.contains('json')) return false;
    if (lower == 'application/octet-stream') return true;
    return lower.startsWith('audio/') ||
        lower.contains('mpeg') ||
        lower.contains('mp3') ||
        lower.contains('wav') ||
        lower.contains('opus') ||
        lower.contains('aac') ||
        lower.contains('flac') ||
        lower.contains('pcm');
  }

  /// 引擎配置了 contentType 正则时，响应 Content-Type 必须匹配（对标
  /// HttpReadAloudService 的 `ct.toRegex()` 校验）。
  static bool _matchesContentType(String? pattern, String? contentType) {
    final trimmed = pattern?.trim();
    if (trimmed == null || trimmed.isEmpty) return true;
    if (contentType == null) return false;
    try {
      return RegExp(trimmed, caseSensitive: false)
          .hasMatch(contentType.split(';').first.trim());
    } on FormatException {
      return true;
    }
  }

  static String _snippet(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length > 160
        ? '${normalized.substring(0, 160)}…'
        : normalized;
  }
}

class _AudioRequestResult {
  const _AudioRequestResult({
    required this.body,
    required this.statusCode,
    required this.contentType,
  });

  final Uint8List body;
  final int? statusCode;
  final String? contentType;
}

/// 解析 HTTP TTS 引擎的 header 字段：支持 JSON 对象字符串与 `键: 值` 换行队列
/// （Legado headerQueue / 宽松 `\r\n` 分隔，参考漫画源 header 解析容错）。
Map<String, String> parseHttpTtsHeaders(String? raw) {
  if (raw == null) return const {};
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const {};
  if (trimmed.startsWith('{')) {
    final decoded = _tryDecodeJsonObject(trimmed);
    if (decoded.isNotEmpty) return decoded;
  }
  final out = <String, String>{};
  for (final line in trimmed.split(RegExp(r'[\r\n]+'))) {
    final part = line.trim();
    if (part.isEmpty) continue;
    final colon = part.indexOf(':');
    if (colon <= 0) continue;
    final key = part.substring(0, colon).trim();
    var value = part.substring(colon + 1).trim();
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (key.isNotEmpty && value.isNotEmpty && !out.containsKey(key)) {
      out[key] = value;
    }
  }
  return out;
}

Map<String, String> _tryDecodeJsonObject(String input) {
  Object? parsed;
  try {
    parsed = jsonDecode(input);
  } on FormatException {
    // 单引号对象字面量归一为 JSON 后重试。
    final buffer = StringBuffer();
    var inSingle = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (char == "'" && (index - 1 < 0 || input[index - 1] != r'\')) {
        inSingle = !inSingle;
        buffer.write('"');
      } else {
        buffer.write(char);
      }
    }
    try {
      parsed = jsonDecode(buffer.toString());
    } on FormatException {
      return const {};
    }
  }
  if (parsed is! Map) return const {};
  final out = <String, String>{};
  for (final entry in parsed.entries) {
    final key = '${entry.key}'.trim();
    final value = entry.value;
    if (key.isEmpty || value is! String || value.trim().isEmpty) continue;
    out[key] = value;
  }
  return out;
}

/// HTTP TTS 异常（可读 message 供 UI 展示）。
class HttpTtsEngineException implements Exception {
  const HttpTtsEngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}