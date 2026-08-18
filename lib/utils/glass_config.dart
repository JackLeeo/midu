// 米读：玻璃态组件配置（BackdropFilter 模糊强度、边框色）
import 'dart:ui';

import 'package:flutter/material.dart';
import 'midu_theme.dart';

class GlassConfig {
  GlassConfig._();

  /// 将任意 child 包成玻璃态背景（已全局移除模糊，改为实色卡片）
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
        final scheme = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        // 实色卡面：亮色用 surfaceContainer，暗色用 surfaceContainerHigh
        final bg = dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainer;
        final radius =
            customBorder ?? BorderRadius.circular(borderRadius);
        final content = Container(
          padding: padding,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
          child: child,
        );

        if (GlassEffectConfig.shouldDisableBlur) {
          return Container(
            margin: margin,
            child: ClipRRect(borderRadius: radius, child: content),
          );
        }
        return Container(
          margin: margin,
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: content,
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
        final scheme = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        // 实色栏面，不透明
        final bg = dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainer;
        final bar = Container(color: bg, child: child);
        if (GlassEffectConfig.shouldDisableBlur) return bar;
        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: bar,
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

  static bool _disableAllGlass = true;

  /// 已全局移除玻璃效果，恒为 true。
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

  /// 全局关闭所有玻璃效果（已强制关闭，忽略入参）。
  static void setDisableAllGlassEffects(bool value) => _disableAllGlass = true;

  /// 应用性能模式：已全局移除玻璃态，忽略入参强制关闭。
  static void applyPerformanceMode({bool reduceEffects = false}) {
    _disableAllGlass = true;
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
