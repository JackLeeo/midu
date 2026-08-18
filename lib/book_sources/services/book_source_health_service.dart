// 米读：书源健康检查 + 7 天临时屏蔽
// - HealthChecker：对已注册 Legado 源执行 search→book→chapters→content 链路探测
// - BlocklistStore：SharedPreferences 存储临时屏蔽到期时间，loadRunnable 过滤
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../legado/legado_runtime.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_client.dart';

// ========== 报告模型 ==========

enum HealthCheckStage {
  init, // 未开始
  search, // 搜索
  detail, // 书籍详情
  catalog, // 章节目录
  content, // 第一章正文
  done, // 成功
}

enum HealthCheckStatus { ok, failed, skipped }

class HealthCheckResult {
  const HealthCheckResult({
    required this.source,
    required this.status,
    required this.stage,
    this.latencyMs,
    this.error,
  });

  final RegisteredBookSource source;
  final HealthCheckStatus status;
  final HealthCheckStage stage; // 失败时的阶段 / 成功时 = done
  final int? latencyMs; // 整链路耗时（毫秒）
  final String? error; // 失败原因（可读字符串）

  bool get isHealthy => status == HealthCheckStatus.ok;
}

class HealthCheckReport {
  const HealthCheckReport({required this.results});
  final List<HealthCheckResult> results;

  int get total => results.length;
  int get healthyCount =>
      results.where((r) => r.status == HealthCheckStatus.ok).length;
  int get failedCount =>
      results.where((r) => r.status == HealthCheckStatus.failed).length;

  List<HealthCheckResult> get failures =>
      results.where((r) => r.status == HealthCheckStatus.failed).toList();
}

// ========== 健康检查服务 ==========

/// 进度回调：(completed, total, healthyCount, currentProcessingSourceId)
typedef BookSourceHealthProgress = void Function(
  int completed,
  int total,
  int healthy,
  String? currentSourceId,
);

class BookSourceHealthChecker {
  BookSourceHealthChecker({
    required this.client,
    this.maxConcurrency = 8,
    this.probeQueries = const ['斗破苍穹', '诡秘之主', '完美世界'],
    this.stageTimeout = const Duration(seconds: 10),
  });

  final BookSourceClient client;
  final int maxConcurrency;
  final List<String> probeQueries;
  final Duration stageTimeout;

  Future<HealthCheckReport> run(
    List<RegisteredBookSource> sources, {
    BookSourceHealthProgress? onProgress,
    bool onlyLegado = true,
  }) async {
    final targets = onlyLegado
        ? sources
            .where((s) => s.sourceProtocol == BookSourceProtocolKind.legado)
            .toList()
        : sources.toList();
    if (targets.isEmpty) {
      return const HealthCheckReport(results: []);
    }

    final out = <HealthCheckResult?>[]..length = targets.length;
    var next = 0;
    var completed = 0;
    var healthy = 0;
    String? currentId;

    Future<void> worker() async {
      while (true) {
        final idx = next++;
        if (idx >= targets.length) return;
        final s = targets[idx];
        currentId = s.id;
        onProgress?.call(completed, targets.length, healthy, currentId);
        final r = await _probeOne(s);
        out[idx] = r;
        completed++;
        if (r.isHealthy) healthy++;
        currentId = null;
        onProgress?.call(completed, targets.length, healthy, currentId);
      }
    }

    final workers = List.generate(
      targets.length.clamp(0, maxConcurrency),
      (_) => worker(),
    );
    await Future.wait(workers);

    final results =
        out.whereType<HealthCheckResult>().toList(growable: false);
    return HealthCheckReport(results: results);
  }

