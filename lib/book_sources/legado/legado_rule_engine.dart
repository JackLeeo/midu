import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../protocol/book_source_protocol.dart';
import 'legado_fjs_sandbox.dart';

class LegadoRuleDocument {
  LegadoRuleDocument._({required this.value, required this.baseUri, this.rawBody = ''});

  factory LegadoRuleDocument.parse(String body, Uri baseUri) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return LegadoRuleDocument._(
          value: jsonDecode(body),
          baseUri: baseUri,
          rawBody: body,
        );
      } on FormatException {
        // Some HTML pages begin with text resembling JSON. Parse them as HTML.
      }
    }
    return LegadoRuleDocument._(
      value: html_parser.parse(body),
      baseUri: baseUri,
      rawBody: body,
    );
  }

  final Object? value;
  final Uri baseUri;
  final String rawBody;
}

class LegadoRuleEngine {
  const LegadoRuleEngine({this.sandbox});

  final LegadoFjsSandbox? sandbox;

  static void ensureSupported(String rule, {required String field}) {
    // 米读：不再禁用 JS / XPath / state 语法，统一走 fjs 沙箱或原生 fallback；
    // 空规则允许返回空字符串，由上层决定是否视为失败。
    final text = rule.trim();
    if (text.isEmpty) return;
    // 保留对极个别破坏性语法的 sanity check（如包含 </script> 的注入风险），这里放行
    return;
  }

  Future<List<Object?>> evaluateList(
    LegadoRuleDocument document,
    Object? context,
    String rule,
  ) async {
    ensureSupported(rule, field: 'list rule');
    final transformed = _splitTransform(rule);
    if (transformed.selector.trimLeft().startsWith(':')) {
      return _evaluateRegexList(document, context, transformed.selector);
    }
    final values = await _evaluateAlternatives(
      document,
      context,
      transformed.selector,
      listMode: true,
    );
    return values.where((value) => value != null).toList(growable: false);
  }

  List<Object?> _evaluateRegexList(
    LegadoRuleDocument document,
    Object? context,
    String selector,
  ) {
    final stages = selector.trimLeft().substring(1).split('&&');
    var inputs = <String>[_rawString(context ?? document.value)];
    List<_RegexRuleContext> matches = const [];
    try {
      for (final stage in stages) {
        final pattern = RegExp(stage, multiLine: true, dotAll: true);
        matches = [
          for (final input in inputs)
            for (final match in pattern.allMatches(input))
              _RegexRuleContext(match),
        ];
        inputs = matches.map((match) => match.fullMatch).toList();
        if (inputs.isEmpty) break;
      }
    } on FormatException {
      throw const BookSourceProtocolException(
        'Legado list rule contains an invalid regular expression.',
      );
    }
    return matches;
  }

