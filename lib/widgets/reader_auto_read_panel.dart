import 'dart:async';

import 'package:flutter/material.dart';

import '../core/reader/reader_settings.dart';
import '../utils/localization_extension.dart';
import '../utils/reader_themes.dart';

/// 弹出自动阅读控制条（对标 Legado `AutoReadDialog`），复用
/// [ReaderAutoReadPanel] 的底部弹层视觉（半透明背景 + 拖拽手柄）。
Future<void> showReaderAutoReadPanelSheet({
  required BuildContext context,
  required ReaderAutoReadController controller,
  required ReaderThemePalette palette,
  required ThemeData themeData,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  enableDrag: true,
  showDragHandle: true,
  backgroundColor: palette.controlBar,
  constraints: BoxConstraints(
    maxWidth: 720,
    maxHeight: MediaQuery.sizeOf(context).height * 0.6,
  ),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  clipBehavior: Clip.antiAlias,
  builder: (sheetContext) => Theme(
    data: themeData,
    child: ReaderAutoReadPanel(
      controller: controller,
      palette: palette,
    ),
  ),
);

/// 自动阅读控制条（对标 Legado `AutoReadDialog`）：通过底栏的
/// 速度滑杆调节每次翻页间隔（秒），并提供「播放/暂停」「进度定位」与
/// 「停止」动作。状态与翻页引擎状态共享一个 [ReaderAutoReadController]。
class ReaderAutoReadPanel extends StatefulWidget {
  const ReaderAutoReadPanel({
    super.key,
    required this.controller,
    required this.palette,
  });

  final ReaderAutoReadController controller;
  final ReaderThemePalette palette;

  @override
  State<ReaderAutoReadPanel> createState() => _ReaderAutoReadPanelState();
}

class _ReaderAutoReadPanelState extends State<ReaderAutoReadPanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final palette = widget.palette;
    final textTheme = Theme.of(context).textTheme;
    final seconds = c.seconds;
    return SizedBox(
      height: 220,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.autoReadTitle,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Text(
                  context.l10n.autoReadSpeedLabel,
                  style: textTheme.labelMedium?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
                const Spacer(),
                Text(
                  '${seconds}s',
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: palette.accent,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: palette.accent,
                inactiveTrackColor: palette.accent.withValues(alpha: 0.18),
                thumbColor: palette.accent,
                overlayColor: palette.accent.withValues(alpha: 0.12),
              ),
              child: Slider(
                value: seconds
                    .clamp(
                      ReaderSettings.minAutoReadSeconds,
                      ReaderSettings.maxAutoReadSeconds,
                    )
                    .toDouble(),
                min: ReaderSettings.minAutoReadSeconds.toDouble(),
                max: ReaderSettings.maxAutoReadSeconds.toDouble(),
                divisions:
                    ReaderSettings.maxAutoReadSeconds -
                        ReaderSettings.minAutoReadSeconds,
                label: '${seconds}s',
                onChanged: c.running ? null : (v) => c.setSeconds(v.round()),
              ),
            ),
            Text(
              context.l10n.autoReadSpeedHint,
              style: textTheme.labelSmall?.copyWith(
                color: palette.secondaryText,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ActionButton(
                  key: const ValueKey('auto-read-prev-chapter'),
                  palette: palette,
                  icon: Icons.skip_previous_rounded,
                  label: context.l10n.tapZonePreviousChapter,
                  onPressed: c.onPreviousChapter,
                ),
                _ActionButton(
                  key: const ValueKey('auto-read-toggle'),
                  palette: palette,
                  icon: c.running
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  label: c.running
                      ? context.l10n.autoReadPause
                      : context.l10n.autoReadStart,
                  active: c.running,
                  onPressed: c.toggle,
                ),
                _ActionButton(
                  key: const ValueKey('auto-read-next-chapter'),
                  palette: palette,
                  icon: Icons.skip_next_rounded,
                  label: context.l10n.tapZoneNextChapter,
                  onPressed: c.onNextChapter,
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (c.running || c.wasRunning)
              OutlinedButton.icon(
                key: const ValueKey('auto-read-stop'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.accent,
                  side: BorderSide(
                    color: palette.accent.withValues(alpha: 0.5),
                  ),
                ),
                onPressed: c.stop,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(context.l10n.autoReadStop),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.palette,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final ReaderThemePalette palette;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? palette.accent : palette.text;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: palette.secondaryText,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自动阅读翻页引擎控制器（对标 Legado `AutoPager`）。
///
/// 持有计时器按固定间隔触发翻页；页码前进通过 [onTurn] 回调交由阅读页
/// 驱动。提供独立的运行/暂停状态、秒数持久化，以及播放完成后自动收尾。
class ReaderAutoReadController extends ChangeNotifier {
  ReaderAutoReadController({
    required int seconds,
    VoidCallback? onTurn,
    VoidCallback? onFinish,
    VoidCallback? onPreviousChapter,
    VoidCallback? onNextChapter,
    ReaderSettingsStore? store,
  })  : _seconds = seconds.clamp(
          ReaderSettings.minAutoReadSeconds,
          ReaderSettings.maxAutoReadSeconds,
        ),
        _onTurn = onTurn,
        _onFinish = onFinish,
        _onPreviousChapter = onPreviousChapter,
        _onNextChapter = onNextChapter,
        _store = store;

  final VoidCallback? _onTurn;
  final VoidCallback? _onFinish;
  final VoidCallback? _onPreviousChapter;
  final VoidCallback? _onNextChapter;
  final ReaderSettingsStore? _store;

  int _seconds;
  bool _running = false;
  bool _wasRunning = false;
  Timer? _timer;

  int get seconds => _seconds;
  bool get running => _running;

  /// 曾经运行过（用于展示“停止”按钮的确定性状态）。
  bool get wasRunning => _wasRunning;

  VoidCallback? get onPreviousChapter => _onPreviousChapter;
  VoidCallback? get onNextChapter => _onNextChapter;

  void setSeconds(int value) {
    final v = value.clamp(
      ReaderSettings.minAutoReadSeconds,
      ReaderSettings.maxAutoReadSeconds,
    );
    if (_seconds == v) return;
    _seconds = v;
    notifyListeners();
    _persistSeconds();
  }

  Future<void> _persistSeconds() async {
    final store = _store;
    if (store == null) return;
    final settings = await store.load();
    await store.save(settings.copyWith(autoReadSeconds: _seconds));
  }

  void _restartTimer() {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(Duration(seconds: _seconds), () {
      if (!_running) return;
      final turn = _onTurn;
      if (turn == null) {
        _finishAtEnd();
        return;
      }
      turn();
    });
  }

  void toggle() => _running ? pause() : start();

  void start() {
    if (_running) return;
    _running = true;
    _wasRunning = true;
    notifyListeners();
    _restartTimer();
  }

  void pause() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    notifyListeners();
  }

  void stop() {
    _running = false;
    _wasRunning = false;
    _timer?.cancel();
    notifyListeners();
  }

  /// 当无法继续翻页（已到全书末尾）时收尾。由阅读页在翻页回调返回
  /// false 后驱动，或在此控制器无翻页回调时自动触发。
  void _finishAtEnd() {
    stop();
    _onFinish?.call();
  }

  /// 翻页引擎收到“已到末尾”通知后调用，优雅停止并触发 [onFinish]。
  void finish() => _finishAtEnd();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
