// 文件说明：AutoTask 调度器 —— 定时（interval/cron）与事件双通道触发。
// 技术要点：
// - 时钟注入：`now` 与 `scheduleTimer` 可注入，测试用假时钟确定性驱动；
// - 轮询式 watchdog：周期 tick 检查到期任务，避免为每个任务挂长 Timer；
// - 事件总线：跨模块 emit 事件，匹配 event 型任务立即触发；
// - 故障重试：执行失败按 maxRetries 重试，每次重试写一条日志；
// - 每任务执行串行化：同一任务并发触发时合并为一次，避免动作重入。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../sync/sync_models.dart';
import '../sync/webdav_sync_controller.dart';
import 'auto_task_model.dart';
import 'cron_parser.dart';

/// 可注入的定时器调度：生产用 Timer，测试收集回调手动驱动。
typedef TimerScheduler = void Function(Duration delay, void Function() tick);

/// 日志环形缓冲（默认 300 条）。
class AutoTaskLogBuilder {
  AutoTaskLogBuilder({this.capacity = 300});

  final int capacity;
  final List<AutoTaskLogEntry> _entries = [];

  List<AutoTaskLogEntry> get entries => List.unmodifiable(_entries);

  void add(AutoTaskLogEntry entry) {
    _entries.add(entry);
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
  }
}

class AutoTaskLogEntry {
  AutoTaskLogEntry({
    required this.taskId,
    required this.taskName,
    required this.time,
    required this.ok,
    required this.message,
  });

  final String taskId;
  final String taskName;
  final DateTime time;
  final bool ok;
  final String message;

  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'taskName': taskName,
    'time': time.millisecondsSinceEpoch,
    'ok': ok,
    'message': message,
  };

  factory AutoTaskLogEntry.fromJson(Map<String, Object?> json) {
    final raw = json['time'];
    return AutoTaskLogEntry(
      taskId: json['taskId'] as String,
      taskName: json['taskName'] as String? ?? '',
      time: raw is num
          ? DateTime.fromMillisecondsSinceEpoch(raw.toInt())
          : DateTime.now(),
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String? ?? '',
    );
  }
}

/// 动作处理器：返回执行摘要文本，抛错表示失败。
abstract interface class AutoTaskActionHandler {
  Future<String> handle(AutoTaskActionContext context);
}

/// 传给动作处理器的上下文（含解码后的请求参数）。
class AutoTaskActionContext {
  AutoTaskActionContext({required this.task, required this.params});

  final AutoTask task;

  /// 动作参数（editor 写入的字符串值；json/body 键按需 JSON 解析）。
  final Map<String, String> params;

  String get param => params['url'] ?? '';
}

/// 动作执行器：类型 → 处理器注册表；默认注册 webRequest 与 webDavBackup。
class AutoTaskActionExecutor {
  /// 默认注册 [DioWebRequestHandler]（webRequest）与 [WebDavBackupHandler]（webDavBackup）。
  AutoTaskActionExecutor([Dio? webRequestDio]) {
    register(
      AutoTaskActionType.webRequest,
      DioWebRequestHandler(dio: webRequestDio),
    );
    register(
      AutoTaskActionType.webDavBackup,
      WebDavBackupHandler(),
    );
  }

  final Map<AutoTaskActionType, AutoTaskActionHandler> _handlers = {};

  void register(AutoTaskActionType type, AutoTaskActionHandler handler) {
    _handlers[type] = handler;
  }

  AutoTaskActionHandler? handlerOf(AutoTaskActionType type) => _handlers[type];

  bool isSupported(AutoTaskActionType type) => _handlers.containsKey(type);

  Future<String> execute(AutoTask task) async {
    final handler = _handlers[task.actionType];
    if (handler == null) {
      throw StateError('未注册动作处理器: ${task.actionType.storage}');
    }
    return handler.handle(
      AutoTaskActionContext(task: task, params: task.actionParams),
    );
  }
}

