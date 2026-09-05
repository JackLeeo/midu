// 文件说明：RSS 文章列表页与文章阅读页。
// 技术要点：列表页按「缓存命中即显、过期静默刷新」加载 feed；阅读页用
// package:html 把正文 HTML 转换为纯文本段落（与电子书阅读一致的文体，
// 避免直接渲染不可信 HTML/脚本）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../services/rss/rss_feed_model.dart';
import '../../services/rss/rss_subscription_store.dart';
import '../../utils/localization_extension.dart';

/// 文章列表页：展示某订阅源的最新文章，点击进入阅读页。
class RssArticlesPage extends StatefulWidget {
  const RssArticlesPage({
    super.key,
    required this.feedUrl,
    required this.service,
  });

  final String feedUrl;
  final RssFeedService service;

  @override
  State<RssArticlesPage> createState() => _RssArticlesPageState();
}

class _RssArticlesPageState extends State<RssArticlesPage> {
  RssFeed? _feed;
  Object? _error;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final feed = await widget.service.loadFeed(widget.feedUrl);
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final feed = await widget.service.loadFeed(
        widget.feedUrl,
        refresh: true,
      );
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    final title = feed?.title?.isNotEmpty == true
        ? feed!.title!
        : Uri.tryParse(widget.feedUrl)?.host ?? widget.feedUrl;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('rss-articles-refresh'),
            tooltip: context.l10n.rssRefresh,
            onPressed: _refreshing ? null : () => unawaited(_refresh()),
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _error != null && feed == null
          ? Center(child: Text(context.l10n.rssFeedError))
          : feed == null
          ? const Center(child: CircularProgressIndicator())
          : feed.items.isEmpty
          ? Center(child: Text(context.l10n.rssNoArticles))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                itemCount: feed.items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => _ArticleTile(
                  feedTitle: title,
                  item: feed.items[index],
                ),
              ),
            ),
    );
  }
}

class _ArticleTile extends StatelessWidget {
  const _ArticleTile({required this.feedTitle, required this.item});

  final String feedTitle;
  final RssItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RssArticlePage(feedTitle: feedTitle, item: item),
          ),
        ),
        title: Text(
          item.title ?? context.l10n.rssUntitled,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: item.author == null
            ? null
            : Text(
                '${item.author}${item.publishedAt != null ? ' · ${_dateText(item.publishedAt!)}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
      ),
    );
  }

  static String _dateText(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${_pad(local.month)}-${_pad(local.day)} '
        '${_pad(local.hour)}:${_pad(local.minute)}';
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');
}

/// 文章阅读页：标题/作者/时间 + 正文（HTML 净化为纯文本段落）。
class RssArticlePage extends StatelessWidget {
  const RssArticlePage({
    super.key,
    required this.feedTitle,
    required this.item,
  });

  final String feedTitle;
  final RssItem item;

  @override
  Widget build(BuildContext context) {
    final paragraphs = htmlToParagraphs(item.body);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(feedTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
        children: [
          Text(
            item.title ?? context.l10n.rssUntitled,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          if (item.author != null || item.publishedAt != null) ...[
            const SizedBox(height: 10),
            Text(
              [
                if (item.author != null && item.author!.isNotEmpty)
                  item.author!,
                if (item.publishedAt != null)
                  _ArticleTile._dateText(item.publishedAt!),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
          if (paragraphs.isEmpty)
            Text(
              item.link ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            )
          else
            for (final paragraph in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  paragraph,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                ),
              ),
        ],
      ),
    );
  }
}

/// 把 HTML 正文转换为段落列表：
/// - 剔除 script/style
/// - 块级元素（p/div/h1-6/li/blockquote/tr）+ <br> 断行
/// - 纯文本节点累积为段落，避免无块标签 feed 挤成一大段
List<String> htmlToParagraphs(String html) {
  final cleaned = html.trim();
  if (cleaned.isEmpty) return const [];
  final document = html_parser.parse(cleaned);
  final paragraphs = <String>[];
  final buffer = StringBuffer();

  void flush() {
    final text = _collapse(buffer.toString());
    buffer.clear();
    if (text.isNotEmpty) paragraphs.add(text);
  }

  void visit(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'script' || tag == 'style' || tag == 'noscript') return;
    if (_blockTags.contains(tag) || tag == 'br') {
      flush();
      if (tag != 'br') {
        for (final child in node.nodes) {
          visit(child);
        }
        flush();
      }
      return;
    }
    for (final child in node.nodes) {
      visit(child);
    }
  }

  for (final node in document.body?.nodes ?? const <dom.Node>[]) {
    visit(node);
    flush();
  }
  return paragraphs;
}

const Set<String> _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'blockquote',
  'tr',
  'td',
  'th',
};

String _collapse(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();