  Future<HealthCheckResult> _probeOne(RegisteredBookSource source) async {
    final sw = Stopwatch()..start();
    try {
      // Stage 1: search
      BookSourceBook? match;
      for (final q in probeQueries) {
        try {
          final page = await client
              .search(source, q, pageSize: 3)
              .timeout(stageTimeout);
          final list = page.items
              .where((b) =>
                  b.id.trim().isNotEmpty && b.title.trim().isNotEmpty)
              .toList();
          if (list.isNotEmpty) {
            match = list.first;
            break;
          }
        } catch (_) {}
      }
      if (match == null) {
        return _fail(source, sw, HealthCheckStage.search,
            '搜索未返回有效结果（已尝试 ${probeQueries.length} 个关键词）');
      }

      // Stage 2: book detail
      BookSourceBook detail;
      try {
        detail = await client.getBook(source, match.id).timeout(stageTimeout);
      } catch (e) {
        return _fail(source, sw, HealthCheckStage.detail, '书籍详情：${_errMsg(e)}');
      }

      // Stage 3: chapters catalog
      List<BookSourceChapter> chapters;
      try {
        chapters = await client.getChapters(source, detail.id).timeout(stageTimeout);
      } catch (e) {
        return _fail(source, sw, HealthCheckStage.catalog,
            '章节目录：${_errMsg(e)}');
      }
      if (chapters.isEmpty) {
        return _fail(source, sw, HealthCheckStage.catalog, '章节目录为空');
      }

      // Stage 4: chapter content（优先取第 3~10 章，跳过楔子/序章广告）
      final idx = chapters.length < 10 ? 0 : 3;
      try {
        final content = await client
            .getChapterContent(
              source,
              bookId: detail.id,
              chapterId: chapters[idx].id,
            )
            .timeout(stageTimeout);
        if (content.content.trim().length < 30) {
          return _fail(source, sw, HealthCheckStage.content,
              '章节正文过短（< 30 字符，疑似失效）');
        }
      } catch (e) {
        return _fail(source, sw, HealthCheckStage.content,
            '章节正文：${_errMsg(e)}');
      }

      sw.stop();
      return HealthCheckResult(
        source: source,
        status: HealthCheckStatus.ok,
        stage: HealthCheckStage.done,
        latencyMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return _fail(source, sw, HealthCheckStage.init, '未知异常：${_errMsg(e)}');
    }
  }

  static HealthCheckResult _fail(
    RegisteredBookSource source,
    Stopwatch sw,
    HealthCheckStage stage,
    String error,
  ) {
    sw.stop();
    return HealthCheckResult(
      source: source,
      status: HealthCheckStatus.failed,
      stage: stage,
      latencyMs: sw.elapsedMilliseconds,
      error: error,
    );
  }

  static String _errMsg(Object? e) {
    if (e is BookSourceProtocolException) return e.message;
    if (e is TimeoutException) return '超时';
    if (e == null) return '';
    return '$e'.replaceAll(RegExp(r'\s+'), ' ').trim().substringSafe(0, 200);
  }
}

// ========== 临时屏蔽存储（SharedPreferences，7天） ==========

class BookSourceBlocklistStore {
  BookSourceBlocklistStore._();
  static final BookSourceBlocklistStore instance = BookSourceBlocklistStore._();

  static const String _key = 'midu_book_source_blocklist_v1';
  static const Duration defaultBlockDuration = Duration(days: 7);

  /// sourceId -> blockedUntil (ISO8601 字符串)
  final Map<String, DateTime> _cache = {};
  bool _loaded = false;

  Future<void> _ensure() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final t = DateTime.tryParse('${e.value}');
            if (t != null) _cache['${e.key}'] = t;
          }
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = _cache.map((k, v) => MapEntry(k, v.toIso8601String()));
    await prefs.setString(_key, jsonEncode(payload));
  }

  Future<void> block(String sourceId, {Duration? duration}) async {
    await _ensure();
    final until =
        DateTime.now().toUtc().add(duration ?? defaultBlockDuration);
    _cache[sourceId] = until;
    await _flush();
  }

  Future<void> unblock(String sourceId) async {
    await _ensure();
    if (_cache.remove(sourceId) != null) await _flush();
  }

  Future<DateTime?> blockedUntil(String sourceId) async {
    await _ensure();
    final t = _cache[sourceId];
    if (t == null) return null;
    if (t.isBefore(DateTime.now().toUtc())) {
      // 过期自动清理
      _cache.remove(sourceId);
      await _flush();
      return null;
    }
    return t;
  }

  Future<bool> isBlocked(String sourceId) async =>
      (await blockedUntil(sourceId)) != null;

  /// 过滤被屏蔽源：返回新列表，同时清理已过期的屏蔽
  Future<List<RegisteredBookSource>> filterBlocked(
    List<RegisteredBookSource> sources,
  ) async {
    await _ensure();
    final now = DateTime.now().toUtc();
    bool dirty = false;
    final out = <RegisteredBookSource>[];
    for (final s in sources) {
      final until = _cache[s.id];
      if (until == null) {
        out.add(s);
        continue;
      }
      if (until.isBefore(now)) {
        _cache.remove(s.id);
        dirty = true;
        out.add(s);
        continue;
      }
      // 仍在屏蔽期内 → 排除
    }
    if (dirty) await _flush();
    return out;
  }

  /// 所有当前在屏蔽期内的 sourceId → until
  Future<Map<String, DateTime>> allBlocked() async {
    await _ensure();
    final now = DateTime.now().toUtc();
    bool dirty = false;
    final out = <String, DateTime>{};
    final toDel = <String>[];
    for (final e in _cache.entries) {
      if (e.value.isBefore(now)) {
        toDel.add(e.key);
        dirty = true;
      } else {
        out[e.key] = e.value;
      }
    }
    for (final k in toDel) _cache.remove(k);
    if (dirty) await _flush();
    return out;
  }
}

// ========== 辅助 ==========

extension _StringSubstringSafe on String {
  String substringSafe(int start, int endExcl) {
    if (isEmpty) return this;
    final s = start < 0 ? 0 : start;
    final e = endExcl > length ? length : endExcl;
    if (s >= e) return '';
    return substring(s, e);
  }
}

// Legacy typedef 保留（和 LegadoSourceVerifier 导入不冲突）
typedef LegadoRuntimeForHealth = LegadoRuntime;
