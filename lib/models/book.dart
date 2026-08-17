// 文件说明：书籍数据模型，定义书籍元数据、阅读进度、缓存字段和 CanonicalLocator 双轨定位字段。
// 技术要点：Dart 数据模型、CanonicalLocator JSON 序列化、nullable 新字段兼容旧数据。

import 'dart:convert';

import 'package:midu/core/reader/canonical_locator.dart';
import '../book_sources/protocol/book_source_protocol.dart';

class Book {
  final int? id;
  final String title;
  final String author;
  final String filePath; // 存储书籍文件的路径，而不是内容
  final String format;
  final int currentPage;
  final int totalPages; // 添加总页数字段
  final double? readingProgress;
  final DateTime importDate;
  // 缓存相关字段
  final String? cachedContent;
  final String? cachedPages;
  final int? fileModifiedTime;
  final String? contentHash;
  final String? tableOfContents;
  final String? coverImagePath; // 书籍封面图片路径
  final String? textEncoding; // TXT编码（导入时自动检测的结果）

  // ---- CanonicalLocator 双轨定位字段 ----

  /// 上次阅读位置的 CanonicalLocator JSON 序列化。
  ///
  /// 布局无关定位真相源，跨设备、跨排版参数可稳定恢复。
  /// null 表示该书籍尚无 canonical 进度记录（旧数据兼容）。
  final String? lastCanonicalLocator;

  /// 上次阅读位置的 RenderedLocator JSON 序列化。
  ///
  /// 当前设备 + 当前排版参数下的屏幕位置，仅用于 UI 快速恢复。
  /// null 表示该书籍尚无 rendered 进度记录。
  final String? lastRenderedLocator;

  /// 排版参数指纹。
  ///
  /// 由字号/行高/边距/视口/翻页模式等排版参数决定。
  /// 任何影响分页结果的设置变更都会导致 layoutSignature 变化，
  /// 旧分页缓存和 rendered locator 失效。
  /// null 表示尚未计算或旧数据兼容。
  final String? layoutSignature;
  final String storageType;
  final String? sourceId;
  final String? sourceBookId;
  final String? sourceJson;
  final String? sourceBookJson;
  final String? sourceKind;
  final String? sourceLocator;
  final int? sourceModifiedTime;

  // ============================================================
  //  米读：多源书架扩展（换源功能）
  // ============================================================

  /// 这本书在多个书源中的指针列表 JSON。
  ///
  /// 结构：`List<Map<String, dynamic>>`，每项字段参考 `SourcedBookPointer`：
  ///   { sourceId, sourceName, bookId, book (可选, BookSourceBook json) }
  ///
  /// 为 null 时，该书只有单源（sourceId + sourceBookId）。
  final String? multiSourceJson;

  /// 当前选中的源 ID。
  ///
  /// - null 或空时，回退到 `sourceId`。
  /// - 切换源时，应同时更新 `sourceId` / `sourceBookId` 以兼容旧逻辑。
  final String? currentSourceId;

  bool get isOnline => storageType == 'online';

  /// 全书阅读进度。新数据使用统一的 0..1 值，旧数据继续兼容页码比值。
  double get progress {
    final normalized = readingProgress;
    if (normalized != null) return normalized.clamp(0.0, 1.0);
    if (totalPages <= 0) return 0;
    return (currentPage / totalPages).clamp(0.0, 1.0);
  }

  Book({
    this.id,
    required this.title,
    this.author = '未知',
    required this.filePath,
    required this.format,
    this.currentPage = 0,
    this.totalPages = 1, // 默认总页数为1
    this.readingProgress,
    DateTime? importDate,
    this.cachedContent,
    this.cachedPages,
    this.fileModifiedTime,
    this.contentHash,
    this.tableOfContents,
    this.coverImagePath,
    this.textEncoding,
    this.lastCanonicalLocator,
    this.lastRenderedLocator,
    this.layoutSignature,
    this.storageType = 'local',
    this.sourceId,
    this.sourceBookId,
    this.sourceJson,
    this.sourceBookJson,
    this.sourceKind,
    this.sourceLocator,
    this.sourceModifiedTime,
    this.multiSourceJson,
    this.currentSourceId,
  }) : importDate = importDate ?? DateTime.now();

