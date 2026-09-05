// 文件说明：Web 管理服务器 —— dart:io HttpServer + REST + WebSocket(MCP)。
// 技术要点：
// - 默认仅绑定 loopback（address 可注入，集成测试用 127.0.0.1）；
// - /api/* 全部要求 `Authorization: Bearer <token>` 或 `?token=`，缺失/错误 → 401；
// - /ws 升级前校验 token（WebSocketRpcHub），非法则 401 拒绝升级；
// - 入站出参中任何将被代理/转发的 URL 先过 BookSourceNetworkPolicy.validate；
// - Flutter Web（kIsWeb）无 dart:io，入口由上层条件禁用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../book_sources/services/book_source_network_policy.dart';
import 'mcp_server.dart';
import 'web_socket_service.dart';

/// 允许绑定指定地址（默认 loopback）。Web 目标不可用（无 dart:io）。
class WebManagementServerConfig {
  const WebManagementServerConfig({
    this.address,
    this.staticConsole = _defaultConsole,
  });

  final InternetAddress? address;

  /// 内嵌极简管理台 HTML（GET / 返回）。
  final String staticConsole;

  static const String _defaultConsole = '''
<!DOCTYPE html>
<html lang="zh-CN"><meta charset="utf-8">
<title>米读 Web 管理台</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui;padding:24px;max-width:640px;margin:auto}
code{background:#f2f2f2;padding:2px 6px;border-radius:4px}</style>
<body>
<h1>米读 Web 管理台</h1>
<p>该页面由本地 Web 管理服务器提供。REST API 挂载于 <code>/api/*</code>，
WebSocket / MCP 挂载于 <code>/ws?token=…</code>。</p>
<ul>
<li><code>GET /api/health</code> — 健康检查</li>
<li><code>GET /api/status</code> — 服务器状态</li>
<li><code>WS  /ws?token=…</code> — JSON-RPC / MCP 工具调用</li>
</ul>
<p>所有接口均需携带令牌（<code>Authorization: Bearer &lt;token&gt;</code>）。</p>
</body></html>
''';
}

