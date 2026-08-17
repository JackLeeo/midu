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

  final LegadoJsSandbox? sandbox;

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
    // 米读：列表规则中的 @put:{...} 需要对列表的每个元素求值后存变量
    // （如 chapterList: "$..list[*]@put:{bid:$.info.articleid}"）。
    if (transformed.selector.contains('@put:')) {
      final cleaned = _stripPutBlocks(transformed.selector);
      final contexts = await evaluateList(document, context, cleaned);
      final putBodies = _extractPutBodies(transformed.selector);
      for (final ctx in contexts) {
        for (final body in putBodies) {
          for (final pair in _splitPutPairs(body)) {
            _storePut(pair.key, await _evalPutValue(document, ctx, pair.value));
          }
        }
      }
      return contexts;
    }
    final values = await _evaluateAlternatives(
      document,
      context,
      transformed.selector,
      listMode: true,
    );
    // 米读：JSON 路径返回单个 List 时展开为列表项（对齐 Legado getStringList 语义，
    // 如 "bookList": "data.data" 直接指向数组本身）。
    if (values.length == 1 && values.single is List) {
      return (values.single as List).whereType<Object?>().toList();
    }
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
    // 米读：中段 @js: 规则整体路由——先按 @js: 拆分，左侧（可含 ## 正则替换）
    // 先求值作为 result，再执行 JS。避免 _splitTransform 把 @js: 代码误吞进
    // 正则 replacement（如 intro: "id.intro@text##pat##rep@js:result.replace(...)"）。
    final jsMarker = _jsMarkerIndex(rule);
    if (jsMarker != null) {
      final left = rule.substring(0, jsMarker.index).trim();
      final jsPart = rule.substring(jsMarker.index).trim();
      if (left.isNotEmpty) {
        final leftResult = await evaluateString(
          document,
          context,
          left,
          resolveUrl: false,
        );
        final jsBody = _stripJsTag(jsPart).trim();
        // @js:##pattern##replacement 形式：仅对 result 做正则替换（无需 JS）
        if (jsBody.startsWith('##')) {
          final transformed = _splitTransform(jsBody);
          if (transformed.pattern == null) {
            return resolveUrl
                ? _resolveUrlString(document, leftResult)
                : leftResult;
          }
          try {
            final replaced = _replaceRegex(
              leftResult,
              RegExp(transformed.pattern!, multiLine: true, dotAll: true),
              transformed.replacement,
            );
            return resolveUrl
                ? _resolveUrlString(document, replaced)
                : replaced;
          } on FormatException {
            return resolveUrl
                ? _resolveUrlString(document, leftResult)
                : leftResult;
          }
        }
        if (jsBody.isEmpty) {
          return resolveUrl
              ? _resolveUrlString(document, leftResult)
              : leftResult;
        }
        final jsCode = jsPart.contains('{{')
            ? await _interpolateJs(jsPart, context ?? document.value, document)
            : jsPart;
        final jsValues = await _runJsRule(
          document,
          context,
          jsCode,
          listMode: false,
          result: leftResult,
        );
        if (jsValues == null || jsValues.isEmpty) return '';
        var value = _stringValue(jsValues.first);
        if (resolveUrl && value.isNotEmpty) value = _resolveUrlString(document, value);
        return value;
      }
    }
    final transformed = _splitTransform(rule);
    // 米读：先处理 @put:{...} / @get:{...} 操作符（可能在 ||/&& 拆分前执行，
    // 且 @get 替换结果需要作为字面量返回，而不是再当选择器解析）。
    final processed = await _preprocessPutGet(
      document,
      context,
      transformed.selector,
    );
    var result = processed.isPure ? processed.literal : '';
    if (!processed.isPure) {
      final selected = processed.selector.trim().isEmpty
          ? _rawValues(document, context)
          : await _evaluateAlternatives(
              document,
              context,
              processed.selector,
              listMode: false,
            );
      final values = selected
          .map(_stringValue)
          .where((value) => value.isNotEmpty)
          .toList();
      // 米读：URL 规则不应该把多个候选 join 在一起。
      // 例如 chapterUrl/nextContentUrl/bookUrl 匹配多个元素时，只取第一个有效值
      // （避免 "下一页" 链接在页首/页尾重复出现时被拼成 url1url2 导致后续 baseUri.resolve 出错）
      // 其余文本规则与 Legado 一致，多值用换行连接（如正文 $..content 匹配多段）。
      result = resolveUrl
          ? (values.isNotEmpty ? values.first : '')
          : values.join('\n');
    }
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: true,
        );
        result =
            processed.selector.trim().isEmpty &&
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
      return _resolveUrlString(document, result);
    }
    return result;
  }

  /// 把相对 URL 解析为绝对 URL（与 evaluateString 的 resolve 语义一致）。
  ///
  /// 提取结果已是完整绝对 URL（带 scheme）或协议相对 URL（// 开头）时直接返回，
  /// 避免被调用方二次 resolve 产生重复路径拼接。
  String _resolveUrlString(LegadoRuleDocument document, String value) {
    if (value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('//')) {
      if (value.startsWith('//')) {
        final scheme =
            document.baseUri.scheme == 'https' ? 'https:' : 'http:';
        return '$scheme$value';
      }
      return value;
    }
    final uri = document.baseUri.resolve(value);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const BookSourceProtocolException(
        'Legado rule produced a non-HTTP URL.',
      );
    }
    return uri.toString();
  }

  /// 先处理 @put / @get 操作符，返回清理后的选择器与（可选）字面量结果。
  ///
  /// - 规则完全由 @put/@get 组成时，[literal] 为最终字面量值（@get 结果），
  ///   不再作为选择器解析。
  /// - 混合规则（如 URL 模板含 @get）时，[literal] 为空，[selector] 为替换后的
  ///   字符串，继续走正常规则解析。
  Future<_ProcessedOps> _preprocessPutGet(
    LegadoRuleDocument document,
    Object? context,
    String selector,
  ) async {
    if (!selector.contains('@put:') && !selector.contains('@get:')) {
      return _ProcessedOps(selector: selector);
    }
    var cleaned = selector;
    final putBodies = _extractPutBodies(cleaned);
    cleaned = _stripPutBlocks(cleaned);
    // @put 对当前上下文求值后存变量
    for (final body in putBodies) {
      for (final pair in _splitPutPairs(body)) {
        _storePut(pair.key, await _evalPutValue(document, context, pair.value));
      }
    }
    // @get 替换为已存变量
    cleaned = cleaned.replaceAllMapped(RegExp(r'@get:\{([^{}]*)\}'), (match) {
      return _storeGet(match.group(1)!.trim());
    });
    // 规则原本全部是 @put/@get 操作符 → 结果即替换后的字面量
    // （含纯 @put 的 init 规则，此时 literal 为空、isPure=true，避免回落选择器解析）
    if (selector.contains('@') &&
        RegExp(r'^\s*(@(put|get):\{[^{}]*\}|[^\S\n])*\s*$').hasMatch(selector)) {
      return _ProcessedOps(selector: '', literal: cleaned, isPure: true);
    }
    return _ProcessedOps(selector: cleaned);
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
    for (final fallback in _splitAlternatives(selector)) {
      final concatenated = <Object?>[];
      for (final part in _splitAlternatives(fallback, andSplit: true)) {
        concatenated.addAll(
          await _evaluateSingle(document, context, part.trim(), listMode: listMode),
        );
      }
      if (concatenated.any((value) => _stringValue(value).isNotEmpty)) {
        return concatenated;
      }
    }
    return const [];
  }

  /// 拆分 `||`（及 [andSplit] 时的 `&&`）候选项。
  ///
  /// 纯 `@js:`/`<js>` 规则或中段 `@js:` 标记之后的 JS 代码整体作为一个单元，
  /// 不再拆分——JS 代码内可能有顶层 `||`/`&&`（如 `java.get("跳")==1||re==baseUrl&&...`），
  /// 误拆会破坏代码。仅 JS 标记之前的提取规则部分按 `||`/`&&` 拆分。
  List<String> _splitAlternatives(String selector, {bool andSplit = false}) {
    final delimiter = andSplit ? '&&' : '||';
    final lower = selector.trimLeft().toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) {
      return [selector];
    }
    final marker = _jsMarkerIndex(selector);
    if (marker != null) {
      final prefix = selector.substring(0, marker.index);
      final rest = selector.substring(marker.index);
      final parts = _splitTopLevel(prefix, delimiter);
      if (parts.isEmpty) {
        return [rest];
      }
      parts[parts.length - 1] = parts.last + rest;
      return parts;
    }
    return _splitTopLevel(selector, delimiter);
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
    // 米读：Legado 规则允许以 - 开头（-$.data.[*] / -.catalog_b@li@a），
    // 语义上等价于去掉负号后的规则，直接忽略前缀。
    if (normalized.startsWith('-')) {
      normalized = normalized.substring(1).trimLeft();
    }
    // 米读：@js / <js> 规则直接进入 JS 沙箱
    final lower = normalized.toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) {
      // 米读：Legado 先插值 {{...}} 再执行 JS（如 "@js:...bookId: {{$..bookId}}..."）
      final jsCode = normalized.contains('{{')
          ? await _interpolateJs(normalized, context ?? document.value, document)
          : normalized;
      final jsResult = await _runJsRule(document, context, jsCode, listMode: listMode);
      if (jsResult != null) return jsResult;
      return const [];
    }
    // 米读：中段 @js:（提取规则@js:JS代码）。先求值左侧提取规则作为 result，
    // 再执行 JS（如 coverUrl: "a@href\n@js:var id=result.match(...)"、
    // chapterUrl: "href@js:result+',{webView:\"true\"}'"）。
    // 左侧可含 ## 正则替换（如 intro: "id.intro@text##pat##rep@js:result.replace(...)"）。
    final jsMarker = _jsMarkerIndex(normalized);
    if (jsMarker != null) {
      final left = normalized.substring(0, jsMarker.index).trim();
      final jsPart = normalized.substring(jsMarker.index).trim();
      if (left.isNotEmpty) {
        final leftValues = await _evaluateSingle(
          document,
          context,
          left,
          listMode: listMode,
        );
        final leftResult = leftValues.map(_stringValue).join('\n');
        final jsBody = _stripJsTag(jsPart).trim();
        // @js:##pattern##replacement 形式：仅对 result 做正则替换（无需 JS）
        if (jsBody.startsWith('##')) {
          final transformed = _splitTransform(jsBody);
          if (transformed.pattern == null) return leftValues;
          try {
            return [
              _replaceRegex(
                leftResult,
                RegExp(transformed.pattern!, multiLine: true, dotAll: true),
                transformed.replacement,
              ),
            ];
          } on FormatException {
            return leftValues;
          }
        }
        if (jsBody.isEmpty) return leftValues;
        final jsCode = jsPart.contains('{{')
            ? await _interpolateJs(jsPart, context ?? document.value, document)
            : jsPart;
        final jsResult = await _runJsRule(
          document,
          context,
          jsCode,
          listMode: listMode,
          result: leftResult,
        );
        if (jsResult != null) return jsResult;
        return const [];
      }
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
    // 米读：@{{...}} 形式（如 "author": "@{{$.author_nickname}}"）去掉前导 @
    if (normalized.startsWith('@') && normalized.contains('{{')) {
      normalized = normalized.substring(1);
    }
    if (normalized.isEmpty) return const [];
    final root = context ?? document.value;
    // 米读：规则值 "0" 表示返回当前原始内容（对齐 Legado，常见于 kind 字段）
    if (normalized == '0') return [_rawString(root)];
    if (root is _RegexRuleContext) {
      return [root.expand(normalized)];
    }
    if (normalized.contains('{{') || _singleBraceTemplate.hasMatch(normalized)) {
      return [await _interpolate(normalized, root, document)];
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
    String result = '',
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
        'contextHtml': ?ctxValue,
        // 中段 @js: 规则：左侧提取结果作为 result 注入（JS 内可直接读 result）
        if (result.isNotEmpty) 'result': result,
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
      'ownText' => nodes.map(_ownText).toList(),
      // 米读：textNodes 应返回元素内所有文本节点内容（含后代 <p> 等），
      // 之前误用 ownText 只取直接子文本，导致正文段落被丢空。
      'textNodes' => nodes.map((node) => node.text.trim()).toList(),
      // 与 Legado 一致：@html 返回元素 outerHtml（含自身标签），并移除 script/style
      'html' => nodes.map((node) {
        for (final junk in node.querySelectorAll('script,style')) {
          junk.remove();
        }
        return node.outerHtml;
      }).toList(),
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
    // 米读：:nth-of-type 伪类 html 包不支持，走手动求值路径
    if (raw.contains(':nth-of-type(')) {
      try {
        return _selectWithNthOfType(roots, raw, includeRoots: includeRoots);
      } catch (_) {
        return const [];
      }
    }
    final parsed = _legacySelector(raw);
    // 米读：JSoup 语义的 [attr~=regex] 正则属性匹配 + 属性值补引号
    final attrPrep = _prepareAttributeSelector(parsed.css);
    // 米读：JSoup 伪类 :has(sel) / :lt(n) / :gt(n) / :eq(n) 手动求值
    final pseudoPrep = _extractPseudoFilters(attrPrep.css);
    final css = _escapeDigitClasses(pseudoPrep.css);
    final selected = <Element>[];
    for (final root in roots) {
      if (parsed.text != null) {
        final candidates = <Element>[root, ...root.querySelectorAll('*')];
        // 与 Legado 一致：text.xxx 用 ownText 包含匹配（getElementsContainingOwnText），
        // 同时兜底整段文本包含，兼容文字在子元素内的情况（如 <a><span>下一页</span></a>）。
        selected.addAll(
          candidates.where(
            (element) =>
                _ownText(element).contains(parsed.text!) ||
                element.text.contains(parsed.text!),
          ),
        );
      } else {
        try {
          if (includeRoots && _matches(root, css)) selected.add(root);
          selected.addAll(root.querySelectorAll(css));
        } on FormatException {
          throw BookSourceProtocolException(
            'Unsupported Legado CSS selector: $css.',
          );
        } on UnimplementedError {
          // 无法解析的伪类等：跳过该选择器，避免整条规则崩溃
          continue;
        }
      }
    }
    final deduped = selected.toSet().toList();
    if (attrPrep.regexes.isNotEmpty) {
      deduped.removeWhere((element) {
        for (final filter in attrPrep.regexes) {
          final value = element.attributes[filter.attr];
          if (value == null || !filter.pattern.hasMatch(value)) return true;
        }
        return false;
      });
    }
    var working = deduped;
    for (final filter in pseudoPrep.filters) {
      working = switch (filter.type) {
        'has' => working
            .where((element) => element.querySelectorAll(filter.arg).isNotEmpty)
            .toList(),
        'lt' => working.take(int.tryParse(filter.arg) ?? 0).toList(),
        'gt' => working
            .skip((int.tryParse(filter.arg) ?? 0) + 1)
            .toList(),
        'eq' => (() {
          final index = int.tryParse(filter.arg) ?? -1;
          return index >= 0 && index < working.length
              ? [working[index]]
              : <Element>[];
        })(),
        _ => working,
      };
    }
    if (parsed.excludes != null) {
      final excluded = parsed.excludes!
          .map((value) => _normalizedIndex(value, working.length))
          .where((value) => value >= 0 && value < working.length)
          .toSet();
      if (excluded.isNotEmpty) {
        for (var index = working.length - 1; index >= 0; index--) {
          if (excluded.contains(index)) working.removeAt(index);
        }
      }
    }
    if (parsed.indexes == null) return working;
    return parsed.indexes!
        .map((value) => _normalizedIndex(value, working.length))
        .where((value) => value >= 0 && value < working.length)
        .map((value) => working[value])
        .toList();
  }

  /// 提取 JSoup 伪类 :has(sel) / :lt(n) / :gt(n) / :eq(n)，返回基础选择器与过滤器。
  ({String css, List<_PseudoFilter> filters}) _extractPseudoFilters(String css) {
    final filters = <_PseudoFilter>[];
    var cleaned = css.replaceAllMapped(
      RegExp(r':(has|lt|gt|eq)\(([^()]*)\)'),
      (match) {
        filters.add(_PseudoFilter(match.group(1)!, match.group(2)!.trim()));
        return '';
      },
    );
    // 清理可能残留的连续空白（如 `tr:has(.odd):lt(6)` → `tr`）
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return (css: cleaned, filters: filters);
  }

  /// JSoup 语义的 [attr~=regex]：value 含正则元字符时按正则匹配；
  /// 同时给含冒号等非 ident 字符的属性值补引号（[property=og:title]）。
  /// 属性值可能含嵌套方括号（如 [href~=/[^/]+/\d+.htm]），用扫描器配对括号。
  ({String css, List<_AttrRegexFilter> regexes}) _prepareAttributeSelector(
    String css,
  ) {
    var cleaned = css;
    final regexes = <_AttrRegexFilter>[];
    final segments = <String>[];
    var cursor = 0;
    while (cursor < cleaned.length) {
      final open = cleaned.indexOf('[', cursor);
      if (open < 0) {
        segments.add(cleaned.substring(cursor));
        break;
      }
      // 配对 ]（支持值内嵌套 [ ]）
      var depth = 0;
      var close = -1;
      for (var i = open; i < cleaned.length; i++) {
        if (cleaned[i] == '[') {
          depth++;
        } else if (cleaned[i] == ']') {
          depth--;
          if (depth == 0) {
            close = i;
            break;
          }
        }
      }
      if (close < 0) {
        segments.add(cleaned.substring(cursor));
        break;
      }
      segments.add(cleaned.substring(cursor, open));
      final inner = cleaned.substring(open + 1, close);
      final parsed = _parseAttributeSelector(inner);
      if (parsed == null) {
        segments.add(cleaned.substring(open, close + 1));
      } else if (parsed.op == '~=' &&
          RegExp(r'[|()*+?^$\\\s]').hasMatch(parsed.value)) {
        regexes.add(_AttrRegexFilter(parsed.attr, parsed.value));
        segments.add('[${parsed.attr}]');
      } else if (parsed.op == '=' &&
          !RegExp(r'^[\w-]+$').hasMatch(parsed.value)) {
        segments.add('[${parsed.attr}="${parsed.value}"]');
      } else {
        segments.add(cleaned.substring(open, close + 1));
      }
      cursor = close + 1;
    }
    return (css: segments.join(), regexes: regexes);
  }

  /// 解析 [attr=value] / [attr~=value] 等属性选择器内部内容。
  ({String attr, String op, String value})? _parseAttributeSelector(
    String inner,
  ) {
    final match = RegExp(r'^\s*([\w-]+)\s*(~=|$=|\^=|\*=|!=|>=|<=|=)\s*(.*?)\s*$')
        .firstMatch(inner);
    if (match == null) return null;
    var value = match.group(3)!;
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    return (attr: match.group(1)!, op: match.group(2)!, value: value);
  }

  /// 数字开头的类名转 CSS 转义（.8dxgao → .\38 dxgao）。
  String _escapeDigitClasses(String css) =>
      css.replaceAllMapped(RegExp(r'\.(\d)'), (match) {
        return '.\\3${match.group(1)} ';
      });

  /// :nth-of-type(n) 手动求值，支持尾随 `~ sel` / `> sel` / 后代选择器。
  List<Element> _selectWithNthOfType(
    List<Element> roots,
    String raw, {
    required bool includeRoots,
  }) {
    final baseIdx = raw.indexOf(':nth-of-type(');
    final baseCss = raw.substring(0, baseIdx).trim();
    final rest = raw.substring(baseIdx + ':nth-of-type('.length);
    final closeIdx = rest.indexOf(')');
    final expression = rest.substring(0, closeIdx).trim();
    final tail = rest.substring(closeIdx + 1).trim();
    final nth = int.tryParse(expression);
    if (nth == null) return const [];
    final candidates = baseCss.isEmpty
        ? roots
        : _select(roots, baseCss, includeRoots: includeRoots);
    Element? picked;
    for (final element in candidates) {
      final parent = element.parent;
      if (parent == null) continue;
      final siblings =
          parent.children.where((c) => c.localName == element.localName).toList();
      if (siblings.indexOf(element) + 1 == nth) {
        picked = element;
        break;
      }
    }
    if (picked == null) return const [];
    if (tail.isEmpty) return [picked];
    if (tail.startsWith('~')) {
      final after = tail.substring(1).trim();
      final result = <Element>[];
      final siblings = picked.parent!.children;
      final start = siblings.indexOf(picked);
      for (var i = start + 1; i < siblings.length; i++) {
        if (_matches(siblings[i], after)) result.add(siblings[i]);
      }
      return result;
    }
    if (tail.startsWith('>')) {
      return _select([picked], tail.substring(1).trim(), includeRoots: false);
    }
    return _select([picked], tail, includeRoots: false);
  }

  _LegacySelector _legacySelector(String input) {
    var selector = input.trim();
    List<int>? excludes;
    // 米读：支持 Legado 多索引排除 !0:1:2 / 负索引 !0:-1（移除指定位置的元素）
    final exclusion = RegExp(r'!(-?\d+(?::-?\d+)*)$').firstMatch(selector);
    if (exclusion != null) {
      excludes = exclusion.group(1)!.split(':').map(int.parse).toList();
      selector = selector.substring(0, exclusion.start);
    }
    List<int>? indexes;
    // 米读：支持 Legado 方括号范围索引 tr[1:5]（1..4 左闭右开）
    final rangeMatch = RegExp(r'\[(\d+):(\d+)\]$').firstMatch(selector);
    if (rangeMatch != null) {
      final start = int.parse(rangeMatch.group(1)!);
      final end = int.parse(rangeMatch.group(2)!);
      indexes = [for (var i = start; i < end; i++) i];
      selector = selector.substring(0, rangeMatch.start);
    } else {
      final indexMatch = RegExp(r'\.(-?\d+(?::-?\d+)*)$').firstMatch(selector);
      if (indexMatch != null) {
        indexes = indexMatch.group(1)!.split(':').map(int.parse).toList();
        selector = selector.substring(0, indexMatch.start);
      }
    }
    String? text;
    if (selector.startsWith('class.')) {
      selector = '.${selector.substring(6)}';
    } else if (selector.startsWith('id.')) {
      selector = '#${selector.substring(3)}';
    } else if (selector.startsWith('tag.')) {
      selector = selector.substring(4);
    } else if (selector.startsWith('css.')) {
      // 米读：@css: 前缀可能出现在规则中段（如 div@css:.list@a），
      // 这里的 css. 是去除 @css: 前缀后的中段形式。
      selector = selector.substring(4);
    } else if (selector.startsWith('text.')) {
      text = selector.substring(5);
      selector = '*';
    }
    // 米读：排除/索引剥离后可能残留尾随点（如 tag.li.!0:1:2 → li.），去尾点
    while (selector.endsWith('.')) {
      selector = selector.substring(0, selector.length - 1);
    }
    if (selector.isEmpty) selector = '*';
    return _LegacySelector(
      css: selector,
      indexes: indexes,
      excludes: excludes,
      text: text,
    );
  }

  List<Object?> _jsonPath(Object? root, String path) {
    var normalized = path.trim();
    if (normalized == r'$') return [root];
    if (normalized.startsWith(r'$..')) {
      // 深扫描：只去掉 $，保留 ..
      normalized = normalized.substring(1);
    } else if (normalized.startsWith(r'$.')) {
      normalized = normalized.substring(2);
    }
    // 米读：兼容不带 $ 前缀的裸路径（如 book_name）
    else if (normalized.startsWith(r'$')) {
      normalized = normalized.substring(1);
    }
    if (normalized.isEmpty) return [root];
    final tokens = _tokenizeJsonPath(normalized);
    if (tokens.isEmpty) return const [];
    var values = <Object?>[root];
    for (final token in tokens) {
      final next = <Object?>[];
      for (final value in values) {
        switch (token.type) {
          case _JsonPathTokenType.deep:
            // 对齐 jayway JsonPath：$..x 递归下降时也检查根层容器自身
            next.add(value);
            _collectDeepContainers(value, next);
          case _JsonPathTokenType.all:
            if (value is List) {
              next.addAll(value);
            } else if (value is Map) {
              next.addAll(value.values);
            }
          case _JsonPathTokenType.idx:
            if (value is List) {
              final index = _normalizedIndex(token.value!, value.length);
              if (index >= 0 && index < value.length) next.add(value[index]);
            }
          case _JsonPathTokenType.filter:
            if (value is List) {
              next.addAll(value.where((item) => token.filter!.test(item)));
            } else if (value is Map) {
              next.addAll(
                value.values.where((item) => token.filter!.test(item)),
              );
            }
          case _JsonPathTokenType.key:
            if (value is Map && value.containsKey(token.key)) {
              next.add(value[token.key]);
            } else if (value is List) {
              // Legado 允许 $.data.0.url 这种把下标当作 key 的写法
              final rawIndex = int.tryParse(token.key!);
              if (rawIndex != null) {
                final index = _normalizedIndex(rawIndex, value.length);
                if (index >= 0 && index < value.length) next.add(value[index]);
              }
            }
        }
      }
      values = next;
    }
    return values;
  }

  /// 把 JSON 路径拆成 token 序列，支持：
  /// - `..` 深扫描（任意深度查找）
  /// - `[*]` / `*` 取全部元素（List 展开 / Map 全部值）
  /// - `[n]` 或 `.n` 下标访问
  /// - 普通 key 访问
  List<_JsonPathToken> _tokenizeJsonPath(String path) {
    final tokens = <_JsonPathToken>[];
    final key = StringBuffer();
    void flushKey() {
      final text = key.toString();
      if (text.isNotEmpty) {
        tokens.add(_JsonPathToken.key(text));
        key.clear();
      }
    }

    for (var i = 0; i < path.length; i++) {
      final ch = path[i];
      if (ch == '.') {
        if (i + 1 < path.length && path[i + 1] == '.') {
          flushKey();
          tokens.add(const _JsonPathToken.deep());
          i++;
        } else {
          flushKey();
        }
      } else if (ch == '[') {
        flushKey();
        final end = path.indexOf(']', i);
        if (end < 0) break;
        final inner = path.substring(i + 1, end).trim();
        if (inner == '*') {
          tokens.add(const _JsonPathToken.all());
        } else if (inner.startsWith('?(') && inner.endsWith(')')) {
          // 米读：支持 JSONPath 过滤器 [?(@.volume == false)]
          final filter = _parseJsonFilter(inner.substring(2, inner.length - 1));
          if (filter != null) tokens.add(_JsonPathToken.filter(filter));
        } else {
          final index = int.tryParse(inner);
          if (index != null) tokens.add(_JsonPathToken.idx(index));
        }
        i = end;
      } else if (ch == '*') {
        flushKey();
        tokens.add(const _JsonPathToken.all());
      } else {
        key.write(ch);
      }
    }
    flushKey();
    return tokens;
  }

  /// 递归收集 value 内所有层级的 Map/List（用于 `..` 深扫描）。
  static void _collectDeepContainers(Object? value, List<Object?> out) {
    if (value is Map) {
      for (final child in value.values) {
        if (child is Map || child is List) {
          out.add(child);
          _collectDeepContainers(child, out);
        }
      }
    } else if (value is List) {
      for (final child in value) {
        if (child is Map || child is List) {
          out.add(child);
          _collectDeepContainers(child, out);
        }
      }
    }
  }

  Future<String> _interpolate(
    String template,
    Object? context,
    LegadoRuleDocument doc,
  ) async {
    // 单趟：同时插值 {{...}} 与单花括号 {$.x} 模板
    return _interpolateTemplate(template, context, doc, singleBrace: true);
  }

  /// 只插值 {{...}}（JS 规则专用）：避免单花括号破坏 JS 对象字面量。
  Future<String> _interpolateJs(
    String code,
    Object? context,
    LegadoRuleDocument doc,
  ) async {
    return _interpolateTemplate(code, context, doc, singleBrace: false);
  }

  /// 插值模板：{{...}} 必须插值；[singleBrace] 时同时插值单花括号 {...}。
  Future<String> _interpolateTemplate(
    String template,
    Object? context,
    LegadoRuleDocument doc, {
    required bool singleBrace,
  }) async {
    var result = '';
    // 惰性匹配 {{...}}，允许内容含花括号（如 {{result=String(...).replace(/\{|\}/g,"")}}）
    final doubleBrace = RegExp(r'\{\{\s*([\s\S]*?)\s*\}\}');
    var cursor = 0;
    for (final match in doubleBrace.allMatches(template)) {
      result += template.substring(cursor, match.start);
      result += await _evalInterpolation(match.group(1)!, context, doc);
      cursor = match.end;
    }
    result += template.substring(cursor);
    if (!singleBrace) return result;
    var out = '';
    var c = 0;
    for (final match in _singleBraceTemplate.allMatches(result)) {
      out += result.substring(c, match.start);
      out += await _evalInterpolation(match.group(1)!.trim(), context, doc);
      c = match.end;
    }
    out += result.substring(c);
    return out;
  }

  /// 返回规则中第一个 `@js:` / `<js>` 标记的位置（仅当位于中段，即不是开头）。
  /// 开头形式的 `@js:` / `<js>` 已由纯 JS 分支处理，这里返回 null。
  ({int index, String marker})? _jsMarkerIndex(String rule) {
    final jsIdx = rule.indexOf('@js:');
    final tagIdx = rule.toLowerCase().indexOf('<js>');
    final int idx;
    if (jsIdx < 0 && tagIdx < 0) return null;
    if (tagIdx < 0 || (jsIdx >= 0 && jsIdx < tagIdx)) {
      idx = jsIdx;
    } else {
      idx = tagIdx;
    }
    if (idx <= 0) return null;
    return (index: idx, marker: rule.substring(idx, idx + 4));
  }

  /// 去掉 `@js:` / `<js>`…`</js>` 包裹标记，得到纯 JS 代码。
  static String _stripJsTag(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('@js:')) s = s.substring(4);
    s = s.replaceFirst(RegExp(r'^\s*<js>\s*', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'\s*</js>\s*$', caseSensitive: false), '');
    return s;
  }

  /// 求值 {{...}} / {...} 内的插值表达式，支持 `||` 回退（{{$.a||$.b}}）。支持：
  /// - @htmlRule（@@ 作用于整页，@ 作用于当前上下文），含 ## 正则转换
  /// - $.jsonPath，含 ## 正则转换
  /// - 纯变量名（{{bid}} 等）优先查 @put 变量存储
  /// - 引号包裹的字面量
  /// - JS 表达式（{{java.getString('$.x')}} / {{source.get('k')}} / {{result=...}}）
  Future<String> _evalInterpolation(
    String raw,
    Object? context,
    LegadoRuleDocument doc,
  ) async {
    for (final alternative in _splitTopLevel(raw, '||')) {
      final value = await _evalInterpolationSingle(alternative.trim(), context, doc);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<String> _evalInterpolationSingle(
    String expression,
    Object? context,
    LegadoRuleDocument doc,
  ) async {
    if (expression.startsWith('@')) {
      final wholeDoc = expression.startsWith('@@');
      final ruleBody = wholeDoc ? expression.substring(2) : expression.substring(1);
      final transformed = _splitTransform(ruleBody);
      var value = '';
      if (transformed.selector.trim().isNotEmpty) {
        final root = wholeDoc ? doc.value : context;
        final roots = <Element>[];
        if (root is Document) {
          roots.add(root.documentElement!);
        } else if (root is Element) {
          roots.add(root);
        } else if (doc.value is Document) {
          roots.add((doc.value as Document).documentElement!);
        }
        if (roots.isNotEmpty) {
          try {
            value = _htmlRule(roots, transformed.selector, listMode: false)
                .map(_stringValue)
                .join();
          } on BookSourceProtocolException {
            value = '';
          }
        }
      }
      if (transformed.pattern != null) {
        try {
          value = _replaceRegex(
            value,
            RegExp(transformed.pattern!, multiLine: true, dotAll: true),
            transformed.replacement,
          );
        } on FormatException {
          // 无效正则：保留原值，避免 Dart/JS 正则差异导致整条规则失败
        }
      }
      return value;
    }
    if ((expression.startsWith('"') && expression.endsWith('"')) ||
        (expression.startsWith("'") && expression.endsWith("'"))) {
      return expression.substring(1, expression.length - 1);
    }
    // 米读：纯变量名（{{bid}} 等）优先查 @put 变量存储
    if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(expression)) {
      final stored = _storeGet(expression);
      if (stored.isNotEmpty) return stored;
    }
    // 支持 {{$..path##pattern##replacement}}（表达式内嵌正则转换）
    final transformed = _splitTransform(expression);
    var value = _jsonPath(context, transformed.selector).map(_stringValue).join();
    if (transformed.pattern != null) {
      try {
        value = _replaceRegex(
          value,
          RegExp(transformed.pattern!, multiLine: true, dotAll: true),
          transformed.replacement,
        );
      } on FormatException {
        // 无效正则：保留原值
      }
    }
    if (value.isNotEmpty) return value;
    // 米读：非 JSON 路径表达式 → 尝试 JS 求值（{{java.getString('$.x')}}、
    // {{source.get('k')}}、{{result=String(...).replace(...)}} 等 Legado 插值 JS
    // 形态），避免 {{...}} 模板残留。
    if (RegExp(r'[()=+/]').hasMatch(expression)) {
      final js = await _evalJsInterpolation(expression, doc);
      if (js.isNotEmpty) return js;
    }
    return '';
  }

  /// 对插值表达式做 JS 求值：`@js:finalResult = (<expr>);`
  /// 赋值表达式（{{result=...}}）整体作为表达式求值即可返回其结果。
  Future<String> _evalJsInterpolation(
    String expression,
    LegadoRuleDocument doc,
  ) async {
    final s = sandbox;
    if (s == null) return '';
    try {
      final r = await s.evalJs(
        '@js:finalResult = ($expression);',
        docHtml: doc.rawBody,
        baseUri: doc.baseUri,
      );
      return r.trim();
    } catch (_) {
      return '';
    }
  }

  // ===== @put / @get 变量操作 =====

  String _storeGet(String key) => sandbox?.getSourceVar(key.trim()) ?? '';

  void _storePut(String key, String value) =>
      sandbox?.putSourceVar(key.trim(), value);

  static List<String> _extractPutBodies(String rule) {
    final pattern = RegExp(r'@put:\{([^{}]*)\}');
    final matches = pattern.allMatches(rule).toList(growable: false);
    return matches.map((m) => m.group(1)!).toList(growable: false);
  }

  static String _stripPutBlocks(String rule) {
    return rule.replaceAll(RegExp(r'@put:\{([^{}]*)\}'), '');
  }

  /// 解析 @put:{k1:v1,k2:v2} 中的键值对。仅在顶层逗号处拆分（引号/花括号内不算）。
  static List<MapEntry<String, String>> _splitPutPairs(String body) {
    final pairs = <MapEntry<String, String>>[];
    final parts = <String>[];
    var start = 0;
    var quote = 0; // 0=无引号, 1=双引号, 2=单引号
    var brace = 0;
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch == '"' || ch == "'") {
        if (i == 0 || body[i - 1] != r'\') {
          if (quote == 0) {
            quote = ch == '"' ? 1 : 2;
          } else if ((quote == 1 && ch == '"') || (quote == 2 && ch == "'")) {
            quote = 0;
          }
        }
      } else if (ch == '{') {
        brace++;
      } else if (ch == '}') {
        if (brace > 0) brace--;
      } else if (ch == ',' && quote == 0 && brace == 0) {
        parts.add(body.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(body.substring(start));
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final sep = trimmed.indexOf(':');
      if (sep <= 0) continue;
      final key = trimmed.substring(0, sep).trim();
      final value = trimmed.substring(sep + 1).trim();
      if (key.isEmpty) continue;
      pairs.add(MapEntry(key, value));
    }
    return pairs;
  }

  Future<String> _evalPutValue(
    LegadoRuleDocument document,
    Object? context,
    String rule,
  ) async {
    if (rule.trim().isEmpty) return '';
    // 真实书源中 @put 的值常带引号包裹（如 "@put:{intro:\"...@text\"}"），
    // 引号内是规则而非字面量，去引号后按规则求值。
    var value = rule.trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.isEmpty) return '';
    final result = await _evaluateAlternatives(
      document,
      context,
      value,
      listMode: false,
    );
    return result.map(_stringValue).join();
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

/// 单花括号插值模板：{$.json.path} 或 {varName}（不匹配 @put/@get 的 {} 块之外的内容）。
final _singleBraceTemplate = RegExp(r'\{(\s*\$[^{}]+|[A-Za-z_][A-Za-z0-9_]*)\}');

/// 在顶层（花括号平衡层级 0、引号外）按 [delimiter] 分割。
/// 保护 {{...##...}} 表达式内嵌的 ## / && / || 不被误拆分。
List<String> _splitTopLevel(String input, String delimiter) {
  final result = <String>[];
  var start = 0;
  var brace = 0;
  var quote = 0; // 0=无引号, 1=双引号, 2=单引号
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (ch == '"' || ch == "'") {
      if (i == 0 || input[i - 1] != r'\') {
        if (quote == 0) {
          quote = ch == '"' ? 1 : 2;
        } else if ((quote == 1 && ch == '"') || (quote == 2 && ch == "'")) {
          quote = 0;
        }
      }
    } else if (quote == 0) {
      if (ch == '{') {
        brace++;
      } else if (ch == '}') {
        if (brace > 0) brace--;
      } else if (brace == 0 && input.startsWith(delimiter, i)) {
        result.add(input.substring(start, i));
        i += delimiter.length - 1;
        start = i + 1;
      }
    }
  }
  result.add(input.substring(start));
  return result;
}

