// 文件说明：Cron 5 字段表达式解析与「下一次触发时刻」计算。
// 技术要点：纯 Dart 无依赖；支持 `*`、`,`、`-`、`*/n`、单值与周别名（0/7=周日、
// SUN-MON）。每次 O(分钟粒度) 上界扫描，最坏 400 天，够用且确定性可测。

class CronParseException implements Exception {
  CronParseException(this.field, this.message);

  final int field;
  final String message;

  @override
  String toString() => 'CronParseException(field=$field): $message';
}

/// 解析后的 cron 字段（分钟 0-59 / 小时 0-23 / 日 1-31 / 月 1-12 / 周 0-6）。
class CronExpression {
  CronExpression(this.minutes, this.hours, this.daysOfMonth, this.months,
      this.daysOfWeek);

  /// 周字段 0=周日 … 6=周六（解析时统一归一）。
  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> daysOfMonth;
  final Set<int> months;
  final Set<int> daysOfWeek;

  static final RegExp _token = RegExp(r'^(\*|[0-9]+)(/([0-9]+))?$');
  static const Map<String, int> _weekNames = {
    'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6,
    'sun-7': 0,
  };

  /// 解析标准 5 字段表达式："分 时 日 月 周"。
  factory CronExpression.parse(String expression) {
    final fields = expression.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) {
      throw CronParseException(-1, '需要 5 个字段，实际 ${fields.length} 个');
    }
    return CronExpression(
      _parseField(fields[0], 0, 59, '分'),
      _parseField(fields[1], 0, 23, '时'),
      _parseField(fields[2], 1, 31, '日'),
      _parseField(fields[3], 1, 12, '月'),
      _parseWeek(fields[4]),
    );
  }

  /// 字段解析规则：
  /// - `*` / `*/n`：从域最小值到最大值按步长取；
  /// - `N`：单值；`N-M`：闭区间；`N-M/k`：区间按步长；
  /// - 多值用 `,` 分隔。
  static Set<int> _parseField(String raw, int min, int max, String label) {
    final result = <int>{};
    for (final part in raw.split(',').map((e) => e.trim())) {
      if (part.isEmpty) {
        throw CronParseException(-2, '$label 字段存在空项');
      }
      final stepMatch = _token.firstMatch(part);
      if (stepMatch == null) {
        // 范围语法 a-b 或 a-b/k
        final rangeMatch = RegExp(
          r'^([0-9]+)-([0-9]+)(?:/([0-9]+))?$',
        ).firstMatch(part);
        if (rangeMatch == null) {
          throw CronParseException(-2, '$label 字段无法解析: "$part"');
        }
        final from = int.parse(rangeMatch.group(1)!);
        final to = int.parse(rangeMatch.group(2)!);
        final step = int.tryParse(rangeMatch.group(3) ?? '1') ?? 1;
        if (step <= 0) {
          throw CronParseException(-2, '$label 步长必须为正');
        }
        if (from > to) {
          throw CronParseException(-2, '$label 区间起点大于终点: "$part"');
        }
        for (var v = from; v <= to; v += step) {
          result.add(v);
        }
        continue;
      }
      final isStar = stepMatch.group(1) == '*';
      final step = int.tryParse(stepMatch.group(3) ?? '1') ?? 1;
      if (step <= 0) {
        throw CronParseException(-2, '$label 步长必须为正');
      }
      if (isStar) {
        for (var v = min; v <= max; v += step) {
          result.add(v);
        }
      } else {
        result.add(int.parse(stepMatch.group(1)!));
      }
    }
    final outOfRange = result.where((v) => v < min || v > max).toList();
    if (outOfRange.isNotEmpty) {
      throw CronParseException(-2, '$label 越界: ${outOfRange.join(",")}');
    }
    return result;
  }

  static Set<int> _parseWeek(String raw) {
    final fields = raw.split(',').map((e) => e.trim().toLowerCase()).toList();
    final set = <int>{};
    for (var part in fields) {
      // 周别名 SUN..SAT（支持 SUN-SAT 区间）
      for (final entry in _weekNames.entries) {
        part = part.replaceAll(entry.key, '${entry.value}');
      }
      if (part.startsWith('*')) {
        set.addAll(List.generate(7, (i) => i));
        continue;
      }
      if (part.contains('-')) {
        final bounds = part.split('-');
        final int a, b;
        a = int.parse(bounds[0]);
        b = int.parse(bounds[1]);
        // 包装区间：FRI-MON 表示 5,6,0,1
        var v = a;
        while (true) {
          set.add(v % 7);
          if (v == b) break;
          v = (v + 1) % 7;
        }
        continue;
      }
      final value = int.parse(part) % 7;
      set.add(value);
    }
    if (set.isEmpty) throw CronParseException(4, '周字段为空');
    return set;
  }

  /// 计算严格晚于 [from] 的下一个触发时刻（含秒截断到整分）。
  /// 找不到（如 2 月 30 日）返回 null。
  DateTime? nextAfter(DateTime from) {
    final start = DateTime(from.year, from.month, from.day, from.hour,
        from.minute);
    var candidate = start.add(const Duration(minutes: 1));
    final limit = start.add(const Duration(days: 400));
    while (!candidate.isAfter(limit)) {
      if (months.contains(candidate.month) &&
          daysOfMonth.contains(candidate.day) &&
          hours.contains(candidate.hour) &&
          minutes.contains(candidate.minute) &&
          daysOfWeek.contains(candidate.weekday % 7)) {
        return candidate;
      }
      candidate = candidate.add(const Duration(minutes: 1));
    }
    return null;
  }

  /// 下一次触发与 [from] 的间隔（找不到抛 [CronParseException]）。
  Duration nextInterval(DateTime from) {
    final next = nextAfter(from);
    if (next == null) {
      throw CronParseException(-1, 'cron 表达式无匹配时刻（如 2 月 30 日）');
    }
    return next.difference(from);
  }

  /// 展示用的压缩描述（如 "0 8 * * *" → "每天 08:00"）。
  String get describe {
    final minuteList = minutes.toList()..sort();
    final hourList = hours.toList()..sort();
    if (_isFull(minuteList, 0, 59) && _isFull(hourList, 0, 23) &&
        _isFull(daysOfMonth.toList()..sort(), 1, 31) &&
        _isFull(months.toList()..sort(), 1, 12)) {
      return '每分钟';
    }
    if (minuteList.length == 1 && hourList.length == 1) {
      final h = hourList.single.toString().padLeft(2, '0');
      final m = minuteList.single.toString().padLeft(2, '0');
      final dayPart = _isFull(daysOfMonth.toList()..sort(), 1, 31)
          ? ''
          : ' ${daysOfMonth.join(",")} 日';
      return '每天$dayPart $h:$m';
    }
    return toString();
  }

  static bool _isFull(List<int> sorted, int min, int max) {
    if (sorted.length != max - min + 1) return false;
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] != min + i) return false;
    }
    return true;
  }

  @override
  String toString() {
    String fmt(List<int> sorted, int min, int max) =>
        _isFull(sorted, min, max) ? '*' : sorted.join(',');

    return [
      fmt(minutes.toList()..sort(), 0, 59),
      fmt(hours.toList()..sort(), 0, 23),
      fmt(daysOfMonth.toList()..sort(), 1, 31),
      fmt(months.toList()..sort(), 1, 12),
      fmt(daysOfWeek.toList()..sort(), 0, 6),
    ].join(' ');
  }
}