/// 一次 HTTP 抓取结果（http/get 工具出参）。
class McpHttpResponse {
  const McpHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// MCP http/get 的实际传输层（可注入以离线测试）。
typedef McpHttpTransport = Future<McpHttpResponse> Function(Uri uri);

/// 默认传输：最小头 GET（R2：不带 Content-Type、不改 Referer），UTF-8 解码。
Future<McpHttpResponse> defaultMcpHttpTransport(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return McpHttpResponse(statusCode: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

class WebManagementServer {
  WebManagementServer({
    required this.token,
    McpToolRegistry? registry,
    WebSocketRpcHub? wsHub,
    Future<List<String>> Function()? sourceListProvider,
    BookSourceNetworkPolicy? networkPolicy,
    McpHttpTransport? httpTransport,
    this.config = const WebManagementServerConfig(),
  }) : registry =
           registry ??
           _defaultRegistry(
             sourceListProvider: sourceListProvider,
             networkPolicy: networkPolicy,
             httpTransport: httpTransport,
           ),
       _wsHub = wsHub,
       _sourceListProvider = sourceListProvider ?? _noSources;

  static Future<List<String>> _noSources() async => const [];

  /// 默认工具集：基础工具（ping/status/sources/list）+ http/get（SSRF 前置校验）。
  static McpToolRegistry _defaultRegistry({
    Future<List<String>> Function()? sourceListProvider,
    BookSourceNetworkPolicy? networkPolicy,
    McpHttpTransport? httpTransport,
  }) {
    final registry = defaultMcpToolRegistry(
      sourceListProvider: sourceListProvider,
    );
    registry.register(
      McpTool(
        name: 'http/get',
        description: '通过 SSRF 校验后抓取指定 URL（返回状态码与正文前 2000 字符）。',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': '目标 URL'},
          },
          'required': ['url'],
        },
        handler: (args) => _mcpHttpGet(
          args,
          networkPolicy: networkPolicy ?? const BookSourceNetworkPolicy(),
          transport: httpTransport ?? defaultMcpHttpTransport,
        ),
      ),
    );
    return registry;
  }

  static Future<Object?> _mcpHttpGet(
    Map<String, Object?> args, {
    required BookSourceNetworkPolicy networkPolicy,
    required McpHttpTransport transport,
  }) async {
    final url = args['url'];
    if (url is! String || url.trim().isEmpty) {
      throw const McpError(-32602, 'http/get 缺少 url 参数');
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority) {
      throw const McpError(-32602, 'url 无法解析为有效地址');
    }
    // R3：所有新增网络入口先过 SSRF 校验；私有/内网目标在此被拒。
    await networkPolicy.validate(uri);
    final response = await transport(uri);
    final body = response.body.length > 2000
        ? '${response.body.substring(0, 2000)}…(已截断)'
        : response.body;
    return {'statusCode': response.statusCode, 'body': body};
  }

  final String token;
  final McpToolRegistry registry;
  final Future<List<String>> Function() _sourceListProvider;
  final WebSocketRpcHub? _wsHub;
  final WebManagementServerConfig config;

  HttpServer? _server;
  DateTime? _startedAt;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;
  Duration get uptime =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  WebSocketRpcHub get _hub => _wsHub ?? WebSocketRpcHub(registry: registry);

  /// 启动服务器并返回实际端口（port=0 时随机空闲端口，便于集成测试）。
  Future<int> start({int port = 0}) async {
    if (_server != null) return _server!.port;
    final address = config.address ?? InternetAddress.loopbackIPv4;
    final server = await HttpServer.bind(address, port);
    _server = server;
    _startedAt = DateTime.now();
    server.listen(_handleRequest);
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/' || path.isEmpty) {
        await _send(
          request.response,
          200,
          body: config.staticConsole,
          contentType: 'text/html; charset=utf-8',
        );
        return;
      }
      if (path == '/ws') {
        await _hub.handleUpgrade(request, token: token);
        return;
      }
      if (path.startsWith('/api/')) {
        if (!_authorized(request)) {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
          await _sendJson(request.response, {'error': 'unauthorized'});
          return;
        }
        await _handleApi(request);
        return;
      }
      await _send404(request.response);
    } catch (error) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.writeln('Internal error: $error');
        await request.response.close();
      } catch (_) {
        // 连接已断开
      }
    }
  }

  bool _authorized(HttpRequest request) {
    final bearer = request.headers.value(HttpHeaders.authorizationHeader);
    if (bearer != null && bearer == 'Bearer $token') return true;
    final queryToken = request.uri.queryParameters['token'];
    if (queryToken != null && queryToken == token) return true;
    return false;
  }

  Future<void> _handleApi(HttpRequest request) async {
    final path = request.uri.path;
    switch (path) {
      case '/api/health':
        await _sendJson(request.response, {'ok': true, 'service': 'midu'});
        return;
      case '/api/status':
        await _sendJson(request.response, {
          'ok': true,
          'port': port,
          'uptimeMs': uptime.inMilliseconds,
          'connections': _hub.activeConnections,
          'tools': [for (final tool in registry.tools) tool.name],
        });
        return;
      case '/api/sources':
        final names = await _sourceListProvider();
        await _sendJson(request.response, {'sources': names});
        return;
      default:
        await _send404(request.response);
    }
  }

  static Future<void> _send404(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    await _sendJson(response, {'error': 'not found'});
  }

  static Future<void> _sendJson(HttpResponse response, Object body) async {
    await _send(
      response,
      response.statusCode,
      body: jsonEncode(body),
      contentType: 'application/json; charset=utf-8',
    );
  }

  static Future<void> _send(
    HttpResponse response,
    int status, {
    required String body,
    required String contentType,
  }) async {
    response.statusCode = status;
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    response.write(body);
    await response.close();
  }
}