/// webRequest 默认处理器：dio 请求，GET 不带 Content-Type/body，POST 带 body。
/// （遵循全局 R2：不注入自定义 Referer 等指纹头。）
class DioWebRequestHandler implements AutoTaskActionHandler {
  DioWebRequestHandler({Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(responseType: ResponseType.plain));

  final Dio _dio;

  @override
  Future<String> handle(AutoTaskActionContext context) async {
    final url = context.params[AutoTaskParamKeys.url] ?? '';
    if (url.isEmpty) throw StateError('webRequest 缺少 URL 参数');
    final method = (context.params[AutoTaskParamKeys.method] ?? 'GET')
        .toUpperCase();
    final body = context.params[AutoTaskParamKeys.body];
    final isPost = method == 'POST' || method == 'PUT' || method == 'PATCH';
    final response = await _dio.request<String>(
      url,
      data: isPost ? body : null,
      options: Options(method: method),
    );
    return '${response.statusCode}';
  }
}

/// webDavBackup 默认处理器：触发一次 WebDAV 全量备份同步。
/// 执行回调可注入（离线测试）；生产默认走 [WebDavSyncController]。
class WebDavBackupHandler implements AutoTaskActionHandler {
  WebDavBackupHandler({Future<WebDavSyncRunResult> Function()? runSync})
      : _runSync = runSync ?? _defaultRunSync;

  final Future<WebDavSyncRunResult> Function() _runSync;

  static Future<WebDavSyncRunResult> _defaultRunSync() async {
    final controller = WebDavSyncController();
    await controller.initialize();
    if (!controller.isConfigured) {
      throw StateError('未配置 WebDAV 同步，请先在设置中配置');
    }
    return controller.syncNow();
  }

  @override
  Future<String> handle(AutoTaskActionContext context) async {
    final result = await _runSync();
    return 'backup: ↑${result.uploaded} ↓${result.downloaded} '
        'skip${result.skipped} conflict${result.conflictsResolved}';
  }
}

/// 事件总线：跨模块 emit 事件名，调度器据此触发 event 型任务。
class AutoTaskEventBus {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void emit(String eventName) {
    if (_controller.isClosed) return;
    _controller.add(eventName);
  }

  void dispose() {
    _controller.close();
  }
}

/// 调度器。用法：
/// ```dart
/// final scheduler = AutoTaskScheduler();
/// scheduler.upsert(task);
/// scheduler.start();
/// ...
/// scheduler.dispose();
/// ```
class AutoTaskScheduler {
  AutoTaskScheduler({
    DateTime Function()? now,
    TimerScheduler? scheduleTimer,
    AutoTaskEventBus? eventBus,
    AutoTaskActionExecutor? executor,
    AutoTaskLogBuilder? log,
    this.tickInterval = const Duration(seconds: 1),
    this.maxRetries = 1,
  }) : _now = now ?? DateTime.now,
       _schedule = scheduleTimer ?? _scheduleWithTimer,
       _eventBus = eventBus ?? AutoTaskEventBus(),
       _executor = executor ?? AutoTaskActionExecutor(),
       _log = log ?? AutoTaskLogBuilder();

  static void _scheduleWithTimer(
    Duration delay,
    void Function() tick,
  ) {
    Timer(delay, tick);
  }

  final DateTime Function() _now;
  final TimerScheduler _schedule;
  final AutoTaskEventBus _eventBus;
  final AutoTaskActionExecutor _executor;
  final AutoTaskLogBuilder _log;

  final Duration tickInterval;
  final int maxRetries;

  final Map<String, AutoTask> _tasks = {};
  StreamSubscription<String>? _eventSubscription;
  bool _started = false;
  bool _tickScheduled = false;
  bool _disposed = false;

  /// 正在执行的任务 id → future（避免重入）。
  final Map<String, Future<void>> _running = {};

  /// cron 型任务的下一次到期时刻（tick 粒度可能错过整分边界，需缓存后补触发）。
  final Map<String, DateTime> _nextCronDue = {};

  AutoTaskEventBus get eventBus => _eventBus;
  AutoTaskLogBuilder get log => _log;
  AutoTaskActionExecutor get executor => _executor;

  List<AutoTask> get tasks => List.unmodifiable(_tasks.values);

  AutoTask? taskOf(String id) => _tasks[id];