  Future<String> evaluateString(
    LegadoRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
  }) async {
    ensureSupported(rule, field: 'value rule');
    final transformed = _splitTransform(rule);
    final selected = transformed.selector.trim().isEmpty
        ? _rawValues(document, context)
        : await _evaluateAlternatives(
            document,
            context,
            transformed.selector,
            listMode: false,
          );
    final values = selected
        .map(_stringValue)
        .where((value) => value.isNotEmpty)
        .toList();
    var result = values.join();
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: true,
        );
        result =
            transformed.selector.trim().isEmpty &&
                transformed.replacement.isNotEmpty
            ? _extractRegex(result, pattern, transformed.replacement)
            : _replaceRegex(result, pattern, transformed.replacement);
      } on FormatException {
        throw const BookSourceProtocolException(
          'Legado rule contains an invalid regular expression.',
        );
      }
    }
    result = result.trim();
    if (resolveUrl && result.isNotEmpty) {
      final uri = document.baseUri.resolve(result);
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw const BookSourceProtocolException(
          'Legado rule produced a non-HTTP URL.',
        );
      }
      return uri.toString();
    }
    return result;
  }

  String applyReplaceRule(String input, String rule) {
    if (rule.trim().isEmpty) return input;
    ensureSupported(rule, field: 'replacement rule');
    final transformed = _splitTransform(
      rule.trim().startsWith('##') ? rule : '##$rule',
    );
    if (transformed.pattern == null) return input;
    try {
      return _replaceRegex(
        input,
        RegExp(transformed.pattern!, multiLine: true, dotAll: true),
        transformed.replacement,
      );
    } on FormatException {
      throw const BookSourceProtocolException(
        'Legado replacement contains an invalid regular expression.',
      );
    }
  }

  Future<List<Object?>> _evaluateAlternatives(
    LegadoRuleDocument document,
    Object? context,
    String selector, {
    required bool listMode,
  }) async {
    for (final fallback in selector.split('||')) {
      final concatenated = <Object?>[];
      for (final part in fallback.split('&&')) {
        concatenated.addAll(
          await _evaluateSingle(document, context, part.trim(), listMode: listMode),
        );
      }
      if (concatenated.any((value) => _stringValue(value).isNotEmpty)) {
        if (listMode && concatenated.isNotEmpty) return concatenated;
        return concatenated;
      }
    }
    return const [];
  }

  Future<List<Object?>> _evaluateSingle(
    LegadoRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
  }) async {
    var normalized = rule.trim();
    if (normalized.startsWith('+')) {
      normalized = normalized.substring(1).trimLeft();
    }
    // 米读：@js / <js> 规则直接进入 fjs 沙箱
    final lower = normalized.toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) {
      final jsResult = await _runJsRule(document, context, normalized, listMode: listMode);
      if (jsResult != null) return jsResult;
      return const [];
    }
    // 米读：XPath 规则 —— 先通过 fjs polyfill 模拟
    if (lower.startsWith('@xpath:') || normalized.trimLeft().startsWith('//')) {
      final xpathRule = lower.startsWith('@xpath:')
          ? normalized.substring(7)
          : normalized;
      final jsRule =
          '@js:finalResult = (typeof bridge === "function") ? String(bridge(JSON.stringify({__cmd:"doc_xpath", args:[${jsonEncode(xpathRule)}]})) || "") : "";';
      final jsResult = await _runJsRule(document, context, jsRule, listMode: listMode);
      if (jsResult != null) return jsResult;
      return const [];
    }
    if (normalized.toLowerCase().startsWith('@css:')) {
      normalized = normalized.substring(5).trimLeft();
    }
    if (normalized.isEmpty) return const [];
    final root = context ?? document.value;
    if (root is _RegexRuleContext) {
      return [root.expand(normalized)];
    }
    if (normalized.contains('{{')) {
      return [_interpolate(normalized, root, document)];
    }
    if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
        (normalized.startsWith("'") && normalized.endsWith("'"))) {
      return [normalized.substring(1, normalized.length - 1)];
    }
    final normalizedRule = normalized.toLowerCase().startsWith('@json:')
        ? normalized.substring(6)
        : normalized;
    if (root is Map || root is List || normalizedRule.startsWith(r'$.')) {
      return _jsonPath(root, normalizedRule);
    }
    final nodes = <Element>[];
    if (root is Document) {
      nodes.add(root.documentElement!);
    } else if (root is Element) {
      nodes.add(root);
    } else {
      return [root];
    }
    return _htmlRule(nodes, normalized, listMode: listMode);
  }

  Future<List<Object?>?> _runJsRule(
    LegadoRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
  }) async {
    final s = sandbox;
    if (s == null) return null;
    try {
      final ctxValue = context != null
          ? (context is Element
              ? context.outerHtml
              : context is Document
              ? context.outerHtml
              : jsonEncode(context))
          : null;
      final globals = <String, dynamic>{
        if (ctxValue != null) 'contextHtml': ctxValue,
      };
      final str = await s.evalJs(
        rule,
        docHtml: document.rawBody,
        baseUri: document.baseUri,
        extraGlobals: globals,
      );
      if (str.isEmpty) return null;
      // listMode：若结果是 JSON 数组，则展开；否则作为单值
      if (listMode) {
        final trimmed = str.trim();
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List) return decoded.toList(growable: false);
          } catch (_) {}
        }
        return [str];
      }
      return [str];
    } catch (_) {
      return null;
    }
  }

  List<Object?> _htmlRule(
    List<Element> roots,
    String rule, {
    required bool listMode,
  }) {
    final segments = rule.split('@').where((part) => part.isNotEmpty).toList();
    if (segments.isEmpty) return roots;
    var current = roots;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index].trim();
      final terminal = _terminalValue(current, segment);
      if (terminal != null && index == segments.length - 1) return terminal;
      current = _select(current, segment, includeRoots: index == 0);
      if (current.isEmpty) return const [];
    }
    return listMode ? current : current.map((node) => node.text).toList();
  }

  List<Object?>? _terminalValue(List<Element> nodes, String segment) {
    return switch (segment) {
      'text' => nodes.map((node) => node.text).toList(),
      'ownText' || 'textNodes' => nodes.map(_ownText).toList(),
      'html' => nodes.map((node) => node.innerHtml).toList(),
      // 米读：@all 在 Legado 中表示获取元素的完整内容（outerHtml），
      // 常用于章节正文提取，如 "id.content@all##广告" 规则。
      'all' => nodes.map((node) => node.outerHtml).toList(),
      _
          when _htmlAttributeNames.contains(segment.toLowerCase()) ||
              nodes.any((node) => node.attributes.containsKey(segment)) =>
        nodes.map((node) => node.attributes[segment] ?? '').toList(),
      _ => null,
    };
  }

  List<Element> _select(
    List<Element> roots,
    String raw, {
    required bool includeRoots,
  }) {
    final parsed = _legacySelector(raw);
    final selected = <Element>[];
    for (final root in roots) {
      if (parsed.text != null) {
        final candidates = <Element>[root, ...root.querySelectorAll('*')];
        final exact = candidates
            .where((element) => element.text.trim() == parsed.text)
            .toList();
        selected.addAll(
          exact.isNotEmpty
              ? exact
              : candidates.where(
                  (element) => element.text.contains(parsed.text!),
                ),
        );
      } else {
        try {
          if (includeRoots && _matches(root, parsed.css)) selected.add(root);
          selected.addAll(root.querySelectorAll(parsed.css));
        } on FormatException {
          throw BookSourceProtocolException(
            'Unsupported Legado CSS selector: ${parsed.css}.',
          );
        }
      }
    }
    final deduped = selected.toSet().toList();
    if (parsed.exclude != null) {
      final excluded = _normalizedIndex(parsed.exclude!, deduped.length);
      if (excluded >= 0 && excluded < deduped.length) {
        deduped.removeAt(excluded);
      }
    }
    if (parsed.indexes == null) return deduped;
    return parsed.indexes!
        .map((value) => _normalizedIndex(value, deduped.length))
        .where((value) => value >= 0 && value < deduped.length)
        .map((value) => deduped[value])
        .toList();
  }

  _LegacySelector _legacySelector(String input) {
    var selector = input.trim();
    int? exclude;
    final exclusion = RegExp(r'!(-?\d+)$').firstMatch(selector);
    if (exclusion != null) {
      exclude = int.parse(exclusion.group(1)!);
      selector = selector.substring(0, exclusion.start);
    }
    List<int>? indexes;
    final indexMatch = RegExp(r'\.(-?\d+(?::-?\d+)*)$').firstMatch(selector);
    if (indexMatch != null) {
      indexes = indexMatch.group(1)!.split(':').map(int.parse).toList();
      selector = selector.substring(0, indexMatch.start);
    }
    String? text;
    if (selector.startsWith('class.')) {
      selector = '.${selector.substring(6)}';
    } else if (selector.startsWith('id.')) {
      selector = '#${selector.substring(3)}';
    } else if (selector.startsWith('tag.')) {
      selector = selector.substring(4);
    } else if (selector.startsWith('text.')) {
      text = selector.substring(5);
      selector = '*';
    }
    if (selector.isEmpty) selector = '*';
    return _LegacySelector(
      css: selector,
      indexes: indexes,
      exclude: exclude,
      text: text,
    );
  }

  List<Object?> _jsonPath(Object? root, String path) {
    var normalized = path.trim();
    if (normalized == r'$') return [root];
    if (normalized.startsWith(r'$.')) normalized = normalized.substring(2);
    final tokens = RegExp(r'([^.\[\]]+)|\[(-?\d+|\*)\]')
        .allMatches(normalized)
        .map((match) => match.group(1) ?? match.group(2)!)
        .toList();
    if (tokens.isEmpty || tokens.join().isEmpty) return const [];
    var values = <Object?>[root];
    for (final token in tokens) {
      final next = <Object?>[];
      for (final value in values) {
        if (token == '*' && value is List) {
          next.addAll(value);
        } else if (value is Map && value.containsKey(token)) {
          next.add(value[token]);
        } else if (value is List) {
          final rawIndex = int.tryParse(token);
          if (rawIndex != null) {
            final index = _normalizedIndex(rawIndex, value.length);
            if (index >= 0 && index < value.length) next.add(value[index]);
          }
        }
      }
      values = next;
    }
    return values;
  }

  String _interpolate(
    String template,
    Object? context,
    LegadoRuleDocument doc,
  ) {
    return template.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (
      match,
    ) {
      final expression = match.group(1)!;
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        return expression.substring(1, expression.length - 1);
      }
      return _jsonPath(context, expression).map(_stringValue).join();
    });
  }

  List<Object?> _rawValues(LegadoRuleDocument document, Object? context) {
    final value = context ?? document.value;
    return switch (value) {
      Document document => [document.outerHtml],
      Element element => [element.outerHtml],
      _ => [value],
    };
  }
}