_RuleTransform _splitTransform(String rule) {
  final parts = _splitTopLevel(rule, '##');
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
    this.excludes,
    this.text,
  });

  final String css;
  final List<int>? indexes;
  final List<int>? excludes;
  final String? text;
}

/// JSoup [attr~=regex] 正则属性匹配过滤器。
class _AttrRegexFilter {
  _AttrRegexFilter(this.attr, String regex)
      : pattern = RegExp(regex, multiLine: true);

  final String attr;
  final RegExp pattern;
}

/// JSoup 伪类过滤器（:has / :lt / :gt / :eq）。
class _PseudoFilter {
  const _PseudoFilter(this.type, this.arg);

  final String type;
  final String arg;
}

/// @put/@get 预处理结果：selector 为清理后的选择器，literal 非空时直接作为字面量结果。
/// isPure=true 表示原规则全部由 @put/@get 操作符组成，结果即 literal（可为空）。
class _ProcessedOps {
  const _ProcessedOps({this.selector = '', this.literal = '', this.isPure = false});

  final String selector;
  final String literal;
  final bool isPure;
}

class _JsonPathToken {
  const _JsonPathToken._(this.type, {this.key, this.value, this.filter});

  const _JsonPathToken.deep() : this._(_JsonPathTokenType.deep);

