// 文件说明：AutoTask 自动化任务管理页（对标 Legado AutoTask）。
// 技术要点：列表（启停状态/最近结果）+ 触发器/动作编辑器 + 执行日志；
// 调度器与存储可注入（widget 测试）；任务持久化为 JSON。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/automation/auto_task_model.dart';
import '../../services/automation/auto_task_scheduler.dart';
import '../../services/automation/auto_task_storage.dart';
import '../../services/automation/cron_parser.dart';
import '../../utils/localization_extension.dart';

class AutoTaskPage extends StatefulWidget {
  const AutoTaskPage({
    super.key,
    this.scheduler,
    this.storage,
  });

  final AutoTaskScheduler? scheduler;
  final AutoTaskStorage? storage;

  @override
  State<AutoTaskPage> createState() => _AutoTaskPageState();
}

class _AutoTaskPageState extends State<AutoTaskPage> {
  late final AutoTaskScheduler _scheduler =
      widget.scheduler ?? AutoTaskScheduler();
  late final AutoTaskStorage _storage = widget.storage ?? AutoTaskStorage();

  List<AutoTask> _tasks = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (widget.scheduler == null) _scheduler.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await _storage.load();
    for (final task in stored) {
      _scheduler.upsert(task);
    }
    if (widget.scheduler == null) _scheduler.start();
    if (!mounted) return;
    setState(() {
      _tasks = _scheduler.orderedTasks;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await _storage.save(_scheduler.orderedTasks);
    if (!mounted) return;
    setState(() => _tasks = _scheduler.orderedTasks);
  }

  Future<void> _openEditor({AutoTask? task}) async {
    final result = await Navigator.of(context).push<AutoTask>(
      MaterialPageRoute<AutoTask>(
        builder: (_) => AutoTaskEditPage(task: task),
      ),
    );
    if (result == null || !mounted) return;
    _scheduler.upsert(result);
    await _persist();
  }

  Future<void> _delete(AutoTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.autoTaskDeleteTask),
        content: Text('${context.l10n.autoTaskDeleteTask}: ${task.name}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.autoTaskDeleteTask),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _scheduler.remove(task.id);
    await _persist();
  }

  void _openLogs() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AutoTaskLogsPage(log: _scheduler.log),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.autoTaskTitle),
        actions: [
          IconButton(
            key: const ValueKey('auto-task-logs-button'),
            tooltip: l10n.autoTaskLogs,
            onPressed: _openLogs,
            icon: const Icon(Icons.receipt_long_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tasks.isEmpty
          ? _emptyState(l10n)
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _tasks.length,
              itemBuilder: (context, index) {
                final task = _tasks[index];
                return _taskTile(task);
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('auto-task-add-button'),
        onPressed: () => unawaited(_openEditor()),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.autoTaskAddTask),
      ),
    );
  }

