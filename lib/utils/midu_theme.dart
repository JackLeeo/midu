// 米读品牌色 Tokens（暖橙朱砂系 + A 端统一）
// 暖橙主色：#E8503A (朱砂橙)，渐变 + 玻璃态 + iOS 优先（参考主流阅读APP暖调）。
import 'package:flutter/material.dart';

class MiduColors {
  MiduColors._();

  // ---------- 品牌色（A 端统一暖橙朱砂） ----------
  static const Color brand = Color(0xFFE8503A); // 主色：朱砂暖橙
  static const Color brandDeep = Color(0xFFB2331F); // 深橙：按钮按下/强调
  static const Color brandSoft = Color(0xFFFF8A65); // 浅橙：渐变/高亮
  static const Color brandBg = Color(0xFFFFF0EA); // 淡橙：卡片背景/主色 5%

  // ---------- 渐变 ----------
  static const List<Color> brandGradient = [
    Color(0xFFFF7A5C), // 左上
    Color(0xFFE8503A), // 中
    Color(0xFFC0392B), // 右下
  ];

  static const List<Color> heroGradient = [
    Color(0xFF3A0F02),
    Color(0xFF5A1E08),
    Color(0xFF8C2F14),
    Color(0xFFE8503A),
  ];

  // ---------- 玻璃态 ----------
  static const Color glassLight = Color(0x80FFFFFF); // 70% 透明白（light）
  static const Color glassDark = Color(0x55200B03); // 深底半透（dark）
  static const Color glassBorderLight = Color(0x33FFFFFF);
  static const Color glassBorderDark = Color(0x22FF8A65);

  // ---------- 中性色（暖调灰） ----------
  static const Color ink900 = Color(0xFF26110B); // 标题深
  static const Color ink700 = Color(0xFF4A3026); // 正文
  static const Color ink500 = Color(0xFF8A6F66); // 次要文字
  static const Color ink300 = Color(0xFFC9B4AC); // 辅助文字
  static const Color surface = Color(0xFFFFF9F6); // 主背景
  static const Color surfaceDim = Color(0xFFFBEDE6); // 次级背景
  static const Color line = Color(0xFFF3DCD3); // 分割线

  // ---------- 语义色 ----------
  static const Color success = Color(0xFF31C48D);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4473);
  static const Color info = Color(0xFF3B82F6);
}

// 玻璃态模糊强度约定
class MiduGlassSigma {
  MiduGlassSigma._();
  static const double navBar = 22;
  static const double card = 14;
  static const double sheet = 28;
  static const double dialog = 18;
}

// 圆角约定（iOS 风格连续圆角）
class MiduRadius {
  MiduRadius._();
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

// 阴影约定（紫调软阴影）
class MiduShadows {
  MiduShadows._();
  static List<BoxShadow> get softCard => const [
        BoxShadow(
          color: Color(0x2AB2331F),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
        BoxShadow(
          color: Color(0x12E8503A),
          blurRadius: 4,
          offset: Offset(0, 2),
        ),
      ];

  static List<BoxShadow> get floatButton => const [
        BoxShadow(
          color: Color(0x4AE8503A),
          blurRadius: 22,
          offset: Offset(0, 10),
        ),
      ];

  static List<BoxShadow> get navBar => const [
        BoxShadow(
          color: Color(0x158C2F14),
          blurRadius: 12,
          offset: Offset(0, -2),
        ),
      ];
}
