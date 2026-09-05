// 书源调试记录器：只读地记录一次调试会话中发出的请求与对应响应/错误。
//
// 对标 Legado BookSourceDebugActivity 的日志区：把每次请求的 URL、方法、请求头、
// 请求体、状态码、响应头、耗时与正文预览，以及规则执行结果/JS 错误，按时间
// 顺序写入环形缓冲（默认 400 条），供调试页实时展示。UI 之外无人订阅时开销
// 仅为一次内存写入，不影响正常阅读链路（生产共享 BookSourceClient 不注入
// recorder，行为与改造前完全一致）。
import 'package:flutter/foundation.dart';

/// 调试日志所属的请求阶段（对标 Legado 调试页的五个分区）。
enum BookSourceDebugStage {
  search, // 搜索
  bookInfo, // 详情
  toc, // 目录
  content, // 正文
  image, // 图片
  js, // JS/规则
  raw, // 浏览器兜底/java.ajax 等原始请求
}

/// 调试日志条目类型。
enum BookSourceDebugKind {
  request, // 发出的请求（URL/方法/请求头/请求体）
  response, // 收到的响应（状态/耗时/响应头/正文预览）
  error, // 请求或执行失败
  ruleResult, // 规则/JS 执行结果
  info, // 阶段状态提示（如开始搜索、匹配数、翻页）
}

/// 单条调试日志。
class BookSourceDebugEntry {
  const BookSourceDebugEntry({
    required this.kind,
    required this.stage,
    required this.time,
    required this.sourceName,
    this.order = 0,
    this.url,
    this.method,
    this.requestHeaders,
    this.requestBody,
    this.statusCode,
    this.responseHeaders,
    this.elapsedMs,
    this.message,
  });

  final BookSourceDebugKind kind;
  final BookSourceDebugStage stage;
  final DateTime time;

  /// 源名（调试页一次只调试一个源，用于日志首行展示）。
  final String sourceName;

  /// 同一条请求内 request/response 共享的序号（0 表示无关联/纯提示）。
  final int order;

  final String? url;
  final String? method;

  /// 请求头（条目类型为 request 时非空）。
  final Map<String, String>? requestHeaders;
  final String? requestBody;

  /// 响应状态码（条目类型为 response/error 时可能非空）。
  final int? statusCode;

  /// 响应头。
  final Map<String, String>? responseHeaders;

  /// 请求到响应的耗时（毫秒）。
  final int? elapsedMs;

  /// 正文预览 / 错误信息 / 规则执行结果。
  final String? message;

  String get stageLabel => switch (stage) {
        BookSourceDebugStage.search => '搜索',
        BookSourceDebugStage.bookInfo => '详情',
        BookSourceDebugStage.toc => '目录',
        BookSourceDebugStage.content => '正文',
        BookSourceDebugStage.image => '图片',
        BookSourceDebugStage.js => 'JS/规则',
        BookSourceDebugStage.raw => '请求',
      };

  String get kindLabel => switch (kind) {
        BookSourceDebugKind.request => '请求',
        BookSourceDebugKind.response => '响应',
        BookSourceDebugKind.error => '错误',
        BookSourceDebugKind.ruleResult => '结果',
        BookSourceDebugKind.info => '提示',
      };
}

/// 环形调试日志缓冲。每次入队调用 [notifyListeners]，调试页通过
/// [ChangeNotifier] 订阅实时刷新；最大条数 [maxEntries]，超出时丢弃最旧。
class BookSourceDebugRecorder extends ChangeNotifier {
  static const int maxEntries = 400;

  final List<BookSourceDebugEntry> _entries = <BookSourceDebugEntry>[];
  int _nextOrder = 1;

  /// 当前所有日志（按时间正序：最早在前）。
  List<BookSourceDebugEntry> get entries => List.unmodifiable(_entries);

  /// 当前日志数。
  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _nextOrder = 1;
    notifyListeners();
  }

  int _claimOrder() => _nextOrder++;

  void _add(BookSourceDebugEntry entry) {
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    notifyListeners();
  }

  int _thisOrder(int order) => order == 0 ? _claimOrder() : order;

  /// 记录一次请求的发出（响应完成后由 [recordResponse]/[recordError] 补全）。
  /// 返回本次请求序号，供同一请求的后续条目复用。
  int recordRequest({
    required BookSourceDebugStage stage,
    required String sourceName,
    required String url,
    required String method,
    String? body,
    Map<String, String>? headers,
    int? order,
  }) {
    final serial = _thisOrder(order ?? 0);
    _add(
      BookSourceDebugEntry(
        kind: BookSourceDebugKind.request,
        stage: stage,
        time: DateTime.now(),
        sourceName: sourceName,
        order: serial,
        url: url,
        method: method,
        requestHeaders: headers,
        requestBody: body,
      ),
    );
    return serial;
  }

  /// 记录一次成功的响应。
  void recordResponse({
    required BookSourceDebugStage stage,
    required String sourceName,
    required int order,
    required int statusCode,
    String? preview,
    Map<String, String>? headers,
    int? elapsedMs,
    String? url,
  }) {
    _add(
      BookSourceDebugEntry(
        kind: BookSourceDebugKind.response,
        stage: stage,
        time: DateTime.now(),
        sourceName: sourceName,
        order: order,
        url: url,
        statusCode: statusCode,
        responseHeaders: headers,
        elapsedMs: elapsedMs,
        message: preview,
      ),
    );
  }

  /// 记录一次失败的请求（网络错误/解析错误）。
  void recordError({
    required BookSourceDebugStage stage,
    required String sourceName,
    required String message,
    int? order,
    int? statusCode,
    int? elapsedMs,
    String? url,
  }) {
    _add(
      BookSourceDebugEntry(
        kind: BookSourceDebugKind.error,
        stage: stage,
        time: DateTime.now(),
        sourceName: sourceName,
        order: order ?? 0,
        url: url,
        statusCode: statusCode,
        elapsedMs: elapsedMs,
        message: message,
      ),
    );
  }

  /// 记录规则/JS 执行结果（不带网络请求，如规则单测）。
  void recordRuleResult({
    required BookSourceDebugStage stage,
    required String sourceName,
    required String message,
    String? url,
  }) {
    _add(
      BookSourceDebugEntry(
        kind: BookSourceDebugKind.ruleResult,
        stage: stage,
        time: DateTime.now(),
        sourceName: sourceName,
        order: 0,
        url: url,
        message: message,
      ),
    );
  }

  /// 记录阶段提示（开始搜索、chapterList 匹配数、翻页等）。
  void recordInfo({
    required BookSourceDebugStage stage,
    required String sourceName,
    required String message,
  }) {
    _add(
      BookSourceDebugEntry(
        kind: BookSourceDebugKind.info,
        stage: stage,
        time: DateTime.now(),
        sourceName: sourceName,
        order: 0,
        message: message,
      ),
    );
  }
}

/// 响应体预览截断长度（调试页与日志存底共用，避免超大响应占满内存）。
const int debugPreviewMaxChars = 2000;

String debugPreview(String body, {int max = debugPreviewMaxChars}) {
  if (body.length <= max) return body;
  return '${body.substring(0, max)}\n…（响应过长，仅显示前 $max 字符）';
}