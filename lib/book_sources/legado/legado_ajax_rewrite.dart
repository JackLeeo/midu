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

final RegExp _ajaxCallRe = RegExp(r'java\.(ajax|connect|post)\s*\(');

/// 把 [code] 里的 `java.ajax('URL')` / `java.connect('URL', {options})` 调用，
/// 以及 `java.post(URL[, body][, headers]).body()` 调用先取回响应，改写为内联
/// 字符串字面量后返回。
///
/// 支持的参数形式：
///  - 字符串字面量第一参数：直接取回响应内联（现状行为）。
///  - 动态表达式参数：通过 [evalArg] 在 run 前先求值出 URL（对 `java.post`
///    用 `JSON.stringify([url, body, headers])` 一次性解析各实参），再取回响应
///    内联。求值失败或 [evalArg] 为空时，该调用原样保留（交给 JS 内
///    java.ajax/java.post 兜底返回空串）。
///  - `java.post(...).body()` 的 `.body()` 方法链会在替换时一并吞掉，避免替换
///    成 `"resp".body()` 抛 TypeError。
///
/// 无法定位到匹配右括号的调用原样保留。`fetcher` 为 null 时原样返回 [code]。
Future<String> rewriteAjaxCalls(
  String code, {
  Uri? baseUri,
  AjaxFetcher? fetcher,
  Future<String?> Function(String expr)? evalArg,
}) async {
  if (fetcher == null) return code;
  if (!code.contains('java.')) return code;
  final sb = StringBuffer();
  var index = 0;
  for (final match in _ajaxCallRe.allMatches(code).toList()) {
    sb.write(code.substring(index, match.start));
    final kind = match.group(1)!;
    final openParen = match.end; // 指向 '(' 之后的实参起始（正则把 '(' 计入 match）
    final closeParen = findCallClose(code, openParen);
    String? inlined;
    if (closeParen != null) {
      if (kind == 'post') {
        inlined = await _tryRewritePost(match, code, openParen, closeParen, baseUri, fetcher, evalArg);
      } else {
        // 优先按字符串字面量第一参数处理
        final urlLit = readJsString(code, openParen);
        if (urlLit != null) {
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
            sb.write(code.substring(match.start, match.end));
            index = match.end;
            continue;
          }
          final resolved = (baseUri != null)
              ? baseUri.resolve(urlLit.value).toString()
              : urlLit.value;
          final resp = await fetcher(
            resolved,
            method: method,
            headers: headers,
            body: body,
          );
          inlined = jsonEncode(resp);
        } else if (evalArg != null) {
          // 动态表达式第一参数：先求值出 URL，再取回响应内联（best-effort）。
          final argExpr = code.substring(openParen, closeParen).trim();
          if (argExpr.isNotEmpty) {
            try {
              final url = await evalArg(argExpr);
              final trimmed = url?.trim() ?? '';
              if (trimmed.isNotEmpty &&
                  (trimmed.startsWith('http://') ||
                      trimmed.startsWith('https://') ||
                      trimmed.startsWith('//'))) {
                final resolved = (baseUri != null)
                    ? baseUri.resolve(trimmed).toString()
                    : trimmed;
                final resp = await fetcher(resolved);
                inlined = jsonEncode(resp);
              }
            } catch (_) {
              inlined = null;
            }
          }
        }
      }
    }
    final endIndex = (closeParen != null)
        ? recalcEnd(code, closeParen, kind)
        : code.length;
    if (inlined == null) {
      // 无法解析/求值失败：原样保留该调用
      sb.write(code.substring(match.start, match.end));
      index = match.end;
      continue;
    }
    sb.write(inlined);
    index = endIndex;
  }
  sb.write(code.substring(index));
  return sb.toString();
}

/// 计算某次被改写调用的「真实结束下标」。对 `java.post(...)` 会把紧随其后的
/// `.body()` / `.text()` 方法链一并纳入替换区间；其它类型就是右括号之后。
int recalcEnd(String code, int closeParen, String kind) {
  var end = closeParen + 1;
  if (kind == 'post') {
    final cursor = skipWhitespace(code, end);
    if (cursor + 1 < code.length && code[cursor] == '.') {
      final chain = code.substring(cursor + 1);
      final m = RegExp(r'^(body|text|html)\(\)').firstMatch(chain);
      if (m != null) {
        end = cursor + 1 + m.end;
      }
    }
  }
  return end;
}

