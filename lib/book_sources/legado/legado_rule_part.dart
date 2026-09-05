// 文件说明：Legado 规则分片（RulePart）解析与重组。
// 技术要点：书源规则在 Legado 语义中是「由多个指令块按 && / || 组合」的字符串；
// 编辑页要能无损地把一条规则拆成可独立编辑的片段（@js:、@put:、@get:、@xpath:、
// @json:、@css:、:::、@webView 等），保存时再重组回原语义。本文件只负责
// 字符串层面的拆分/重组，不执行任何规则，保证编辑往返无损。

/// 单个规则片段：指令类型 + 原始文本。
class LegadoRulePart {
  const LegadoRulePart({
    required this.type,
    required this.body,
    this.separator = '&&',
  });

  /// 指令类型：`js` / `put` / `get` / `xpath` / `json` / `css` / `regex` /
  /// `webBrowser` / `webView` / `text`（无前缀的普通选择器）。
  final String type;

  /// 指令体（不含前缀，不含结束分隔符）。
  final String body;

  /// 本片段与前一片段之间的连接符（`&&` 或 `||`）。
  final String separator;

  /// 还原为可执行规则的字符串片段（含前缀与分隔符前缀）。
  String get rendered {
    final prefix = switch (type) {
      'js' => '@js:',
      'put' => '@put:',
      'get' => '@get:',
      'xpath' => '@xpath:',
      'json' => '@json:',
      'css' => '@css:',
      'regex' => ':',
      'webBrowser' => '@webBrowser:',
      'webView' => '@webView:',
      'text' => '',
      _ => '',
    };
    return '$prefix$body';
  }
}

/// 把一条完整规则拆解为规则片段列表。
///
/// 拆分策略（对齐 Legado 的 RuleAnalyzer 顶层切分）：
/// - 仅在顶层切分 `&&` / `||`（忽略括号、引号、[] 内的分隔符）；
/// - 每个片段再按前缀识别指令类型；
/// - 首个片段的 [LegadoRulePart.separator] 为空串。
List<LegadoRulePart> splitLegadoRule(String rule) {
  final segments = _splitTopLevelWithSeparators(rule);
  final parts = <LegadoRulePart>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final raw = segment.text.trim();
    if (raw.isEmpty) continue;
    final separator = index == 0 ? '' : segment.separatorBefore;
    final (type, body) = _typeOf(raw);
    parts.add(
      LegadoRulePart(type: type, body: body.trim(), separator: separator),
    );
  }
  return parts;
}

/// 顶层切分结果片段：正文 + 与前一片段之间的分隔符。
class _RuleSegment {
  const _RuleSegment({required this.text, required this.separatorBefore});

  final String text;
  final String separatorBefore;
}

/// 按顶层 `&&` / `||` 切分（保护括号/引号），同时记录每段前的分隔符。
List<_RuleSegment> _splitTopLevelWithSeparators(String input) {
  final result = <_RuleSegment>[];
  var start = 0;
  var paren = 0;
  var square = 0;
  var brace = 0;
  var quote = 0; // 0=无引号, 1=双引号, 2=单引号
  String lastSeparator = '';
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
      if (ch == '(') {
        paren++;
      } else if (ch == ')') {
        if (paren > 0) paren--;
      } else if (ch == '[') {
        square++;
      } else if (ch == ']') {
        if (square > 0) square--;
      } else if (ch == '{') {
        brace++;
      } else if (ch == '}') {
        if (brace > 0) brace--;
      } else if (paren == 0 && square == 0 && brace == 0) {
        if (i + 1 < input.length && input[i] == '&' && input[i + 1] == '&') {
          result.add(
            _RuleSegment(
              text: input.substring(start, i),
              separatorBefore: lastSeparator,
            ),
          );
          i += 1;
          start = i + 1;
          lastSeparator = '&&';
        } else if (i + 1 < input.length &&
            input[i] == '|' &&
            input[i + 1] == '|') {
          result.add(
            _RuleSegment(
              text: input.substring(start, i),
              separatorBefore: lastSeparator,
            ),
          );
          i += 1;
          start = i + 1;
          lastSeparator = '||';
        }
      }
    }
  }
  result.add(
    _RuleSegment(
      text: input.substring(start),
      separatorBefore: lastSeparator,
    ),
  );
  return result;
}

/// 把片段列表重组成一条规则字符串（无损往返）。
String joinLegadoRule(List<LegadoRulePart> parts) {
  final buffer = StringBuffer();
  for (final part in parts) {
    if (part.separator.isNotEmpty) buffer.write(part.separator);
    final rendered = part.rendered;
    buffer.write(rendered);
    if (part.type == 'regex') {
      // 正则片段以整个 `:pattern` 形式书写，无额外前缀，rendered 已含前导冒号。
      // 保持原样。
    }
  }
  return buffer.toString();
}

/// 识别指令类型。
(String, String) _typeOf(String raw) {
  for (final prefix in const [
    '@js:',
    '@put:',
    '@get:',
    '@xpath:',
    '@json:',
    '@css:',
    '@webBrowser:',
    '@webView:',
  ]) {
    if (raw.startsWith(prefix)) {
    return (
      prefix.replaceAll('@', '').replaceAll(':', '').toLowerCase(),
      raw.substring(prefix.length),
    );
  }
  }
  if (raw.startsWith(':')) {
    return ('regex', raw.substring(1));
  }
  return ('text', raw);
}