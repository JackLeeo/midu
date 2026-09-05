import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';

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

  /// 环形缓冲上限。此前 5000 在长会话里被 getDiscovery 等高频事件快速打满，
  /// 会挤掉「全量聚合开始/完成」等定位卡顿的关键标记；加大容量让整段会话的
  /// 事件轴完整可回溯（getDiscovery 的 exploreUrl 字段已做截断控制内存）。
  final int _maxEntries = 30000;
  bool _enabled = false;

  /// 调试模式开关。开启后同步启动帧耗时监控（见 [FrameJankMonitor]），
  /// 关闭时停止，帧统计与日志埋点均只在调试期间产生开销。
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      FrameJankMonitor.instance.start();
    } else {
      FrameJankMonitor.instance.stop();
    }
  }

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

/// 帧耗时监控（仅调试模式开启时运行）。
///
/// 周期汇总 UI 线程每帧的 build/raster 耗时，统计超过 16ms/33ms 的长帧，
/// 并写入 [DebugLogger]。定位「用一会变卡」时，把这些帧尖峰时间点与
/// 发现页聚合 / 栏目刷新 / 引擎新建事件的时间轴对齐，即可判断卡顿究竟
/// 由哪类主线程活动引起。关闭调试模式即停止，正常使用零开销。
class FrameJankMonitor {
  FrameJankMonitor._();
  static final FrameJankMonitor instance = FrameJankMonitor._();

  /// 统计窗口：每 2 秒汇总一次。
  static const Duration _window = Duration(seconds: 2);

  /// 连续多少个「无长帧」窗口才打一条心跳，用于锚定时间轴（长帧窗口即时上报）。
  static const int _heartbeatWindows = 15;

  Timer? _timer;
  bool _hasBinding = false;

  // 当前窗口累加器。
  int _frames = 0;
  int _longFrames = 0; // 单帧 totalSpan > 16ms
  int _severeFrames = 0; // 单帧 totalSpan > 50ms（肉眼可见卡顿）
  Duration _maxSpan = Duration.zero;
  double _buildMs = 0;
  double _rasterMs = 0;
  int _cleanWindows = 0;
  bool _dirty = false;

  /// 窗口内最长帧来自哪里（用于区分 build 还是 raster 主导）。
  bool _maxIsBuild = false;

  void start() {
    if (_timer != null) return;
    try {
      // 纯 Dart 测试或初始化前没有 SchedulerBinding 时，仅降级为不采集。
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _hasBinding = true;
    } catch (_) {
      _hasBinding = false;
    }
    _timer = Timer.periodic(_window, (_) => _flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_hasBinding) {
      try {
        SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      } catch (_) {}
      _hasBinding = false;
    }
    if (_dirty) _flush();
    _resetWindow();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final total = timing.totalSpan;
      _frames++;
      if (total > const Duration(microseconds: 16000)) {
        _longFrames++;
        _dirty = true;
      }
      if (total > const Duration(milliseconds: 50)) _severeFrames++;
      if (total > _maxSpan) {
        _maxSpan = total;
        _maxIsBuild = timing.buildDuration >= timing.rasterDuration;
      }
      _buildMs += timing.buildDuration.inMicroseconds / 1000;
      _rasterMs += timing.rasterDuration.inMicroseconds / 1000;
    }
  }

  void _flush() {
    if (!DebugLogger.instance.enabled) return;
    final hasLong = _longFrames > 0;
    if (!hasLong) {
      _cleanWindows++;
    } else {
      _cleanWindows = 0;
    }
    // 心跳：长时间无卡顿时周期性锚点，让日志时间轴连续可对照。
    final heartbeat = !hasLong && _cleanWindows >= _heartbeatWindows;
    if (heartbeat) _cleanWindows = 0;
    if (hasLong || heartbeat) {
      DebugLogger.instance.log(
        'frame',
        hasLong ? 'UI 线程出现长帧' : '帧统计心跳',
        details: {
          'frames': _frames,
          'over16ms': _longFrames,
          'over50ms': _severeFrames,
          'maxSpanMs': _ms(_maxSpan.inMicroseconds / 1000),
          'dominant': _maxIsBuild ? 'build' : 'raster',
          'buildMs': _ms(_buildMs),
          'rasterMs': _ms(_rasterMs),
        },
      );
    }
    _resetWindow();
  }

  static double _ms(double v) => (v * 10).roundToDouble() / 10;

  void _resetWindow() {
    _frames = 0;
    _longFrames = 0;
    _severeFrames = 0;
    _maxSpan = Duration.zero;
    _maxIsBuild = false;
    _buildMs = 0;
    _rasterMs = 0;
    _dirty = false;
  }
}
