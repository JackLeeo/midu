// 文件说明：RSS 底部 tab 页 —— 订阅源列表 + 添加/移除/刷新 + 进入文章列表。
// 技术要点：订阅与抓取服务可注入（便于 widget 测试）；列表项懒加载 feed 元数据，
// 点击后进入 [RssArticlesPage]（含缓存命中即显、过期静默刷新）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/rss/rss_feed_model.dart';
import '../../services/rss/rss_subscription_store.dart';
import '../../utils/localization_extension.dart';
import 'rss_article_page.dart';

class RssPage extends StatefulWidget {
  const RssPage({
    super.key,
    this.store,
    this.service,
    this.sourceFeedResolver,
  });

  final RssSubscriptionStore? store;
  final RssFeedService? service;

  /// 书源式 RSS（ruleRss）收集器；未注入时使用默认实现（读书源注册表）。
  final Future<List<RssSourceFeed>> Function()? sourceFeedResolver;

  @override
  State<RssPage> createState() => _RssPageState();
}

class _RssPageState extends State<RssPage> {
  late final RssSubscriptionStore _store =
      widget.store ?? RssSubscriptionStore();
  late final RssFeedService _service =
      widget.service ?? RssFeedService();
  late final Future<List<RssSourceFeed>> Function() _sourceFeedResolver =
      widget.sourceFeedResolver ?? defaultRssSourceFeeds;

  List<String> _urls = const [];
  List<RssSourceFeed> _sourceFeeds = const [];
  final Map<String, RssFeed> _feeds = {};
  final Map<String, Object?> _errors = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUrls();
  }

  Future<void> _loadUrls() async {
    final urls = await _store.loadUrls();
    List<RssSourceFeed> sourceFeeds = const [];
    try {
      sourceFeeds = await _sourceFeedResolver();
    } catch (_) {
      // 注册表不可用（测试/首次）时静默跳过书源 RSS 段
    }
    if (!mounted) return;
    setState(() {
      _urls = urls;
      _sourceFeeds = sourceFeeds;
      _loading = false;
    });
    for (final url in urls) {
      unawaited(_loadFeedMeta(url, refresh: false));
    }
  }

  Future<void> _loadFeedMeta(String url, {required bool refresh}) async {
    try {
      final feed = await _service.loadFeed(url, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _feeds[url] = feed;
        _errors.remove(url);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errors[url] = error);
    }
  }

  Future<void> _addFeed() async {
    final saved = await showDialog<String>(
      context: context,
      builder: (_) => const _AddFeedDialog(),
    );
    if (saved == null || saved.trim().isEmpty) return;
    final urls = await _store.addUrl(saved);
    if (!mounted) return;
    setState(() => _urls = urls);
    await _loadFeedMeta(saved, refresh: true);
  }

  Future<void> _removeFeed(String url) async {
    final urls = await _store.removeUrl(url);
    if (!mounted) return;
    setState(() {
      _urls = urls;
      _feeds.remove(url);
      _errors.remove(url);
    });
    await _service.invalidate(url);
  }

  void _openFeed(String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssArticlesPage(feedUrl: url, service: _service),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _urls.isEmpty && _sourceFeeds.isEmpty
          ? _emptyState(l10n)
          : RefreshIndicator(
              onRefresh: () async {
                for (final url in _urls) {
                  await _loadFeedMeta(url, refresh: true);
                }
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  if (_sourceFeeds.isNotEmpty) ...[
                    _sectionHeader(context.l10n.rssSourceFeedsSection),
                    for (final feed in _sourceFeeds) _buildSourceFeedTile(feed),
                    const SizedBox(height: 8),
                  ],
                  if (_urls.isNotEmpty) ...[
                    _sectionHeader(context.l10n.rssMyFeedsSection),
                    for (final url in _urls) _buildFeedTile(url),
                  ],
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('rss-add-feed-button'),
        onPressed: _addFeed,
        icon: const Icon(Icons.rss_feed_rounded),
        label: Text(l10n.rssAddFeed),
      ),
    );
  }

  Widget _emptyState(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.rss_feed_rounded,
              size: 52,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.rssNoFeeds,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.rssNoFeedsHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildSourceFeedTile(RssSourceFeed feed) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          key: ValueKey('rss-source-feed-${feed.name}'),
          onTap: () => _openFeed(feed.url),
          leading: Icon(Icons.auto_stories_rounded, color: scheme.tertiary),
          title: Text(
            feed.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            feed.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }

  Widget _buildFeedTile(String url) {
    final scheme = Theme.of(context).colorScheme;
    final feed = _feeds[url];
    final error = _errors[url];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          key: ValueKey('rss-feed-tile-$url'),
          onTap: () => _openFeed(url),
          leading: Icon(Icons.rss_feed_rounded, color: scheme.primary),
          title: Text(
            feed?.title?.isNotEmpty == true
                ? feed!.title!
                : Uri.tryParse(url)?.host ?? url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            error != null
                ? context.l10n.rssFeedError
                : (feed?.description?.isNotEmpty == true
                      ? feed!.description!
                      : url),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: context.l10n.rssRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: () => unawaited(_loadFeedMeta(url, refresh: true)),
              ),
              IconButton(
                tooltip: context.l10n.rssRemove,
                icon: Icon(Icons.delete_outline_rounded, size: 20,
                    color: scheme.error),
                onPressed: () => unawaited(_removeFeed(url)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 添加订阅对话框：TextField 控制器挂在 State 上随生命周期释放，
/// 避免对话框关闭动画期间 dispose 导致崩溃。
class _AddFeedDialog extends StatefulWidget {
  const _AddFeedDialog();

  @override
  State<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<_AddFeedDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.rssAddFeed),
      content: TextField(
        key: const ValueKey('rss-feed-url-editor'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          hintText: context.l10n.rssFeedUrlHint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}