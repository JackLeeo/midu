// M9 AutoTask 页面 widget 专项测试：
// 1. 空状态
// 2. 新建任务全流程（编辑器保存 → 列表展示）
// 3. 编辑器校验（空名称不可保存）
// 4. 从持久化 JSON 恢复任务列表
// 5. 立即执行写入执行日志，日志页可查看

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/l10n/app_localizations.dart';
import 'package:midu/pages/settings/auto_task_page.dart';
import 'package:midu/services/automation/auto_task_model.dart';
import 'package:midu/services/automation/auto_task_scheduler.dart';
import 'package:midu/services/automation/auto_task_storage.dart';

Future<void> _pumpPage(
  WidgetTester tester, {
  AutoTaskScheduler? scheduler,
  AutoTaskStorage? storage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: AutoTaskPage(scheduler: scheduler, storage: storage),
    ),
  );
  await tester.pumpAndSettle();
}

/// 注入 no-op scheduleTimer 的调度器（避免真实 Timer 产生 pending timer 问题）。
AutoTaskScheduler _testScheduler({AutoTaskActionExecutor? executor}) {
  return AutoTaskScheduler(
    scheduleTimer: (_, _) {},
    executor: executor,
  );
}

void main() {
  testWidgets('空状态展示引导文案', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final scheduler = _testScheduler();
    addTearDown(scheduler.dispose);
    await _pumpPage(tester, scheduler: scheduler);
    expect(find.text('还没有自动化任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建任务：编辑器保存后列表出现任务', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final scheduler = _testScheduler();
    addTearDown(scheduler.dispose);
    await _pumpPage(tester, scheduler: scheduler);

    await tester.tap(find.byKey(const ValueKey('auto-task-add-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('auto-task-name-field')),
      '定时备份任务',
    );
    await tester.tap(find.byKey(const ValueKey('auto-task-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('定时备份任务'), findsOneWidget);
    expect(find.textContaining('间隔（分钟）: 60'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 持久化：重新载入应恢复
    final store = AutoTaskStorage();
    final stored = await store.load();
    expect(stored, hasLength(1));
    expect(stored.single.name, '定时备份任务');
  });

  testWidgets('编辑器校验：空名称不可保存', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final scheduler = _testScheduler();
    addTearDown(scheduler.dispose);
    await _pumpPage(tester, scheduler: scheduler);

    await tester.tap(find.byKey(const ValueKey('auto-task-add-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('auto-task-save-button')));
    await tester.pumpAndSettle();

    // 校验失败 → 仍停留在编辑器
    expect(find.byKey(const ValueKey('auto-task-name-field')), findsOneWidget);
    expect(find.text('还没有自动化任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从持久化 JSON 恢复任务列表', (tester) async {
    final stored = AutoTask(
      id: 'saved-1',
      name: '恢复的任务',
      triggerType: AutoTaskTriggerType.cron,
      cronExpression: '0 9 * * *',
    );
    SharedPreferences.setMockInitialValues({
      AutoTaskStorage.debugStorageKey: jsonEncode([stored.toJson()]),
    });

    final scheduler = _testScheduler();
    addTearDown(scheduler.dispose);
    await _pumpPage(tester, scheduler: scheduler);
    expect(find.text('恢复的任务'), findsOneWidget);
    expect(find.textContaining('0 9 * * *'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('立即执行 → 日志页展示执行记录', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final executed = <String>[];
    final scheduler = _testScheduler(
      executor: AutoTaskActionExecutor()
        ..register(
          AutoTaskActionType.webRequest,
          _FakeWebHandler(executed),
        ),
    );
    addTearDown(scheduler.dispose);
    final task = AutoTask(
      id: 't1',
      name: 'ping 任务',
      actionParams: {AutoTaskParamKeys.url: 'https://example.com/ping'},
    );
    scheduler.upsert(task);

    await _pumpPage(tester, scheduler: scheduler);
    scheduler.runNow('t1');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('auto-task-logs-button')));
    await tester.pumpAndSettle();

    expect(executed, ['https://example.com/ping']);
    expect(find.textContaining('执行成功'), findsOneWidget);
    expect(find.textContaining('ping 任务'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

/// 记录 URL 的 webRequest 处理器（不复用 dio 执行网络）。
class _FakeWebHandler implements AutoTaskActionHandler {
  _FakeWebHandler(this.executed);

  final List<String> executed;

  @override
  Future<String> handle(AutoTaskActionContext context) async {
    executed.add(context.params[AutoTaskParamKeys.url] ?? '');
    return 'ok 200';
  }
}