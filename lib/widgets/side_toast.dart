// 米读：轻提示（侧边 Toast 风格的 SnackBar 封装）
import 'package:flutter/material.dart';

import '../utils/midu_theme.dart';

/// 侧边 Toast 类型（用于区分 info / success / warning / error 的视觉强调）。
enum SideToastKind { info, success, warning, error }

class SideToast {
  SideToast._();

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
    IconData icon = Icons.info_outline,
    Color? accent,
    SideToastKind? kind,
  }) {
    final effectiveIcon = kind != null
        ? switch (kind) {
            SideToastKind.success => Icons.check_circle_outline,
            SideToastKind.error => Icons.error_outline,
            SideToastKind.warning => Icons.warning_amber_outlined,
            SideToastKind.info => Icons.info_outline,
          }
        : icon;
    final scheme = Theme.of(context).colorScheme;
    final bar = SnackBar(
      duration: duration,
      behavior: SnackBarBehavior.floating,
      // 米读：SnackBar 不允许 width 与 margin 同时设置（断言），
      // 固定宽度放到内部 Container，SnackBar 只保留 margin 完成侧边定位。
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      elevation: 0,
      content: Container(
        width: 340,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(MiduRadius.lg),
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.35),
            width: 0.5,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x223A1F7A),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              effectiveIcon,
              color: accent ?? scheme.primary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      // Fallback: root ScaffoldMessenger
      return ScaffoldMessenger.of(context).showSnackBar(bar);
    }
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(bar);
  }

  /// 按 kind 快捷显示侧边 Toast。
  static void showKind(
    BuildContext context,
    SideToastKind kind,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, duration: duration, kind: kind);
  }
}

/// 兼容旧代码：顶层函数调用。
void showSideToast(
  BuildContext context,
  String message, {
  Duration? duration,
  IconData? icon,
  SideToastKind? kind,
}) {
  SideToast.show(
    context,
    message,
    duration: duration ?? const Duration(seconds: 2),
    icon: icon ?? Icons.info_outline,
    kind: kind,
  );
}
