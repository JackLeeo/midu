// 词典规则服务：对标 Legado DictRuleActivity + DictRuleEngine。
//
// 与 Legado 一致，词典规则由两段规则构成：
//   - urlRule：请求词典接口的 URL 模板（支持 {{key}} 占位与 @js:/<js> 动态生成）
//   - showRule：对响应正文抽取释义的规则（支持 Legado 选择器 / JSONPath /
//     @js: 表达式；多条规则用 && 串联，逐条求值后合并）
// 列表持久化到 SharedPreferences（与 ReplaceRuleService 同构），单例
// [DictRuleService.instance] 供阅读页长按查词与设置页共享。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../legado/legado_fjs_sandbox.dart';
import '../legado/legado_request.dart';
import '../legado/legado_rule_engine.dart';

/// 单条词典规则。
class DictRule {
  const DictRule({
    required this.id,
    required this.name,
    required this.urlRule,
    this.showRule = '',
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 词典接口 URL 模板：`{{key}}` 替换为查词词条，支持 `@js:...` 动态生成。
  final String urlRule;

  /// 释义抽取规则：Legado 选择器 / JSONPath / @js: 表达式，`&&` 分隔多条。
  final String showRule;

  final bool enabled;

  DictRule copyWith({
    String? name,
    String? urlRule,
    String? showRule,
    bool? enabled,
  }) => DictRule(
    id: id,
    name: name ?? this.name,
    urlRule: urlRule ?? this.urlRule,
    showRule: showRule ?? this.showRule,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'urlRule': urlRule,
        'showRule': showRule,
        'enabled': enabled,
      };

  static DictRule fromJson(Map<String, dynamic> json) => DictRule(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    urlRule: '${json['urlRule'] ?? ''}',
    showRule: '${json['showRule'] ?? ''}',
    enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
  );
}

/// 词典查询结果。
class DictLookupResult {
  const DictLookupResult({
    required this.word,
    required this.entries,
    this.rawPreview = '',
  });

  final String word;

  /// 逐条释义（由 showRule 各段求值结果汇集）。
  final List<String> entries;

  /// showRule 为空时回退的正文预览。
  final String rawPreview;

  bool get isEmpty => entries.isEmpty && rawPreview.trim().isEmpty;
}

/// 词典规则仓库 + 查词引擎。
///
/// 仓库部分（列表 CRUD/持久化）与 [ReplaceRuleService] 同构；引擎部分每个
/// 实例持有独立的 fjs 沙箱与 HTTP 传输（携带默认 SSRF 校验），避免与书源
/// 运行时互相污染变量。
class DictRuleService extends ChangeNotifier {
  DictRuleService();

  static const String storageKey = 'dict_rules_v1';

  /// 全局共享实例（阅读页查词与设置页共用同一份规则）。
  static final DictRuleService instance = DictRuleService();

  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  List<DictRule> _rules = const [];
  bool _loaded = false;

  LegadoFjsSandbox? _sandbox;
  LegadoHttpTransport? _transport;
  Future<LegadoRuleEngine>? _engineFuture;

  /// 当前全部规则。
  List<DictRule> get rules => List.unmodifiable(_rules);

  /// 当前启用的规则（长按查词时按序执行）。
  List<DictRule> get enabledRules =>
      _rules.where((rule) => rule.enabled).toList(growable: false);

  /// 确保已从存储加载（幂等）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _rules = decoded
              .whereType<Map>()
              .map((e) => DictRule.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false);
        }
      } on FormatException {
        _rules = const [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode(_rules.map((rule) => rule.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> add(DictRule rule) async {
    await ensureLoaded();
    _rules = [..._rules, rule];
    await _persist();
  }

  Future<void> update(String id, DictRule rule) async {
    await ensureLoaded();
    _rules = [
      for (final existing in _rules)
        if (existing.id == id) rule else existing,
    ];
    await _persist();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _rules = _rules.where((rule) => rule.id != id).toList(growable: false);
    await _persist();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await ensureLoaded();
    _rules = [
      for (final rule in _rules)
        if (rule.id == id) rule.copyWith(enabled: enabled) else rule,
    ];
    await _persist();
  }

  static int _idCounter = 0;
  static String newId() {
    final seq = _idCounter++;
    return 'dr_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_$seq';
  }

  // ===== 查词引擎 =====

  Future<LegadoRuleEngine> _engine() {
    return _engineFuture ??= () async {
      final sandbox = LegadoFjsSandbox();
      await sandbox.init();
      _sandbox = sandbox;
      _transport = LegadoHttpTransport();
      return LegadoRuleEngine(sandbox: sandbox);
    }();
  }

  /// 释放引擎持有的沙箱与会话（设置页退出时可调用）。
  void closeEngine() {
    _sandbox?.dispose();
    _transport?.close(force: true);
    _sandbox = null;
    _transport = null;
    _engineFuture = null;
  }

  /// 用单条规则查询 [word] 并抽取释义。
  Future<DictLookupResult> lookup(String word, DictRule rule) async {
    if (word.trim().isEmpty) {
      return DictLookupResult(word: word, entries: const []);
    }
    final engine = await _engine();
    final url = await _renderUrlRule(rule.urlRule, word);
    final response = await _fetch(url);
    if (response.body.trim().isEmpty) {
      return DictLookupResult(word: word, entries: const [], rawPreview: '（空响应）');
    }
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final showRule = rule.showRule.trim();
    if (showRule.isEmpty) {
      final preview = response.body.trim();
      return DictLookupResult(
        word: word,
        entries: const [],
        rawPreview: preview.length > 4000
            ? '${preview.substring(0, 4000)}\n…'
            : preview,
      );
    }
    if (_isJsRule(showRule)) {
      final evaluated = await _evaluateJs(showRule, docHtml: response.body);
      return DictLookupResult(word: word, entries: _stringifyJsResult(evaluated));
    }
    // 选择器/JSONPath：按 && 拆段，每段用规则引擎求值成列表后合并去重。
    final entries = <String>[];
    for (final segment in _splitShowRule(showRule)) {
      if (segment.isEmpty) continue;
      try {
        final values = await engine.evaluateList(document, null, segment);
        final strings = values
            .map(_flattenValue)
            .where((value) => value.trim().isNotEmpty)
            .toList(growable: false);
        if (strings.isNotEmpty) {
          entries.addAll(strings);
        } else {
          final single = await engine.evaluateString(document, null, segment);
          if (single.trim().isNotEmpty) entries.add(single.trim());
        }
      } on Exception {
        continue;
      }
    }
    return DictLookupResult(word: word, entries: List.unmodifiable(entries));
  }

  /// 渲染 urlRule：`{{key}}`/`{{word}}` 替换词条；`@js:`/`<js>` 走沙箱求值。
  Future<String> _renderUrlRule(String urlRule, String word) async {
    final trimmed = urlRule.trim();
    if (trimmed.isEmpty) return '';
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) {
      final result = await _evaluateJs(
        trimmed,
        extraGlobals: {'key': word, 'word': word},
      );
      return result.trim().isEmpty ? '' : result.trim();
    }
    return trimmed
        .replaceAll('{{key}}', word)
        .replaceAll('{{word}}', word);
  }

  Future<String> _evaluateJs(
    String code, {
    String? docHtml,
    Map<String, dynamic> extraGlobals = const {},
  }) async {
    final engine = await _engine();
    final sandbox = engine.sandbox;
    if (sandbox == null) return '';
    try {
      return await sandbox.evalJs(
        code,
        docHtml: docHtml,
        extraGlobals: extraGlobals,
      );
    } catch (_) {
      return '';
    }
  }

  Future<LegadoResponse> _fetch(String url) async {
    final transport = _transport;
    if (transport == null) {
      await _engine();
      return _fetch(url);
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const DictLookupException('invalid_url', '词典接口地址无效');
    }
    try {
      return await transport
          .send(
            LegadoRequestTemplate(
              url: uri,
              method: LegadoRequestMethod.get,
              headers: _browserHeaders,
              charset: 'utf-8',
            ),
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const DictLookupException('timeout', '词典请求超时');
    }
  }

  static List<String> _splitShowRule(String rule) {
    // 顶层 && 拆分：@js:/<js> 段内可能含 &&，先保护 JS 块再拆分。
    final jsBlocks = <String>[];
    var protected = rule.replaceAllMapped(RegExp('<js>.*?</js>', dotAll: true), (m) {
      jsBlocks.add(m.group(0)!);
      return '\u0001${jsBlocks.length - 1}\u0001';
    });
    final segments = protected.split('&&').map((s) => s.trim()).toList();
    for (var i = 0; i < segments.length; i++) {
      final repl = RegExp(r'^\u0001(\d+)\u0001$').firstMatch(segments[i]);
      if (repl != null) {
        final index = int.parse(repl.group(1)!);
        segments[i] = jsBlocks[index];
      }
    }
    return segments;
  }

  static bool _isJsRule(String rule) {
    final lower = rule.trimLeft().toLowerCase();
    return lower.startsWith('@js:') || lower.startsWith('<js>');
  }

  static String _flattenValue(Object? value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num || value is bool) return '$value';
    if (value is Map) {
      final name = value['name'];
      final text = value['text'];
      if (name is String && name.trim().isNotEmpty) return name.trim();
      if (text is String && text.trim().isNotEmpty) return text.trim();
    }
    return '$value';
  }

  static List<String> _stringifyJsResult(String evaluated) {
    final trimmed = evaluated.trim();
    if (trimmed.isEmpty) return const [];
    // JS 表达式结果为 JSON 数组时拆成逐条；否则整体作为一段释义。
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded.map(_flattenValue).where((s) => s.isNotEmpty).toList();
        }
      } on FormatException {
        // 非 JSON 数组按文本处理
      }
    }
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final values = <String>[];
          void collect(Object? v) {
            if (v is Map) {
              v.values.forEach(collect);
            } else if (v is List) {
              v.forEach(collect);
            } else if (v != null && '$v'.trim().isNotEmpty) {
              values.add('$v'.trim());
            }
          }

          collect(decoded);
          if (values.isNotEmpty) return values;
        }
      } on FormatException {
        // 按文本处理
      }
    }
    return [trimmed];
  }
}

/// 词典查询异常（可读 message 供 UI 展示）。
class DictLookupException implements Exception {
  const DictLookupException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}