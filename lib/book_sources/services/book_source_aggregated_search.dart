// 米读：跨源聚合搜索
// 1. 并发调用所有 Legado 书源 search()，单源错误不影响整体（错误被记录）
// 2. 去重合并：以 (规范化书名, 规范化作者) 为 key，将多源结果合并为一个 AggregatedSearchHit
// 3. 三级相关性排序：
//    tier 0 — 书名完全匹配 && 作者完全匹配（用户 query 如 "诡秘之主 爱潜水的乌贼" 时）
//    tier 1 — 书名完全匹配
//    tier 2 — 模糊匹配（按字符重合度打分排序）
import 'dart:async';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_client.dart';

class BookSourceAggregatedSearch {
  const BookSourceAggregatedSearch(this._client);

  final BookSourceClient _client;

  static const Duration defaultPerSourceTimeout = Duration(seconds: 12);
  static const int defaultPerSourcePageSize = 20;

  Future<AggregatedSearchPage> search(
    List<RegisteredBookSource> sources,
    String rawQuery, {
    int page = 1,
    int aggregatedPageSize = 20,
    Duration perSourceTimeout = defaultPerSourceTimeout,
    int perSourcePageSize = defaultPerSourcePageSize,
  }) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      return AggregatedSearchPage(
        hits: const [],
        query: query,
        sourceCount: sources.length,
        respondedSourceCount: 0,
        perSourceErrors: const {},
        hasMore: false,
      );
    }

    // 解析用户查询：尝试拆成 书名 + 作者
    final parsed = _parseQuery(query);
    final normTitle = _norm(parsed.titleHint);
    final normAuthor = _norm(parsed.authorHint);

    // 并发搜索所有源
    final errors = <String, String>{};
    final allItems = <_SourcedBook>[];
    var responded = 0;

    final futures = sources.map((s) async {
      try {
        final page0 = await _client
            .search(s, query, page: page, pageSize: perSourcePageSize)
            .timeout(perSourceTimeout);
        return _SearchOk(s, page0);
      } catch (e) {
        return _SearchErr(s, e.toString());
      }
    });
    final results = await Future.wait(futures);
    for (final r in results) {
      if (r is _SearchOk) {
        responded++;
        for (final b in r.page.items) {
          allItems.add(_SourcedBook(source: r.source, book: b));
        }
      } else if (r is _SearchErr) {
        errors[r.source.id] = r.error;
      }
    }

    // 去重合并
    final merged = <String, AggregatedSearchHitBuilder>{};
    for (final item in allItems) {
      final key = _dedupKey(item.book.title, item.book.author);
      final builder = merged.putIfAbsent(key, () => AggregatedSearchHitBuilder());
      builder.add(item);
    }

    // 计算 tier 和 score + 排序
    final sortedHits = merged.values
        .map((b) => b.build(
              normTitleQuery: normTitle,
              normAuthorQuery: normAuthor,
              rawTitleQuery: parsed.titleHint,
            ))
        .toList(growable: false)
      ..sort((a, b) {
        final r = a.tier.compareTo(b.tier);
        if (r != 0) return r;
        // tier 相同：score 高在前，其次按源数多在前
        final r2 = b.score.compareTo(a.score);
        if (r2 != 0) return r2;
        return b.sources.length.compareTo(a.sources.length);
      });

    final totalHits = sortedHits.length;
    final hasMore = totalHits > aggregatedPageSize;
    final paged =
        hasMore ? sortedHits.sublist(0, aggregatedPageSize) : sortedHits;

    return AggregatedSearchPage(
      hits: List.unmodifiable(paged),
      query: query,
      sourceCount: sources.length,
      respondedSourceCount: responded,
      perSourceErrors: Map.unmodifiable(errors),
      hasMore: hasMore,
    );
  }

  // ========== 查询解析：支持 "书名 作者" 或 "书名·作者" 或 "书名,作者" ==========

  _ParsedQuery _parseQuery(String raw) {
    final q = raw.trim();
    // 按常见分隔符拆分
    final bySep = q.split(RegExp(r'\s*[·•\-_,，]\s*'));
    if (bySep.length >= 2 && bySep.first.trim().isNotEmpty) {
      final a = bySep.first.trim();
      final b = bySep.sublist(1).join(' ').trim();
      if (a.isNotEmpty && b.isNotEmpty) {
        return _ParsedQuery(titleHint: a, authorHint: b);
      }
    }
    // 否则尝试最后两字/三字是作者（不强制，仅当用户用空格分开）
    final parts = q.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      // 启发式：最后一段长度 >= 2 且 <= 5 时视作可能的作者
      final last = parts.last.trim();
      if (last.length >= 2 && last.length <= 6) {
        return _ParsedQuery(
          titleHint: parts.sublist(0, parts.length - 1).join(' ').trim(),
          authorHint: last,
        );
      }
    }
    return _ParsedQuery(titleHint: q, authorHint: '');
  }
}

