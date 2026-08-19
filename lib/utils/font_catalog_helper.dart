// 米读：字体目录辅助（A 端 iOS 优先，不需要读取三方字体文件目录）
// 保留文件以兼容原项目导入点；未来可扩展自定义字体导入。
import 'package:flutter/material.dart';

class FontCatalogHelper {
  FontCatalogHelper._();

  /// iOS 系统自带字体白名单（A 端可用）
  static const List<String> iosBuiltinCJKFonts = [
    'PingFang SC',
    'Hiragino Sans GB',
    'Heiti SC',
    'Songti SC',
    'STHeiti',
    'STSong',
    'Kaiti SC',
    'Yuanti SC',
  ];

  /// 获取一个 TextTheme 子集，用于阅读器字体选择预览。
  /// 注：这里只枚举 iOS 自带字体，保证巨魔/自签安装也可直接使用。
  static Map<String, TextStyle> previewPresets() {
    final base = const TextStyle(
      fontSize: 16,
      height: 1.6,
      color: Color(0xFF26110B),
    );
    return {
      for (final f in iosBuiltinCJKFonts) f: base.copyWith(fontFamily: f),
    };
  }
}

// ============================================================
//  字体目录存根（兼容原 open-reading API 表面）
//  米读当前仅使用系统字体；在线/自定义字体留作未来扩展。
// ============================================================

/// 字体作用域：App 全局 vs 阅读器。
enum FontDomain { app, reader }

/// 字体风格分类（用于 UI 分组与预览）。
enum FontTone { sansSerif, serif, monospace }

/// 字体选项：描述一个可选字体的完整元信息。
class FontOption {
  final String id;
  final String? family;
  final List<String> fallbackFamilies;
  final FontTone tone;
  final String displayName;
  final String? sourceFileName;
  final int? fileSize;
  final bool isCustom;
  final bool isAvailable;
  final bool isOnline;
  final int onlineTotalBytes;
  final List<String> downloadFiles;

  const FontOption({
    required this.id,
    this.family,
    this.fallbackFamilies = const <String>[],
    this.tone = FontTone.sansSerif,
    required this.displayName,
    this.sourceFileName,
    this.fileSize,
    this.isCustom = false,
    this.isAvailable = true,
    this.isOnline = false,
    this.onlineTotalBytes = 0,
    this.downloadFiles = const <String>[],
  });
}

/// 字体目录：管理 App / 阅读器可选字体列表与查找。
/// 当前为最小存根——仅提供系统默认字体，在线/自定义字体返回空列表。
class FontCatalog {
  FontCatalog._();

  static const FontOption defaultAppFont = FontOption(
    id: 'system',
    displayName: 'System',
  );

  static const FontOption defaultReaderFont = FontOption(
    id: 'system_reader',
    displayName: 'System',
  );

  /// iOS 系统自带可用的 CJK 字体选项，作为 App / 阅读器可选字体。
  /// 通过 `fontFamily` 直接引用系统字体族，无需打包字体文件，自签/巨魔安装也可用。
  static const List<FontOption> appFonts = <FontOption>[
    FontOption(
      id: 'ios_pingfang',
      family: 'PingFang SC',
      tone: FontTone.sansSerif,
      displayName: '苹方 PingFang',
    ),
    FontOption(
      id: 'ios_songti',
      family: 'Songti SC',
      tone: FontTone.serif,
      displayName: '宋体 Songti',
    ),
    FontOption(
      id: 'ios_kaiti',
      family: 'Kaiti SC',
      tone: FontTone.serif,
      displayName: '楷体 Kaiti',
    ),
    FontOption(
      id: 'ios_heiti',
      family: 'Heiti SC',
      tone: FontTone.sansSerif,
      displayName: '黑体 Heiti',
    ),
    FontOption(
      id: 'ios_yuanti',
      family: 'Yuanti SC',
      tone: FontTone.sansSerif,
      displayName: '圆体 Yuanti',
    ),
    FontOption(
      id: 'ios_hiragino',
      family: 'Hiragino Sans GB',
      tone: FontTone.sansSerif,
      displayName: '冬青黑 Hiragino',
    ),
    FontOption(
      id: 'ios_stsong',
      family: 'STSong',
      tone: FontTone.serif,
      displayName: '华文宋体 STSong',
    ),
  ];
  static const List<FontOption> readerFonts = appFonts;

  /// Instrument Sans 字体 ID。
  static const String instrumentSansId = 'instrument_sans';

  /// Newsreader 字体 ID。
  static const String newsreaderId = 'newsreader';

  /// 系统字体 ID。
  static const String systemId = 'system';

  /// App 回退字体 family 列表（存根：空列表，保留 API 兼容）。
  static List<String> appFallbacks([String? family]) => const <String>[];

  static FontOption appFontForId(String id, {List<FontOption>? customFonts}) {
    for (final f in <FontOption>[...appFonts, ...?customFonts]) {
      if (f.id == id) return f;
    }
    return defaultAppFont;
  }

  static FontOption readerFontForId(
    String? id, {
    List<FontOption>? customFonts,
  }) {
    if (id != null) {
      for (final f in <FontOption>[...readerFonts, ...?customFonts]) {
        if (f.id == id) return f;
      }
    }
    return defaultReaderFont;
  }

  static FontOption appFontForFamily(String family) {
    for (final f in appFonts) {
      if (f.family == family) return f;
    }
    return defaultAppFont;
  }

  static String labelFor(Object l10n, FontOption option) => option.displayName;

  static String descriptionFor(Object l10n, FontOption option) =>
      option.displayName;
}
