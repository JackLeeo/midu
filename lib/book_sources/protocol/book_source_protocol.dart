// 米读（MiDu）书源协议精简层：
// 该文件是原 ORSP 协议层的子集，仅保留 Legado 运行时和客户端需要的数据模型。
// 不再支持 ORSP 协议本身（参见 P1.4）。

import 'dart:convert';

/// 协议版本：常量保留以兼容旧代码（Legado 书源不会使用）。
const String openReadingSourceProtocolVersion = '1.2.2-midu';

// ============================================================
//  异常
// ============================================================

class BookSourceProtocolException implements Exception {
  const BookSourceProtocolException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => code == null
      ? 'BookSourceProtocolException: $message'
      : 'BookSourceProtocolException [$code]: $message';
}

// ============================================================
//  JSON 解码辅助（剥离 UTF-8 BOM 等）
// ============================================================

Object? decodeBookSourceJson(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) return raw; // already parsed JSON (Map/List/num/bool)
  var text = raw;
  if (text.startsWith('\ufeff')) text = text.substring(1);
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return jsonDecode(trimmed);
}

// ============================================================
//  书源 Manifest（Legado 模式下大部分字段为空，仅用于接口兼容）
// ============================================================

class BookSourceManifest {
  const BookSourceManifest({
    required this.id,
    required this.name,
    required this.description,
    required this.apiBaseUrl,
    required this.protocolVersion,
    required this.languages,
    required this.capabilities,
    this.iconUrl,
    this.websiteUrl,
    this.operatorName = '',
    this.contactUrl,
    this.contentLicense = '',
    this.rightsStatement = '',
    this.maxCatalogPageSize,
  });

  final String id;
  final String name;
  final String description;
  final Uri apiBaseUrl;
  final String protocolVersion;
  final List<String> languages;
  final Set<String> capabilities;
  final Uri? iconUrl;
  final Uri? websiteUrl;
  final String operatorName;
  final Uri? contactUrl;
  final String contentLicense;
  final String rightsStatement;
  final int? maxCatalogPageSize;

  factory BookSourceManifest.fromJson(Map<String, dynamic> json) {
    return BookSourceManifest(
      id: _requireString(json, 'id'),
      name: _requireString(json, 'name'),
      description: _requireString(json, 'description'),
      apiBaseUrl: Uri.parse(_requireString(json, 'apiBaseUrl')),
      protocolVersion:
          json['protocolVersion'] as String? ?? openReadingSourceProtocolVersion,
      languages: (json['languages'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      capabilities: (json['capabilities'] as List? ?? const [])
          .whereType<String>()
          .toSet(),
      iconUrl: _optionalUri(json['iconUrl']),
      websiteUrl: _optionalUri(json['websiteUrl']),
      operatorName: json['operatorName'] as String? ?? '',
      contactUrl: _optionalUri(json['contactUrl']),
      contentLicense: json['contentLicense'] as String? ?? '',
      rightsStatement: json['rightsStatement'] as String? ?? '',
      maxCatalogPageSize: (json['maxCatalogPageSize'] as num?)?.toInt(),
    );
  }
}

// ============================================================
//  搜索结果
// ============================================================

class BookSourceSearchPage {
  const BookSourceSearchPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
  });

  factory BookSourceSearchPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List? ?? const [];
    return BookSourceSearchPage(
      items: rawItems
          .map((item) => BookSourceBook.fromJson(
                (item as Map).map((k, v) => MapEntry('$k', v)),
              ))
          .toList(growable: false),
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['pageSize'] as num?)?.toInt() ?? 20,
      hasMore: json['hasMore'] == true,
    );
  }

  final List<BookSourceBook> items;
  final int page;
  final int pageSize;
  final bool hasMore;
}

// ============================================================
//  书籍元信息
// ============================================================

class BookSourceBook {
  const BookSourceBook({
    required this.id,
    required this.title,
    this.author = '',
    this.description,
    this.coverUrl,
    this.categories = const [],
    this.status,
    this.latestChapter,
    this.wordCount,
    this.lastUpdateTime,
    this.updatedAt,
  });

