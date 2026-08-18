// 米读：应用主题入口（兼容原 utils/app_themes.dart 导入点）
// iOS 优先：Material 3 + 紫色种子色 + 玻璃态 + 大字号 / 宽松间距。
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'midu_theme.dart';

class MiduAppTheme {
  MiduAppTheme._();

  // 单例主题缓存，避免每次 build 重建
  static ThemeData? _light;
  static ThemeData? _dark;

  static ThemeData get light => _light ??= _buildLight();
  static ThemeData get dark => _dark ??= _buildDark();

  static ColorScheme _lightScheme() => ColorScheme.fromSeed(
        seedColor: MiduColors.brand,
        brightness: Brightness.light,
        primary: MiduColors.brand,
        onPrimary: Colors.white,
        primaryContainer: MiduColors.brandBg,
        onPrimaryContainer: MiduColors.brandDeep,
        secondary: const Color(0xFFFF8A65),
        surface: MiduColors.surface,
        onSurface: MiduColors.ink900,
        surfaceContainerHighest: MiduColors.surfaceDim,
        outline: MiduColors.line,
      );

  static ColorScheme _darkScheme() => ColorScheme.fromSeed(
        seedColor: MiduColors.brand,
        brightness: Brightness.dark,
        primary: MiduColors.brandSoft,
        onPrimary: const Color(0xFF3A0F02),
        primaryContainer: MiduColors.brandDeep,
        onPrimaryContainer: MiduColors.brandSoft,
        secondary: const Color(0xFFFFAA85),
        surface: const Color(0xFF1A0B06),
        onSurface: const Color(0xFFFBE9E2),
        surfaceContainerHighest: const Color(0xFF2E170E),
        outline: const Color(0xFF5A3020),
      );

  static ThemeData _base({required ColorScheme scheme, required bool dark}) {
    final typography = Typography.material2021(
      platform: TargetPlatform.iOS, // iOS 优先
      colorScheme: scheme,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      typography: typography,
      fontFamily: 'PingFang SC', // iOS 默认中文字体，A 端自签也 OK
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashColor: scheme.primary.withValues(alpha: 0.15),
      highlightColor: scheme.primary.withValues(alpha: 0.08),
      // ---------- AppBar：iOS 大标题风格 + 毛玻璃 ----------
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
        centerTitle: true,
      ),
      // ---------- NavigationBar：底部玻璃态（由页面包 BackdropFilter 实现） ----------
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
              size: 24,
            )),
      ),
      // ---------- Card：玻璃态卡片 ----------
      cardTheme: CardThemeData(
        color: dark ? MiduColors.glassDark : MiduColors.glassLight,
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiduRadius.lg),
          side: BorderSide(
            color: dark ? MiduColors.glassBorderDark : MiduColors.glassBorderLight,
            width: 0.5,
          ),
        ),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
      ),
      // ---------- Buttons ----------
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MiduRadius.pill),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          minimumSize: const Size(0, 40),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MiduRadius.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MiduRadius.pill),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
      ),
      // ---------- Input（iOS 胶囊风） ----------
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.45)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MiduRadius.pill),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MiduRadius.pill),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MiduRadius.pill),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      // ---------- ListTile ----------
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiduRadius.md),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant,
        ),
      ),
      // ---------- Divider ----------
      dividerTheme: DividerThemeData(
        color: scheme.outline.withValues(alpha: 0.35),
        space: 0.5,
        thickness: 0.5,
      ),
      // ---------- Chip ----------
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        labelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiduRadius.pill),
        ),
      ),
      // ---------- Bottom Sheet：毛玻璃 ----------
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(MiduRadius.xl),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      // ---------- Dialog ----------
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xCC150A33) : const Color(0xCCFFFFFF),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiduRadius.xl),
        ),
      ),
      // ---------- SnackBar ----------
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xE526110B),
        contentTextStyle: const TextStyle(
          color: Color(0xFFFBE9E2),
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiduRadius.lg),
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      ),
      // ---------- Page Transition（iOS 水平推入优先） ----------
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(), // A 端全 iOS 风
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData _buildLight() {
    final scheme = _lightScheme();
    return _base(scheme: scheme, dark: false).copyWith(
      primaryColor: MiduColors.brand,
      scaffoldBackgroundColor: MiduColors.surface,
      textTheme: _textTheme(scheme.onSurface, scheme.onSurfaceVariant),
    );
  }

  static ThemeData _buildDark() {
    final scheme = _darkScheme();
    return _base(scheme: scheme, dark: true).copyWith(
      primaryColor: MiduColors.brandSoft,
      scaffoldBackgroundColor: const Color(0xFF1A0B06),
      textTheme: _textTheme(
        const Color(0xFFFBE9E2),
        const Color(0xFFC9A89B),
      ),
    );
  }

  static TextTheme _textTheme(Color onSurface, Color onSurfaceVariant) {
    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: onSurface,
        letterSpacing: -0.3,
      ),
      displayMedium: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        color: onSurface,
        letterSpacing: -0.2,
      ),
      headlineLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      titleLarge: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: onSurface,
        height: 1.45,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: onSurface,
        height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: 12.5,
        color: onSurfaceVariant,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: onSurfaceVariant,
      ),
      labelSmall: TextStyle(
        fontSize: 10.5,
        color: onSurfaceVariant,
        letterSpacing: 0.2,
      ),
    );
  }
}

