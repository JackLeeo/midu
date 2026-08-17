// 米读品牌色 Tokens（紫色系 + A 端统一）
// 紫色主色：#6C4CF6 (紫水晶)，渐变 + 玻璃态 + iOS 优先。
import 'package:flutter/material.dart';

class MiduColors {
  MiduColors._();

  // ---------- 品牌色（A 端统一紫色） ----------
  static const Color brand = Color(0xFF6C4CF6); // 主色：紫水晶
  static const Color brandDeep = Color(0xFF4A2FD1); // 深紫：按钮按下/强调
  static const Color brandSoft = Color(0xFFA28EFF); // 浅紫：渐变/高亮
  static const Color brandBg = Color(0xFFF2EEFF); // 淡紫：卡片背景/主色 5%

  // ---------- 渐变 ----------
  static const List<Color> brandGradient = [
    Color(0xFF8569FF), // 左上
    Color(0xFF6C4CF6), // 中
    Color(0xFF4A2FD1), // 右下
  ];

  static const List<Color> heroGradient = [
    Color(0xFF1A0B3F),
    Color(0xFF2C135C),
    Color(0xFF3A1F7A),
    Color(0xFF6C4CF6),
  ];

  // ---------- 玻璃态 ----------
  static const Color glassLight = Color(0x80FFFFFF); // 70% 透明白（light）
  static const Color glassDark = Color(0x55120A2E); // 深底半透（dark）
  static const Color glassBorderLight = Color(0x33FFFFFF);
  static const Color glassBorderDark = Color(0x22A28EFF);

  // ---------- 中性色 ----------
  static const Color ink900 = Color(0xFF150A33); // 标题深
  static const Color ink700 = Color(0xFF3A2E66); // 正文
  static const Color ink500 = Color(0xFF6E6599); // 次要文字
  static const Color ink300 = Color(0xFFB6B0D6); // 辅助文字
  static const Color surface = Color(0xFFFAF8FF); // 主背景
  static const Color surfaceDim = Color(0xFFF0ECFB); // 次级背景
  static const Color line = Color(0xFFE6DFFA); // 分割线

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
          color: Color(0x2A4A2FD1),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
        BoxShadow(
          color: Color(0x126C4CF6),
          blurRadius: 4,
          offset: Offset(0, 2),
        ),
      ];

  static List<BoxShadow> get floatButton => const [
        BoxShadow(
          color: Color(0x4A6C4CF6),
          blurRadius: 22,
          offset: Offset(0, 10),
        ),
      ];

  static List<BoxShadow> get navBar => const [
        BoxShadow(
          color: Color(0x153A1F7A),
          blurRadius: 12,
          offset: Offset(0, -2),
        ),
      ];
}