  Widget _emptyState(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 52,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.autoTaskEmptyTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.autoTaskEmptyHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskTile(AutoTask task) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ValueKey('auto-task-tile-${task.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => unawaited(_openEditor(task: task)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Icon(
                  task.isFailed
                      ? Icons.error_outline_rounded
                      : Icons.schedule_rounded,
                  color: task.isFailed ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _describe(task, l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (task.lastStatus != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${l10n.autoTaskLatestStatus}: ${task.lastStatus}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: task.isFailed ? scheme.error : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Switch(
                  value: task.enabled,
                  onChanged: (value) {
                    _scheduler.upsert(task.copyWith(enabled: value));
                    unawaited(_persist());
                  },
                ),
                PopupMenuButton<_TaskAction>(
                  enabled: true,
                  onSelected: (action) {
                    switch (action) {
                      case _TaskAction.runNow:
                        unawaited(_scheduler.runNow(task.id));
                      case _TaskAction.edit:
                        unawaited(_openEditor(task: task));
                      case _TaskAction.delete:
                        unawaited(_delete(task));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _TaskAction.runNow,
                      child: Text(l10n.autoTaskRunNow),
                    ),
                    PopupMenuItem(
                      value: _TaskAction.edit,
                      child: Text(l10n.autoTaskEditTask),
                    ),
                    PopupMenuItem(
                      value: _TaskAction.delete,
                      child: Text(
                        l10n.autoTaskDeleteTask,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _describe(AutoTask task, AppLocalizations l10n) {
    final trigger = switch (task.triggerType) {
      AutoTaskTriggerType.interval =>
        '${l10n.autoTaskIntervalMinutes}: ${task.intervalMinutes}min',
      AutoTaskTriggerType.cron => task.cronExpression,
      AutoTaskTriggerType.event => '${l10n.autoTaskEventName}: ${task.eventName}',
    };
    return '$trigger · ${_actionLabel(task.actionType, l10n)}';
  }

  static String _actionLabel(AutoTaskActionType type, AppLocalizations l10n) {
    return switch (type) {
      AutoTaskActionType.webRequest => 'Web 请求',
      AutoTaskActionType.webDavBackup => l10n.autoTaskActionBackup,
      AutoTaskActionType.cacheChapters => l10n.autoTaskActionCache,
    };
  }
}

enum _TaskAction { runNow, edit, delete }

/// 任务编辑器：触发器（interval/cron/event）+ 动作（webRequest/backup/cache）。
class AutoTaskEditPage extends StatefulWidget {
  const AutoTaskEditPage({super.key, this.task});

  final AutoTask? task;

  @override
  State<AutoTaskEditPage> createState() => _AutoTaskEditPageState();
}

class _AutoTaskEditPageState extends State<AutoTaskEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _interval;
  late final TextEditingController _cron;
  late final TextEditingController _event;
  late final TextEditingController _webUrl;
  late final TextEditingController _webBody;
  late final TextEditingController _bookId;

  late AutoTaskTriggerType _triggerType;
  late AutoTaskActionType _actionType;
  late String _webMethod;
  late String _backupScope;

  String? _nameError;
  String? _cronError;
  String? _eventError;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _name = TextEditingController(text: task?.name ?? '');
    _interval = TextEditingController(text: '${task?.intervalMinutes ?? 60}');
    _cron = TextEditingController(text: task?.cronExpression ?? '0 8 * * *');
    _event = TextEditingController(text: task?.eventName ?? '');
    _webUrl = TextEditingController(
      text: task?.actionParams[AutoTaskParamKeys.url] ?? '',
    );
    _webBody = TextEditingController(
      text: task?.actionParams[AutoTaskParamKeys.body] ?? '',
    );
    _bookId = TextEditingController(
      text: task?.actionParams[AutoTaskParamKeys.bookId] ?? '',
    );
    _triggerType = task?.triggerType ?? AutoTaskTriggerType.interval;
    _actionType = task?.actionType ?? AutoTaskActionType.webRequest;
    _webMethod = task?.actionParams[AutoTaskParamKeys.method] ?? 'GET';
    _backupScope = task?.actionParams[AutoTaskParamKeys.scope] ?? 'books';
  }

  @override
  void dispose() {
    _name.dispose();
    _interval.dispose();
    _cron.dispose();
    _event.dispose();
    _webUrl.dispose();
    _webBody.dispose();
    _bookId.dispose();
    super.dispose();
  }

  bool _validate() {
    final nameOk = _name.text.trim().isNotEmpty;
    setState(() {
      _nameError = nameOk ? null : ' ';
    });
    var ok = nameOk;
    if (_triggerType == AutoTaskTriggerType.cron) {
      try {
        CronExpression.parse(_cron.text);
        setState(() => _cronError = null);
      } catch (error) {
        setState(() => _cronError = '$error');
        ok = false;
      }
    }
    if (_triggerType == AutoTaskTriggerType.event &&
        _event.text.trim().isEmpty) {
      setState(() => _eventError = ' ');
      ok = false;
    } else {
      setState(() => _eventError = null);
    }
    if (_actionType == AutoTaskActionType.webRequest &&
        _webUrl.text.trim().isEmpty) {
      // url 为空时保存也能接受（执行时才失败），不阻塞编辑
      ok = ok;
    }
    return ok;
  }

  void _save() {
    if (!_validate()) return;
    final params = <String, String>{};
    switch (_actionType) {
      case AutoTaskActionType.webRequest:
        params[AutoTaskParamKeys.url] = _webUrl.text.trim();
        params[AutoTaskParamKeys.method] = _webMethod;
        if (_webBody.text.trim().isNotEmpty) {
          params[AutoTaskParamKeys.body] = _webBody.text.trim();
        }
      case AutoTaskActionType.webDavBackup:
        params[AutoTaskParamKeys.scope] = _backupScope;
      case AutoTaskActionType.cacheChapters:
        if (_bookId.text.trim().isNotEmpty) {
          params[AutoTaskParamKeys.bookId] = _bookId.text.trim();
        }
    }
    final minutes = int.tryParse(_interval.text) ?? 60;
    final task = AutoTask(
      id: widget.task?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim(),
      triggerType: _triggerType,
      intervalMinutes: minutes < 1 ? 1 : minutes,
      cronExpression: _cron.text.trim().isEmpty ? '0 8 * * *' : _cron.text.trim(),
      eventName: _event.text.trim(),
      actionType: _actionType,
      actionParams: params,
      runCount: widget.task?.runCount ?? 0,
      lastRunAt: widget.task?.lastRunAt,
      lastStatus: widget.task?.lastStatus,
      createdAt: widget.task?.createdAt ?? DateTime.now(),
    );
    Navigator.of(context).pop(task);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task == null ? l10n.autoTaskAddTask : l10n.autoTaskEditTask),
        actions: [
          TextButton(
            key: const ValueKey('auto-task-save-button'),
            onPressed: _save,
            child: Text(l10n.autoTaskSave),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
        children: [
          TextField(
            key: const ValueKey('auto-task-name-field'),
            controller: _name,
            decoration: InputDecoration(
              labelText: l10n.autoTaskName,
              border: const OutlineInputBorder(),
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<AutoTaskTriggerType>(
            key: const ValueKey('auto-task-trigger-type'),
            initialValue: _triggerType,
            decoration: InputDecoration(
              labelText: l10n.autoTaskTriggerLabel,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final type in AutoTaskTriggerType.values)
                DropdownMenuItem(
                  value: type,
                  child: Text(_triggerLabel(type, l10n)),
                ),
            ],
            onChanged: (value) => setState(() {
              if (value != null) _triggerType = value;
            }),
          ),
          const SizedBox(height: 16),
          if (_triggerType == AutoTaskTriggerType.interval)
            TextField(
              key: const ValueKey('auto-task-interval-field'),
              controller: _interval,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.autoTaskIntervalMinutes,
                suffixText: 'min',
                border: const OutlineInputBorder(),
              ),
            )
          else if (_triggerType == AutoTaskTriggerType.cron)
            TextField(
              key: const ValueKey('auto-task-cron-field'),
              controller: _cron,
              decoration: InputDecoration(
                labelText: l10n.autoTaskCronExpression,
                hintText: '0 8 * * *',
                border: const OutlineInputBorder(),
                errorText: _cronError,
              ),
            )
          else
            TextField(
              key: const ValueKey('auto-task-event-field'),
              controller: _event,
              decoration: InputDecoration(
                labelText: l10n.autoTaskEventName,
                border: const OutlineInputBorder(),
                errorText: _eventError,
              ),
            ),
          const SizedBox(height: 24),
          DropdownButtonFormField<AutoTaskActionType>(
            key: const ValueKey('auto-task-action-type'),
            initialValue: _actionType,
            decoration: InputDecoration(
              labelText: l10n.autoTaskActionLabel,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final type in AutoTaskActionType.values)
                DropdownMenuItem(
                  value: type,
                  child: Text(_actionLabel(type, l10n)),
                ),
            ],
            onChanged: (value) => setState(() {
              if (value != null) _actionType = value;
            }),
          ),
          const SizedBox(height: 16),
          if (_actionType == AutoTaskActionType.webRequest) ...[
            TextField(
              key: const ValueKey('auto-task-web-url-field'),
              controller: _webUrl,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.autoTaskWebUrl,
                hintText: 'https://…',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('auto-task-web-method'),
              initialValue: _webMethod,
              decoration: InputDecoration(
                labelText: l10n.autoTaskWebMethod,
                border: const OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'GET', child: Text('GET')),
                DropdownMenuItem(value: 'POST', child: Text('POST')),
              ],
              onChanged: (value) => setState(() {
                if (value != null) _webMethod = value;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('auto-task-web-body-field'),
              controller: _webBody,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: l10n.autoTaskWebBody,
                hintText: l10n.autoTaskWebBodyHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ] else if (_actionType == AutoTaskActionType.webDavBackup)
            DropdownButtonFormField<String>(
              key: const ValueKey('auto-task-backup-scope'),
              initialValue: _backupScope,
              decoration: InputDecoration(
                labelText: l10n.autoTaskBackupScope,
                border: const OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'books', child: Text('书架与在线书籍')),
                DropdownMenuItem(value: 'sources', child: Text('书源')),
                DropdownMenuItem(value: 'all', child: Text('全部')),
              ],
              onChanged: (value) => setState(() {
                if (value != null) _backupScope = value;
              }),
            )
          else
            TextField(
              key: const ValueKey('auto-task-cache-book-field'),
              controller: _bookId,
              decoration: InputDecoration(
                labelText: l10n.autoTaskCacheBook,
                border: const OutlineInputBorder(),
              ),
            ),
        ],
      ),
    );
  }

  static String _triggerLabel(
    AutoTaskTriggerType type,
    AppLocalizations l10n,
  ) {
    return switch (type) {
      AutoTaskTriggerType.interval => l10n.autoTaskTriggerInterval,
      AutoTaskTriggerType.cron => l10n.autoTaskTriggerCron,
      AutoTaskTriggerType.event => l10n.autoTaskTriggerEvent,
    };
  }

  static String _actionLabel(AutoTaskActionType type, AppLocalizations l10n) {
    return switch (type) {
      AutoTaskActionType.webRequest => l10n.autoTaskActionWeb,
      AutoTaskActionType.webDavBackup => l10n.autoTaskActionBackup,
      AutoTaskActionType.cacheChapters => l10n.autoTaskActionCache,
    };
  }
}

/// 执行日志页：最近日志倒序展示。
class AutoTaskLogsPage extends StatelessWidget {
  const AutoTaskLogsPage({super.key, required this.log});

  final AutoTaskLogBuilder log;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = log.entries.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.autoTaskLogs)),
      body: entries.isEmpty
          ? Center(child: Text(l10n.autoTaskLogsEmpty))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    entry.ok
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    color: entry.ok
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: Text(entry.message, maxLines: 2),
                  subtitle: Text(
                    '${entry.taskName} · ${_formatTime(entry.time)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
    );
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
  }
}