// 米读：通用 UI 风格（间距、动效时长、渐变装饰等便捷构造）
import 'package:flutter/material.dart';
import 'midu_theme.dart';
import 'app_themes.dart';
export 'app_themes.dart';

class UIStyle {
  UIStyle._();

  // ---------- 尺寸 ----------
  static const double pagePadding = 18;
  static const double sectionSpacing = 22;
  static const double cardSpacing = 14;
  static const double itemSpacing = 10;
  static const double topSafe = 12;
  static const double bottomNavBarHeight = 74;

  // ---------- 动效 ----------
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 380);
  static const Duration hero = Duration(milliseconds: 520);

  // ---------- 装饰 ----------
  static BoxDecoration brandGradientBox({
    BorderRadiusGeometry radius =
        const BorderRadius.all(Radius.circular(MiduRadius.lg)),
    List<Color>? colors,
    AlignmentGeometry begin = Alignment.topLeft,
    AlignmentGeometry end = Alignment.bottomRight,
  }) =>
      BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: begin,
          end: end,
          colors: colors ?? MiduColors.brandGradient,
        ),
      );

  static BoxDecoration heroGradientBg() => const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: MiduColors.heroGradient,
        ),
      );

  static List<BoxShadow> softShadow({Color color = const Color(0x2A4A2FD1)}) =>
      [
        BoxShadow(
          color: color,
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ];
}

// 便捷 EdgeInsets 工厂
class Pad {
  Pad._();
  static const page = EdgeInsets.all(UIStyle.pagePadding);
  static const pageH = EdgeInsets.symmetric(horizontal: UIStyle.pagePadding);
  static const card = EdgeInsets.all(14);
  static const cardH = EdgeInsets.symmetric(horizontal: 14);
  static const cardV = EdgeInsets.symmetric(vertical: 12);
  static const sectionV = EdgeInsets.symmetric(vertical: 6);
  static const chipH = EdgeInsets.symmetric(horizontal: 10, vertical: 6);
  static const bottomNav = EdgeInsets.fromLTRB(0, 0, 0, 12);
}

/// UI 风格 ThemeExtension：将 AppUiStyle 挂载到 Theme 上，供 widget 读取。
class UiStyleThemeExtension extends ThemeExtension<UiStyleThemeExtension> {
  final AppUiStyle style;

  const UiStyleThemeExtension({required this.style});

  bool get isMaterial3Style => style == AppUiStyle.material3;

  @override
  UiStyleThemeExtension copyWith({AppUiStyle? style}) =>
      UiStyleThemeExtension(style: style ?? this.style);

  @override
  UiStyleThemeExtension lerp(UiStyleThemeExtension? other, double t) => this;
}
