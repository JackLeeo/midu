import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:gbk_codec/gbk_codec.dart';

import '../../utils/fast_gbk_decoder.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_source_network_policy.dart';

enum LegadoRequestMethod { get, post }

class LegadoRequestTemplate {
  const LegadoRequestTemplate({
    required this.url,
    required this.method,
    required this.headers,
    required this.charset,
    this.body,
  });

  final Uri url;
  final LegadoRequestMethod method;
  final Map<String, String> headers;
  final String charset;
  final String? body;

  static LegadoRequestTemplate parse(
    String template, {
    required Uri baseUri,
    Map<String, String> variables = const {},
    Map<String, String> sourceHeaders = const {},
  }) {
    // 米读：先探测请求字符集（options 里的 charset），{{key}}/{{page}} 等变量
    // 按该字符集百分号编码——GBK 站点若用 UTF-8 编码关键词会搜索不到结果。
    final charset = _peekCharset(template.trim());
    // 米读：注入 Legado 内置变量 baseUrl / sourceUrl（源根 URL）。部分源（品如
    // 漫画等）的请求选项块里用 `{{baseUrl}}/` 作 Referer，此前未注入导致
    // _unresolvedVariables 命中而抛「unsupported template expression」。
    if (baseUri.hasAuthority) {
      final root = '${baseUri.scheme}://${baseUri.host}'
          '${baseUri.hasPort ? ':${baseUri.port}' : ''}';
      variables = {
        ...variables,
        if (!variables.containsKey('baseUrl')) 'baseUrl': root,
        if (!variables.containsKey('sourceUrl')) 'sourceUrl': root,
      };
    }
    final expanded = _expandVariables(template.trim(), variables, charset: charset);
    if (_unresolvedVariables.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'Legado request contains an unsupported template expression.',
      );
    }
    if (_unsupportedRequestSyntax.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'Legado request uses scripting, which is not supported.',
      );
    }
    if (expanded.isEmpty) {
      throw const BookSourceProtocolException('Legado request URL is empty.');
    }

    var urlText = expanded;
    var options = const <String, dynamic>{};
    final optionsStart = _findOptionsStart(expanded);
    if (optionsStart >= 0) {
      final candidate = expanded.substring(optionsStart + 1).trim();
      try {
        final decoded = _decodeOptions(candidate);
        if (decoded is! Map) throw const FormatException();
        options = decoded.map((key, value) => MapEntry('$key', value));
        urlText = expanded.substring(0, optionsStart).trim();
      } on FormatException {
        throw const BookSourceProtocolException(
          'Legado request options must be a JSON object.',
        );
      }
    }

    final uri = baseUri.resolve(urlText);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Legado request targets must use HTTP or HTTPS.',
      );
    }

    final methodText = '${options['method'] ?? 'GET'}'.trim().toUpperCase();
    final method = switch (methodText) {
      'GET' => LegadoRequestMethod.get,
      'POST' => LegadoRequestMethod.post,
      _ => throw BookSourceProtocolException(
        'Unsupported Legado request method: $methodText.',
      ),
    };
    // 宽容：Legado 的 POST body 可能是字符串表单，也可能是 JSON 对象/数字
    // （API 类源常直接写 body 对象，如 {"keyword":...,"page":...}）。对象/数组
    // 序列化为 JSON 字符串，数字/布尔按文本发送；其余非文本类型才报错。
    final bodyRaw = options['body'];
    final String? body;
    var jsonBody = false;
    if (bodyRaw is String) {
      body = bodyRaw;
    } else if (bodyRaw is num || bodyRaw is bool) {
      body = bodyRaw.toString();
    } else if (bodyRaw is Map || bodyRaw is List) {
      body = jsonEncode(bodyRaw);
      jsonBody = true;
    } else if (bodyRaw == null) {
      body = null;
    } else {
      throw const BookSourceProtocolException(
        'Legado request body must be text.',
      );
    }
    if (method == LegadoRequestMethod.get && body != null && body.isNotEmpty) {
      throw const BookSourceProtocolException(
        'GET Legado requests cannot contain a body.',
      );
    }

    final headers = <String, String>{};
    for (final entry in sourceHeaders.entries) {
      final name = entry.key.trim();
      // 宽容：content-length/transfer-encoding 属 HTTP/2 伪头部，由传输层管理，
      // 源里显式设置（纵横中文等源）直接跳过而非报错，避免「header is not allowed」。
      if (name.isEmpty || _forbiddenHeaders.contains(name.toLowerCase())) {
        continue;
      }
      headers[name] = entry.value;
    }
    final optionHeaders = options['headers'];
    if (optionHeaders != null) {
      Object? normalizedHeaders = optionHeaders;
      if (normalizedHeaders is String) {
        try {
          normalizedHeaders = _decodeOptions(normalizedHeaders);
        } on FormatException {
          // 宽松降级：部分源 headers 用无引号键的对象写法（如 {Content-Type: ...}），
          // 严格 JSON/单引号归一都失败时，按「键: 值」朴素提取（咚漫漫画等源）。
          final loose = _looseDecodeHeaderText(normalizedHeaders as String);
          if (loose.isEmpty) {
            throw const BookSourceProtocolException(
              'Legado request headers must be valid JSON.',
            );
          }
          normalizedHeaders = loose;
        }
      }
      if (normalizedHeaders is! Map) {
        throw const BookSourceProtocolException(
          'Legado request headers must be an object.',
        );
      }
      for (final entry in normalizedHeaders.entries) {
        final name = '${entry.key}'.trim();
        final value = entry.value;
        if (name.isEmpty || value is! String) {
          throw const BookSourceProtocolException(
            'Legado request headers must contain text values.',
          );
        }
        if (_forbiddenHeaders.contains(name.toLowerCase())) {
          continue;
        }
        headers[name] = value;
      }
    }
    var resolvedCharset = '${options['charset'] ?? 'utf-8'}'.trim().toLowerCase();
    // 宽容：空 charset 视为 UTF-8；Legado 的 `escape`/`javascript`（URL escape 编码
    // 而非响应体编码）对我们而言仅影响查询参数编码（统一按 UTF-8 percent 编码），
    // 响应体解码又走内容自适应，因此直接映射到 utf-8 即可（铁血读书/佩蒲斐榕等源）。
    if (resolvedCharset.isEmpty ||
        resolvedCharset == 'escape' ||
        resolvedCharset == 'javascript') {
      resolvedCharset = 'utf-8';
    }
    if (!_supportedCharsets.contains(resolvedCharset)) {
      throw BookSourceProtocolException(
        'Unsupported Legado request charset: $resolvedCharset.',
      );
    }
    if (method == LegadoRequestMethod.post &&
        !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      headers['Content-Type'] = jsonBody
          ? 'application/json; charset=$resolvedCharset'
          : 'application/x-www-form-urlencoded; charset=$resolvedCharset';
    }
    return LegadoRequestTemplate(
      url: uri,
      method: method,
      headers: Map.unmodifiable(headers),
      charset: resolvedCharset,
      body: body,
    );
  }
}

