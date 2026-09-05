// 文件说明：WebSocket 消息中枢 —— 同时服务 JSON-RPC（MCP）与 ping/pong。
// 技术要点：连接建立需携带 token 查询参数（未带/错误 → 401 拒绝升级）；
// 每条文本消息交给 McpJsonRpcSession 处理，回复原样放回 socket。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_server.dart';

class WebSocketRpcHub {
  WebSocketRpcHub({required this.registry});

  final McpToolRegistry registry;

  int _connections = 0;
  int get activeConnections => _connections;

  /// 处理一条已升级的连接。token 不匹配时在握手前拒绝。
  /// 返回 false 表示连接被拒（未升级）。
  Future<bool> handleUpgrade(HttpRequest request, {required String token}) async {
    final queryToken = request.uri.queryParameters['token'];
    if (queryToken == null || queryToken != token) {
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..writeln('missing or invalid token');
      await request.response.close();
      return false;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _connections++;
    await _serve(socket);
    _connections--;
    return true;
  }

  Future<void> _serve(WebSocket socket) async {
    final session = McpJsonRpcSession(registry: registry);
    await for (final event in socket) {
      if (event is! String) continue;
      String? reply;
      try {
        reply = await session.handle(event);
      } catch (error) {
        reply = jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32603, 'message': '$error'},
        });
      }
      if (reply != null) {
        socket.add(reply);
      }
    }
  }
}