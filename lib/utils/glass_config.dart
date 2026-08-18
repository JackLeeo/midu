// 米读：玻璃态组件配置（BackdropFilter 模糊强度、边框色）
import 'dart:ui';

import 'package:flutter/material.dart';
import 'midu_theme.dart';

class GlassConfig {
  GlassConfig._();

  /// 将任意 child 包成玻璃态背景（iOS 风毛玻璃）
  static Widget card({
    required Widget child,
    double sigma = 14,
    Color? tintLight,
    Color? tintDark,
    double borderRadius = MiduRadius.lg,
    BorderRadiusGeometry? customBorder,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
  }) {
    return Builder(
      builder: (context) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final bg = dark
            ? (tintDark ?? MiduColors.glassDark)
            : (tintLight ?? MiduColors.glassLight);
        final borderSide = BorderSide(
          color: dark
              ? MiduColors.glassBorderDark
              : MiduColors.glassBorderLight,
          width: 0.5,
        );
        return Container(
          margin: margin,
          child: ClipRRect(
            borderRadius:
                customBorder ?? BorderRadius.circular(borderRadius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: Container(
                padding: padding,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius:
                      customBorder ?? BorderRadius.circular(borderRadius),
                  border: Border.fromBorderSide(borderSide),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 导航/底部栏用：宽尺寸玻璃 + 无圆角边
  static Widget bar({
    required Widget child,
    double sigma = 22,
    Color? tintLight,
    Color? tintDark,
  }) {
    return Builder(
      builder: (context) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final bg = dark
            ? (tintDark ?? const Color(0x66120A2E))
            : (tintLight ?? const Color(0x72FFFFFF));
        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Container(color: bg, child: child),
          ),
        );
      },
    );
  }
}

// ============================================================
//  玻璃态效果配置存根（兼容原 open-reading API 表面）
//  GlassEffectConfig 为静态工具类，提供全局玻璃开关与颜色辅助。
//  GlassEffectHelper 提供阅读器控制栏等场景的参数预设。
// ============================================================

class GlassEffectConfig {
  GlassEffectConfig._();

  static bool _disableAllGlass = false;

  /// 当设备不支持或用户关闭玻璃效果时返回 true。
  static bool get shouldDisableBlur => _disableAllGlass;

  /// 对基础透明度做 clamp 归一化。
  static double effectiveOpacity(double base) => base.clamp(0.0, 1.0);

  /// 取当前主题 surface 色并叠加 opacity。
  static Color surfaceColor(BuildContext context, {double opacity = 1.0}) {
    return Theme.of(context).colorScheme.surface.withValues(alpha: opacity);
  }

  /// Chrome 控件基色：在暗色/亮色下微调混合。
  static Color chromeBaseColor(
    Color base,
    Brightness brightness, {
    double lightBlend = 0.0,
  }) {
    if (lightBlend <= 0) return base;
    return Color.lerp(base, Colors.white, lightBlend) ?? base;
  }

  /// Chrome 控件阴影色。
  static Color chromeShadowColor({
    required Color source,
    required Brightness brightness,
    double darkOpacity = 0.4,
  }) {
    return source.withValues(alpha: darkOpacity);
  }

  /// Chrome 容器表面色。
  static Color chromeSurfaceColor(BuildContext context) {
    return Theme.of(context).colorScheme.surface;
  }

  /// 全局关闭所有玻璃效果。
  static void setDisableAllGlassEffects(bool value) => _disableAllGlass = value;

  /// 应用性能模式：当 reduceEffects 为 true 时关闭玻璃态等高开销效果。
  static void applyPerformanceMode({bool reduceEffects = false}) {
    if (reduceEffects) _disableAllGlass = true;
  }

  /// 导航栏模糊强度。
  static double get navigationBarBlur => 22.0;

  /// AppBar 模糊强度。
  static double get appBarBlur => 18.0;
}

class GlassEffectHelper {
  GlassEffectHelper._();

  /// 阅读器控制栏玻璃参数预设。返回 Map 以兼容原 API（config['opacity'], config['blur']）。
  static Map<String, double> getReadingControlConfig({
    required bool isTopBar,
    required Brightness brightness,
  }) {
    return const <String, double>{
      'opacity': 0.6,
      'blur': 14.0,
    };
  }
}