  /// 全量读取（含顺序）。
  List<AutoTask> get orderedTasks {
    final list = _tasks.values.toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  void upsert(AutoTask task) {
    _tasks[task.id] = task;
    // 编辑后失效 cron 到期缓存，防止使用旧表达式
    _nextCronDue.remove(task.id);
  }

  void remove(String id) {
    _tasks.remove(id);
    _nextCronDue.remove(id);
  }

  /// 手动立即执行某任务（列表页「立即执行」按钮）。
  Future<void> runNow(String id) {
    final task = _tasks[id];
    if (task == null) return Future.value();
    return _run(task);
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _eventSubscription = _eventBus.stream.listen(_onEvent);
    _scheduleTick();
  }

  void _scheduleTick() {
    if (_tickScheduled || !_started || _disposed) return;
    _tickScheduled = true;
    _schedule(tickInterval, () {
      _tickScheduled = false;
      _tick();
      if (_started && !_disposed) _scheduleTick();
    });
  }

  /// 轮询：触发所有已到期任务（测试可手动调用）。
  @visibleForTesting
  void tick() => _tick();

  void _tick() {
    if (_disposed) return;
    final now = _now();
    for (final task in _tasks.values.toList()) {
      if (!task.enabled || _running.containsKey(task.id)) continue;
      final due = _dueAt(task, now);
      if (due == null || now.isBefore(due)) continue;
      unawaited(_run(task));
    }
  }

  void _onEvent(String eventName) {
    if (_disposed) return;
    for (final task in _tasks.values.toList()) {
      if (!task.enabled) continue;
      if (task.triggerType != AutoTaskTriggerType.event) continue;
      if (task.eventName != eventName) continue;
      unawaited(_run(task));
    }
  }

  /// 计算任务下次触发时刻；事件型返回 null（由总线驱动）。
  DateTime? _dueAt(AutoTask task, DateTime now) {
    switch (task.triggerType) {
      case AutoTaskTriggerType.interval:
        final base = task.lastRunAt ?? task.createdAt;
        return base.add(Duration(minutes: task.intervalMinutes));
      case AutoTaskTriggerType.cron:
        try {
          final cached = _nextCronDue[task.id];
          // 已缓存到期时刻直接返回（即便已过也返回，由 _tick 补触发并随后清缓存）
          if (cached != null) return cached;
          final due = CronExpression.parse(task.cronExpression).nextAfter(now);
          if (due == null) return null;
          _nextCronDue[task.id] = due;
          return due;
        } catch (_) {
          // 表达式非法：跳过本轮，等待用户修正
          return null;
        }
      case AutoTaskTriggerType.event:
        return null;
    }
  }

  Future<void> _run(AutoTask task) {
    final existing = _running[task.id];
    if (existing != null) return existing;
    final future = _execute(task);
    _running[task.id] = future;
    // 记录仍在 _running 中直到完成（进入 tick 前清理）
    return future.whenComplete(() {
      _running.remove(task.id);
      // cron 任务完成后清到期缓存，下次 tick 从 lastRunAt 重新计算，避免重复触发
      if (task.triggerType == AutoTaskTriggerType.cron) {
        _nextCronDue.remove(task.id);
      }
    });
  }

  Future<void> _execute(AutoTask task) {
    return _attempt(task, attempt: 1);
  }

  Future<void> _attempt(AutoTask task, {required int attempt}) async {
    // 同步刷新计数（runCount 按轮次计，重试不重复累加）：
    if (attempt == 1) task.runCount++;
    task.lastRunAt = _now();
    _log.add(
      AutoTaskLogEntry(
        taskId: task.id,
        taskName: task.name,
        time: task.lastRunAt!,
        ok: true,
        message: '开始执行（第 $attempt 次）',
      ),
    );
    try {
      final summary = await _executor.execute(task);
      task.lastStatus = 'ok: $summary';
      _log.add(
        AutoTaskLogEntry(
          taskId: task.id,
          taskName: task.name,
          time: _now(),
          ok: true,
          message: '执行成功: $summary',
        ),
      );
    } catch (error) {
      _log.add(
        AutoTaskLogEntry(
          taskId: task.id,
          taskName: task.name,
          time: _now(),
          ok: false,
          message: '执行失败: $error',
        ),
      );
      if (attempt <= maxRetries) {
        _log.add(
          AutoTaskLogEntry(
            taskId: task.id,
            taskName: task.name,
            time: _now(),
            ok: true,
            message: '重试中…（第 ${attempt + 1} 次）',
          ),
        );
        return _attempt(task, attempt: attempt + 1);
      }
      task.lastStatus = 'error: $error';
      _log.add(
        AutoTaskLogEntry(
          taskId: task.id,
          taskName: task.name,
          time: _now(),
          ok: false,
          message: '已达到重试上限',
        ),
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    _eventSubscription?.cancel();
    _eventBus.dispose();
  }
}