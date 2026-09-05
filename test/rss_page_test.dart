// M8 RSS 页面 widget 专项测试：
// 1. 空状态：无订阅时展示空态引导
// 2. 书源式 RSS（ruleRss）双轨区展示
// 3. 添加订阅：对话框输入 URL → 保存 → 列表出现 feed（标题来自抓取）
// 4. 订阅列表刷新/移除入口
// 5. 文章列表页点击进入阅读页展示正文段落

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/l10n/app_localizations.dart';
import 'package:midu/pages/rss/rss_page.dart';
import 'package:midu/services/rss/rss_parser_service.dart';
import 'package:midu/services/rss/rss_subscription_store.dart';

const String _feedUrl = 'https://example.com/feed.xml';

const String _rssXml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>页面测试源</title>
    <link>https://example.com/</link>
    <item>
      <guid>item-1</guid>
      <title>测试文章一</title>
      <author>作者甲</author>
      <description>文章摘要</description>
      <content:encoded><![CDATA[<p>正文第一段。</p><p>正文第二段。</p>]]></content:encoded>
    </item>
  </channel>
</rss>
''';

class _FakeFetcher extends RssFeedFetcher {
  @override
  Future<String> fetch(String url) async => _rssXml;
}

Future<void> _pumpRssPage(
  WidgetTester tester, {
  Future<List<RssSourceFeed>> Function()? sourceResolver,
}) async {
  SharedPreferences.setMockInitialValues({});
  final service = RssFeedService(
    fetcher: _FakeFetcher(),
    parser: const RssParserService(),
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: RssPage(
        store: RssSubscriptionStore(),
        service: service,
        sourceFeedResolver: sourceResolver ?? () async => const [],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空状态展示引导文案', (tester) async {
    await _pumpRssPage(tester);
    expect(find.text('还没有订阅源'), findsOneWidget);
    expect(find.textContaining('添加订阅'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书源式 RSS（ruleRss）区块展示', (tester) async {
    await _pumpRssPage(
      tester,
      sourceResolver: () async => const [
        RssSourceFeed(name: '源A', url: 'https://a.example/rss'),
        RssSourceFeed(name: '源B', url: 'https://b.example/rss'),
      ],
    );
    expect(find.text('书源订阅'), findsOneWidget);
    expect(find.text('源A'), findsOneWidget);
    expect(find.text('源B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加订阅：对话框保存后列表出现 feed', (tester) async {
    await _pumpRssPage(tester);

    await tester.tap(find.byKey(const ValueKey('rss-add-feed-button')));
    await tester.pumpAndSettle();
    expect(find.text('添加订阅'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('rss-feed-url-editor')),
      _feedUrl,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('页面测试源'), findsOneWidget);
    expect(find.byKey(ValueKey('rss-feed-tile-$_feedUrl')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法 URL 添加被拒绝，列表保持空', (tester) async {
    await _pumpRssPage(tester);

    await tester.tap(find.byKey(const ValueKey('rss-add-feed-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rss-feed-url-editor')),
      'not a url',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('还没有订阅源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文章列表→阅读页展示正文段落', (tester) async {
    await _pumpRssPage(tester);
    await _subscribeFirstFeed(tester);

    await tester.tap(find.text('页面测试源'));
    await tester.pumpAndSettle();
    expect(find.text('测试文章一'), findsOneWidget);
    expect(find.text('作者甲'), findsOneWidget);

    await tester.tap(find.text('测试文章一'));
    await tester.pumpAndSettle();
    expect(find.text('正文第一段。'), findsOneWidget);
    expect(find.text('正文第二段。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移除订阅后返回空状态', (tester) async {
    await _pumpRssPage(tester);
    await _subscribeFirstFeed(tester);

    await tester.tap(find.byTooltip('取消订阅'));
    await tester.pumpAndSettle();
    expect(find.text('还没有订阅源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _subscribeFirstFeed(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('rss-add-feed-button')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('rss-feed-url-editor')),
    _feedUrl,
  );
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
}