  const _JsonPathToken.all() : this._(_JsonPathTokenType.all);

  const _JsonPathToken.idx(int index) : this._(_JsonPathTokenType.idx, value: index);

  const _JsonPathToken.key(String key) : this._(_JsonPathTokenType.key, key: key);

  const _JsonPathToken.filter(_JsonPathFilter filter)
      : this._(_JsonPathTokenType.filter, filter: filter);

  final _JsonPathTokenType type;
  final String? key;
  final int? value;
  final _JsonPathFilter? filter;
}

enum _JsonPathTokenType { deep, all, idx, key, filter }

/// JSONPath 过滤器（如 [?(@.volume == false)]）。
class _JsonPathFilter {
  _JsonPathFilter(this.left, this.op, this.literal, {this.rightPath});

  final String left;
  final String op;
  final Object? literal;
  final String? rightPath;

  bool test(Object? element) {
    final leftValue = _readFilterPath(element, left);
    final Object? rightValue =
        rightPath != null ? _readFilterPath(element, rightPath!) : literal;
    return switch (op) {
      '==' => leftValue == rightValue,
      '!=' => leftValue != rightValue,
      '>' => _compareFilter(leftValue, rightValue) > 0,
      '>=' => _compareFilter(leftValue, rightValue) >= 0,
      '<' => _compareFilter(leftValue, rightValue) < 0,
      '<=' => _compareFilter(leftValue, rightValue) <= 0,
      _ => leftValue != null,
    };
  }

