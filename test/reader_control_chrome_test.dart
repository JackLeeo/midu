import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midu/core/reader/reader_leaf_status.dart';
import 'package:midu/utils/reader_themes.dart';
import 'package:midu/widgets/reader_control_chrome.dart';

void main() {
  testWidgets('reader chrome control bar uses solid color background', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());

    // 控制栏为通栏实色背景（玻璃质感已移除）：无 BackdropFilter，
    // 面板颜色不透明且与主题 controlBar 一致。
    expect(find.byType(BackdropFilter), findsNothing);
    expect(_panelColor(tester), ReaderThemes.day.controlBar);
    expect(_panelColor(tester).a, 1);
  });

  testWidgets('reader-owned top information shows time title and battery', (
    tester,
  ) async {
    final status = ReaderLeafStatusData(
      time: DateTime(2026, 7, 18, 9, 5),
      battery: const ReaderBatteryStatus(level: 73, charging: false),
      revision: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Scaffold(
            body: ReaderChromeOverlay(
              palette: ReaderThemes.day,
              visible: false,
              title: 'Chapter 4',
              statusBottom: 8,
              statusBuilder: (context, style, key) =>
                  Text('4 / 12', key: key, style: style),
              onBack: () {},
              onBookmark: () {},
              onTableOfContents: () {},
              onSettings: () {},
              backTooltip: 'Back',
              bookmarkTooltip: 'Bookmark',
              tableOfContentsTooltip: 'Contents',
              settingsTooltip: 'Settings',
              bookmarked: false,
              showViewportStatus: false,
              showViewportTitle: true,
              viewportTitleTop: 24,
              viewportTitleKey: const ValueKey('reader-top-information'),
              readerStatus: status,
            ),
          ),
        ),
      ),
    );

    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('Chapter 4'), findsNWidgets(2));
    expect(find.text('73%'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('reader-top-information')),
          )
          .opacity,
      1,
    );
  });

  testWidgets('reader chrome preserves the selected reading theme color', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(palette: ReaderThemes.green),
    );
    expect(_panelColor(tester), ReaderThemes.green.controlBar);

    await tester.pumpWidget(
      _testApp(palette: ReaderThemes.rose),
    );
    expect(_panelColor(tester), ReaderThemes.rose.controlBar);
  });

  testWidgets('bottom control bar only shows reader actions', (tester) async {
    const bottomKey = ValueKey('reader-bottom-controls');
    const statusKey = ValueKey('reader-status');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderChromeOverlay(
            palette: ReaderThemes.day,
            visible: true,
            title: 'Chapter 4',
            statusBottom: 8,
            statusBuilder: (context, style, key) =>
                Text('4 / 12', key: key, style: style),
            onBack: () {},
            onBookmark: () {},
            onTableOfContents: () {},
            onReadAloud: () {},
            onSettings: () {},
            backTooltip: 'Back',
            bookmarkTooltip: 'Bookmark',
            tableOfContentsTooltip: 'Contents',
            readAloudTooltip: 'Read aloud',
            settingsTooltip: 'Settings',
            bookmarked: false,
            bottomKey: bottomKey,
            statusKey: statusKey,
            showViewportStatus: false,
          ),
        ),
      ),
    );

    final bottomControls = find.byKey(bottomKey);
    expect(
      find.descendant(of: bottomControls, matching: find.text('4 / 12')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: bottomControls,
        matching: find.byIcon(Icons.format_list_bulleted_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bottomControls,
        matching: find.byIcon(Icons.headphones_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bottomControls,
        matching: find.byIcon(Icons.tune_rounded),
      ),
      findsOneWidget,
    );
    expect(find.byKey(statusKey), findsOneWidget);
  });

  testWidgets('idle book percent shows while controls hidden, fades on show', (
    tester,
  ) async {
    Widget buildChrome({required bool visible}) {
      return MaterialApp(
        home: Scaffold(
          body: ReaderChromeOverlay(
            palette: ReaderThemes.day,
            visible: visible,
            title: 'Chapter 4',
            statusBottom: 8,
            statusBuilder: (context, style, key) =>
                Text('4 / 12', key: key, style: style),
            onBack: () {},
            onBookmark: () {},
            onTableOfContents: () {},
            onSettings: () {},
            backTooltip: 'Back',
            bookmarkTooltip: 'Bookmark',
            tableOfContentsTooltip: 'Contents',
            settingsTooltip: 'Settings',
            bookmarked: false,
            showViewportStatus: false,
            bookProgress: 0.1234,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildChrome(visible: false));
    await tester.pumpAndSettle();

    // 控制栏收起时右下角常驻整本百分比：页面上 '12%' 有两处（滑出的控制栏内
    // 章节行也有），但仅右下角常驻百分比被 AnimatedOpacity 包裹。
    final idlePercent = find
        .ancestor(of: find.text('12%'), matching: find.byType(AnimatedOpacity))
        .first;
    expect(tester.widget<AnimatedOpacity>(idlePercent).opacity, 1);

    await tester.pumpWidget(buildChrome(visible: true));
    await tester.pumpAndSettle();

    // 唤起控制栏后随设置一起淡出。
    expect(tester.widget<AnimatedOpacity>(idlePercent).opacity, 0);
  });
}

Widget _testApp({
  ReaderThemePalette palette = ReaderThemes.day,
}) {
  return MaterialApp(
    theme: palette.toThemeData(),
    home: Scaffold(
      body: Center(
        child: ReaderControlBar(
          palette: palette,
          isTopBar: true,
          child: SizedBox(
            width: 240,
            height: 58,
            child: ReaderControlIconButton(
              palette: palette,
              onPressed: null,
              tooltip: 'Bookmark',
              icon: Icons.bookmark_border_rounded,
            ),
          ),
        ),
      ),
    ),
  );
}

Color _panelColor(WidgetTester tester) {
  // 控制栏的 DecoratedBox 带 top/bottom 分割线（border），据此从页面中识别。
  final decoration = tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .map((widget) => widget.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((decoration) => decoration.border != null);
  return decoration.color!;
}