/// 改写 `java.post(URL[, body][, headers]).body()`。实参可能全是动态 JS 表达式，
/// 因此优先用 [evalArg] 求值 `JSON.stringify([url, body, headers])` 一次性取回。
/// 当第一参数是字符串字面量时直接按字面量解析，跳过求值。
Future<String?> _tryRewritePost(
  final Match match,
  final String code,
  final int openParen,
  final int closeParen,
  final Uri? baseUri,
  final AjaxFetcher? fetcher,
  final Future<String?> Function(String expr)? evalArg,
) async {
  final argExpr = code.substring(openParen, closeParen).trim();
  if (evalArg == null) return null;
  final split = _splitTopLevelArgs(argExpr);
  if (split.isEmpty) return null;
  // 第一参数：若为字符串字面量，url 直接取值（不再求值）；否则作为动态表达式
  // 放进求值包装，与 body/headers 一并由 evalArg 求值取回。
  String? literalUrl;
  final first = split[0].trim();
  if (first.startsWith('"') || first.startsWith("'")) {
    literalUrl = _stripQuotes(first);
    if (literalUrl == null) return null;
  }
  var second = split.length > 1 ? split[1] : 'null';
  var third = split.length > 2 ? split[2] : 'null';
  // 构造求值包装：JSON.stringify([url, body, headers])。url 为字面量时用
  // null 占位（避免重复求值），结果数组取 [1..2] 的 body/headers。
  final wrapper = literalUrl != null
      ? 'JSON.stringify([null, ($second), ($third)])'
      : 'JSON.stringify([(${first.isEmpty ? '""' : first}), ($second), ($third)])';
  String? jsonStr;
  try {
    jsonStr = await evalArg(wrapper);
  } catch (_) {
    return null;
  }
  if (jsonStr == null) return null;
  late final List<Object?> parts;
  try {
    final arr = jsonDecode(jsonStr) as List<dynamic>;
    final resolvedUrl = literalUrl ?? (arr[0] is String ? arr[0] as String : '');
    final body = (arr.length > 1 && arr[1] is String) ? arr[1] as String : null;
    final headers = (arr.length > 2 && arr[2] is Map)
        ? (arr[2] as Map).map((k, v) => MapEntry('$k', '$v'))
        : const <String, String>{};
    parts = [resolvedUrl, body, headers];
  } catch (_) {
    return null;
  }
  final rawUrl = '${parts[0] ?? ''}'.trim();
  if (rawUrl.isEmpty) return null;
  // 先对 baseUri 归一化（相对字面量如 "morechapter" 也允许），再校验协议。
  final resolved = (baseUri != null) ? baseUri.resolve(rawUrl).toString() : rawUrl;
  if (!(resolved.startsWith('http://') ||
      resolved.startsWith('https://') ||
      resolved.startsWith('//'))) {
    return null;
  }
  final body = parts.length > 1 && parts[1] is String
      ? parts[1] as String
      : null;
  final headers = parts.length > 2 && parts[2] is Map<String, String>
      ? parts[2] as Map<String, String>
      : const <String, String>{};
  try {
    final resp = await fetcher!(
      resolved,
      method: 'POST',
      headers: headers,
      body: body,
    );
    return jsonEncode(resp);
  } catch (_) {
    return null;
  }
}

/// 按顶层逗号拆分实参（忽略字符串/数组/对象/括号内的逗号）。
List<String> _splitTopLevelArgs(String text) {
  final parts = <String>[];
  if (text.trim().isEmpty) return parts;
  var depth = 0;
  var i = 0;
  var start = 0;
  var inString = false;
  var quote = '';
  while (i < text.length) {
    final ch = text[i];
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
    if (ch == '(' || ch == '[' || ch == '{') {
      depth++;
    } else if (ch == ')' || ch == ']' || ch == '}') {
      depth--;
    } else if (ch == ',' && depth == 0) {
      parts.add(text.substring(start, i).trim());
      start = i + 1;
    }
    i++;
  }
  parts.add(text.substring(start).trim());
  return parts.where((p) => p.isNotEmpty).toList();
}