  static Object? _readFilterPath(Object? element, String path) {
    var normalized = path.trim();
    if (normalized.startsWith('@')) normalized = normalized.substring(1);
    if (normalized.startsWith(r'$')) normalized = normalized.substring(1);
    normalized = normalized.replaceFirst(RegExp(r'^\.+'), '');
    if (normalized.isEmpty) return element;
    final values = _evalFilterPath(element, normalized);
    return values.isEmpty ? null : values.first;
  }

  static int _compareFilter(Object? a, Object? b) {
    if (a is num && b is num) return a.compareTo(b);
    return '$a'.compareTo('$b');
  }
}

/// 简易 `[?(@.key op value)]` 过滤器解析，op ∈ == != > >= < <=，value 支持
/// 字面量（数字/字符串/true/false）或另一路径（@.otherKey）。
_JsonPathFilter? _parseJsonFilter(String expression) {
  final match = RegExp(
    r'^\s*([@$]?(?:\.[\w-]+)+)\s*(==|!=|>=|<=|>|<)\s*(.+?)\s*$',
  ).firstMatch(expression);
  if (match == null) return null;
  var raw = match.group(3)!.trim();
  String? rightPath;
  Object? literal;
  if (raw.startsWith('@') || raw.startsWith(r'$')) {
    rightPath = raw;
  } else if ((raw.startsWith('"') && raw.endsWith('"')) ||
      (raw.startsWith("'") && raw.endsWith("'"))) {
    literal = raw.substring(1, raw.length - 1);
  } else if (raw == 'true') {
    literal = true;
  } else if (raw == 'false') {
    literal = false;
  } else if (raw == 'null') {
    literal = null;
  } else {
    literal = num.tryParse(raw) ?? raw;
  }
  return _JsonPathFilter(match.group(1)!, match.group(2)!, literal,
      rightPath: rightPath);
}

/// 过滤器内的简版 JSON 路径求值（按 . 拆 key，支持 [*] 展开）。
List<Object?> _evalFilterPath(Object? root, String path) {
  var values = <Object?>[root];
  for (final segment in path.split('.')) {
    if (segment.isEmpty) continue;
    final next = <Object?>[];
    for (final value in values) {
      if (segment == '*' && value is List) {
        next.addAll(value);
      } else if (value is Map && value.containsKey(segment)) {
        next.add(value[segment]);
      }
    }
    values = next;
    if (values.isEmpty) break;
  }
  return values;
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