  // content 字段已被移除

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'filePath': filePath,
      'format': format,
      'currentPage': currentPage,
      'totalPages': totalPages,
      'reading_progress': readingProgress,
      'importDate': importDate.millisecondsSinceEpoch,
      'cached_content': cachedContent,
      'cached_pages': cachedPages,
      'file_modified_time': fileModifiedTime,
      'content_hash': contentHash,
      'table_of_contents': tableOfContents,
      'cover_image_path': coverImagePath,
      'text_encoding': textEncoding,
      'last_canonical_locator': lastCanonicalLocator,
      'last_rendered_locator': lastRenderedLocator,
      'layout_signature': layoutSignature,
      'storage_type': storageType,
      'source_id': sourceId,
      'source_book_id': sourceBookId,
      'source_json': sourceJson,
      'source_book_json': sourceBookJson,
      'source_kind': sourceKind,
      'source_locator': sourceLocator,
      'source_modified_time': sourceModifiedTime,
      'multi_source_json': multiSourceJson,
      'current_source_id': currentSourceId,
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'],
      title: map['title'],
      author: map['author'] ?? '未知',
      filePath: map['filePath'],
      format: map['format'],
      currentPage: map['currentPage'] ?? 0,
      totalPages: map['totalPages'] ?? 1,
      readingProgress: (map['reading_progress'] as num?)?.toDouble(),
      importDate: DateTime.fromMillisecondsSinceEpoch(map['importDate']),
      cachedContent: map['cached_content'],
      cachedPages: map['cached_pages'],
      fileModifiedTime: map['file_modified_time'],
      contentHash: map['content_hash'],
      tableOfContents: map['table_of_contents'],
      coverImagePath: map['cover_image_path'],
      textEncoding: map['text_encoding'],
      lastCanonicalLocator: map['last_canonical_locator'],
      lastRenderedLocator: map['last_rendered_locator'],
      layoutSignature: map['layout_signature'],
      storageType: map['storage_type'] as String? ?? 'local',
      sourceId: map['source_id'] as String?,
      sourceBookId: map['source_book_id'] as String?,
      sourceJson: map['source_json'] as String?,
      sourceBookJson: map['source_book_json'] as String?,
      sourceKind: map['source_kind'] as String?,
      sourceLocator: map['source_locator'] as String?,
      sourceModifiedTime: map['source_modified_time'] as int?,
      multiSourceJson: map['multi_source_json'] as String?,
      currentSourceId: map['current_source_id'] as String?,
    );
  }

  Book copyWith({
    int? id,
    String? title,
    String? author,
    String? filePath,
    String? format,
    int? currentPage,
    int? totalPages,
    double? readingProgress,
    DateTime? importDate,
    String? cachedContent,
    String? cachedPages,
    int? fileModifiedTime,
    String? contentHash,
    String? tableOfContents,
    String? coverImagePath,
    String? textEncoding,
    String? lastCanonicalLocator,
    String? lastRenderedLocator,
    String? layoutSignature,
    String? storageType,
    String? sourceId,
    String? sourceBookId,
    String? sourceJson,
    String? sourceBookJson,
    String? sourceKind,
    String? sourceLocator,
    int? sourceModifiedTime,
    bool clearSourceMetadata = false,
    String? multiSourceJson,
    bool clearMultiSource = false,
    String? currentSourceId,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      filePath: filePath ?? this.filePath,
      format: format ?? this.format,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      readingProgress: readingProgress ?? this.readingProgress,
      importDate: importDate ?? this.importDate,
      cachedContent: cachedContent ?? this.cachedContent,
      cachedPages: cachedPages ?? this.cachedPages,
      fileModifiedTime: fileModifiedTime ?? this.fileModifiedTime,
      contentHash: contentHash ?? this.contentHash,
      tableOfContents: tableOfContents ?? this.tableOfContents,
      coverImagePath: coverImagePath ?? this.coverImagePath,
      textEncoding: textEncoding ?? this.textEncoding,
      lastCanonicalLocator: lastCanonicalLocator ?? this.lastCanonicalLocator,
      lastRenderedLocator: lastRenderedLocator ?? this.lastRenderedLocator,
      layoutSignature: layoutSignature ?? this.layoutSignature,
      storageType: storageType ?? this.storageType,
      sourceId: clearSourceMetadata ? null : sourceId ?? this.sourceId,
      sourceBookId: clearSourceMetadata
          ? null
          : sourceBookId ?? this.sourceBookId,
      sourceJson: clearSourceMetadata ? null : sourceJson ?? this.sourceJson,
      sourceBookJson: clearSourceMetadata
          ? null
          : sourceBookJson ?? this.sourceBookJson,
      sourceKind: clearSourceMetadata ? null : sourceKind ?? this.sourceKind,
      sourceLocator: clearSourceMetadata
          ? null
          : sourceLocator ?? this.sourceLocator,
      sourceModifiedTime: clearSourceMetadata
          ? null
          : sourceModifiedTime ?? this.sourceModifiedTime,
      multiSourceJson:
          clearMultiSource ? null : multiSourceJson ?? this.multiSourceJson,
      currentSourceId: currentSourceId ?? this.currentSourceId,
    );
  }

  /// 从 lastCanonicalLocator JSON 解析为 CanonicalLocator 对象。
  ///
  /// 返回 null 表示该书籍尚无 canonical 进度记录，
  /// 或 JSON 解析失败（旧数据格式损坏）。
  CanonicalLocator? toCanonicalLocator() {
    if (lastCanonicalLocator == null || lastCanonicalLocator!.trim().isEmpty) {
      return null;
    }
    return LocatorCodec.decodeCanonicalLocator(lastCanonicalLocator!);
  }

  /// 从 lastRenderedLocator JSON 解析为 RenderedLocator 对象。
  ///
  /// 返回 null 表示该书籍尚无 rendered 进度记录，
  /// 或 JSON 解析失败。
  RenderedLocator? toRenderedLocator() {
    if (lastRenderedLocator == null || lastRenderedLocator!.trim().isEmpty) {
      return null;
    }
    return LocatorCodec.decodeRenderedLocator(lastRenderedLocator!);
  }

  // ============================================================
  //  米读：多源辅助
  // ============================================================

  /// 解析并返回该书的所有可用源指针（包括当前主源）。
  ///
  /// - 如果 `multiSourceJson` 有数据，直接解析。
  /// - 否则构造一个只包含 (sourceId, sourceBookId) 的单元素列表。
  List<SourcedBookPointer> decodeAllSources() {
    final raw = multiSourceJson;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final arr = jsonDecode(raw);
        if (arr is List) {
          return arr
              .map((e) => e is Map<String, dynamic>
                  ? _BookMultiSourceCodec.decodePointer(e)
                  : null)
              .whereType<SourcedBookPointer>()
              .toList(growable: false);
        }
      } catch (_) {}
    }
    final sid = sourceId;
    final bid = sourceBookId;
    if (sid != null && sid.isNotEmpty && bid != null) {
      return [
        SourcedBookPointer(
          sourceId: sid,
          sourceName: '主源',
          bookId: bid,
        )
      ];
    }
    return const [];
  }

  /// 除当前选中源之外的备用源列表（用于显示"换源"面板）
  List<SourcedBookPointer> alternateSourcesOfCurrent() {
    final all = decodeAllSources();
    final cur = effectiveCurrentSourceId;
    if (cur == null) return all.skip(1).toList();
    return all.where((p) => p.sourceId != cur).toList(growable: false);
  }

  /// 有效当前源 ID（`currentSourceId` 回退到 `sourceId`）。
  String? get effectiveCurrentSourceId {
    final c = currentSourceId;
    if (c != null && c.trim().isNotEmpty) return c.trim();
    final s = sourceId;
    return s == null || s.isEmpty ? null : s;
  }

  /// 当前选中的源指针（若无则 null）。
  SourcedBookPointer? findCurrentSourcePointer() {
    final all = decodeAllSources();
    if (all.isEmpty) return null;
    final curId = effectiveCurrentSourceId;
    if (curId == null) return all.first;
    return all.firstWhere(
      (p) => p.sourceId == curId,
      orElse: () => all.first,
    );
  }
}

