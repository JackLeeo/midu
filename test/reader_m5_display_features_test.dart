import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/core/reader/reader_layout.dart';
import 'package:midu/core/reader/reader_punctuation_compressor.dart';
import 'package:midu/core/reader/reader_settings.dart';
import 'package:midu/utils/reader_themes.dart';
import 'package:midu/widgets/reader_settings_controls.dart';

void main() {
  group('标点压缩', () {
    test('把行首闭式标点并入上一行行尾', () {
      final text = '第一行正文\n。第二行从闭式标点开始';
      expect(applyPunctuationCompression(text), '第一行正文。\n第二行从闭式标点开始');
    });

    test('把行尾开式标点挪到下一行行首', () {
      final text = '上一行以开引号结尾（\n下一行正文';
      expect(applyPunctuationCompression(text), '上一行以开引号结尾\n（下一行正文');
    });

    test('空行两侧不合并，保护段落结构', () {
      final text = '段落一\n\n。段落二开头';
      expect(applyPunctuationCompression(text), text);
    });

    test('无错误断行时文本原样返回', () {
      final text = '正常文本\n没有异常标点\n一切照旧';
      expect(applyPunctuationCompression(text), text);
    });

    test('压缩后换行总数不增加且无内容丢失', () {
      final text = '甲行\n。乙行\n（丙行\n丁行';
      final result = applyPunctuationCompression(text);
      expect(result.split('\n').length, text.split('\n').length);
      final contentOf = (String s) =>
          s.replaceAll(RegExp(r'\n|。|（'), '');
      expect(contentOf(result), contentOf(text));
      expect(result, contains('。'));
      expect(result, contains('（'));
    });
  });

  group('段评 think', () {
    test('从 Legado 数组字段解析 think 列表', () {
      final thinks = [
        for (final item in [
          {'content': '这本书真好看', 'user': '读者甲', 'likes': '12'},
          {'title': '管理员', 'content': '注意版权'},
          'not-a-map',
          null,
        ])
          BookSourceChapterThink.fromJson(item),
      ];
      expect(thinks, hasLength(4));
      expect(thinks[0].content, '这本书真好看');
      expect(thinks[0].user, '读者甲');
      expect(thinks[0].likes, '12');
      expect(thinks[1].title, '管理员');
      expect(thinks[2].content, isEmpty);
    });

    test('空 content 的 think 不生成物化块', () {
      const think = BookSourceChapterThink(user: '路人');
      expect(think.displayBlock, isEmpty);
    });

    test('物化块带「段评」标记与用户署名', () {
      const think = BookSourceChapterThink(content: '悬念拉满', user: '读者乙');
      expect(think.displayBlock, '\n【段评】悬念拉满 — 读者乙');
    });

    test('attachChapterThink 把评论挂到对应段落之后', () {
      const content = '第一段\n第二段\n第三段';
      final thinks = [
        const BookSourceChapterThink(content: '评一', user: '甲'),
        const BookSourceChapterThink(content: '评二', user: '乙'),
      ];
      final result = attachChapterThink(content, thinks);
      expect(result, '第一段\n【段评】评一 — 甲\n第二段\n【段评】评二 — 乙\n第三段');
    });

    test('attachChapterThink 段落不足时余评拼到文末', () {
      const content = '只有一段';
      final thinks = [
        const BookSourceChapterThink(content: '评一'),
        const BookSourceChapterThink(content: '评二'),
      ];
      final result = attachChapterThink(content, thinks);
      expect(result, '只有一段\n【段评】评一\n【段评】评二');
    });

    test('无 think 或空正文时原样返回', () {
      const content = '正文\n第二行';
      expect(attachChapterThink(content, const []), content);
      expect(attachChapterThink('', [
        const BookSourceChapterThink(content: '评'),
      ]), '');
    });

    test('chapter content 序列化往返保留 thinkList', () {
      final content = BookSourceChapterContent(
        bookId: 'b',
        chapterId: 'c',
        title: '章名',
        content: '正文',
        contentType: 'text/html',
        thinkList: const [
          BookSourceChapterThink(content: '评论', user: '用户'),
        ],
      );
      final restored = BookSourceChapterContent.fromJson(content.toJson());
      expect(restored.thinkList, hasLength(1));
      expect(restored.thinkList.first.content, '评论');
      expect(restored.thinkList.first.user, '用户');
    });
  });

  group('M5 显示设置持久化', () {
    test('标点压缩/沉浸/护眼/暖光字段保存后重新载入', () async {
      SharedPreferences.setMockInitialValues({});
      const store = ReaderSettingsStore();
      const settings = ReaderSettings(
        fontSize: 19,
        lineHeight: 1.75,
        horizontalMargin: 18,
        topMargin: 4,
        bottomMargin: 0,
        themeId: 'parchment',
        pageMode: ReaderPageMode.horizontalSlide,
        punctuationCompression: true,
        immersiveMode: true,
        eyeCareBrightness: 0.5,
        warmth: 0.3,
      );

      await store.save(settings);
      final loaded = await store.load();

      expect(loaded.punctuationCompression, isTrue);
      expect(loaded.immersiveMode, isTrue);
      expect(loaded.eyeCareBrightness, 0.5);
      expect(loaded.warmth, 0.3);
    });

    test('copyWith 对越界的护眼/暖光值做钳制', () {
      const base = ReaderSettings(
        fontSize: 19,
        lineHeight: 1.75,
        horizontalMargin: 18,
        topMargin: 4,
        bottomMargin: 0,
        themeId: 'parchment',
        pageMode: ReaderPageMode.horizontalSlide,
      );
      final next = base.copyWith(eyeCareBrightness: 2, warmth: -1);
      expect(next.eyeCareBrightness, 1.0);
      expect(next.warmth, 0.0);
    });
  });

  group('阅读设置「显示」tab', () {
    testWidgets('渲染标点压缩与沉浸开关并回调', (tester) async {
      bool? punctuationChanged;
      bool? immersiveChanged;

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderSettingsSheet(
            title: '设置',
            tabThemeLabel: '主题',
            tabTextLabel: '文字',
            tabLayoutLabel: '版式',
            tabPagingLabel: '翻页',
            tabDisplayLabel: '显示',
            advancedTypographyTitle: '高级排版',
            themeDescription: '仅改变阅读页面',
            pageModeTitle: '翻页方式',
            pageModeSummary: '横滑',
            topBarStyleTitle: '顶部信息栏',
            topBarStyleSummary: '阅读信息栏',
            pullBookmarkTitle: '下拉书签',
            pullBookmarkHint: '顶部下拉',
            tapPageAnimationTitle: '点击动画',
            tapPageAnimationHint: '左右点击动画',
            tapZonesTitle: '点击区域',
            tapZonesHint: '九宫格自定义',
            showTabletTwoPageToggle: false,
            tabletTwoPageTitle: '平板双页',
            tabletTwoPageHint: '横屏双页',
            fontSizeLabel: '字号',
            lineHeightLabel: '行距',
            letterSpacingLabel: '字距',
            textAlignmentLabel: '对齐',
            textAlignmentNaturalLabel: '自然',
            textAlignmentJustifiedLabel: '两端',
            firstLineIndentLabel: '首行缩进',
            paragraphSpacingLabel: '段距',
            horizontalMarginLabel: '左右边距',
            topMarginLabel: '上边距',
            bottomMarginLabel: '下边距',
            themeId: ReaderThemes.day.id,
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
            punctuationCompressionTitle: '标点压缩',
            punctuationCompressionHint: '压缩错误断行标点',
            immersiveModeTitle: '沉浸模式',
            immersiveModeHint: '隐藏系统栏',
            eyeCareTitle: '护眼亮度',
            eyeCareOnLabel: '开',
            eyeCareOffLabel: '关',
            warmthTitle: '暖光',
            onPunctuationCompressionChanged: (v) => punctuationChanged = v,
            onImmersiveModeChanged: (v) => immersiveChanged = v,
            onEyeCareBrightnessChanged: (_) {},
            onWarmthChanged: (_) {},
          ),
        ),
      );

      // 切到「显示」tab。
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      expect(find.text('标点压缩'), findsOneWidget);
      expect(find.text('沉浸模式'), findsOneWidget);
      expect(find.text('护眼亮度'), findsOneWidget);
      expect(find.text('暖光'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader-punctuation-compression-switch')),
      );
      await tester.pump();
      expect(punctuationChanged, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('reader-immersive-mode-switch')),
      );
      await tester.pump();
      expect(immersiveChanged, isTrue);
    });
  });
}