Object? _decodeOptions(String input) {
  try {
    return jsonDecode(input);
  } on FormatException {
    // Historical source files often use JavaScript-style single-quoted object
    // literals. Normalize only quoted strings and object keys; expressions,
    // functions, comments and other executable syntax remain invalid.
    if (input.contains('`') ||
        input.contains(RegExp(r'\b(function|return|new)\b')) ||
        input.contains('//') ||
        input.contains('/*')) {
      rethrow;
    }
    // 宽容：选项/body 里偶见字符串内未转义的原始换行/制表符（女生文学等源），
    // 先做串内控制符转义再解析。
    try {
      return jsonDecode(_escapeControlCharsInStrings(input));
    } on FormatException {
      // ignore, 继续尝试单引号归一格
    }
    final buffer = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var escaped = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (escaped) {
        buffer.write(char == '"' && inSingle ? r'\"' : char);
        escaped = false;
        continue;
      }
      if (char == r'\') {
        buffer.write(char);
        escaped = true;
        continue;
      }
      if (char == '"' && !inSingle) {
        inDouble = !inDouble;
        buffer.write(char);
        continue;
      }
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
        buffer.write('"');
        continue;
      }
      if (inSingle && char == '"') {
        buffer.write(r'\"');
      } else {
        buffer.write(char);
      }
    }
    if (inSingle) throw const FormatException('Unterminated quoted string.');
    return jsonDecode(buffer.toString());
  }
}