const _htmlAttributeNames = {
  'href',
  'src',
  'content',
  'value',
  'title',
  'alt',
  'data',
  'action',
};

class _RuleTransform {
  const _RuleTransform({
    required this.selector,
    this.pattern,
    this.replacement = '',
  });

  final String selector;
  final String? pattern;
  final String replacement;
}

_RuleTransform _splitTransform(String rule) {
  final parts = rule.split('##');
  if (parts.length == 1) return _RuleTransform(selector: rule);
  return _RuleTransform(
    selector: parts.first,
    pattern: parts.length > 1 ? parts[1] : null,
    replacement: parts.length > 2
        ? parts[2].replaceFirst(RegExp(r'###$'), '')
        : '',
  );
}

class _LegacySelector {
  const _LegacySelector({
    required this.css,
    this.indexes,
    this.exclude,
    this.text,
  });

  final String css;
  final List<int>? indexes;
  final int? exclude;
  final String? text;
}

int _normalizedIndex(int index, int length) =>
    index < 0 ? length + index : index;

String _ownText(Element element) =>
    element.nodes.whereType<Text>().map((node) => node.data).join().trim();

bool _matches(Element element, String selector) {
  final parent = element.parent;
  if (parent != null) {
    return parent.querySelectorAll(selector).contains(element);
  }
  return selector == '*' || selector == element.localName;
}

