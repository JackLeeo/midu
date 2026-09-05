// 文件说明：RSS 数据模型（对标 Legado 底部 RSS tab）。
// 技术要点：纯 Dart 数据类；[RssItem.id] 稳定键用于去重与缓存。
class RssFeed {
  const RssFeed({
    this.title,
    this.link,
    this.description,
    this.language,
    this.updatedAt,
    this.items = const [],
  });

  final String? title;
  final String? link;
  final String? description;
  final String? language;
  final DateTime? updatedAt;
  final List<RssItem> items;

  RssFeed copyWith({List<RssItem>? items}) => RssFeed(
    title: title,
    link: link,
    description: description,
    language: language,
    updatedAt: updatedAt,
    items: items ?? this.items,
  );
}

class RssItem {
  const RssItem({
    required this.id,
    this.title,
    this.link,
    this.author,
    this.publishedAt,
    this.summary,
    this.content,
  });

  /// 稳定唯一键（guid / entry id / JSONFeed id）。
  final String id;

  final String? title;
  final String? link;
  final String? author;
  final DateTime? publishedAt;

  /// 简短摘要（rss description / atom summary / feed summary）。
  final String? summary;

  /// 正文 HTML（content:encoded / atom content / JSONFeed content_html）。
  final String? content;

  /// 首个可用正文（content 优先，其次 summary）。
  String get body => content ?? summary ?? '';

  bool get hasMedia => content?.isNotEmpty ?? false;
}