/// 把 JSON 字符串值内出现的原始换行/回车/制表符转义为对应转义序列，
/// 使含未转义控制符的选项（body/header）可被 jsonDecode 解析。
String _escapeControlCharsInStrings(String input) {
  final sb = StringBuffer();
  var inString = false;
  var escaped = false;
  for (final char in input.split('')) {
    if (escaped) {
      sb.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      sb.write(char);
      escaped = true;
      continue;
    }
    if (char == '"') {
      inString = !inString;
      sb.write(char);
      continue;
    }
    if (inString) {
      if (char == '\n') {
        sb.write(r'\n');
        continue;
      }
      if (char == '\r') {
        sb.write(r'\r');
        continue;
      }
      if (char == '\t') {
        sb.write(r'\t');
        continue;
      }
    }
    sb.write(char);
  }
  return sb.toString();
}

/// 宽松解析无引号键的 header 对象字符串（如 `{Content-Type: application/x-www-form-urlencoded}`）。
/// 去除外层花括号后按逗号切分，逐条提取 `键: 值`；加引号的键/值会被剥离引号。
/// 解析不出任何条目时返回空 Map（由调用方决定是否报错）。
Map<String, String> _looseDecodeHeaderText(String raw) {
  final out = <String, String>{};
  var body = raw.trim();
  if (body.startsWith('{')) body = body.substring(1);
  if (body.endsWith('}')) body = body.substring(0, body.length - 1);
  final parts = body
      .split(RegExp(r'[,;\r\n]+|\r\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty);
  for (final part in parts) {
    final colon = part.indexOf(':');
    if (colon <= 0) continue;
    final key = part
        .substring(0, colon)
        .trim()
        .replaceAll(RegExp('^["\']+|["\']+\$'), '');
    var value = part.substring(colon + 1).trim();
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }
    if (key.isNotEmpty && value.isNotEmpty && !out.containsKey(key)) {
      out[key] = value;
    }
  }
  return out;
}

class LegadoResponse {
  const LegadoResponse({required this.body, required this.finalUri});

  final String body;
  final Uri finalUri;
}

abstract interface class LegadoTransport {
  Future<LegadoResponse> send(LegadoRequestTemplate request);
}

class LegadoHttpTransport implements LegadoTransport {
  LegadoHttpTransport({
    Dio? dio,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _networkPolicy = networkPolicy,
       _dio = dio ?? _createDio(networkPolicy, requestTimeout);

  final Dio _dio;
  final BookSourceNetworkPolicy _networkPolicy;
  final int maxResponseBytes;
  final Duration requestTimeout;

  /// 会话 Cookie jar（按 host 存储）。自动持久化响应里的 Set-Cookie 并在后续
  /// 请求携带——爱下网书等源的「正在验证浏览器」挑战页会先下发 PHPSESSID，
  /// 只有带着它回传 ?challenge=token 才会放行；无 jar 时挑战永远无法通过。
  /// 每个书源独立 runtime/transport，天然隔离，不会跨源串 cookie。
  final Map<String, Map<String, String>> _cookieJar = <String, Map<String, String>>{};

  static Dio _createDio(
    BookSourceNetworkPolicy policy,
    Duration requestTimeout,
  ) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: requestTimeout,
        receiveTimeout: requestTimeout,
        sendTimeout: requestTimeout,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: policy.createPinnedHttpClient,
    );
    return dio;
  }

  void close({bool force = true}) => _dio.close(force: force);

  /// 从响应 Set-Cookie 中提取 cookie 并写入该 host 的 jar（expired 直接删除）。
  void _persistSetCookies(String host, Headers headers) {
    final setCookies = headers['set-cookie'];
    if (setCookies == null || setCookies.isEmpty) return;
    final jar = _cookieJar.putIfAbsent(host, () => <String, String>{});
    for (final raw in setCookies) {
      final eq = raw.indexOf('=');
      if (eq <= 0) continue;
      final semi = raw.indexOf(';', eq);
      final name = raw.substring(0, eq).trim();
      final value = semi > eq ? raw.substring(eq + 1, semi).trim() : raw.substring(eq + 1).trim();
      final lower = raw.toLowerCase();
      if (lower.contains('max-age=0') || lower.contains('expires=thu, 01 jan 1970')) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  /// 拼接该 host 已保存的 cookie（若无则返回 null）。
  String? _cookieHeaderFor(Uri uri) {
    final jar = _cookieJar[uri.host];
    if (jar == null || jar.isEmpty) return null;
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    var current = request.url;
    for (var redirects = 0; redirects <= 5; redirects++) {
      await _networkPolicy.validate(current);
      final cancelToken = CancelToken();
      // 自动携带会话 cookie；源自定义了 Cookie 头时以源的为准。
      final headers = Map<String, String>.from(request.headers);
      final jarCookie = _cookieHeaderFor(current);
      if (jarCookie != null &&
          !headers.keys.any((k) => k.toLowerCase() == 'cookie')) {
        headers['Cookie'] = jarCookie;
      }
      try {
        final response = await _dio.requestUri<List<int>>(
          current,
          data: request.method == LegadoRequestMethod.post
              ? Uint8List.fromList(_encode(request.body ?? '', request.charset))
              : null,
          options: Options(
            method: request.method == LegadoRequestMethod.post ? 'POST' : 'GET',
            headers: headers,
            responseType: ResponseType.bytes,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (received > maxResponseBytes || total > maxResponseBytes) {
              cancelToken.cancel('Response exceeds $maxResponseBytes bytes.');
            }
          },
        );
        _persistSetCookies(current.host, response.headers);
        final status = response.statusCode ?? 0;
        if (status < 300) {
          final bytes = response.data ?? const <int>[];
          if (bytes.length > maxResponseBytes) {
            throw BookSourceProtocolException(
              'Legado response exceeds $maxResponseBytes bytes.',
            );
          }
          return LegadoResponse(
            body: _decode(bytes, request.charset, response.headers),
            finalUri: current,
          );
        }
        if (redirects == 5) {
          throw const BookSourceProtocolException(
            'Legado source redirected too many times.',
          );
        }
        current = BookSourceNetworkPolicy.redirectTarget(
          current,
          response.headers.value(HttpHeaders.locationHeader),
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          throw BookSourceProtocolException(
            error.message ?? 'Legado request was cancelled.',
          );
        }
        throw BookSourceProtocolException(
          error.response?.statusCode == null
              ? 'Could not connect to the Legado source.'
              : 'Legado source returned HTTP ${error.response!.statusCode}.',
        );
      }
    }
    throw const BookSourceProtocolException('Legado source request failed.');
  }
}

const _supportedCharsets = {'utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030'};
final _unresolvedVariables = RegExp(r'\{\{[^{}]+\}\}');
// 米读：不再禁用 @js / <js> 作为请求表达式，交由 fjs 预处理后再展开
final _unsupportedRequestSyntax = RegExp(
  r'@put:|@get:',
  caseSensitive: false,
);
// 米读：巨魔/自签安装，放开 Cookie 限制；仅保留 HTTP/2 禁止的伪头部
const _forbiddenHeaders = {
  // 允许源自定义 Host：部分站点同一 IP 上挂多个域名（同人圈、择日飞升等源），
  // 需显式 Host 才路由到正确 vhost。content-length/transfer-encoding 属 HTTP/2
  // 伪头部，仍禁止覆盖。
  'content-length',
  'transfer-encoding',
};

String _expandVariables(
  String input,
  Map<String, String> variables, {
  String charset = 'utf-8',
}) {
  // 米读：请求模板常形如「url,{...options...}」，末尾是 JSON 选项块。落在该块内、
  // 且紧跟 `:`/`,` 的 {{var}} 属于「未加引号的 JSON 值」（番薯小说/图书迷等 API 源的
  // `{"keyword":{{key}}}` 形态）。其字符集百分号编码会把中文编码成 %xx，再嵌入 JSON
  // 时既不是合法 JSON——关键字应作为 JSON 字符串字面量（页面/数字保持数值）。此处仅
  // 在 JSON 值位置生效，`"body":"searchkey={{key}}"` 这类已加引号/表单片段不受影响。
  final optionsStart = _findOptionsStart(input);
  var result = input.replaceAllMapped(
    RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
    (match) {
      final key = match.group(1)!;
      final value = variables[key] ?? variables[key.trim()];
      if (value != null) {
        // baseUrl / sourceUrl 是源根 URL 字面量，直接原样嵌入
        // （Header 里充当 Referer，对其百分号编码会破坏 `https://` 前缀）。
        if (key.trim() == 'baseUrl' || key.trim() == 'sourceUrl') {
          return value;
        }
        final inOptions = match.start > optionsStart;
        if (inOptions && _isUnquotedJsonValueContext(input, match.start)) {
          return RegExp(r'^-?\d+(\.\d+)?$').hasMatch(value)
              ? value
              : jsonEncode(value);
        }
        return _encodeQueryValue(value, charset);
      }
      // 宽容：`{{cookie.removeCookie(source.getKey())}}` 这类只做 cookie/source
      // 状态管理的脚本块，对结果 URL 无贡献。剥离（替换为空）而非当作“不支持模板
      // 表达式”报错。含 java. 的块（会产出数据/走网络）不剥离。
      final script = key.trim();
      if (!script.contains('java.') &&
          !script.contains('return ') &&
          (script.contains('cookie.') || script.contains('source.'))) {
        return '';
      }
      return match.group(0)!;
    },
  );
  // 米读：Legado 分页追加语法 <,xxx>（如 "page=<,{{page}}>"）——page=1 时整段
  // 移除（站点默认第一页），page>1 时替换为内部内容。此前未处理会被 Uri 转义
  // 成 %3C,1%3E 导致请求畸形。
  final page = variables['page'];
  if (page != null) {
    result = result.replaceAllMapped(RegExp(r'<,([^>]*)>'), (match) {
      return page == '1' ? '' : match.group(1)!;
    });
  }
  return result;
}

/// 定位「逗号 + 可选空白 + 左花括号」的选项分隔位置，返回该逗号的下标。
///
/// Legado 请求模板写作 `URL,{method:...,body:...}`，但部分源（书趣阁等）在
/// 逗号与左花括号之间留有空格或换行，写成 `URL, {\n"method":...\n}`。严格的
/// `lastIndexOf(',{')` 匹配不到，会把整段当 URL 解析抛「Illegal scheme character」。
/// 这里从左花括号往回跳过空白，若紧邻的是逗号，则该花括号就是选项块起点。
/// 取最后一个满足条件的下标（请求模板末尾的 options 块）。
int _findOptionsStart(String input) {
  var idx = input.length - 1;
  while (idx >= 0) {
    final openBrace = input.lastIndexOf('{', idx);
    if (openBrace < 0) return -1;
    var cursor = openBrace - 1;
    while (cursor >= 0 &&
        (input[cursor] == ' ' || input[cursor] == '\t' ||
            input[cursor] == '\r' || input[cursor] == '\n')) {
      cursor--;
    }
    if (cursor >= 0 && input[cursor] == ',') return cursor;
    // 该 `{` 不是选项块（如 URL 内带的 JSON/JS 花括号），继续向前找更早的 `{`。
    // openBrace 为 0 时 idx 会变 -1，由循环条件拦截，避免 lastIndexOf('{', -1) 抛 RangeError。
    idx = openBrace - 1;
  }
  return -1;
}

/// `{{var}}` 是否处于「未加引号的 JSON 值」位置：其位置左侧最近的非空白字符是
/// `:` 或 `,`（对象/数组的值位），且自身未被 `"` 包裹。命中才应作为 JSON 字面量
/// 展开（见 `_expandVariables`）；`"body":"s={{key}}"` 等已加引号片段不命中。
bool _isUnquotedJsonValueContext(String input, int matchStart) {
  if (matchStart == 0) return false;
  // 跳过紧邻 {{}} 左侧的空白。若最近的非空白字符是 `"`，说明 {{}} 位于某个
  // `"..."` 字符串体内（如 `"Referer":"{{baseUrl}}/"`、`"body":"k={{key}}"`），
  // 不是「未加引号的 JSON 值」，应原样展开而非包成 JSON 字符串字面量。
  var i = matchStart - 1;
  while (i >= 0 &&
      (input[i] == ' ' || input[i] == '\t' || input[i] == '\r' ||
          input[i] == '\n')) {
    i--;
  }
  if (i >= 0 && input[i] == '"') return false;
  for (; i >= 0; i--) {
    final ch = input[i];
    if (ch == ':' || ch == ',') return true;
    if (ch == '"' || ch == '{' || ch == '}' || ch == ' ') continue;
    if (ch == '\\') return false;
    // 命中字母/数字/等号等其它字符：不在 JSON 值位
    return false;
  }
  return false;
}

/// 按请求字符集对查询值做百分号编码：GBK 站点关键词需先转 GBK 字节再编码。
String _encodeQueryValue(String value, String charset) {
  if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030') {
    try {
      return gbk_bytes
          .encode(value)
          .map(
            (byte) => '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
          )
          .join();
    } catch (_) {
      // 个别字符 GBK 无法编码时回退 UTF-8
    }
  }
  return Uri.encodeQueryComponent(value);
}

/// 从 URL 模板的 `,{...}` options 中探测 charset（用于变量编码）。
String _peekCharset(String template) {
  final optionsStart = template.lastIndexOf(',{');
  if (optionsStart < 0) return 'utf-8';
  final candidate = template.substring(optionsStart + 1).trim();
  try {
    final decoded = _decodeOptions(candidate);
    if (decoded is Map) {
      final c = decoded['charset'];
      if (c is String && c.trim().isNotEmpty) {
        return c.trim().toLowerCase();
      }
    }
  } on FormatException {
    // 交由 parse 正式解析时报错
  }
  return 'utf-8';
}

List<int> _encode(String value, String charset) {
  if (charset == 'gbk' || charset == 'gb2312') {
    return gbk_bytes.encode(value);
  }
  return utf8.encode(value);
}

String _decode(List<int> bytes, String configured, Headers headers) {
  final raw = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  // 中文站点常把响应的 charset 标错或漏标（HTTP 头、请求配置都与页面实际编码不符），
  // 直接信它们会导致整页乱码，或「详情/目录乱码、正文正常」。
  // 改以内容为准：整段能作为合法 UTF-8 解码即按 UTF-8，否则按 GBK 解码。
  if (_looksLikeUtf8(raw)) {
    return utf8.decode(raw, allowMalformed: true);
  }
  return decodeGbkFast(
    raw,
    lenient: !isLikelyValidGbkByteStream(raw),
  );
}

/// 整段字节按 UTF-8 宽松解码后若无替换符（U+FFFD），判定为合法 UTF-8。
/// 简体中文 GBK 页面的双字节序列几乎不可能构成合法的 UTF-8，故可在 UTF-8/GBK 间可靠判定。
bool _looksLikeUtf8(Uint8List bytes) {
  if (bytes.isEmpty) return true;
  final decoded = utf8.decode(bytes, allowMalformed: true);
  return !decoded.contains('\uFFFD');
}
