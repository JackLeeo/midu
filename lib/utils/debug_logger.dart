import 'dart:convert';
import 'dart:io';

/// 米读调试日志条目。
class DebugLogEntry {
  const DebugLogEntry({
    required this.timestamp,
    required this.category,
    required this.message,
    this.details,
    this.stackTrace,
  });

  final DateTime timestamp;
  final String category;
  final String message;
  final Map<String, dynamic>? details;
  final String? stackTrace;

  String toTextLine() {
    final ts = timestamp.toIso8601String();
    var line = '[$ts] [$category] $message';
    if (details != null && details!.isNotEmpty) {
      line += ' | ${jsonEncode(details)}';
    }
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      line += '\n$stackTrace';
    }
    return line;
  }
}

/// 米读调试日志记录器（单例）。
///
/// 开启调试模式后，记录每一个关键操作的详细日志，包括：
/// - 书源导入/解析/兼容性扫描
/// - 搜索请求/响应/结果聚合
/// - 章节内容加载/规则执行
/// - 发现页分类解析/书籍列表
/// - 网络请求 URL/状态码/响应大小
/// - 异常和错误堆栈
///
/// 用户可在设置页面导出日志文件用于问题定位。
class DebugLogger {
  DebugLogger._();
  static final DebugLogger instance = DebugLogger._();

  final List<DebugLogEntry> _entries = [];
  final int _maxEntries = 5000;
  bool enabled = false;

  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  /// 记录一条日志。调试模式关闭时直接跳过。
  void log(
    String category,
    String message, {
    Map<String, dynamic>? details,
    String? stackTrace,
  }) {
    if (!enabled) return;
    _entries.add(DebugLogEntry(
      timestamp: DateTime.now(),
      category: category,
      message: message,
      details: details,
      stackTrace: stackTrace,
    ));
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
  }

  /// 记录异常日志（含堆栈）。
  void logError(String category, String message, Object error,
      [StackTrace? stack]) {
    log(
      category,
      '$message: $error',
      stackTrace: stack?.toString(),
    );
  }

  void clear() => _entries.clear();

  /// 导出全部日志为文本格式。
  String exportText() {
    final buffer = StringBuffer();
    buffer.writeln('米读调试日志 (${DateTime.now().toIso8601String()})');
    buffer.writeln('条目数: ${_entries.length}');
    buffer.writeln('=' * 60);
    for (final entry in _entries) {
      buffer.writeln(entry.toTextLine());
    }
    return buffer.toString();
  }

  /// 导出到文件，返回文件路径。
  Future<String> exportToFile(String directoryPath) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final fileName = 'midu_debug_$timestamp.txt';
    final file = File('$directoryPath/$fileName');
    await file.writeAsString(exportText());
    return file.path;
  }
}
