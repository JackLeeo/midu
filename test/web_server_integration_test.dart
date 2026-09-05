// 文件说明：M10 Web 管理服务器集成测试。
// 覆盖：REST 鉴权（无 token → 401）、健康/状态/书源接口、WebSocket 升级鉴权、
// JSON-RPC（ping / tools/list / tools/call）、http/get 的 SSRF 拦截与传输注入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/services/web_server/mcp_server.dart';
import 'package:midu/services/web_server/web_server_service.dart';

/// 单一订阅的 WebSocket 回复读取器：保持一条 listen，按调用顺序配对回复。
class _ReplyReader {
  _ReplyReader(WebSocket socket) {
    _sub = socket.listen((event) {
      final pending = _waiters.removeAt(0);
      pending.complete(event);
    });
  }

  late final StreamSubscription<dynamic> _sub;
  final List<Completer<dynamic>> _waiters = [];

  Future<dynamic> next() {
    final completer = Completer<dynamic>();
    _waiters.add(completer);
    return completer.future;
  }

  void close() => _sub.cancel();
}

Future<Map<String, Object?>> _wsCall(
  WebSocket socket,
  _ReplyReader reader,
  int id,
  String method, {
  Map<String, Object?>? params,
}) async {
  socket.add(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    if (params != null) 'params': params,
  }));
  final reply = await reader.next();
  return (jsonDecode(reply as String) as Map).map(
    (key, value) => MapEntry(key.toString(), value),
  );
}

void main() {
  // 注意：不要调用 TestWidgetsFlutterBinding.ensureInitialized() —— 它会
  // 安装 mock HttpClient，使所有真实 HTTP 请求返回 400。这里全部使用 dart:io 真实请求。

  group('WebManagementServer HTTP', () {
    late WebManagementServer server;
    late int port;
    const token = 'test-token-123';

    setUp(() async {
      server = WebManagementServer(
        token: token,
        sourceListProvider: () async => const ['源A', '源B'],
      );
      port = await server.start(port: 0);
    });

    tearDown(() => server.stop());

    test('serves the management console at /', () async {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final body = await response.transform(utf8.decoder).join();
      expect(body, contains('米读 Web 管理台'));
      client.close(force: true);
    });

    test('rejects /api/* without token with 401', () async {
      final client = HttpClient();
      for (final path in ['/api/health', '/api/status', '/api/sources']) {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.unauthorized, reason: path);
        await response.drain<void>();
      }
      client.close(force: true);
    });

    test('serves /api/health with bearer token', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/health'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, Object?>;
      expect(json['ok'], isTrue);
      client.close(force: true);
    });

    test('accepts ?token= query for /api/*', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/health?token=$token'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      client.close(force: true);
    });

    test('/api/status reports port, uptime and tools', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/status'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, Object?>;
      expect(json['port'], port);
      final tools = (json['tools'] as List).cast<String>();
      expect(tools, containsAll(['server/ping', 'server/status', 'http/get']));
      client.close(force: true);
    });

    test('/api/sources returns injected provider names', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/sources'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final json = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, Object?>;
      expect(json['sources'], ['源A', '源B']);
      client.close(force: true);
    });

    test('unknown /api path returns 404', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/api/nope'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.notFound);
      client.close(force: true);
    });
  });

  group('WebSocket + MCP', () {
    late WebManagementServer server;
    late int port;
    const token = 'ws-token-456';

    setUp(() async {
      server = WebManagementServer(token: token);
      port = await server.start(port: 0);
    });

    tearDown(() => server.stop());

    test('refuses upgrade without token', () async {
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port/ws'),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('refuses upgrade with wrong token', () async {
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port/ws?token=wrong'),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('ping, tools/list and tools/call round trip', () async {
      final socket =
          await WebSocket.connect('ws://127.0.0.1:$port/ws?token=$token');
      final reader = _ReplyReader(socket);

      final ping = await _wsCall(socket, reader, 1, 'ping');
      expect(ping['id'], 1);
      expect((ping['result'] as Map)['pong'], isTrue);

      final list = await _wsCall(socket, reader, 2, 'tools/list');
      final tools = ((list['result'] as Map)['tools'] as List)
          .cast<Map>()
          .map((e) => e['name'])
          .toList();
      expect(tools, containsAll(['server/ping', 'http/get']));

      final call = await _wsCall(socket, reader, 3, 'tools/call', params: {
        'name': 'server/ping',
        'arguments': <String, Object?>{},
      });
      expect((call['result'] as Map)['pong'], isTrue);

      final unknown = await _wsCall(socket, reader, 4, 'tools/call', params: {
        'name': 'no/such-tool',
        'arguments': <String, Object?>{},
      });
      expect((unknown['error'] as Map)['code'], -32601);

      reader.close();
      await socket.close();
    });

    test('http/get rejects private-network target (SSRF)', () async {
      final socket =
          await WebSocket.connect('ws://127.0.0.1:$port/ws?token=$token');
      final reader = _ReplyReader(socket);
      final reply = await _wsCall(socket, reader, 5, 'tools/call', params: {
        'name': 'http/get',
        'arguments': {'url': 'http://127.0.0.1:1/'},
      });
      final error = reply['error'] as Map;
      expect(error['code'], -32000);
      expect(error['message'].toString(), contains('not allowed'));
      reader.close();
      await socket.close();
    });
  });

  group('http/get tool (direct registry)', () {
    test('runs SSRF check before invoking transport', () async {
      final seen = <Uri>[];
      final server = WebManagementServer(
        token: 't',
        httpTransport: (uri) async {
          seen.add(uri);
          return const McpHttpResponse(statusCode: 200, body: 'fake body');
        },
      );
      final session = McpJsonRpcSession(registry: server.registry);
      final reply = (await session.handle(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'http/get',
          'arguments': {'url': 'http://1.1.1.1/chapter/1'},
        },
      })))!;
      final json = jsonDecode(reply) as Map<String, Object?>;
      expect(json['error'], isNull);
      expect((json['result'] as Map)['body'], 'fake body');
      expect(seen.single.toString(), 'http://1.1.1.1/chapter/1');
    });

    test('rejects loopback target without contacting transport', () async {
      final contacted = <Uri>[];
      final server = WebManagementServer(
        token: 't',
        httpTransport: (uri) async {
          contacted.add(uri);
          return const McpHttpResponse(statusCode: 200, body: 'x');
        },
      );
      final session = McpJsonRpcSession(registry: server.registry);
      final reply = (await session.handle(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'http/get',
          'arguments': {'url': 'http://127.0.0.1:8080/x'},
        },
      })))!;
      final error = (jsonDecode(reply) as Map<String, Object?>)['error'] as Map;
      expect(error['message'].toString(), contains('not allowed'));
      expect(contacted, isEmpty);
    });

    test('rejects invalid URL arguments', () async {
      final server = WebManagementServer(token: 't');
      final session = McpJsonRpcSession(registry: server.registry);
      final reply = (await session.handle(jsonEncode({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'http/get', 'arguments': {}},
      })))!;
      final error = (jsonDecode(reply) as Map<String, Object?>)['error'] as Map;
      expect(error['message'].toString(), contains('缺少 url'));
    });

    test('returns JSON-RPC parse error for garbage', () async {
      final session = McpJsonRpcSession(registry: defaultMcpToolRegistry());
      final reply = await session.handle('not json');
      expect(reply, isNotNull);
      final json = jsonDecode(reply!) as Map<String, Object?>;
      expect((json['error'] as Map)['code'], -32700);
    });
  });
}