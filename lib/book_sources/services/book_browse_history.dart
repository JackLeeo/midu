import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条在线书籍浏览/阅读记录。
///
/// 只要用户打开过某本在线书（开始阅读）即写入一条，随阅读持续刷新
/// 章节与整本进度；首页「浏览记录」据此断点续读。书架上的书同样保留，
/// 与「继续阅读」各自独立展示。
@immutable
class BookBrowseHistoryEntry {
  const BookBrowseHistoryEntry({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    required this.title,
    this.author = '',
    this.coverUrl,
    this.lastChapterTitle,
    this.chapterIndex = 0,
    this.chapterProgress = 0,
    this.bookPercent = 0,
    this.sourceJson,
    this.sourceBookJson,
    required this.updatedAt,
  });

  final String sourceId;
  final String sourceName;
  final String bookId;
  final String title;
  final String author;
  final Uri? coverUrl;
  final String? lastChapterTitle;
  final int chapterIndex;
  final double chapterProgress;
  final double bookPercent;
  final DateTime updatedAt;

  /// 用于断点续读重建源的序列化快照（未加入书架时兜底用）。
  ///
  /// 书架中已有的书优先走书架记录；两者都没有则用这两个 JSON 重建
  /// [RegisteredBookSource] / [BookSourceBook] 打开阅读器。
  final String? sourceJson;
  final String? sourceBookJson;

  factory BookBrowseHistoryEntry.fromJson(Map<String, dynamic> json) {
    final cover = json['coverUrl'];
    return BookBrowseHistoryEntry(
      sourceId: (json['sourceId'] as String?) ?? '',
      sourceName: (json['sourceName'] as String?) ?? '',
      bookId: (json['bookId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      coverUrl: cover is String && cover.isNotEmpty ? Uri.tryParse(cover) : null,
      lastChapterTitle: json['lastChapterTitle'] as String?,
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterProgress:
          ((json['chapterProgress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
      bookPercent: ((json['bookPercent'] as num?)?.toDouble() ?? 0).clamp(
        0,
        1,
      ),
      sourceJson: json['sourceJson'] as String?,
      sourceBookJson: json['sourceBookJson'] as String?,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'bookId': bookId,
    'title': title,
    'author': author,
    if (coverUrl != null) 'coverUrl': coverUrl.toString(),
    if (lastChapterTitle != null) 'lastChapterTitle': lastChapterTitle,
    'chapterIndex': chapterIndex,
    'chapterProgress': chapterProgress.clamp(0, 1),
    'bookPercent': bookPercent.clamp(0, 1),
    if (sourceJson != null) 'sourceJson': sourceJson,
    if (sourceBookJson != null) 'sourceBookJson': sourceBookJson,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// 是否携带重建打开所需的源/书快照。
  bool get canReopenOffline => (sourceJson?.isNotEmpty ?? false) &&
      (sourceBookJson?.isNotEmpty ?? false);
}

/// 首页「浏览记录」存储：最近阅读的在线书籍，去重后按最近更新时间倒序。
class BookBrowseHistoryStore {
  static const _storageKey = 'book_browse_history_v1';

  /// 单条记录携带重建续读所需的源 JSON，为控制体积取较少的条目数。
  static const int maxEntries = 50;

  const BookBrowseHistoryStore();

  /// 记录写入成功后广播，供驻留内存的首页刷新展示。
  static final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changeController.stream;

  static void notifyChanged() {
    if (!_changeController.isClosed) {
      _changeController.add(null);
    }
  }

  Future<List<BookBrowseHistoryEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final entries = <BookBrowseHistoryEntry>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          entries.add(BookBrowseHistoryEntry.fromJson(item));
        }
      }
      entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// 写入/刷新一条记录：同一 sourceId+bookId 去重并移到最前，超限裁尾。
  Future<void> upsert(BookBrowseHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = [...await load()];
    entries.removeWhere(
      (item) => item.sourceId == entry.sourceId && item.bookId == entry.bookId,
    );
    entries.insert(0, entry);
    if (entries.length > maxEntries) {
      entries.removeRange(maxEntries, entries.length);
    }
    await prefs.setString(
      _storageKey,
      jsonEncode(entries.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> remove({required String sourceId, required String bookId}) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = [...await load()];
    entries.removeWhere(
      (item) => item.sourceId == sourceId && item.bookId == bookId,
    );
    await prefs.setString(
      _storageKey,
      jsonEncode(entries.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
