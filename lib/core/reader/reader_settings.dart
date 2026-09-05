import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chinese_converter.dart';
import 'reader_layout.dart';
import 'reader_margin_settings.dart';
import 'reader_tap_zones.dart';

enum ReaderTextAlignment { natural, justified }

@immutable
class ReaderSettings {
  static const double defaultFontSize = 19;
  static const double defaultLineHeight = 1.75;
  static const double minLetterSpacing = 0;
  static const double maxLetterSpacing = 1.2;
  static const double defaultLetterSpacing = 0;
  static const ReaderTextAlignment defaultTextAlignment =
      ReaderTextAlignment.natural;
  static const double defaultHorizontalMargin = 18;
  static const int defaultFirstLineIndent = 2;
  static const int defaultParagraphSpacing = 0;
  static const String defaultThemeId = 'parchment';
  static const ReaderPageMode defaultPageMode = ReaderPageMode.horizontalSlide;
  static const bool defaultTabletTwoPageEnabled = true;

  /// 默认自动阅读翻页间隔（秒），对标 Legado `ReadBookConfig.autoReadSpeed`。
  static const int defaultAutoReadSeconds = 15;
  static const int minAutoReadSeconds = 1;
  static const int maxAutoReadSeconds = 60;

  const ReaderSettings({
    required this.fontSize,
    required this.lineHeight,
    this.letterSpacing = defaultLetterSpacing,
    this.textAlignment = defaultTextAlignment,
    required this.horizontalMargin,
    required this.topMargin,
    required this.bottomMargin,
    required this.themeId,
    required this.pageMode,
    this.firstLineIndent = defaultFirstLineIndent,
    this.paragraphSpacing = defaultParagraphSpacing,
    this.pullBookmarkEnabled = false,
    this.tapPageAnimationEnabled = true,
    this.tabletTwoPageEnabled = defaultTabletTwoPageEnabled,
    this.punctuationCompression = false,
    this.immersiveMode = false,
    this.eyeCareBrightness = 0,
    this.warmth = 0,
    this.chineseConversion = ChineseConversionMode.off,
    this.textBold = false,
    this.autoReadSeconds = defaultAutoReadSeconds,
  });

  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final ReaderTextAlignment textAlignment;
  final double horizontalMargin;
  final double topMargin;
  final double bottomMargin;
  final String themeId;
  final ReaderPageMode pageMode;
  final int firstLineIndent;
  final int paragraphSpacing;
  final bool pullBookmarkEnabled;
  final bool tapPageAnimationEnabled;
  final bool tabletTwoPageEnabled;

  /// 标点压缩：行首不出现闭式标点、行尾不悬挂开式标点（对标 Legado）。
  final bool punctuationCompression;

  /// 沉浸模式：阅读时隐藏系统状态栏/导航栏（移动端生效，Web 条件禁用）。
  final bool immersiveMode;

  /// 护眼亮度（0..1）：以半透明遮罩降低整体亮度，0 表示关闭。
  final double eyeCareBrightness;

  /// 暖光（0..1）：琥珀色调叠加，0 表示关闭。
  final double warmth;

  /// 正文简繁转换（对标 Legado 中文转换）：off/简体→繁体/繁体→简体。
  final ChineseConversionMode chineseConversion;

  /// 字体加粗（对标 Legado 字体加粗开关）。
  final bool textBold;

  /// 自动阅读翻页间隔（秒），对标 Legado `ReadBookConfig.autoReadSpeed`。
  /// 仅在用户开启自动阅读时生效。
  final int autoReadSeconds;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    ReaderTextAlignment? textAlignment,
    double? horizontalMargin,
    double? topMargin,
    double? bottomMargin,
    String? themeId,
    ReaderPageMode? pageMode,
    int? firstLineIndent,
    int? paragraphSpacing,
    bool? pullBookmarkEnabled,
    bool? tapPageAnimationEnabled,
    bool? tabletTwoPageEnabled,
    bool? punctuationCompression,
    bool? immersiveMode,
    double? eyeCareBrightness,
    double? warmth,
    ChineseConversionMode? chineseConversion,
    bool? textBold,
    int? autoReadSeconds,
  }) {
    return ReaderSettings(
      fontSize: (fontSize ?? this.fontSize).clamp(14, 32),
      lineHeight: (lineHeight ?? this.lineHeight).clamp(1.4, 2.1),
      letterSpacing: (letterSpacing ?? this.letterSpacing).clamp(
        minLetterSpacing,
        maxLetterSpacing,
      ),
      textAlignment: textAlignment ?? this.textAlignment,
      horizontalMargin: (horizontalMargin ?? this.horizontalMargin).clamp(
        ReaderMarginSettings.horizontalMin,
        ReaderMarginSettings.horizontalMax,
      ),
      topMargin: (topMargin ?? this.topMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      ),
      bottomMargin: (bottomMargin ?? this.bottomMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      ),
      themeId: themeId ?? this.themeId,
      pageMode: pageMode ?? this.pageMode,
      firstLineIndent: (firstLineIndent ?? this.firstLineIndent).clamp(0, 4),
      paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing).clamp(0, 2),
      pullBookmarkEnabled: pullBookmarkEnabled ?? this.pullBookmarkEnabled,
      tapPageAnimationEnabled:
          tapPageAnimationEnabled ?? this.tapPageAnimationEnabled,
      tabletTwoPageEnabled: tabletTwoPageEnabled ?? this.tabletTwoPageEnabled,
      punctuationCompression:
          punctuationCompression ?? this.punctuationCompression,
      immersiveMode: immersiveMode ?? this.immersiveMode,
      eyeCareBrightness: (eyeCareBrightness ?? this.eyeCareBrightness).clamp(
        0.0,
        1.0,
      ),
      warmth: (warmth ?? this.warmth).clamp(0.0, 1.0),
      chineseConversion: chineseConversion ?? this.chineseConversion,
      textBold: textBold ?? this.textBold,
      autoReadSeconds: (autoReadSeconds ?? this.autoReadSeconds).clamp(
        minAutoReadSeconds,
        maxAutoReadSeconds,
      ),
    );
  }
}

