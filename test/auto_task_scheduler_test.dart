// M9 AutoTask 专项测试：
// 1. cron 表达式解析与下一次触发时刻计算（条件求值）
// 2. 调度器 interval / cron / event 三种触发
// 3. 故障重试（含重试成功后恢复）
// 4. 停用任务不触发、日志记录、编辑后 cron 缓存失效

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/services/automation/auto_task_model.dart';
import 'package:midu/services/automation/auto_task_scheduler.dart';
import 'package:midu/services/automation/cron_parser.dart';
import 'package:midu/services/sync/sync_models.dart';

DateTime _dt(int year, int month, int day, int hour, int minute) =>
    DateTime(year, month, day, hour, minute);

void main() {
  group('CronExpression 解析与计算', () {
    test('解析合法五字段表达式', () {
      final cron = CronExpression.parse('0 8 * * *');
      expect(cron.minutes, {0});
      expect(cron.hours, {8});
      expect(cron.months.length, 12);
      expect(cron.daysOfWeek.length, 7);
    });

    test('*/15 步长与范围', () {
      final cron = CronExpression.parse('*/15 9-17 * * *');
      expect(cron.minutes, {0, 15, 30, 45});
      expect(cron.hours, {9, 10, 11, 12, 13, 14, 15, 16, 17});
    });

    test('nextAfter：每天 08:00', () {
      final cron = CronExpression.parse('0 8 * * *');
      expect(
        cron.nextAfter(_dt(2026, 9, 4, 6, 0)),
        _dt(2026, 9, 4, 8, 0),
      );
      expect(
        cron.nextAfter(_dt(2026, 9, 4, 8, 30)),
        _dt(2026, 9, 5, 8, 0),
      );
    });

    test('工作日 09:30：周六 23:00 后为周一 09:30', () {
      final cron = CronExpression.parse('30 9 * * 1-5');
      // 2026-09-05 是周六
      expect(
        cron.nextAfter(_dt(2026, 9, 5, 23, 0)),
        _dt(2026, 9, 7, 9, 30),
      );
    });

    test('每月 1 号 00:00', () {
      final cron = CronExpression.parse('0 0 1 * *');
      expect(
        cron.nextAfter(_dt(2026, 9, 4, 12, 0)),
        _dt(2026, 10, 1, 0, 0),
      );
    });

    test('周别名 SUN 与 0/7 等价', () {
      expect(
        CronExpression.parse('0 10 * * SUN').nextAfter(_dt(2026, 9, 3, 0, 0)),
        CronExpression.parse('0 10 * * 0').nextAfter(_dt(2026, 9, 3, 0, 0)),
      );
    });

    test('非法表达式抛错', () {
      expect(() => CronExpression.parse('0 8 * *'), throwsA(anything));
      expect(
        () => CronExpression.parse('60 * * * *'),
        throwsA(isA<CronParseException>()),
      );
      expect(
        () => CronExpression.parse('a b c d e'),
        throwsA(isA<CronParseException>()),
      );
    });

    test('不可能时刻（2月30日）返回 null', () {
      final cron = CronExpression.parse('0 0 30 2 *');
      expect(cron.nextAfter(_dt(2026, 1, 1, 0, 0)), isNull);
    });

    test('describe 展示每天 HH:mm', () {
      expect(CronExpression.parse('0 8 * * *').describe, '每天 08:00');
      expect(CronExpression.parse('* * * * *').describe, '每分钟');
    });
  });

  group('AutoTaskScheduler 触发', () {
    late DateTime fakeNow;
    late AutoTaskScheduler scheduler;
    late List<String> executed;

    setUp(() {
      fakeNow = _dt(2026, 9, 4, 8, 0);
      executed = [];
      scheduler = AutoTaskScheduler(
        now: () => fakeNow,
        scheduleTimer: (_, _) {}, // 手动 tick，不依赖真实 Timer
        executor: AutoTaskActionExecutor()
          ..register(
            AutoTaskActionType.webRequest,
            _RecordingHandler(executed),
          ),
      );
    });

    tearDown(() => scheduler.dispose());

    test('interval：到期一次触发，间隔内不重复', () async {
      var createdTask = AutoTask(
        id: 't1',
        name: '任务 t1',
        triggerType: AutoTaskTriggerType.interval,
        intervalMinutes: 1,
        actionType: AutoTaskActionType.webRequest,
        createdAt: fakeNow.subtract(const Duration(minutes: 61)),
      );
      scheduler.upsert(createdTask);

      scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(executed, hasLength(1));
      expect(createdTask.runCount, 1);
      createdTask = scheduler.taskOf('t1')!;

      // 同一秒内再次 tick（间隔未到）
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(executed, hasLength(1));
    });

    test('cron：整分边界后补触发', () async {
      final task = AutoTask(
        id: 'c1',
        name: 'cron 任务',
        triggerType: AutoTaskTriggerType.cron,
        cronExpression: '0 9 * * *',
        actionType: AutoTaskActionType.webRequest,
        createdAt: fakeNow,
      );
      scheduler.upsert(task);

      // 08:00 未到 09:00
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(executed, isEmpty);

      // 09:00:30（tick 错过整分）仍应触发
      fakeNow = DateTime(2026, 9, 4, 9, 0, 30);
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(executed, hasLength(1));
    });

    test('event：总线事件名匹配立即触发', () async {
      final task = AutoTask(
        id: 'e1',
        name: '事件任务',
        triggerType: AutoTaskTriggerType.event,
        eventName: 'backup.done',
        actionType: AutoTaskActionType.webRequest,
        createdAt: fakeNow,
      );
      scheduler.upsert(task);
      scheduler.start();

      scheduler.eventBus.emit('other.event');
      await Future<void>.delayed(Duration.zero);
      expect(executed, isEmpty);

      scheduler.eventBus.emit('backup.done');
      await Future<void>.delayed(Duration.zero);
      expect(executed, hasLength(1));
      expect(scheduler.taskOf('e1')!.runCount, 1);
    });

    test('停用的任务不触发', () async {
      scheduler.upsert(
        AutoTask(
          id: 't2',
          name: '停用任务',
          enabled: false,
          triggerType: AutoTaskTriggerType.interval,
          intervalMinutes: 1,
          actionType: AutoTaskActionType.webRequest,
          createdAt: fakeNow.subtract(const Duration(minutes: 5)),
        ),
      );
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(executed, isEmpty);
    });

    test('从未注册动作：日志记录失败且 lastStatus 标记 error', () async {
      final task = AutoTask(
        id: 'u1',
        name: '未注册动作',
        triggerType: AutoTaskTriggerType.interval,
        intervalMinutes: 1,
        actionType: AutoTaskActionType.webDavBackup, // 未注册处理器
        createdAt: fakeNow.subtract(const Duration(minutes: 2)),
      );
      scheduler.upsert(task);
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      final updated = scheduler.taskOf('u1')!;
      expect(updated.isFailed, isTrue);
      expect(updated.lastStatus, startsWith('error'));
      final failures = scheduler.log.entries.where((e) => !e.ok);
      expect(failures, isNotEmpty);
    });
  });

  group('故障重试', () {
    test('失败重试上限：最大尝试 1+maxRetries 次', () async {
      var fakeNow = _dt(2026, 9, 4, 8, 0);
      var attempts = 0;
      final scheduler = AutoTaskScheduler(
        now: () => fakeNow,
        scheduleTimer: (_, _) {},
        maxRetries: 2,
        executor: AutoTaskActionExecutor()
          ..register(
            AutoTaskActionType.webRequest,
            _FailingHandler(() => attempts++),
          ),
      );
      addTearDown(scheduler.dispose);

      final task = AutoTask(
        id: 'r1',
        name: '重试任务',
        triggerType: AutoTaskTriggerType.interval,
        intervalMinutes: 1,
        actionType: AutoTaskActionType.webRequest,
        createdAt: fakeNow.subtract(const Duration(minutes: 5)),
      );
      scheduler.upsert(task);
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 3, reason: '1 次初始 + 2 次重试');
      final updated = scheduler.taskOf('r1')!;
      expect(updated.runCount, 1, reason: 'runCount 按轮次计，不随重试累加');
      expect(updated.lastStatus, startsWith('error'));
      final messages = scheduler.log.entries.map((e) => e.message).toList();
      expect(messages.any((m) => m.contains('重试上限')), isTrue);
    });

    test('重试后成功：lastStatus 转为 ok', () async {
      var fakeNow = _dt(2026, 9, 4, 8, 0);
      var attempts = 0;
      final scheduler = AutoTaskScheduler(
        now: () => fakeNow,
        scheduleTimer: (_, _) {},
        maxRetries: 1,
        executor: AutoTaskActionExecutor()
          ..register(
            AutoTaskActionType.webRequest,
            _FlakyHandler(() => attempts++),
          ),
      );
      addTearDown(scheduler.dispose);

      final task = AutoTask(
        id: 'r2',
        name: '抖动任务',
        triggerType: AutoTaskTriggerType.interval,
        intervalMinutes: 1,
        actionType: AutoTaskActionType.webRequest,
        createdAt: fakeNow.subtract(const Duration(minutes: 5)),
      );
      scheduler.upsert(task);
      scheduler.tick();
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 2);
      expect(scheduler.taskOf('r2')!.lastStatus, startsWith('ok'));
    });
  });

  group('动作处理器', () {
    test('默认执行器注册 webRequest 与 webDavBackup', () {
      final executor = AutoTaskActionExecutor();
      expect(executor.isSupported(AutoTaskActionType.webRequest), isTrue);
      expect(executor.isSupported(AutoTaskActionType.webDavBackup), isTrue);
      expect(executor.handlerOf(AutoTaskActionType.webDavBackup), isNotNull);
      expect(executor.isSupported(AutoTaskActionType.cacheChapters), isFalse);
    });

    test('WebDavBackupHandler：注入 runSync 返回备份摘要', () async {
      final handler = WebDavBackupHandler(
        runSync: () async => WebDavSyncRunResult(
          uploaded: 3,
          downloaded: 1,
          skipped: 0,
          conflictsResolved: 1,
          completedAt: DateTime(2026, 9, 4),
        ),
      );
      final task = AutoTask(
        id: 'b1',
        name: '备份任务',
        triggerType: AutoTaskTriggerType.interval,
        intervalMinutes: 60,
        actionType: AutoTaskActionType.webDavBackup,
      );
      final summary = await handler.handle(
        AutoTaskActionContext(task: task, params: task.actionParams),
      );
      expect(summary, contains('backup:'));
      expect(summary, contains('↑3'));
      expect(summary, contains('↓1'));
    });

    test('调度器执行 webDavBackup 任务状态为 ok', () async {
      final scheduler = AutoTaskScheduler(
        scheduleTimer: (_, _) {},
        executor: AutoTaskActionExecutor()
          ..register(
            AutoTaskActionType.webDavBackup,
            WebDavBackupHandler(
              runSync: () async => WebDavSyncRunResult(
                uploaded: 0,
                downloaded: 0,
                skipped: 2,
                conflictsResolved: 0,
                completedAt: DateTime(2026, 9, 4),
              ),
            ),
          ),
      );
      addTearDown(scheduler.dispose);
      final task = AutoTask(
        id: 'b2',
        name: '备份任务 2',
        triggerType: AutoTaskTriggerType.event,
        eventName: 'backup.now',
        actionType: AutoTaskActionType.webDavBackup,
        createdAt: DateTime(2026, 9, 4, 8, 0),
      );
      scheduler.upsert(task);
      scheduler.start();
      scheduler.eventBus.emit('backup.now');
      await Future<void>.delayed(Duration.zero);
      expect(scheduler.taskOf('b2')!.lastStatus, startsWith('ok: backup:'));
      expect(scheduler.taskOf('b2')!.runCount, 1);
    });
  });
}

/// 记录执行调用的处理器。
class _RecordingHandler implements AutoTaskActionHandler {
  _RecordingHandler(this.executed);

  final List<String> executed;

  @override
  Future<String> handle(AutoTaskActionContext context) async {
    executed.add(context.task.id);
    return 'hit ${context.params[AutoTaskParamKeys.url] ?? 'n/a'}';
  }
}

/// 永远失败的处理器。
class _FailingHandler implements AutoTaskActionHandler {
  _FailingHandler(this.onAttempt);

  final void Function() onAttempt;

  @override
  Future<String> handle(AutoTaskActionContext context) async {
    onAttempt();
    throw StateError('动作失败');
  }
}

/// 首次失败、随后成功的处理器。
class _FlakyHandler implements AutoTaskActionHandler {
  _FlakyHandler(this.onAttempt);

  final void Function() onAttempt;
  int _attempts = 0;

  @override
  Future<String> handle(AutoTaskActionContext context) async {
    onAttempt();
    _attempts++;
    if (_attempts < 2) {
      throw StateError('第一次失败');
    }
    return 'retry-ok';
  }
}