/// 去掉单/双引号包裹（含首尾），返回字面量内容；非法返回 null。
String? _stripQuotes(String s) {
  final t = s.trim();
  if (t.length < 2) return null;
  final q = t[0];
  if ((q != '"' && q != "'") || t[t.length - 1] != q) return null;
  return t.substring(1, t.length - 1).replaceAll(r'\"', '"').replaceAll(r"\'", "'");
}

/// 从 [open]（某函数 `(` 之后的第一个实参字符）起，找到与之匹配的 `)` 下标。
/// 跳过字符串字面量与嵌套的 ()/[]/{}。找不到返回 null。
int? findCallClose(String code, int open) {
  var depth = 0;
  var i = open - 1; // 从 '(' 本身开始计数
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
    if (ch == '(' || ch == '[' || ch == '{') {
      depth++;
    } else if (ch == ')' || ch == ']' || ch == '}') {
      depth--;
      if (ch == ')' && depth == 0) return i;
    }
    i++;
  }
  return null;
}

/// 把 ES6 模板字符串 `` `a${expr}b` `` 原位转译为 ES5 字符串拼接，使不支持
/// 模板字面量的 QuickJS（部分 flutter_js 产物）也能执行 Legado 书源规则。
///
/// 只处理反引号模板（含 ${...} 插值），其余代码原样保留；`${expr}` 按模板
/// 语义用 `String(expr)` 转字符串。对已支持模板的引擎也是安全的（结果等价）。
String transpileTemplateLiterals(String js) {
  final out = StringBuffer();
  var i = 0;
  final n = js.length;
  while (i < n) {
    final c = js[i];
    if (c == r'\') {
      // 转义字符（可能转义了反引号本身）整体透传
      out.write(c);
      if (i + 1 < n) {
        out.write(js[i + 1]);
        i++;
      }
      i++;
      continue;
    }
    if (c == '`') {
      i++; // 跳过开头反引号
      final literals = <String>[];
      final exprs = <String>[];
      var lit = StringBuffer();
      var closed = false;
      while (i < n) {
        final ch = js[i];
        if (ch == r'\') {
          if (i + 1 < n) {
            final nxt = js[i + 1];
            if (nxt == '`') {
              lit.write('`');
            } else if (nxt == r'\') {
              lit.write(r'\');
            } else if (nxt == 'n') {
              lit.write('\n');
            } else if (nxt == 't') {
              lit.write('\t');
            } else if (nxt == 'r') {
              lit.write('\r');
            } else if (nxt == r'$') {
              lit.write(r'$');
            } else {
              lit.write(r'\');
              lit.write(nxt);
            }
            i += 2;
          } else {
            lit.write(r'\');
            i++;
          }
          continue;
        }
        if (ch == '`') {
          i++;
          closed = true;
          break;
        }
        if (ch == r'$' && i + 1 < n && js[i + 1] == '{') {
          literals.add(lit.toString());
          lit = StringBuffer();
          // 解析 ${ ... }（避免字符串/嵌套括号混淆）
          var depth = 1;
          var j = i + 2;
          final e = StringBuffer();
          var inStr = false;
          var strCh = '';
          while (j < n) {
            final cc = js[j];
            if (inStr) {
              e.write(cc);
              if (cc == r'\' && j + 1 < n) {
                e.write(js[j + 1]);
                j += 2;
                continue;
              }
              if (cc == strCh) inStr = false;
              j++;
              continue;
            }
            if (cc == '"' || cc == "'") {
              inStr = true;
              strCh = cc;
              e.write(cc);
              j++;
              continue;
            }
            if (cc == '{') {
              depth++;
            } else if (cc == '}') {
              depth--;
              if (depth == 0) {
                j++;
                break;
              }
            }
            e.write(cc);
            j++;
          }
          exprs.add(e.toString());
          i = j;
          continue;
        }
        lit.write(ch);
        i++;
      }
      literals.add(lit.toString());
      if (!closed) {
        // 未闭合：退化为原样（最坏情况丢失少量内容，规则通常不触发）
        out.write('`');
        out.write(literals.single);
      } else if (exprs.isEmpty) {
        out.write(jsonEncode(literals.single));
      } else {
        final seg = StringBuffer();
        seg..write('(')..write(jsonEncode(literals[0]));
        for (var k = 0; k < exprs.length; k++) {
          seg
            ..write(' + String(')
            ..write(exprs[k])
            ..write(') + ')
            ..write(jsonEncode(literals[k + 1]));
        }
        seg.write(')');
        out.write(seg);
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
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