String _stringValue(Object? value) => switch (value) {
  null => '',
  String text => text,
  num number => '$number',
  bool boolean => '$boolean',
  Element element => element.text,
  _RegexRuleContext match => match.fullMatch,
  _ => '$value',
};

String _rawString(Object? value) => switch (value) {
  Document document => document.outerHtml,
  Element element => element.outerHtml,
  _RegexRuleContext match => match.fullMatch,
  null => '',
  _ => '$value',
};

class _RegexRuleContext {
  _RegexRuleContext(RegExpMatch match)
    : fullMatch = match.group(0) ?? '',
      groups = List.generate(match.groupCount + 1, match.group);

  final String fullMatch;
  final List<String?> groups;

  String expand(String template) {
    return template.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index >= groups.length) return capture.group(0)!;
      return groups[index] ?? '';
    });
  }
}

String _replaceRegex(String input, RegExp pattern, String replacement) {
  return input.replaceAllMapped(pattern, (match) {
    return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index > match.groupCount) return capture.group(0)!;
      return match.group(index) ?? '';
    });
  });
}

String _extractRegex(String input, RegExp pattern, String replacement) {
  final match = pattern.firstMatch(input);
  if (match == null) return '';
  return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
    final index = int.tryParse(capture.group(1)!);
    if (index == null || index > match.groupCount) return capture.group(0)!;
    return match.group(index) ?? '';
  });
}
