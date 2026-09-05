// 文件说明：MCP 服务器 —— JSON-RPC 2.0 over WebSocket，工具注册表模式。
// 技术要点：tools/list / tools/call 双方法；工具按注册表分发，实现可注入
// （书源查找、搜索等真实能力由上层接线，服务层保持零外部依赖可测）。

import 'dart:convert';

/// 一条已注册的 MCP 工具。
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    this.inputSchema = const {},
    required this.handler,
  });

  final String name;
  final String description;

  /// JSON Schema（最小子集）：{type:'object', properties: {...}}。
  final Map<String, Object?> inputSchema;

  final Future<Object?> Function(Map<String, Object?> args) handler;
}

/// MCP 工具注册表。
class McpToolRegistry {
  final Map<String, McpTool> _tools = {};

  void register(McpTool tool) {
    _tools[tool.name] = tool;
  }

  McpTool? toolOf(String name) => _tools[name];

  List<McpTool> get tools => List.unmodifiable(_tools.values);
}

/// JSON-RPC 错误码。
class McpError implements Exception {
  const McpError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'McpError($code): $message';
}

/// JSON-RPC 2.0 会话处理：文本消息 ↔ 响应文本。
class McpJsonRpcSession {
  McpJsonRpcSession({required this.registry});

  final McpToolRegistry registry;

  /// 传入一条 JSON-RPC 文本消息；返回响应文本；通知（无 id）返回 null。
  /// 非法 JSON / 未知方法返回 JSON-RPC 错误（id 可空）。
  Future<String?> handle(String raw) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return _error(null, -32700, 'Parse error');
    }
    if (decoded is! Map) return _error(null, -32600, 'Invalid Request');
    final id = decoded['id'];
    if (id == null) return null; // 通知：无响应
    final method = decoded['method'];
    if (method is! String) return _error(id, -32600, 'Invalid Request');
    final params = decoded['params'];
    final args = params is Map
        ? params.map((key, value) => MapEntry('$key', value))
        : <String, Object?>{};
    switch (method) {
      case 'tools/list':
        return _result(
          id,
          {
            'tools': [
              for (final tool in registry.tools)
                {
                  'name': tool.name,
                  'description': tool.description,
                  'inputSchema': tool.inputSchema,
                },
            ],
          },
        );
      case 'tools/call':
        final toolName = args['name'];
        if (toolName is! String) {
          return _error(id, -32602, 'tools/call 缺少 name 参数');
        }
        final tool = registry.toolOf(toolName);
        if (tool == null) {
          return _error(id, -32601, '未知工具: $toolName');
        }
        final toolArgs = args['arguments'];
        final callArgs = toolArgs is Map
            ? toolArgs.map((key, value) => MapEntry('$key', value))
            : <String, Object?>{};
        try {
          final result = await tool.handler(callArgs);
          return _result(id, result ?? {});
        } catch (error) {
          return _error(id, -32000, '工具执行失败: $error');
        }
      case 'ping':
        return _result(id, {'pong': true});
      default:
        return _error(id, -32601, '未知方法: $method');
    }
  }

  String _result(Object? id, Object? result) => jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  });

  String _error(Object? id, int code, String message) => jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });
}

/// 默认工具集合：server/ping、server/status、sources/list。
McpToolRegistry defaultMcpToolRegistry({
  String Function()? statusProvider,
  Future<List<String>> Function()? sourceListProvider,
}) {
  final registry = McpToolRegistry();
  registry.register(
    McpTool(
      name: 'server/ping',
      description: '连通性自检，返回 pong。',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async => {'pong': true},
    ),
  );
  registry.register(
    McpTool(
      name: 'server/status',
      description: '服务器运行状态（端口、运行时长）。',
      handler: (args) async => {'status': statusProvider?.call() ?? 'unknown'},
    ),
  );
  registry.register(
    McpTool(
      name: 'sources/list',
      description: '列出已接入书源名称。',
      handler: (args) async {
        final sources = await (sourceListProvider?.call() ?? Future.value([]));
        return {'sources': sources};
      },
    ),
  );
  return registry;
}