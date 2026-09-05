// 文件说明：AutoTask 任务列表持久化（SharedPreferences JSON）。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'auto_task_model.dart';

class AutoTaskStorage {
  static const String _key = 'auto_task_list';

  /// 测试注入 prefs 时的 storage key。
  static const String debugStorageKey = _key;

  Future<List<AutoTask>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => AutoTask.fromJson(
                e.map((key, value) => MapEntry('$key', value)),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<AutoTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final task in tasks) task.toJson()]),
    );
  }
}