/// （de）序列化 multiSourceJson 的编解码小工具
class _BookMultiSourceCodec {
  static Map<String, dynamic> encodePointer(SourcedBookPointer p) {
    return <String, dynamic>{
      'sourceId': p.sourceId,
      'sourceName': p.sourceName,
      'bookId': p.bookId,
      if (p.book != null) 'book': p.book!.toJson(),
    };
  }

  static SourcedBookPointer? decodePointer(Map<String, dynamic> e) {
    final sid = e['sourceId'];
    final bid = e['bookId'];
    final sname = e['sourceName'] ?? '';
    if (sid is! String || sid.isEmpty) return null;
    if (bid is! String || bid.isEmpty) return null;
    final bookMap = e['book'];
    BookSourceBook? b;
    if (bookMap is Map<String, dynamic>) {
      try {
        b = BookSourceBook.fromJson(bookMap);
      } catch (_) {}
    }
    return SourcedBookPointer(
      sourceId: sid,
      sourceName: sname is String ? sname : '$sid',
      bookId: bid,
      book: b,
    );
  }
}

/// Book 上关于多源的便捷扩展（面向 UI 层）
extension BookMultiSourceExt on Book {
  /// 将 sources 列表编码并写入 `multiSourceJson`
  Book withMultiSourceList(List<SourcedBookPointer> sources) {
    if (sources.isEmpty) {
      return copyWith(clearMultiSource: true);
    }
    final payload = sources
        .map(_BookMultiSourceCodec.encodePointer)
        .toList(growable: false);
    return copyWith(multiSourceJson: jsonEncode(payload));
  }

  /// 从 AggregatedSearchHit 构造多源列表（书架收藏聚合结果时用）
  Book withSourcesFromAggregatedHit(AggregatedSearchHit hit) {
    final updated = withMultiSourceList(hit.sources);
    final primary = hit.primary;
    // 同时把主源回填到兼容字段，保证旧逻辑正常
    return updated.copyWith(
      sourceId: primary.sourceId,
      sourceBookId: primary.bookId,
      currentSourceId: primary.sourceId,
      sourceJson: primary.sourceName,
    );
  }

  /// 当前源是否有备用源（换源按钮是否可用）
  bool get canSwitchSource {
    final all = decodeAllSources();
    return all.length >= 2;
  }

  /// 备用源数量
  int get alternativeSourceCount {
    final n = decodeAllSources().length - 1;
    return n < 0 ? 0 : n;
  }
}
