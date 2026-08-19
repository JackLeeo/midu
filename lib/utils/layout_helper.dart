// 文件说明：响应式布局工具，根据屏幕尺寸判断导航模式与布局类型。
// 技术要点：工具方法、Flutter。

import 'package:flutter/material.dart';

class LayoutHelper {
  // 屏幕尺寸断点
  static const double largeMobileBreakpoint = 414.0; // iPhone Plus/Pro Max等大屏手机
  static const double tabletBreakpoint = 820.0; // 降低断点以支持小尺寸平板(7-8英寸)和折叠屏
  static const double desktopBreakpoint = 1200.0;

  /// 固定尺寸的书封框统一裁满，不能因平台或封面来源改变视觉尺寸。
  static const BoxFit bookCoverFit = BoxFit.cover;

  /// 兼容纯封面网格原有命名。
  static const BoxFit coverOnlyGridFit = bookCoverFit;

  // 判断是否为普通手机
  static bool isSmallMobile(BuildContext context) {
    return MediaQuery.of(context).size.width < largeMobileBreakpoint;
  }

  // 判断是否为大屏手机
  static bool isLargeMobile(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= largeMobileBreakpoint && width < tabletBreakpoint;
  }

  // 判断是否为手机（包括大屏手机）
  static bool isMobile(BuildContext context) {
    return MediaQuery.of(context).size.width < tabletBreakpoint;
  }

  // 判断是否为平板
  static bool isTablet(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= tabletBreakpoint && width < desktopBreakpoint;
  }

  // 判断是否为桌面
  static bool isDesktop(BuildContext context) {
    return MediaQuery.of(context).size.width >= desktopBreakpoint;
  }

  // 判断是否为宽屏设备（平板或桌面）
  static bool isWideScreen(BuildContext context) {
    return MediaQuery.of(context).size.width >= tabletBreakpoint;
  }

  // 获取屏幕类型
  static ScreenType getScreenType(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= desktopBreakpoint) {
      return ScreenType.desktop;
    } else if (width >= tabletBreakpoint) {
      return ScreenType.tablet;
    } else if (width >= largeMobileBreakpoint) {
      return ScreenType.largeMobile;
    } else {
      return ScreenType.mobile;
    }
  }

  // 根据屏幕类型返回不同的值
  static T getValue<T>(
    BuildContext context, {
    required T mobile,
    T? largeMobile,
    T? tablet,
    T? desktop,
  }) {
    switch (getScreenType(context)) {
      case ScreenType.desktop:
        return desktop ?? tablet ?? largeMobile ?? mobile;
      case ScreenType.tablet:
        return tablet ?? largeMobile ?? mobile;
      case ScreenType.largeMobile:
        return largeMobile ?? mobile;
      case ScreenType.mobile:
        return mobile;
    }
  }

  // 获取响应式边距
  static double getHorizontalPadding(BuildContext context) {
    return getValue(
      context,
      mobile: 16.0,
      largeMobile: 20.0,
      tablet: 32.0,
      desktop: 64.0,
    );
  }

  // 获取响应式列数
  static int getColumnCount(
    BuildContext context, {
    int mobileColumns = 1,
    int? tabletColumns,
    int? desktopColumns,
  }) {
    return getValue(
      context,
      mobile: mobileColumns,
      tablet: tabletColumns ?? mobileColumns * 2,
      desktop: desktopColumns ?? tabletColumns ?? mobileColumns * 3,
    );
  }

  // 获取响应式字体大小
  static double getFontSize(
    BuildContext context, {
    required double baseFontSize,
    double? tabletScale,
    double? desktopScale,
  }) {
    final scale = getValue(
      context,
      mobile: 1.0,
      tablet: tabletScale ?? 1.1,
      desktop: desktopScale ?? 1.2,
    );
    return baseFontSize * scale;
  }

  // 书库网格按可用宽度推导列数（网格仅在平板/桌面显示）。
  // 目标是每个格子逻辑像素宽度较小（封面 ~120），旋转屏幕时封面大小
  // 基本不变、只重排列数，避免大屏上封面过大、每屏书籍过少。
  static int bookGridColumnsForWidth(double width) {
    const double targetItemExtent = 140.0;
    const double horizontalPadding = 20.0;
    if (width <= 0) return 3;
    return ((width - horizontalPadding) / targetItemExtent).round().clamp(
      3,
      14,
    );
  }

  /// 纯封面网格密度：按可用宽度自适应列数，封面目标宽度更小，手机也能一排
  /// 3-4 本，平板/桌面按相同密度继续增加列数，避免封面过大、每屏书过少。
  /// [mobileColumns]（2/3）作为下限保留用户的最小列数偏好。
  static int coverOnlyGridColumnsForWidth(
    double width, {
    required int mobileColumns,
  }) {
    final normalizedColumns = mobileColumns == 2 ? 2 : 3;
    // 封面目标宽度：更紧凑，缩放屏幕时列数重排、封面大小基本不变。
    const double targetItemExtent = 120.0;
    const double horizontalPadding = 12.0;
    if (width <= 0) return normalizedColumns;
    return ((width - horizontalPadding) / targetItemExtent).round().clamp(
      normalizedColumns,
      14,
    );
  }

  // 判断是否应该显示双页布局
  static bool shouldShowDoublePage(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    // 横屏且宽度足够时显示双页
    return width > height && width >= tabletBreakpoint;
  }

  // 获取导航栏类型
  static NavigationType getNavigationType(BuildContext context) {
    if (isDesktop(context) || isTablet(context)) {
      return NavigationType.rail;
    } else {
      return NavigationType.bottom;
    }
  }
}

enum ScreenType { mobile, largeMobile, tablet, desktop }

enum NavigationType { bottom, rail }