  factory BookSourceBook.fromJson(Map<String, dynamic> json) {
    final coverUrl = json['coverUrl'];
    final categories = json['categories'];
    return BookSourceBook(
      id: _requireString(json, 'id'),
      title: _requireString(json, 'title'),
      author: json['author'] as String? ?? '',
      description: json['description'] as String?,
      coverUrl: coverUrl is String ? Uri.tryParse(coverUrl) : null,
      categories: categories is List
          ? categories.whereType<String>().toList(growable: false)
          : const [],
      status: json['status'] as String?,
      latestChapter: json['latestChapter'] as String?,
      wordCount: (json['wordCount'] as num?)?.toInt(),
      lastUpdateTime: json['lastUpdateTime'] == null
          ? null
          : DateTime.tryParse('${json['lastUpdateTime']}'),
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.tryParse('${json['updatedAt']}'),
    );
  }

  final String id;
  final String title;
  final String author;
  final String? description;
  final Uri? coverUrl;
  final List<String> categories;
  final String? status;
  final String? latestChapter;
  final int? wordCount;
  final DateTime? lastUpdateTime;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    if (description != null) 'description': description,
    if (coverUrl != null) 'coverUrl': coverUrl.toString(),
    'categories': categories,
    if (status != null) 'status': status,
    if (latestChapter != null) 'latestChapter': latestChapter,
    if (wordCount != null) 'wordCount': wordCount,
    if (lastUpdateTime != null) 'lastUpdateTime': lastUpdateTime!.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };
}

// ============================================================
//  章节
// ============================================================

class BookSourceChapter {
  const BookSourceChapter({
    required this.id,
    required this.title,
    required this.order,
    this.updatedAt,
  });

  factory BookSourceChapter.fromJson(Map<String, dynamic> json) {
    return BookSourceChapter(
      id: _requireString(json, 'id'),
      title: _requireString(json, 'title'),
      order: (json['order'] as num?)?.toInt() ?? 0,
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.tryParse('${json['updatedAt']}'),
    );
  }

  final String id;
  final String title;
  final int order;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'order': order,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };
}

int compareBookSourceChapters(BookSourceChapter a, BookSourceChapter b) {
  final r = a.order.compareTo(b.order);
  if (r != 0) return r;
  return a.id.compareTo(b.id);
}

// ============================================================
//  章节内容
// ============================================================

class BookSourceChapterContent {
  const BookSourceChapterContent({
    required this.bookId,
    required this.chapterId,
    required this.title,
    required this.content,
    required this.contentType,
  });

  factory BookSourceChapterContent.fromJson(Map<String, dynamic> json) {
    return BookSourceChapterContent(
      bookId: _requireString(json, 'bookId'),
      chapterId: _requireString(json, 'chapterId'),
      title: json['title'] as String? ?? '',
      content: _requireString(json, 'content'),
      contentType: json['contentType'] as String? ?? 'text/plain',
    );
  }

  final String bookId;
  final String chapterId;
  final String title;
  final String content;
  final String contentType;

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'title': title,
    'content': content,
    'contentType': contentType,
  };
}

// ============================================================
//  章节目录分页（ORSP 1.5+）
// ============================================================

class BookSourceChapterPage {
  const BookSourceChapterPage({
    required this.items,
    required this.hasMore,
    this.page = 1,
    this.pageSize = 0,
    this.total = 0,
  });

  factory BookSourceChapterPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List? ?? const [];
    return BookSourceChapterPage(
      items: rawItems
          .whereType<Map>()
          .map((m) => BookSourceChapter.fromJson(
                m.map((k, v) => MapEntry('$k', v)),
              ))
          .toList(growable: false),
      hasMore: json['hasMore'] == true,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['pageSize'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
    );
  }

  final List<BookSourceChapter> items;
  final bool hasMore;
  final int page;
  final int pageSize;
  final int total;
}

