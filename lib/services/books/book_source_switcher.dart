// 米读：章节对齐 + 换源服务
// 1. ChapterAligner：基于标题 Jaccard 相似度 + 序号比例 的双对齐算法
// 2. BookSourceSwitcher：
//    - 获取目标源目录 → 对齐定位 → 返回新章节指针
//    - 生成一个 "更新后的 Book"（currentSourceId 已切换 + 兼容字段刷新）
import 'dart:math' as math;

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_client.dart';
import '../../models/book.dart';

class SourceSwitchResult {
  const SourceSwitchResult({
    required this.targetPointer,
    required this.alignedChapter,
    required this.targetChapters,
    this.isApproximate = false,
    this.confidence = 1.0,
  });

  final SourcedBookPointer targetPointer;
  final BookSourceChapter alignedChapter;
  final List<BookSourceChapter> targetChapters; // 目标源完整目录，缓存以便后续直接用
  final bool isApproximate; // true 表示非精确标题匹配，仅按比例对齐
  final double confidence; // 0..1，标题匹配度
}

class BookSourceSwitcher {
  const BookSourceSwitcher(this._client);

  final BookSourceClient _client;

  /// 换源：从当前章节切到目标源。
  ///
  /// - [targetSource]: 已注册的目标源（通常由 UI 通过 Book.decodeAllSources + BookSourceRegistry.load 找到）
  /// - [targetPointer]: 目标源中本书的指针（sourceId/bookId 必须匹配 [targetSource]）
  /// - [currentChapter]: 当前正在阅读的章节（通常来自当前源目录）
  /// - [currentChapterIndexInBook]: 当前章节在当前目录中的序号
  /// - [currentChaptersLength]: 当前目录总长度；用于比例对齐
  Future<SourceSwitchResult> switchTo({
    required RegisteredBookSource targetSource,
    required SourcedBookPointer targetPointer,
    required BookSourceChapter currentChapter,
    required int currentChapterIndexInBook,
    required int currentChaptersLength,
  }) async {
    if (targetPointer.sourceId != targetSource.id) {
      throw SourceSwitchException(
        'sourceId 不匹配：pointer=${targetPointer.sourceId} registered=${targetSource.id}',
      );
    }
    final targetChapters =
        await _client.getChapters(targetSource, targetPointer.bookId).timeout(
              const Duration(seconds: 15),
            );
    if (targetChapters.isEmpty) {
      throw SourceSwitchException('目标源返回空目录');
    }
    final aligned = ChapterAligner.align(
      currentChapter: currentChapter,
      currentIndex: currentChapterIndexInBook,
      currentTotal: currentChaptersLength,
      targetChapters: targetChapters,
    );
    return SourceSwitchResult(
      targetPointer: targetPointer,
      alignedChapter: aligned.chapter,
      targetChapters: targetChapters,
      isApproximate: aligned.isApproximate,
      confidence: aligned.confidence,
    );
  }

  /// 换源后，基于 [SourceSwitchResult] 刷新 Book 的兼容字段。
  Book applyResultToBook(Book book, SourceSwitchResult result) {
    return book.copyWith(
      currentSourceId: result.targetPointer.sourceId,
      sourceId: result.targetPointer.sourceId,
      sourceBookId: result.targetPointer.bookId,
      sourceJson: result.targetPointer.sourceName,
    );
  }
}

// ====================================================================
//  章节对齐算法
// ====================================================================

class AlignResult {
  const AlignResult({
    required this.chapter,
    required this.index,
    required this.isApproximate,
    required this.confidence,
  });
  final BookSourceChapter chapter;
  final int index;
  final bool isApproximate;
  final double confidence;
}

class ChapterAligner {
  static const double exactMatchThreshold = 0.85; // 标题相似度超过此值视为精确匹配
  static const double minMatchThreshold = 0.35; // 低于此值则回退到比例对齐

  /// 核心对齐：先做标题匹配（取最高），不够精确则回退到比例对齐。
  static AlignResult align({
    required BookSourceChapter currentChapter,
    required int currentIndex,
    required int currentTotal,
    required List<BookSourceChapter> targetChapters,
  }) {
    if (targetChapters.isEmpty) {
      throw ArgumentError('targetChapters 为空');
    }
    final normCurrent = _norm(currentChapter.title);
    // 标题匹配阶段
    int bestIdx = -1;
    double bestScore = -1;
    for (var i = 0; i < targetChapters.length; i++) {
      final t = targetChapters[i];
      final s = _similarity(normCurrent, _norm(t.title));
      if (s > bestScore) {
        bestScore = s;
        bestIdx = i;
      }
    }
    if (bestScore >= exactMatchThreshold && bestIdx >= 0) {
      return AlignResult(
        chapter: targetChapters[bestIdx],
        index: bestIdx,
        isApproximate: false,
        confidence: bestScore,
      );
    }

    // 否则：比例对齐，同时在比例点附近 ± 15% 做一个局部标题匹配
    final ratio = currentTotal <= 0
        ? 0.0
        : (currentIndex / currentTotal).clamp(0.0, 1.0);
    final approxIdx =
        (ratio * (targetChapters.length - 1)).round().clamp(0, targetChapters.length - 1);
    final radius = math.max(
      1,
      ((targetChapters.length * 0.15)).round(),
    );
    final lo = (approxIdx - radius).clamp(0, targetChapters.length - 1);
    final hi = (approxIdx + radius).clamp(0, targetChapters.length - 1);
    int localBestIdx = approxIdx;
    double localBestScore = -1;
    for (var i = lo; i <= hi; i++) {
      final s =
          _similarity(normCurrent, _norm(targetChapters[i].title));
      if (s > localBestScore) {
        localBestScore = s;
        localBestIdx = i;
      }
    }
    if (localBestScore >= minMatchThreshold) {
      return AlignResult(
        chapter: targetChapters[localBestIdx],
        index: localBestIdx,
        isApproximate: true,
        confidence: localBestScore,
      );
    }
    // 纯比例对齐
    return AlignResult(
      chapter: targetChapters[approxIdx],
      index: approxIdx,
      isApproximate: true,
      confidence: 0,
    );
  }

  // 规范化：去掉空格/标点/常见章节号前缀
  static String _norm(String s) {
    var v = s.trim().toLowerCase();
    v = v.replaceAll(RegExp(r'^\s*第[0-9零一二三四五六七八九十百千万]+[章节回卷集部篇话]\s*'), '');
    v = v.replaceAll(RegExp(r'^\s*\d+\s*[\.\、\-\:：]\s*'), '');
    v = v.replaceAll(RegExp(r'[\s·•\-_,，。.！!？?:"""''\[\]【】《》<>（）()【】「」『』]+'), '');
    return v;
  }

  static double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    // 完全子串的情况给高分（应对"上"、"中"、"下"、"VIP:"前缀差异）
    if (a.contains(b) || b.contains(a)) {
      final overlap = math.min(a.length, b.length) / math.max(a.length, b.length);
      return 0.7 + overlap * 0.3;
    }
    final setA = a.split('').toSet();
    final setB = b.split('').toSet();
    final inter = setA.where(setB.contains).length;
    if (inter == 0) return 0;
    final uni = setA.length + setB.length - inter;
    return uni == 0 ? 0 : inter / uni;
  }
}

class SourceSwitchException implements Exception {
  SourceSwitchException(this.message);
  final String message;
  @override
  String toString() => 'SourceSwitchException: $message';
}
