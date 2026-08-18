import 'dart:convert';

// java.ajax / java.connect 的「eval 前源码改写」共用实现。
//
// QuickJS 的 bridge 回调是同步的，无法在同步桥里做异步 HTTP；因此采用
// 「eval 前源码改写」：在把规则交给引擎执行前，把 `java.ajax('URL'[,...])`
// 这类字面量调用先取回响应，内联成字符串字面量，再交给 JS。
//
// 该逻辑在多个 JS 运行相互相沿用：
//   - 生产 fjs 沙箱（legado_fjs_sandbox.dart，支持 JS→Dart 异步桥）；
//   - 本地 flutter_js 测试沙箱（test/helpers/flutter_js_sandbox.dart，无桥，
//     同样依赖改写预取）；
// 因此抽取为独立库，避免两份实现漂移。

/// java.ajax / java.connect 的网络执行器。由运行时注入（复用请求层的内容
/// 自适应解码）。为 null 时不做预取改写，相关调用保留交给 JS 兜底（返回空串）。
typedef AjaxFetcher = Future<String> Function(
  String url, {
  String method,
  Map<String, String>? headers,
  String? body,
});

/// 声明实现了 ajax fetcher 注入能力的 JS 沙箱（用于运行时通用注入）。
abstract class AjaxFetcherSink {
  void setAjaxFetcher(AjaxFetcher? fetcher);
}

final RegExp _ajaxCallRe = RegExp(r'java\.(ajax|connect)\s*\(');

/// 把 [code] 里的 `java.ajax('URL')` / `java.connect('URL', {options})`
/// 字面量调用先取回响应，改写为内联字符串字面量后返回。
///
/// 仅处理「第一参数是字符串字面量」且可定位到匹配右括号的调用；无法解析的调用
/// 原样保留。`fetcher` 为 null 时原样返回 [code]。
Future<String> rewriteAjaxCalls(
  String code, {
  Uri? baseUri,
  AjaxFetcher? fetcher,
}) async {
  if (fetcher == null) return code;
  if (!code.contains('java.')) return code;
  final sb = StringBuffer();
  var index = 0;
  for (final match in _ajaxCallRe.allMatches(code).toList()) {
    sb.write(code.substring(index, match.start));
    // 读取函数名后的字符串字面量（URL）
    final urlLit = readJsString(code, match.end);
    if (urlLit == null) {
      sb.write(code.substring(match.start, match.end));
      index = match.end;
      continue;
    }
    var cursor = skipWhitespace(code, urlLit.start);
    String method = 'GET';
    String? body;
    Map<String, String> headers = const<String, String>{};
    if (cursor < code.length && code[cursor] == ',') {
      final brace = readBraceObject(code, skipWhitespace(code, cursor + 1));
      if (brace != null) {
        final opts = parseAjaxOptions(code.substring(brace.start, brace.end + 1));
        method = opts.method;
        body = opts.body;
        headers = opts.headers;
        cursor = skipWhitespace(code, brace.end + 1);
      }
    }
    if (cursor >= code.length || code[cursor] != ')') {
      // 无法定位调用结束，原样保留
      sb.write(code.substring(match.start, match.end));
      index = match.end;
      continue;
    }
    final callEnd = cursor + 1;
    final resolved =
        (baseUri != null) ? baseUri.resolve(urlLit.value).toString() : urlLit.value;
    final resp = await fetcher(
      resolved,
      method: method,
      headers: headers,
      body: body,
    );
    // jsonEncode 保证转义成安全的 JS 字符串字面量
    sb.write(jsonEncode(resp));
    index = callEnd;
  }
  sb.write(code.substring(index));
  return sb.toString();
}

/// 从 [start] 起读取一个 JS 字符串字面量（单/双引号、含转义），返回其内容与结束下标。
({int start, String value})? readJsString(String code, int start) {
  if (start >= code.length) return null;
  final quote = code[start];
  if (quote != '"' && quote != '\'') return null;
  final buf = StringBuffer();
  var i = start + 1;
  var closed = false;
  while (i < code.length) {
    final ch = code[i];
    if (ch == r'\') {
      if (i + 1 >= code.length) return null;
      final n = code[i + 1];
      switch (n) {
        case 'n':
          buf.write('\n');
          break;
        case 't':
          buf.write('\t');
          break;
        case 'r':
          buf.write('\r');
          break;
        default:
          buf.write(n);
      }
      i += 2;
      continue;
    }
    if (ch == quote) {
      closed = true;
      i++;
      break;
    }
    buf.write(ch);
    i++;
  }
  if (!closed) return null;
  return (start: start, value: buf.toString());
}

/// 从 [start]（必须是 `{`）读取一个平衡花括号对象字面量，返回起止下标（含花括号）。
({int start, int end})? readBraceObject(String code, int start) {
  if (start >= code.length || code[start] != '{') return null;
  var depth = 0;
  var i = start;
  var inString = false;
  var quote = '';
  while (i < code.length) {
    final ch = code[i];
    if (inString) {
      if (ch == r'\') {
        i += 2;
        continue;
      }
      if (ch == quote) inString = false;
      i++;
      continue;
    }
    if (ch == '"' || ch == '\'') {
      inString = true;
      quote = ch;
      i++;
      continue;
    }
    if (ch == '{') {
      depth++;
    }
    if (ch == '}') {
      depth--;
      if (depth == 0) return (start: start, end: i);
    }
    i++;
  }
  return null;
}

int skipWhitespace(String code, int start) {
  var i = start;
  while (i < code.length &&
      (code[i] == ' ' || code[i] == '\t' || code[i] == '\n' || code[i] == '\r')) {
    i++;
  }
  return i;
}

({String method, String? body, Map<String, String> headers}) parseAjaxOptions(
  String text,
) {
  var method = 'GET';
  String? body;
  final headers = <String, String>{};
  final methodMatch =
      RegExp(r'''["']method["']\s*:\s*["']([^"']+)["']''').firstMatch(text);
  if (methodMatch != null) method = methodMatch.group(1)!.toUpperCase();
  final bodyMatch =
      RegExp(r'''["']body["']\s*:\s*["']((?:[^"']|\\.)*)["']''').firstMatch(text);
  if (bodyMatch != null) body = unescapeLiteral(bodyMatch.group(1)!);
  final headersMatch = RegExp(r'''["']headers["']\s*:\s*\{([^}]*)\}''').firstMatch(text);
  if (headersMatch != null) {
    final item = RegExp(r'''["']([^"']+)["']\s*:\s*["']((?:[^"']|\\.)*)["']''');
    for (final hm in item.allMatches(headersMatch.group(1)!)) {
      headers[unescapeLiteral(hm.group(1)!)] = unescapeLiteral(hm.group(2)!);
    }
  }
  return (method: method, body: body, headers: headers);
}

String unescapeLiteral(String s) => s.replaceAll(r'\"', '"').replaceAll(r"\'", "'");