// ============================================================
//  内部辅助
// ============================================================

class _ParsedQuery {
  const _ParsedQuery({required this.titleHint, required this.authorHint});
  final String titleHint;
  final String authorHint;
}

class _SearchResult {}

class _SearchOk extends _SearchResult {
  _SearchOk(this.source, this.page);
  final RegisteredBookSource source;
  final BookSourceSearchPage page;
}

class _SearchErr extends _SearchResult {
  _SearchErr(this.source, this.error);
  final RegisteredBookSource source;
  final String error;
}

class _SourcedBook {
  _SourcedBook({required this.source, required this.book});
  final RegisteredBookSource source;
  final BookSourceBook book;
}

/// AggregatedSearchHit 的可变构建器
class AggregatedSearchHitBuilder {
  final List<_SourcedBook> items = [];
  String? _firstTitle;
  String? _firstAuthor;

  void add(_SourcedBook item) {
    items.add(item);
    _firstTitle ??= item.book.title;
    _firstAuthor ??= item.book.author;
  }

  AggregatedSearchHit build({
    required String normTitleQuery,
    required String normAuthorQuery,
    required String rawTitleQuery,
  }) {
    // 选择一个展示用的 canonical 源：优先选有封面 + 简介的
    _SourcedBook? best;
    for (final it in items) {
      if (best == null) {
        best = it;
        continue;
      }
      var score = 0;
      var bestScore = 0;
      if (it.book.coverUrl != null) score++;
      if (best.book.coverUrl != null) bestScore++;
      if ((it.book.description ?? '').isNotEmpty) score++;
      if ((best.book.description ?? '').isNotEmpty) bestScore++;
      if (score > bestScore) best = it;
    }
    final display = best ?? items.first;

    final title = display.book.title;
    final author = display.book.author;
    final nTitle = _norm(title);
    final nAuthor = _norm(author);

    int tier;
    double score;
    if (normTitleQuery.isNotEmpty &&
        nTitle == normTitleQuery &&
        normAuthorQuery.isNotEmpty &&
        nAuthor == normAuthorQuery) {
      tier = 0;
      score = 1.0;
    } else if (normTitleQuery.isNotEmpty && nTitle == normTitleQuery) {
      tier = 1;
      // tier 1 内：作者越接近越高分
      score = 0.8 + 0.19 * _similarity(nAuthor, normAuthorQuery);
    } else {
      tier = 2;
      // 模糊匹配：书名与 query 的字符重合度
      final simTitle = _similarity(nTitle, normTitleQuery.isNotEmpty ? normTitleQuery : _norm(rawTitleQuery));
      final simAuthor = normAuthorQuery.isEmpty
          ? 0.0
          : _similarity(nAuthor, normAuthorQuery);
      score = simTitle * 0.7 + simAuthor * 0.3;
    }

    return AggregatedSearchHit(
      canonicalTitle: title,
      canonicalAuthor: author,
      sources: items
          .map((e) => SourcedBookPointer(
                sourceId: e.source.id,
                sourceName: e.source.name,
                bookId: e.book.id,
                book: e.book,
              ))
          .toList(growable: false),
      tier: tier,
      score: score,
      coverUrl: display.book.coverUrl,
      description: display.book.description,
      latestChapter: display.book.latestChapter,
      categories: display.book.categories,
    );
  }
}

// ============================================================
//  规范化 / 相似度工具
// ============================================================

String _norm(String s) => s
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s·•\-_,，。.！!？?:"""''\[\]【】《》<>]+'), '');

String _dedupKey(String title, String author) {
  final t = _norm(title);
  final a = _norm(author);
  // 标题为空时不要合并；作者为空时只按 title 去重
  if (t.isEmpty) return '!!empty_title!!::${title.hashCode}::${author.hashCode}';
  return '$t|${a.isEmpty ? '_noauthor_' : a}';
}

/// 字符 Jaccard 重合度：|A ∩ B| / |A ∪ B|
double _similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final setA = a.split('').toSet();
  final setB = b.split('').toSet();
  final inter = setA.where(setB.contains).length;
  if (inter == 0) return 0;
  final uni = setA.length + setB.length - inter;
  return uni == 0 ? 0 : inter / uni;
}