// ============================================================
//  兼容原项目设置层的 API（ThemeNotifier / 强调色选择器）
// ============================================================

/// UI 风格模式：Material 3 平面 vs 玻璃态毛玻璃（米读默认 glass）
enum AppUiStyle {
  material3,
  glass;

  /// 持久化到 SharedPreferences 时使用的字符串值。
  String get storageValue => name;

  /// 将 SharedPreferences 里存储的字符串反解为 AppUiStyle。
  static AppUiStyle fromStorage(String? s) {
    switch (s) {
      case 'material3':
        return AppUiStyle.material3;
      case 'glass':
      case null:
      case '':
        return AppUiStyle.glass; // 米读默认玻璃态
      default:
        return AppUiStyle.glass;
    }
  }
}

/// 将 SharedPreferences 里存储的字符串反解为 AppUiStyle
AppUiStyle appUiStyleFromStorage(String? raw) =>
    AppUiStyle.fromStorage(raw);

/// 兼容层 AppTheme：封装 light/dark ColorScheme。
/// 注意：米读视觉上统一使用 `MiduAppTheme.light / .dark` 作为 ThemeData；
/// 这里的 AppTheme 仅保留 ColorScheme 接口，供 ThemeNotifier / 强调色 UI 使用。
class AppTheme {
  const AppTheme({required this.lightColorScheme, required this.darkColorScheme});

  final ColorScheme lightColorScheme;
  final ColorScheme darkColorScheme;
}

/// 兼容原 `AppThemes` 静态工厂类。
class AppThemes {
  AppThemes._();

  /// 米读默认强调色（暖橙朱砂主色 #E8503A）。
  static const Color defaultAccentColor = MiduColors.brand;

  /// 预设强调色列表（供颜色选择器使用）。
  static const List<Color> accentColors = <Color>[
    Color(0xFFE8503A), // 朱砂橙
    Color(0xFF2196F3), // 蓝
    Color(0xFF4CAF50), // 绿
    Color(0xFFFF9800), // 橙
    Color(0xFFE91E63), // 粉
    Color(0xFF795548), // 棕
  ];

  /// 基于强调色生成一组 AppTheme（light + dark 色板）。
  /// 用户选择自定义强调色时调用。
  static AppTheme fromAccentColor(Color accent) {
    final light = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
      primary: accent,
    );
    final dark = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      primary: Color.alphaBlend(
        accent.withValues(alpha: 0.85),
        const Color(0xFF3A0F02),
      ),
    );
    return AppTheme(lightColorScheme: light, darkColorScheme: dark);
  }

  /// 兼容旧主题名称的强调色映射。
  static Color accentColorForLegacyTheme(String? name) {
    switch (name) {
      case 'purple':
        return const Color(0xFFE8503A);
      case 'blue':
        return const Color(0xFF2196F3);
      case 'green':
        return const Color(0xFF4CAF50);
      case 'orange':
        return const Color(0xFFFF9800);
      default:
        return const Color(0xFFE8503A);
    }
  }

  /// 根据强调色返回名称（简单匹配常见主色）。
  static String getAccentColorName(Color color) {
    if (color.toARGB32() == 0xFFE8503A) return 'purple';
    return 'custom';
  }
}

/// Color 兼容扩展：旧代码用到的 ARGB32 / 调色板便捷属性。
extension AppThemeColorExt on Color {
  /// Flutter Color.value 就是 0xAARRGGBB。
  int toARGB32() => value;
}