class ReaderSettingsStore {
  static const fontSizeKey = 'native_reader_font_size';
  static const lineHeightKey = 'native_reader_line_height';
  static const letterSpacingKey = 'native_reader_letter_spacing';
  static const textAlignmentKey = 'native_reader_text_alignment';
  static const horizontalMarginKey = 'native_reader_horizontal_margin';
  static const topMarginKey = 'native_reader_top_margin';
  static const bottomMarginKey = 'native_reader_bottom_margin';
  static const legacyVerticalMarginKey = 'native_reader_vertical_margin';
  static const themeKey = 'native_reader_theme';
  static const pageModeKey = 'native_reader_page_mode';
  static const firstLineIndentKey = 'native_reader_first_line_indent';
  static const paragraphSpacingKey = 'native_reader_paragraph_spacing';
  static const _legacyPageTurnStyleKey = 'native_reader_page_turn_style';
  static const pullBookmarkKey = 'reader_pull_bookmark_enabled';
  static const tapPageAnimationKey = 'reader_tap_page_animation_enabled';
  static const tabletTwoPageKey = 'reader_tablet_two_page_enabled';
  static const scrollByChapterKey = 'native_reader_scroll_by_chapter';
  static const txtChapterTitlePageKey =
      'native_reader_txt_chapter_title_page_enabled';
  static const tapZonesKey = 'reader_tap_zones_v1';
  static const legacyBookSourceLineHeightKey = 'book_source_reader_line_height';
  static const punctuationCompressionKey = 'native_reader_punctuation_compression';
  static const immersiveModeKey = 'native_reader_immersive_mode';
  static const eyeCareBrightnessKey = 'native_reader_eye_care_brightness';
  static const warmthKey = 'native_reader_warmth';
  static const chineseConversionKey = 'native_reader_chinese_conversion';
  static const textBoldKey = 'native_reader_text_bold';
  static const autoReadSecondsKey = 'reader_auto_read_seconds';

  const ReaderSettingsStore();

