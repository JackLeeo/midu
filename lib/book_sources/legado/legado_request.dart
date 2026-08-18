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
    final optionsStart = expanded.lastIndexOf(',{');
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
    final body = options['body'];
    if (body != null && body is! String) {
      throw const BookSourceProtocolException(
        'Legado request body must be text.',
      );
    }
    if (method == LegadoRequestMethod.get &&
        body is String &&
        body.isNotEmpty) {
      throw const BookSourceProtocolException(
        'GET Legado requests cannot contain a body.',
      );
    }

    final headers = <String, String>{};
    for (final entry in sourceHeaders.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || _forbiddenHeaders.contains(name.toLowerCase())) {
        throw BookSourceProtocolException(
          'Legado request header is not allowed: $name.',
        );
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
          throw const BookSourceProtocolException(
            'Legado request headers must be valid JSON.',
          );
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
          throw BookSourceProtocolException(
            'Legado request header is not allowed: $name.',
          );
        }
        headers[name] = value;
      }
    }
    final resolvedCharset = '${options['charset'] ?? 'utf-8'}'.trim().toLowerCase();
    if (!_supportedCharsets.contains(resolvedCharset)) {
      throw BookSourceProtocolException(
        'Unsupported Legado request charset: $resolvedCharset.',
      );
    }
    if (method == LegadoRequestMethod.post &&
        !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=$resolvedCharset';
    }
    return LegadoRequestTemplate(
      url: uri,
      method: method,
      headers: Map.unmodifiable(headers),
      charset: resolvedCharset,
      body: body as String?,
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

  @override
  Future<LegadoResponse> send(LegadoRequestTemplate request) async {
    var current = request.url;
    for (var redirects = 0; redirects <= 5; redirects++) {
      await _networkPolicy.validate(current);
      final cancelToken = CancelToken();
      try {
        final response = await _dio.requestUri<List<int>>(
          current,
          data: request.method == LegadoRequestMethod.post
              ? Uint8List.fromList(_encode(request.body ?? '', request.charset))
              : null,
          options: Options(
            method: request.method == LegadoRequestMethod.post ? 'POST' : 'GET',
            headers: request.headers,
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
  'host',
  'content-length',
  'transfer-encoding',
};

String _expandVariables(
  String input,
  Map<String, String> variables, {
  String charset = 'utf-8',
}) {
  var result = input.replaceAllMapped(
    RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
    (match) {
      final key = match.group(1)!;
      final value = variables[key];
      if (value == null) return match.group(0)!;
      return _encodeQueryValue(value, charset);
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
