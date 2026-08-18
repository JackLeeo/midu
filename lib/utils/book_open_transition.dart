// 米读：书籍打开 Hero 动画（iOS 书脊翻开感 + 紫色光晕）
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'midu_theme.dart';
import 'page_transitions.dart';

/// 书架卡片 -> 书籍详情/阅读器 之间的 Hero 标签构造。
class BookHeroTag {
  BookHeroTag._();
  static String cover(int? bookId, String fallback) =>
      'book_cover_${bookId ?? fallback.hashCode}';
  static String title(int? bookId, String fallback) =>
      'book_title_${bookId ?? fallback.hashCode}';
  static String card(int? bookId, String fallback) =>
      'book_card_${bookId ?? fallback.hashCode}';
}

/// 书架/搜索卡片点击：带紫色光晕的展开式过渡（包装 Material 路由）
Route<T> buildBookOpenRoute<T>({
  required WidgetBuilder builder,
  bool fullscreenDialog = false,
}) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    fullscreenDialog: fullscreenDialog,
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 340),
    opaque: true,
    transitionsBuilder: (context, a, b, child) {
      final curve = CurvedAnimation(
        parent: a,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final fade = FadeTransition(
        opacity: Tween<double>(begin: 0.3, end: 1.0).animate(curve),
        child: child,
      );
      // 进入时，先从下往上偏移 36px，再配合 scale 微小弹入
      final slide = Tween<Offset>(
        begin: const Offset(0, 0.06),
        end: Offset.zero,
      ).animate(curve);
      final scale = Tween<double>(begin: 0.985, end: 1.0).animate(curve);
      final halo = Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.4,
            colors: [
              const Color(0x008569FF),
              MiduColors.brand.withValues(alpha: 0.12 * curve.value),
            ],
          ),
        ),
      );
      return Stack(
        children: [
          Positioned.fill(child: halo),
          SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: fade),
          ),
        ],
      );
    },
  );
}

// ============================================================
//  书籍打开过渡存根（兼容原 open-reading API 表面）
//  BookOpenTransition 为静态工具类，管理打开阅读器的路由创建与导航。
//  BookOpenAnimation 描述自定义翻书动画参数（如封面展开）。
// ============================================================

class _BookOpenActivity {
  void dispose() {}
}

class BookOpenTransition {
  BookOpenTransition._();

  /// 当前是否有阅读器处于活跃状态（打开动画/阅读中，导航栏应隐藏）。
  static bool _hasActiveReaderActivity = false;

  static final ValueNotifier<bool> _navHiddenNotifier =
      ValueNotifier<bool>(false);

  /// 打开动画落定状态（存根：无打开动画，恒为已落定）。
  static final ValueNotifier<bool> _openingSettledNotifier =
      ValueNotifier<bool>(true);

  /// 打开封面停留状态（存根：无封面停留阶段，恒为已到达）。
  static final ValueNotifier<bool> _openingCoverHoldNotifier =
      ValueNotifier<bool>(true);

  /// 当前是否有阅读器处于活跃状态（阅读器路由存在期间为 true）。
  static bool get hasActiveReaderActivity => _hasActiveReaderActivity;

  /// 导航栏隐藏状态的可监听值。阅读器路由创建/弹出时同步更新，
  /// 首页悬浮导航据此滑出/滑入。
  static ValueListenable<bool> get navigationHiddenListenable =>
      _navHiddenNotifier;

  /// 开始一次打开活动，返回可 dispose 的句柄。
  static _BookOpenActivity beginActivity() {
    _setReaderActive(true);
    return _BookOpenActivity();
  }

  /// 退出阅读器路由（存根：导航先恢复显示，活跃状态保持到路由完全弹出）。
  /// 兼容三种调用形式：beginExit()、beginExit(context)、beginExit(context, onCompleted: cb)。
  static void beginExit([
    BuildContext? context,
    VoidCallback? onCompleted,
  ]) {
    // 阅读器开始退出时首页悬浮导航立即滑回；活跃状态（系统 inset 锁定等）
    // 由 createRoute 里监听 route.completed 的路由弹出回调清除。
    if (_navHiddenNotifier.value) _navHiddenNotifier.value = false;
    onCompleted?.call();
  }

  static void _setReaderActive(bool active) {
    _hasActiveReaderActivity = active;
    _navHiddenNotifier.value = active;
  }

  /// 标记阅读器内容已就绪（存根）。
  static void markReaderContentReady(BuildContext context) {}

  /// 打开动画飞行 settle 的可监听值（存根：无打开动画，恒为已落定 true）。
  static ValueListenable<bool> openingFlightSettledListenableOf(
          BuildContext context) =>
      _openingSettledNotifier;

  /// 打开封面停留的可监听值（存根：无封面停留阶段，恒为已到达 true）。
  static ValueListenable<bool> openingCoverHoldListenableOf(BuildContext context) =>
      _openingCoverHoldNotifier;

  /// 创建书籍打开路由。
  static Route<T> createRoute<T>(
    Widget child, {
    ReaderPageTransitionOrigin origin = ReaderPageTransitionOrigin.standard,
    BookOpenAnimation? animation,
    LibraryBookOpenAnimation? libraryAnimation,
    Color? readerBackgroundColor,
    bool waitForReaderReady = false,
  }) {
    // 阅读器路由存在期间隐藏首页悬浮导航。
    _setReaderActive(true);
    final route = PageRouteBuilder<T>(
      pageBuilder: (context, anim, secondaryAnim) => child,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 340),
      transitionsBuilder: (context, anim, secondaryAnim, child) {
        final curve = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curve),
          child: child,
        );
      },
    );
    // 路由被完全弹出后清除阅读器活跃状态，恢复首页悬浮导航。
    route.completed.whenComplete(() => _setReaderActive(false));
    return route;
  }

  /// 推入书籍打开路由。
  static Future<T?> push<T>(BuildContext context, Route<T> route) {
    return Navigator.of(context).push<T>(route);
  }
}

class BookOpenAnimation {
  const BookOpenAnimation();

  /// 从封面 GlobalKey 创建封面展开动画参数。
  factory BookOpenAnimation.fromCoverKey(
    GlobalKey coverKey, {
    BorderRadius? radius,
    WidgetBuilder? coverBuilder,
  }) {
    return const BookOpenAnimation();
  }
}
