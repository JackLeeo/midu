import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/core/reader/chinese_converter.dart';
import 'package:midu/core/reader/reader_custom_theme.dart';
import 'package:midu/core/reader/reader_layout.dart';
import 'package:midu/core/reader/reader_settings.dart';
import 'package:midu/utils/reader_themes.dart';
import 'package:midu/widgets/reader_settings_controls.dart';

void main() {
  // ===== 1. 简繁转换引擎 =====
  group('ChineseConverter', () {
    test('off mode returns original text unchanged', () {
      const text = '这是一个简体中文测试';
      expect(ChineseConverter.convert(text, ChineseConversionMode.off), text);
    });

    test('s2t converts common simplified characters', () {
      final result = ChineseConverter.convert(
        '计算机网络技术',
        ChineseConversionMode.simplifiedToTraditional,
      );
      expect(result, '計算機網絡技術');
    });

    test('t2s converts common traditional characters', () {
      final result = ChineseConverter.convert(
        '計算機網絡技術',
        ChineseConversionMode.traditionalToSimplified,
      );
      expect(result, '计算机网络技术');
    });

    test('phrase disambiguation: 头发 → 頭髮', () {
      final result = ChineseConverter.convert(
        '她的头发很漂亮',
        ChineseConversionMode.simplifiedToTraditional,
      );
      expect(result, '她的頭髮很漂亮');
    });

    test('phrase disambiguation: 干部 → 幹部', () {
      final result = ChineseConverter.convert(
        '他是干部',
        ChineseConversionMode.simplifiedToTraditional,
      );
      expect(result.contains('幹部'), isTrue);
    });

    test('phrase disambiguation: 皇后 → 皇后 (not 後)', () {
      final result = ChineseConverter.convert(
        '皇后娘娘',
        ChineseConversionMode.simplifiedToTraditional,
      );
      // 皇后的「后」在古文中不应转为「後」
      expect(result.contains('皇后'), isTrue);
    });

    test('conversion is length-preserving', () {
      const texts = [
        '你好世界',
        '计算机网络技术',
        '她的头发很漂亮',
        '这是一个简体中文测试文本',
        '双循环在考试中至关重要',
      ];
      for (final text in texts) {
        final s2t = ChineseConverter.convert(
          text,
          ChineseConversionMode.simplifiedToTraditional,
        );
        expect(s2t.length, text.length,
            reason: 'S2T length mismatch: "$text" → "$s2t"');
        final t2s = ChineseConverter.convert(
          s2t,
          ChineseConversionMode.traditionalToSimplified,
        );
        expect(t2s, text,
            reason: 'S2T→T2S roundtrip mismatch: "$text" → "$s2t" → "$t2s"');
      }
    });

    test('non-Chinese characters are preserved', () {
      final result = ChineseConverter.convert(
        'Hello 123! @测试',
        ChineseConversionMode.simplifiedToTraditional,
      );
      expect(result, 'Hello 123! @測試');
    });

    test('empty text returns empty', () {
      expect(ChineseConverter.convert('', ChineseConversionMode.simplifiedToTraditional), '');
    });
  });

  // ===== 2. 设置持久化 =====
  group('ReaderSettings chineseConversion + textBold', () {
    test('default values are off/false', () {
      final settings = const ReaderSettings(
        fontSize: 19,
        lineHeight: 1.75,
        horizontalMargin: 18,
        topMargin: 4,
        bottomMargin: 0,
        themeId: 'day',
        pageMode: ReaderPageMode.horizontalSlide,
      );
      expect(settings.chineseConversion, ChineseConversionMode.off);
      expect(settings.textBold, isFalse);
    });

    test('copyWith sets new values', () {
      final settings = ReaderSettings(
        fontSize: 19,
        lineHeight: 1.75,
        horizontalMargin: 18,
        topMargin: 4,
        bottomMargin: 0,
        themeId: 'day',
        pageMode: ReaderPageMode.horizontalSlide,
      ).copyWith(
        chineseConversion: ChineseConversionMode.simplifiedToTraditional,
        textBold: true,
      );
      expect(
        settings.chineseConversion,
        ChineseConversionMode.simplifiedToTraditional,
      );
      expect(settings.textBold, isTrue);
    });

    test('load/save roundtrip', () async {
      SharedPreferences.setMockInitialValues({});
      final store = const ReaderSettingsStore();
      await store.save(ReaderSettings(
        fontSize: 19,
        lineHeight: 1.75,
        horizontalMargin: 18,
        topMargin: 4,
        bottomMargin: 0,
        themeId: 'day',
        pageMode: ReaderPageMode.horizontalSlide,
        chineseConversion: ChineseConversionMode.traditionalToSimplified,
        textBold: true,
      ));
      final loaded = await store.load();
      expect(loaded.chineseConversion, ChineseConversionMode.traditionalToSimplified);
      expect(loaded.textBold, isTrue);
    });
  });

  // ===== 3. 弹层控件：字体加粗开关 + 简繁转换分段按钮 =====
  group('ReaderSettingsSheet M7 controls', () {
    testWidgets('text bold switch appears and fires callback', (tester) async {
      bool? boldChanged;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderSettingsSheet(
            title: 'Settings',
            tabThemeLabel: 'Theme',
            tabTextLabel: 'Text',
            tabLayoutLabel: 'Layout',
            tabPagingLabel: 'Paging',
            advancedTypographyTitle: 'Advanced',
            themeDescription: 'Theme desc',
            pageModeTitle: 'Page mode',
            pageModeSummary: 'Horizontal',
            topBarStyleTitle: 'Top bar',
            topBarStyleSummary: 'Reader',
            pullBookmarkTitle: 'Pull bookmark',
            pullBookmarkHint: 'Pull hint',
            tapPageAnimationTitle: 'Tap animation',
            tapPageAnimationHint: 'Tap hint',
            tapZonesTitle: 'Tap zones',
            tapZonesHint: 'Zones hint',
            showTabletTwoPageToggle: false,
            tabletTwoPageTitle: 'Two page',
            tabletTwoPageHint: 'Two page hint',
            fontSizeLabel: 'Font size',
            lineHeightLabel: 'Line height',
            letterSpacingLabel: 'Letter spacing',
            textAlignmentLabel: 'Alignment',
            textAlignmentNaturalLabel: 'Natural',
            textAlignmentJustifiedLabel: 'Justified',
            firstLineIndentLabel: 'Indent',
            paragraphSpacingLabel: 'Spacing',
            horizontalMarginLabel: 'H margin',
            topMarginLabel: 'Top margin',
            bottomMarginLabel: 'Bottom margin',
            themeId: 'day',
            fontSize: 19,
            lineHeight: 1.75,
            letterSpacing: 0,
            textAlignment: ReaderTextAlignment.natural,
            firstLineIndent: 2,
            paragraphSpacing: 0,
            horizontalMargin: 18,
            topMargin: 4,
            bottomMargin: 0,
            pullBookmarkEnabled: false,
            tapPageAnimationEnabled: true,
            tabletTwoPageEnabled: true,
            themeLabelFor: (id) => id,
            onThemeChanged: (_) {},
            onCustomThemeTap: () {},
            onPageModeTap: () {},
            onTopBarStyleTap: () {},
            onTapZonesTap: () {},
            onFontSizeChanged: (_) {},
            onLineHeightChanged: (_) {},
            onLetterSpacingChanged: (_) {},
            onTextAlignmentChanged: (_) {},
            onFirstLineIndentChanged: (_) {},
            onParagraphSpacingChanged: (_) {},
            onHorizontalMarginChanged: (_) {},
            onTopMarginChanged: (_) {},
            onBottomMarginChanged: (_) {},
            onPullBookmarkChanged: (_) {},
            onTapPageAnimationChanged: (_) {},
            onTabletTwoPageChanged: (_) {},
            // M7 controls
            textBold: false,
            textBoldTitle: 'Bold text',
            textBoldHint: 'Bold the body',
            onTextBoldChanged: (value) => boldChanged = value,
            chineseConversion: ChineseConversionMode.off,
            chineseConversionTitle: 'Chinese conversion',
            chineseConversionOffLabel: 'Off',
            chineseConversionS2tLabel: 'S→T',
            chineseConversionT2sLabel: 'T→S',
            onChineseConversionChanged: (_) {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 文字 tab 页应有加粗开关
      await tester.tap(find.text('Text'));
      await tester.pump();
      await tester.pump();
      final boldSwitch = find.byKey(const ValueKey('reader-text-bold-switch'));
      expect(boldSwitch, findsOneWidget);
      await tester.ensureVisible(boldSwitch);
      await tester.pump();
      await tester.tap(boldSwitch);
      await tester.pump();
      expect(boldChanged, isTrue);
    });

    testWidgets('chinese conversion segmented button appears and fires callback',
        (tester) async {
      ChineseConversionMode? conversionChanged;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderSettingsSheet(
            title: 'Settings',
            tabThemeLabel: 'Theme',
            tabTextLabel: 'Text',
            tabLayoutLabel: 'Layout',
            tabPagingLabel: 'Paging',
            advancedTypographyTitle: 'Advanced',
            themeDescription: 'Theme desc',
            pageModeTitle: 'Page mode',
            pageModeSummary: 'Horizontal',
            topBarStyleTitle: 'Top bar',
            topBarStyleSummary: 'Reader',
            pullBookmarkTitle: 'Pull bookmark',
            pullBookmarkHint: 'Pull hint',
            tapPageAnimationTitle: 'Tap animation',
            tapPageAnimationHint: 'Tap hint',
            tapZonesTitle: 'Tap zones',
            tapZonesHint: 'Zones hint',
            showTabletTwoPageToggle: false,
            tabletTwoPageTitle: 'Two page',
            tabletTwoPageHint: 'Two page hint',
            fontSizeLabel: 'Font size',
            lineHeightLabel: 'Line height',
            letterSpacingLabel: 'Letter spacing',
            textAlignmentLabel: 'Alignment',
            textAlignmentNaturalLabel: 'Natural',
            textAlignmentJustifiedLabel: 'Justified',
            firstLineIndentLabel: 'Indent',
            paragraphSpacingLabel: 'Spacing',
            horizontalMarginLabel: 'H margin',
            topMarginLabel: 'Top margin',
            bottomMarginLabel: 'Bottom margin',
            themeId: 'day',
            fontSize: 19,
            lineHeight: 1.75,
            letterSpacing: 0,
            textAlignment: ReaderTextAlignment.natural,
            firstLineIndent: 2,
            paragraphSpacing: 0,
            horizontalMargin: 18,
            topMargin: 4,
            bottomMargin: 0,
            pullBookmarkEnabled: false,
            tapPageAnimationEnabled: true,
            tabletTwoPageEnabled: true,
            themeLabelFor: (id) => id,
            onThemeChanged: (_) {},
            onCustomThemeTap: () {},
            onPageModeTap: () {},
            onTopBarStyleTap: () {},
            onTapZonesTap: () {},
            onFontSizeChanged: (_) {},
            onLineHeightChanged: (_) {},
            onLetterSpacingChanged: (_) {},
            onTextAlignmentChanged: (_) {},
            onFirstLineIndentChanged: (_) {},
            onParagraphSpacingChanged: (_) {},
            onHorizontalMarginChanged: (_) {},
            onTopMarginChanged: (_) {},
            onBottomMarginChanged: (_) {},
            onPullBookmarkChanged: (_) {},
            onTapPageAnimationChanged: (_) {},
            onTabletTwoPageChanged: (_) {},
            // M7 controls
            tabDisplayLabel: 'Display',
            chineseConversion: ChineseConversionMode.off,
            chineseConversionTitle: 'Chinese conversion',
            chineseConversionOffLabel: 'Off',
            chineseConversionS2tLabel: 'S→T',
            chineseConversionT2sLabel: 'T→S',
            onChineseConversionChanged: (value) => conversionChanged = value,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 显示 tab 页应有简繁转换分段按钮
      await tester.tap(find.text('Display'));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-chinese-conversion-control')),
        findsOneWidget,
      );

      // 点击「S→T」分段
      await tester.tap(find.text('S→T'));
      await tester.pump();
      expect(conversionChanged, ChineseConversionMode.simplifiedToTraditional);
    });
  });

  // ===== 4. ReaderCustomTheme secondaryText =====
  group('ReaderCustomTheme secondaryText', () {
    test('default secondaryText is null (derived)', () {
      final theme = ReaderCustomTheme(
        background: const Color(0xFFFFFFFF),
        text: const Color(0xFF202124),
        controlBar: const Color(0xFFF7F7F8),
      );
      expect(theme.secondaryText, isNull);
      expect(theme.effectiveSecondaryText, isNotNull);
    });

    test('explicit secondaryText is preserved', () {
      final theme = ReaderCustomTheme(
        background: const Color(0xFFFFFFFF),
        text: const Color(0xFF202124),
        controlBar: const Color(0xFFF7F7F8),
        secondaryText: const Color(0xFF888888),
      );
      expect(theme.secondaryText, const Color(0xFF888888));
      expect(theme.effectiveSecondaryText, const Color(0xFF888888));
    });

    test('toMap/fromMap roundtrip with secondaryText', () {
      final theme = ReaderCustomTheme(
        id: 'custom:test',
        name: 'Test Theme',
        background: const Color(0xFFF6F0E4),
        text: const Color(0xFF342D25),
        controlBar: const Color(0xFFE6D9C5),
        secondaryText: const Color(0xFF999999),
      );
      final map = theme.toMap();
      final restored = ReaderCustomTheme.fromMap(map);
      expect(restored.id, theme.id);
      expect(restored.secondaryText, const Color(0xFF999999));
    });

    test('toMap/fromMap roundtrip without secondaryText', () {
      final theme = ReaderCustomTheme(
        id: 'custom:test2',
        name: 'No Secondary',
        background: const Color(0xFFF6F0E4),
        text: const Color(0xFF342D25),
        controlBar: const Color(0xFFE6D9C5),
      );
      final map = theme.toMap();
      expect(map['secondaryText'], isNull);
      final restored = ReaderCustomTheme.fromMap(map);
      expect(restored.secondaryText, isNull);
    });

    test('ReaderThemes.fromCustomTheme uses explicit secondaryText', () {
      final custom = ReaderCustomTheme(
        background: const Color(0xFF15202B),
        text: const Color(0xFFDDE7F0),
        controlBar: const Color(0xFF223443),
        secondaryText: const Color(0xFFCCDDEE),
      );
      final palette = ReaderThemes.fromCustomTheme(custom);
      expect(palette.secondaryText, const Color(0xFFCCDDEE));
    });
  });

  // ===== 5. ChineseConversionMode fromName =====
  group('ChineseConversionMode fromName', () {
    test('returns off for null/unknown', () {
      expect(ChineseConversionMode.fromName(null), ChineseConversionMode.off);
      expect(ChineseConversionMode.fromName('unknown'), ChineseConversionMode.off);
    });

    test('parses valid names', () {
      expect(
        ChineseConversionMode.fromName('simplifiedToTraditional'),
        ChineseConversionMode.simplifiedToTraditional,
      );
      expect(
        ChineseConversionMode.fromName('traditionalToSimplified'),
        ChineseConversionMode.traditionalToSimplified,
      );
      expect(
        ChineseConversionMode.fromName('off'),
        ChineseConversionMode.off,
      );
    });
  });
}