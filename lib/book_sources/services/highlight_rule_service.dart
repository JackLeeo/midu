// 高亮规则服务：对标 Legado HighlightRuleActivity + HighlightRule。
//
// 提供「自动高亮规则」——按规则把正文中匹配的文本自动着色，用于人名、术语、
// 关键词的阅读辅助。字段对齐 Legado HighlightRule：
//   - pattern：匹配文本；isRegex：是否为正则
//   - applyToBody / applyToTitle：是否作用于正文/章节标题
//   - styleHex：高亮颜色（十六进制，不含 #）
// 列表持久化到 SharedPreferences（与 ReplaceRuleService 同构），单例
// [HighlightRuleService.instance] 由阅读页渲染时应用。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条自动高亮规则。
class HighlightRule {
  const HighlightRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.isRegex = true,
    this.applyToBody = true,
    this.applyToTitle = true,
    this.styleHex = 'FFEB3B',
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 匹配模式：isRegex=true 时为正则；false 时为普通字符串。
  final String pattern;

  final bool isRegex;

  /// 是否作用于章节正文。
  final bool applyToBody;

  /// 是否作用于章节标题。
  final bool applyToTitle;

  /// 高亮颜色（十六进制，不含 # 前缀）。
  final String styleHex;

  final bool enabled;

  HighlightRule copyWith({
    String? name,
    String? pattern,
    bool? isRegex,
    bool? applyToBody,
    bool? applyToTitle,
    String? styleHex,
    bool? enabled,
  }) => HighlightRule(
    id: id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    isRegex: isRegex ?? this.isRegex,
    applyToBody: applyToBody ?? this.applyToBody,
    applyToTitle: applyToTitle ?? this.applyToTitle,
    styleHex: styleHex ?? this.styleHex,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'pattern': pattern,
        'isRegex': isRegex,
        'applyToBody': applyToBody,
        'applyToTitle': applyToTitle,
        'styleHex': styleHex,
        'enabled': enabled,
      };

  static HighlightRule fromJson(Map<String, dynamic> json) => HighlightRule(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    pattern: '${json['pattern'] ?? ''}',
    isRegex: json['isRegex'] is bool ? json['isRegex'] as bool : true,
    applyToBody: json['applyToBody'] is bool
        ? json['applyToBody'] as bool
        : true,
    applyToTitle: json['applyToTitle'] is bool
        ? json['applyToTitle'] as bool
        : true,
    styleHex: '${json['styleHex'] ?? 'FFEB3B'}',
    enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
  );
}

/// 自动高亮命中区间（相对于匹配文本的 UTF-16 偏移）。
class AutoHighlightRange {
  const AutoHighlightRange({
    required this.start,
    required this.end,
    required this.styleHex,
    required this.ruleId,
  });

  final int start;
  final int end;
  final String styleHex;
  final String ruleId;

  bool get isValid => start >= 0 && end > start;
}

/// 对正文/标题文本计算全部启用规则的高亮区间（按命中位置升序）。
///
/// - 正则模式使用全局匹配（不跨行，`^`/`$` 仅匹配串首尾）；
/// - 普通字符串模式按字面量查找全部命中；
/// - 非法正则静默跳过，不影响其他规则；
/// - 区间去重（重叠区间两两合并，避免重复叠加颜色）。
///
/// [title] 独立于 [text] 传入（章节标题通常不在正文串内）；[titleOffsetInText]
/// 为标题起始处相对 [text] 的偏移（未找到传 -1），>=0 时标题命中映射回正文
/// 偏移以便 span 渲染，否则标题命中被丢弃。
List<AutoHighlightRange> matchAutoHighlightRanges(
  String text,
  List<HighlightRule> rules, {
  String? title,
  int titleOffsetInText = -1,
}) {
  if (text.isEmpty || rules.isEmpty) return const [];
  final ranges = <AutoHighlightRange>[];
  void addRuleMatches(HighlightRule rule, String target, bool isTitle) {
    if (!rule.enabled || rule.pattern.isEmpty || target.isEmpty) return;
    // 作用范围过滤：正文/标题开关决定该规则是否命中对应文本。
    if (isTitle && !rule.applyToTitle) return;
    if (!isTitle && !rule.applyToBody) return;
    final baseOffset = isTitle && titleOffsetInText >= 0
        ? titleOffsetInText
        : 0;
    if (isTitle && baseOffset == 0 && titleOffsetInText < 0) return;
    if (rule.isRegex) {
      try {
        final re = RegExp(rule.pattern, caseSensitive: false, unicode: true);
        for (final match in re.allMatches(target)) {
          if (match.start < 0 || match.end <= match.start) continue;
          ranges.add(
            AutoHighlightRange(
              start: match.start + baseOffset,
              end: match.end + baseOffset,
              styleHex: rule.styleHex,
              ruleId: rule.id,
            ),
          );
        }
      } on FormatException {
        return;
      }
    } else {
      var from = 0;
      while (true) {
        final index = target.indexOf(rule.pattern, from);
        if (index < 0) break;
        ranges.add(
          AutoHighlightRange(
            start: index + baseOffset,
            end: index + rule.pattern.length + baseOffset,
            styleHex: rule.styleHex,
            ruleId: rule.id,
          ),
        );
        from = index + rule.pattern.length;
      }
    }
  }

  for (final rule in rules) {
    addRuleMatches(rule, text, false);
    if (title != null && title.isNotEmpty) {
      addRuleMatches(rule, title, true);
    }
  }
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : b.end.compareTo(a.end);
  });
  // 重叠合并：命中区间合并为最大跨度（颜色取最先出现的规则）。
  final merged = <AutoHighlightRange>[];
  for (final range in ranges) {
    if (merged.isEmpty || range.start >= merged.last.end) {
      merged.add(range);
    } else if (range.end > merged.last.end) {
      final last = merged.last;
      merged[merged.length - 1] = AutoHighlightRange(
        start: last.start,
        end: range.end,
        styleHex: last.styleHex,
        ruleId: last.ruleId,
      );
    }
  }
  return List.unmodifiable(merged);
}

/// 高亮规则仓库：内存列表 + SharedPreferences 持久化。
class HighlightRuleService extends ChangeNotifier {
  HighlightRuleService();

  static const String storageKey = 'highlight_rules_v1';

  /// 全局共享实例（阅读页渲染与设置页共用同一份规则）。
  static final HighlightRuleService instance = HighlightRuleService();

  List<HighlightRule> _rules = const [];
  bool _loaded = false;

  /// 当前全部规则。
  List<HighlightRule> get rules => List.unmodifiable(_rules);

  /// 当前启用的规则（渲染时传入匹配引擎）。
  List<HighlightRule> get enabledRules =>
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
              .map((e) => HighlightRule.fromJson(e.cast<String, dynamic>()))
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

  Future<void> add(HighlightRule rule) async {
    await ensureLoaded();
    _rules = [..._rules, rule];
    await _persist();
  }

  Future<void> update(String id, HighlightRule rule) async {
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
    return 'hr_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_$seq';
  }
}