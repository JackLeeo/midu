// 文件说明：AutoTask 自动化任务数据模型（对标 Legado AutoTask）。
// 技术要点：单扁平类 + JSON DTO，触发器（定时/cron/事件）与动作类型枚举化，
// 动作参数用 Map 承载（编辑器按类型渲染对应表单）。

/// 触发器类型。
enum AutoTaskTriggerType {
  /// 固定间隔轮询（分钟）。
  interval('interval'),

  /// Cron 5 字段表达式（分 时 日 月 周）。
  cron('cron'),

  /// 应用内事件总线事件名（跨模块触发，如 WebDAV 备份完成后）。
  event('event');

  const AutoTaskTriggerType(this.storage);

  final String storage;

  static AutoTaskTriggerType fromStorage(String value) {
    for (final type in AutoTaskTriggerType.values) {
      if (type.storage == value) return type;
    }
    return AutoTaskTriggerType.interval;
  }
}

/// 动作类型。
enum AutoTaskActionType {
  /// HTTP 请求（dio）。
  webRequest('webRequest'),

  /// WebDAV 备份入口（由上层注册处理器后可用）。
  webDavBackup('webDavBackup'),

  /// 章节缓存预载入口（由上层注册处理器后可用）。
  cacheChapters('cacheChapters');

  const AutoTaskActionType(this.storage);

  final String storage;

  static AutoTaskActionType fromStorage(String value) {
    for (final type in AutoTaskActionType.values) {
      if (type.storage == value) return type;
    }
    return AutoTaskActionType.webRequest;
  }
}

/// webRequest 参数键。
class AutoTaskParamKeys {
  AutoTaskParamKeys._();

  static const String url = 'url';
  static const String method = 'method';
  static const String body = 'body';
  static const String headers = 'headers';

  // webDavBackup
  static const String scope = 'scope';

  // cacheChapters
  static const String sourceId = 'sourceId';
  static const String bookId = 'bookId';
  static const String sourceRevision = 'sourceRevision';
}

/// 自动化任务：一个触发器 + 一个动作 + 运行统计。
class AutoTask {
  AutoTask({
    required this.id,
    required this.name,
    this.enabled = true,
    this.triggerType = AutoTaskTriggerType.interval,
    this.intervalMinutes = 60,
    this.cronExpression = '0 8 * * *',
    this.eventName = '',
    this.actionType = AutoTaskActionType.webRequest,
    this.actionParams = const {},
    this.runCount = 0,
    this.lastRunAt,
    this.lastStatus,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  bool enabled;

  AutoTaskTriggerType triggerType;

  /// interval 触发的分钟间隔（>= 1）。
  int intervalMinutes;

  /// cron 触发的 5 字段表达式。
  String cronExpression;

  /// event 触发的总线事件名。
  String eventName;

  AutoTaskActionType actionType;
  Map<String, String> actionParams;

  int runCount;
  DateTime? lastRunAt;

  /// 最近一次执行结果摘要（ok/error + 消息）。
  String? lastStatus;

  final DateTime createdAt;

  bool get isFailed => lastStatus?.startsWith('error') ?? false;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'triggerType': triggerType.storage,
    'intervalMinutes': intervalMinutes,
    'cronExpression': cronExpression,
    'eventName': eventName,
    'actionType': actionType.storage,
    'actionParams': actionParams,
    'runCount': runCount,
    'lastRunAt': lastRunAt?.millisecondsSinceEpoch,
    'lastStatus': lastStatus,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  factory AutoTask.fromJson(Map<String, Object?> json) => AutoTask(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    triggerType: AutoTaskTriggerType.fromStorage(
      json['triggerType'] as String? ?? '',
    ),
    intervalMinutes: json['intervalMinutes'] as int? ?? 60,
    cronExpression: json['cronExpression'] as String? ?? '0 8 * * *',
    eventName: json['eventName'] as String? ?? '',
    actionType: AutoTaskActionType.fromStorage(
      json['actionType'] as String? ?? '',
    ),
    actionParams: (json['actionParams'] as Map?)?.map(
      (key, value) => MapEntry('$key', '$value'),
    ) ?? const {},
    runCount: json['runCount'] as int? ?? 0,
    lastRunAt: _epoch(json['lastRunAt']),
    lastStatus: json['lastStatus'] as String?,
    createdAt: _epoch(json['createdAt']) ?? DateTime.now(),
  );

  AutoTask copyWith({
    String? name,
    bool? enabled,
    AutoTaskTriggerType? triggerType,
    int? intervalMinutes,
    String? cronExpression,
    String? eventName,
    AutoTaskActionType? actionType,
    Map<String, String>? actionParams,
  }) {
    return AutoTask(
      id: id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      triggerType: triggerType ?? this.triggerType,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      cronExpression: cronExpression ?? this.cronExpression,
      eventName: eventName ?? this.eventName,
      actionType: actionType ?? this.actionType,
      actionParams: actionParams ?? this.actionParams,
      runCount: runCount,
      lastRunAt: lastRunAt,
      lastStatus: lastStatus,
      createdAt: createdAt,
    );
  }
}

DateTime? _epoch(Object? value) {
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  return null;
}