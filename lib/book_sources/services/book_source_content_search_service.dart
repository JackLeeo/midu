// 文件说明：正文搜索（对标 Legado ui/book/searchContent）。
// 技术要点：
// - 逐章拉取正文（走阅读器同一章节缓存/净化链路），支持并发上限与取消；
// - 普通 contains / 正则两种匹配，命中处取前后 ±20 字符上下文片段；
// - 单章完成后立即增量回调（页面按 chapterIndex 归并展示）；
// - 单章失败仅跳过该章，不中断整本搜索（对标 Legado 行为）。
import 'dart:async';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_chapter_text.dart';
import 'book_source_client.dart';
import 'replace_rule_service.dart';

/// 单条正文命中。
class ContentSearchMatch {
  const ContentSearchMatch({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.snippet,
    required this.queryIndexInSnippet,
    required this.isRegex,
  });

  final int chapterIndex;
  final String chapterTitle;

  /// 命中关键词周边 ±20 字符上下文。
  final String snippet;

  /// [snippet] 内关键词起始偏移（用于高亮）。
  final int queryIndexInSnippet;
  final bool isRegex;
}

/// 搜索进度快照（每完成一章即回调一次）。
class ContentSearchProgress {
  const ContentSearchProgress({
    required this.scannedChapters,
    required this.totalChapters,
    required this.matches,
  });

  final int scannedChapters;
  final int totalChapters;
  final List<ContentSearchMatch> matches;
}

/// 章节正文获取抽象（可注入 fake 供离线测试）。
typedef ContentSearchChapterLoader =
    Future<String> Function(int order, String chapterId);

/// 正文搜索服务：给定书源 + 书籍 + 目录，逐章搜索正文。
class BookSourceContentSearchService {
  const BookSourceContentSearchService();

  /// 命中上下文每侧字符数（对标 Legado SearchContentViewModel 的 length=20）。
  static const int contextLength = 20;

  /// 同步搜索单段文本，返回全部命中起始偏移（普通/正则）。
  static List<int> positionsOf(String text, String query, {bool regex = false}) {
    if (query.isEmpty) return const [];
    if (regex) {
      try {
        return RegExp(query).allMatches(text).map((m) => m.start).toList();
      } on FormatException {
        return const [];
      }
    }
    final positions = <int>[];
    var index = text.indexOf(query);
    while (index >= 0) {
      positions.add(index);
      index = text.indexOf(query, index + query.length);
    }
    return positions;
  }

  /// 逐章搜索。
  ///
  /// [loader] 返回第 [order] 章的（已净化/可读）正文；为 null 时内部用 [client]
  /// 以缓存优先加载。结果通过 [onProgress] 增量回调（可实时上屏），全部完成时
  /// 返回按章节升序的完整结果；[isCancelled] 返回 true 提前结束。
  Future<List<ContentSearchMatch>> searchBook({
    required RegisteredBookSource source,
    required String bookId,
    required List<BookSourceChapter> chapters,
    required String query,
    ContentSearchChapterLoader? loader,
    bool useReplace = true,
    List<ReplaceRule> replaceRules = const [],
    bool regex = false,
    int concurrent = 3,
    void Function(ContentSearchProgress)? onProgress,
    bool Function()? isCancelled,
    BookSourceClient? client,
  }) async {
    if (query.trim().isEmpty || chapters.isEmpty) return const [];
    final loadText =
        loader ??
        _defaultLoader(client, source, bookId, useReplace, replaceRules);

    final matches = <ContentSearchMatch>[];
    var scanned = 0;

    Future<void> scan(int index) async {
      if (isCancelled?.call() ?? false) return;
      final chapter = chapters[index];
      final String text;
      try {
        text = await loadText(chapter.order, chapter.id).timeout(
          const Duration(seconds: 30),
          onTimeout: () => '',
        );
      } catch (_) {
        return; // 单章失败跳过
      }
      for (final position in positionsOf(text, query, regex: regex)) {
        matches.add(
          _buildMatch(chapter, text, position, query, regex),
        );
      }
      scanned++;
      onProgress?.call(
        ContentSearchProgress(
          scannedChapters: scanned,
          totalChapters: chapters.length,
          matches: List<ContentSearchMatch>.from(matches),
        ),
      );
    }

    await _spread(concurrent, chapters.length, scan);
    matches.sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    return matches;
  }

  static ContentSearchMatch _buildMatch(
    BookSourceChapter chapter,
    String text,
    int position,
    String query,
    bool regex,
  ) {
    final length = contextLength;
    final actualStart = position >= length ? position - length : 0;
    final actualEnd =
        (position + query.length + length).clamp(0, text.length);
    final snippet = text.substring(actualStart, actualEnd);
    return ContentSearchMatch(
      chapterIndex: chapter.order,
      chapterTitle: chapter.title,
      snippet: snippet,
      queryIndexInSnippet: position - actualStart,
      isRegex: regex,
    );
  }

  /// 并发上限执行器。
  Future<void> _spread(
    int concurrent,
    int total,
    Future<void> Function(int index) task,
  ) async {
    if (total == 0) return;
    var next = 0;
    var limit = concurrent.clamp(1, 8);
    if (limit > total) limit = total;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= total) return;
        await task(index);
      }
    }

    await Future.wait<void>([
      for (var i = 0; i < limit; i++) worker(),
    ]);
  }

  ContentSearchChapterLoader _defaultLoader(
    BookSourceClient? client,
    RegisteredBookSource source,
    String bookId,
    bool useReplace,
    List<ReplaceRule> replaceRules,
  ) {
    if (client == null) {
      throw BookSourceProtocolException('正文搜索需要 BookSourceClient 实例');
    }
    return (order, chapterId) async {
      final content = await client.getChapterContent(
        source,
        bookId: bookId,
        chapterId: chapterId,
      );
      return readableBookSourceChapterText(
        content,
        fallbackTitle: '',
        replaceRules: useReplace ? replaceRules : const [],
      );
    };
  }
}