  Future<String> loadThemeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(themeKey) ?? ReaderSettings.defaultThemeId;
  }

  Future<ReaderSettings> load({
    ReaderPageMode fallbackPageMode = ReaderSettings.defaultPageMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final storedTopMargin = prefs.getDouble(topMarginKey);
    final storedBottomMargin = prefs.getDouble(bottomMarginKey);
    final margins = ReaderMarginSettings.fromStored(
      top: storedTopMargin,
      bottom: storedBottomMargin,
      legacyVertical: prefs.getDouble(legacyVerticalMarginKey),
    );
    if (storedTopMargin == null || storedBottomMargin == null) {
      await Future.wait([
        prefs.setDouble(topMarginKey, margins.top),
        prefs.setDouble(bottomMarginKey, margins.bottom),
      ]);
    }
    if (prefs.containsKey(_legacyPageTurnStyleKey)) {
      await prefs.remove(_legacyPageTurnStyleKey);
    }

    return ReaderSettings(
      fontSize: (prefs.getDouble(fontSizeKey) ?? ReaderSettings.defaultFontSize)
          .clamp(14, 32),
      lineHeight:
          (prefs.getDouble(lineHeightKey) ??
                  prefs.getDouble(legacyBookSourceLineHeightKey) ??
                  ReaderSettings.defaultLineHeight)
              .clamp(1.4, 2.1),
      letterSpacing:
          (prefs.getDouble(letterSpacingKey) ??
                  ReaderSettings.defaultLetterSpacing)
              .clamp(
                ReaderSettings.minLetterSpacing,
                ReaderSettings.maxLetterSpacing,
              ),
      textAlignment: ReaderTextAlignment.values.firstWhere(
        (alignment) => alignment.name == prefs.getString(textAlignmentKey),
        orElse: () => ReaderSettings.defaultTextAlignment,
      ),
      horizontalMargin:
          (prefs.getDouble(horizontalMarginKey) ??
                  ReaderSettings.defaultHorizontalMargin)
              .clamp(
                ReaderMarginSettings.horizontalMin,
                ReaderMarginSettings.horizontalMax,
              ),
      topMargin: margins.top,
      bottomMargin: margins.bottom,
      themeId: prefs.getString(themeKey) ?? ReaderSettings.defaultThemeId,
      pageMode: readerPageModeFromName(
        prefs.getString(pageModeKey),
        fallback: fallbackPageMode,
      ),
      firstLineIndent:
          (prefs.getInt(firstLineIndentKey) ??
                  ReaderSettings.defaultFirstLineIndent)
              .clamp(0, 4),
      paragraphSpacing:
          (prefs.getInt(paragraphSpacingKey) ??
                  ReaderSettings.defaultParagraphSpacing)
              .clamp(0, 2),
      pullBookmarkEnabled: prefs.getBool(pullBookmarkKey) ?? false,
      tapPageAnimationEnabled: prefs.getBool(tapPageAnimationKey) ?? true,
      tabletTwoPageEnabled:
          prefs.getBool(tabletTwoPageKey) ??
          ReaderSettings.defaultTabletTwoPageEnabled,
      punctuationCompression:
          prefs.getBool(punctuationCompressionKey) ?? false,
      immersiveMode: prefs.getBool(immersiveModeKey) ?? false,
      eyeCareBrightness:
          (prefs.getDouble(eyeCareBrightnessKey) ?? 0).clamp(0.0, 1.0),
      warmth: (prefs.getDouble(warmthKey) ?? 0).clamp(0.0, 1.0),
      chineseConversion: ChineseConversionMode.fromName(
        prefs.getString(chineseConversionKey),
      ),
      textBold: prefs.getBool(textBoldKey) ?? false,
      autoReadSeconds:
          (prefs.getInt(autoReadSecondsKey) ??
                  ReaderSettings.defaultAutoReadSeconds)
              .clamp(
                ReaderSettings.minAutoReadSeconds,
                ReaderSettings.maxAutoReadSeconds,
              ),
    );
  }

  Future<void> save(ReaderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble(fontSizeKey, settings.fontSize),
      prefs.setDouble(lineHeightKey, settings.lineHeight),
      prefs.setDouble(letterSpacingKey, settings.letterSpacing),
      prefs.setString(textAlignmentKey, settings.textAlignment.name),
      prefs.setDouble(horizontalMarginKey, settings.horizontalMargin),
      prefs.setDouble(topMarginKey, settings.topMargin),
      prefs.setDouble(bottomMarginKey, settings.bottomMargin),
      prefs.setString(themeKey, settings.themeId),
      prefs.setString(pageModeKey, settings.pageMode.name),
      prefs.setInt(firstLineIndentKey, settings.firstLineIndent),
      prefs.setInt(paragraphSpacingKey, settings.paragraphSpacing),
      prefs.setBool(pullBookmarkKey, settings.pullBookmarkEnabled),
      prefs.setBool(tapPageAnimationKey, settings.tapPageAnimationEnabled),
      prefs.setBool(tabletTwoPageKey, settings.tabletTwoPageEnabled),
      prefs.setBool(
        punctuationCompressionKey,
        settings.punctuationCompression,
      ),
      prefs.setBool(immersiveModeKey, settings.immersiveMode),
      prefs.setDouble(eyeCareBrightnessKey, settings.eyeCareBrightness),
      prefs.setDouble(warmthKey, settings.warmth),
      prefs.setString(chineseConversionKey, settings.chineseConversion.name),
      prefs.setBool(textBoldKey, settings.textBold),
      prefs.setInt(autoReadSecondsKey, settings.autoReadSeconds),
    ]);
  }

  Future<bool> loadScrollByChapter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(scrollByChapterKey) ?? true;
  }

  Future<void> saveScrollByChapter(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(scrollByChapterKey, value);
  }

  Future<bool> loadTxtChapterTitlePageEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(txtChapterTitlePageKey) ?? true;
  }

  Future<void> saveTxtChapterTitlePageEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(txtChapterTitlePageKey, value);
  }

  Future<ReaderTapZones> loadTapZones() async {
    final prefs = await SharedPreferences.getInstance();
    return ReaderTapZones.decode(prefs.getString(tapZonesKey));
  }

  Future<void> saveTapZones(ReaderTapZones zones) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tapZonesKey, zones.encode());
  }
}