// ============================================================
//  发现页（Legado exploreUrl + ruleExplore，暂未使用，预留接口）
// ============================================================

class BookSourceCategory {
  const BookSourceCategory({
    required this.id,
    required this.name,
    this.children = const [],
  });

  factory BookSourceCategory.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'] as List? ?? const [];
    return BookSourceCategory(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      children: rawChildren
          .whereType<Map>()
          .map((m) => BookSourceCategory.fromJson(
                m.map((k, v) => MapEntry('$k', v)),
              ))
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final List<BookSourceCategory> children;
}

class BookSourceDiscoveryItem {
  const BookSourceDiscoveryItem({
    this.title = '',
    this.subtitle = '',
    this.coverUrl,
    this.targetUrl,
    this.kind = 'book', // book | banner | category
    this.book,
  });

  final String title;
  final String subtitle;
  final Uri? coverUrl;
  final String? targetUrl;
  final String kind;
  final BookSourceBook? book;
}

class BookSourceDiscoveryPage {
  const BookSourceDiscoveryPage({
    required this.title,
    required this.sections,
    this.nextPageUrl,
  });

  final String title;
  final List<BookSourceDiscoverySection> sections;
  final String? nextPageUrl;
}

class BookSourceDiscoverySection {
  const BookSourceDiscoverySection({
    required this.title,
    required this.items,
    this.layout = 'list', // list | grid | banner
  });

  final String title;
  final List<BookSourceDiscoveryItem> items;
  final String layout;
}

// ============================================================
//  米读：跨源聚合搜索结果
// ============================================================

/// 指向特定源中的特定书的指针
class SourcedBookPointer {
  const SourcedBookPointer({
    required this.sourceId,
    required this.sourceName,
    required this.bookId,
    this.book,
  });

  final String sourceId;
  final String sourceName;
  final String bookId;
  final BookSourceBook? book; // 原始单源书籍元信息（完整可选）
}

/// 聚合搜索结果中的一本书：去重合并后的多源视图
class AggregatedSearchHit {
  AggregatedSearchHit({
    required this.canonicalTitle,
    required this.canonicalAuthor,
    required this.sources,
    required this.tier,
    required this.score,
    this.coverUrl,
    this.description,
    this.latestChapter,
    this.categories = const [],
  });

  final String canonicalTitle; // 规范化标题（用于显示的第一个源的标题）
  final String canonicalAuthor; // 规范化作者
  final List<SourcedBookPointer> sources; // 可切换的多个源（至少 1 个）
  final int tier; // 0=书名+作者完全匹配; 1=书名完全匹配; 2=模糊匹配
  final double score; // 同 tier 内的精细排序分（字符重合度）
  final Uri? coverUrl;
  final String? description;
  final String? latestChapter;
  final List<String> categories;

  /// 主源（优先取 tier 内排名第一的源）
  SourcedBookPointer get primary => sources.first;

  /// 这本书的"备用源"数量（除主源外）
  int get alternativeCount => sources.length - 1;
}

/// 聚合搜索结果页
class AggregatedSearchPage {
  const AggregatedSearchPage({
    required this.hits,
    required this.query,
    required this.sourceCount,
    required this.respondedSourceCount,
    required this.perSourceErrors,
    required this.hasMore,
  });

  final List<AggregatedSearchHit> hits;
  final String query;
  final int sourceCount; // 总并发源数
  final int respondedSourceCount; // 成功返回源数
  final Map<String, String> perSourceErrors; // sourceId -> error message
  final bool hasMore;
}

// ============================================================
//  内部辅助
// ============================================================

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw BookSourceProtocolException('Missing required field: $key');
  }
  return value;
}

Uri? _optionalUri(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return Uri.tryParse(value);
}

Map<String, dynamic> asBookSourceJsonObject(Object? decoded) {
  if (decoded is! Map) {
    throw const BookSourceProtocolException('Expected a JSON object.');
  }
  return decoded.map((key, value) => MapEntry('$key', value));
}
