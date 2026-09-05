// 替换净化规则服务：对标 Legado ReplaceRuleListActivity。
//
// 提供全局「替换净化规则」——对任意书源提取后的正文文本做顺序替换/删除，
// 用于去掉站点注入的广告行、推广段落等。规则模型对齐 Legado ReplaceRule：
//   - pattern：正则（isRegex=true）或普通字符串（isRegex=false）
//   - replacement：替换文本（正则模式支持 $1 分组引用；为空表示删除匹配内容）
//   - enabled：开关；isRegex：是否按正则处理
//   - name：规则名（仅展示）
//
// 执行串为顺序的启用规则链（[applyReplaceRules]），文本先经段落到换行的归一
// 再做规则替换，与 Legado 的「正文替换净化」语义一致；列表持久化到
// SharedPreferences，单例 [ReplaceRuleService.instance] 供阅读页与设置页共享。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条替换净化规则。
class ReplaceRule {
  const ReplaceRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = true,
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 匹配模式：isRegex=true 时为正则表达式；false 时为普通字符串。
  final String pattern;

  /// 替换文本（正则模式支持 $1 分组引用；为空表示删除匹配内容）。
  final String replacement;

  /// 是否按正则解析 [pattern]。
  final bool isRegex;

  /// 该规则当前是否启用。
  final bool enabled;

  ReplaceRule copyWith({
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
  }) {
    return ReplaceRule(
      id: id,
      name: name ?? this.name,
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      isRegex: isRegex ?? this.isRegex,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'pattern': pattern,
        'replacement': replacement,
        'isRegex': isRegex,
        'enabled': enabled,
      };

  static ReplaceRule fromJson(Map<String, dynamic> json) {
    return ReplaceRule(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      pattern: '${json['pattern'] ?? ''}',
      replacement: '${json['replacement'] ?? ''}',
      isRegex: json['isRegex'] is bool ? json['isRegex'] as bool : true,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    );
  }
}

/// 展开替换模板中的分组引用：`$1`..`$n`（0 为整段匹配）与 `$$`（转义字面 \$）。
///
/// Legado replaceRegex 语义：替换文本按正则分组反向引用展开；
/// 无索引/越界分组展开为空串。
String _expandReplacementTemplate(String template, Match match) {
  if (!template.contains(r'$')) return template;
  return template.replaceAllMapped(
    RegExp(r'\$\$|\$(\d+)'),
    (m) {
      if (m.group(0) == r'$$') return r'$';
      final index = int.parse(m.group(1)!);
      final value = match.group(index);
      return value ?? '';
    },
  );
}

/// 顺序应用一组替换净化规则，返回净化后的文本。
///
/// - 仅应用 [enabled] 的规则，按列表顺序逐条执行（与 Legado 一致）；
/// - 正则模式使用多行匹配（`^`/`$` 作用于行边界，便于删除「以广告开头」的
///   整行），替换文本支持 `$1` 等分组引用（经 [_expandReplacementTemplate]）；
/// - 普通字符串模式走逐字面替换；
/// - 关闭的规则/非法正则跳过，不影响其余规则与原文（净化不能破坏正文）。
String applyReplaceRules(String input, List<ReplaceRule> rules) {
  if (input.isEmpty || rules.isEmpty) return input;
  var result = input;
  for (final rule in rules) {
    if (!rule.enabled) continue;
    final patternText = rule.pattern;
    if (patternText.isEmpty) continue;
    try {
      if (rule.isRegex) {
        // 正则净化默认多行（Legado replaceRegex 语义）：行锚点可命中广告行；
        // 不启用 DOTALL（避免贪婪分支跨行吞正文）。
        final re = RegExp(
          patternText,
          multiLine: true,
          caseSensitive: false,
          unicode: true,
        );
        result = result.replaceAllMapped(
          re,
          (match) => _expandReplacementTemplate(rule.replacement, match),
        );
      } else {
        result = result.replaceAll(patternText, rule.replacement);
      }
    } on FormatException {
      // 非法正则：跳过该规则，不破坏正文。
      continue;
    }
  }
  return result;
}

/// 替换净化规则仓库：内存列表 + SharedPreferences 持久化。
class ReplaceRuleService extends ChangeNotifier {
  ReplaceRuleService();

  static const String storageKey = 'replace_rules_v1';

  /// 全局共享实例（阅读页与设置页共用同一份规则链）。
  static final ReplaceRuleService instance = ReplaceRuleService();

  List<ReplaceRule> _rules = const [];
  bool _loaded = false;

  /// 当前全部规则（按执行顺序）。
  List<ReplaceRule> get rules => List.unmodifiable(_rules);

  /// 当前启用的规则（阅读渲染时传入净化链）。
  List<ReplaceRule> get enabledRules =>
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
              .map((e) => ReplaceRule.fromJson(e.cast<String, dynamic>()))
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

  /// 新增一条规则（追加到队尾）。
  Future<void> add(ReplaceRule rule) async {
    await ensureLoaded();
    _rules = [..._rules, rule];
    await _persist();
  }

  /// 更新指定 id 的规则（未找到则忽略）。
  Future<void> update(String id, ReplaceRule rule) async {
    await ensureLoaded();
    _rules = [
      for (final existing in _rules)
        if (existing.id == id) rule else existing,
    ];
    await _persist();
  }

  /// 删除指定 id 的规则。
  Future<void> remove(String id) async {
    await ensureLoaded();
    _rules = _rules.where((rule) => rule.id != id).toList(growable: false);
    await _persist();
  }

  /// 切换启停。
  Future<void> setEnabled(String id, bool enabled) async {
    await ensureLoaded();
    _rules = [
      for (final rule in _rules)
        if (rule.id == id) rule.copyWith(enabled: enabled) else rule,
    ];
    await _persist();
  }

  /// 将 [from] 位置的规则移动到 [to] 位置（其余保持相对顺序）。
  Future<void> move(int from, int to) async {
    await ensureLoaded();
    if (from < 0 || from >= _rules.length) return;
    final list = [..._rules];
    final moved = list.removeAt(from);
    final clamped = to.clamp(0, list.length);
    list.insert(clamped, moved);
    _rules = list;
    await _persist();
  }

  /// 生成新规则 id：时间戳（36 进制）+ 单调计数，保证同一微秒内连续调用也唯一。
  static int _idCounter = 0;
  static String newId() {
    final seq = _idCounter++;
    return 'rr_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_$seq';
  }
}