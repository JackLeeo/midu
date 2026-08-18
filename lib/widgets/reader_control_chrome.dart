import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/reader/reader_leaf_status.dart';
import '../utils/glass_config.dart';
import '../utils/reader_themes.dart';
import 'reader_top_information_bar.dart';

typedef ReaderStatusBuilder =
    Widget Function(BuildContext context, TextStyle? style, Key? key);

class ReaderChromeOverlay extends StatelessWidget {
  const ReaderChromeOverlay({
    super.key,
    required this.palette,
    required this.visible,
    required this.title,
    required this.statusBottom,
    required this.statusBuilder,
    required this.onBack,
    required this.onBookmark,
    required this.onTableOfContents,
    required this.onSettings,
    required this.backTooltip,
    required this.bookmarkTooltip,
    required this.tableOfContentsTooltip,
    required this.settingsTooltip,
    required this.bookmarked,
    this.onReadAloud,
    this.readAloudTooltip,
    this.readAloudActive = false,
    this.onAskAi,
    this.askAiTooltip,
    this.onSwitchSource,
    this.switchSourceTooltip,
    this.bookmarkBusy = false,
    this.topKey,
    this.bottomKey,
    this.statusKey,
    this.showViewportStatus = true,
    this.showViewportTitle = false,
    this.viewportTitleTop = 0,
    this.viewportTitleKey,
    this.readerStatus,
    this.viewportStatusAlignment = Alignment.centerRight,
    this.viewportStatusHorizontalPadding = 14,
    this.showSettingsAction = true,
    this.chapterLabel,
    this.chapterProgress = 0,
    this.bookProgress = 0,
    this.onPreviousChapter,
    this.onNextChapter,
    this.onSliderSeek,
  });

  final ReaderThemePalette palette;
  final bool visible;
  final String title;
  final double statusBottom;
  final ReaderStatusBuilder statusBuilder;
  final VoidCallback onBack;
  final VoidCallback? onBookmark;
  final VoidCallback? onTableOfContents;
  final VoidCallback onSettings;
  final VoidCallback? onReadAloud;
  final VoidCallback? onAskAi;
  final String? askAiTooltip;
  final VoidCallback? onSwitchSource;
  final String? switchSourceTooltip;
  final String backTooltip;
  final String bookmarkTooltip;
  final String tableOfContentsTooltip;
  final String settingsTooltip;
  final String? readAloudTooltip;
  final bool bookmarked;
  final bool readAloudActive;
  final bool bookmarkBusy;
  final Key? topKey;
  final Key? bottomKey;
  final Key? statusKey;
  final bool showViewportStatus;
  final bool showViewportTitle;
  final double viewportTitleTop;
  final Key? viewportTitleKey;
  final ReaderLeafStatusData? readerStatus;
  final AlignmentGeometry viewportStatusAlignment;
  final double viewportStatusHorizontalPadding;
  final bool showSettingsAction;
  final String? chapterLabel;
  final double chapterProgress;
  final double bookProgress;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final ValueChanged<double>? onSliderSeek;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showViewportTitle)
          Positioned(
            left: 30,
            right: 30,
            top: viewportTitleTop,
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: viewportTitleKey,
                opacity: visible ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: ReaderTopInformationBar(
                  palette: palette,
                  title: title,
                  status: readerStatus,
                ),
              ),
            ),
          ),
        if (showViewportStatus)
          Positioned(
            left: 0,
            right: 0,
            bottom: statusBottom,
            child: IgnorePointer(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: viewportStatusHorizontalPadding,
                ),
                child: Align(
                  alignment: viewportStatusAlignment,
                  child: statusBuilder(
                    context,
                    textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      height: 1,
                      color: palette.secondaryText.withValues(
                        alpha: visible ? 0 : 0.58,
                      ),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    statusKey,
                  ),
                ),
              ),
            ),
          ),
        if (!showViewportStatus && statusKey != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: statusBottom,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 0,
                  child: statusBuilder(context, null, statusKey),
                ),
              ),
            ),
          ),
        AnimatedPositioned(
          key: topKey,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          left: 20,
          right: 20,
          top: visible ? 10 : -130,
          child: SafeArea(
            bottom: false,
            child: ReaderControlBar(
              palette: palette,
              isTopBar: true,
              child: SizedBox(
                height: 58,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      ReaderControlIconButton(
                        palette: palette,
                        onPressed: onBack,
                        tooltip: backTooltip,
                        icon: Icons.arrow_back_rounded,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.1,
                            color: palette.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ReaderControlIconButton(
                        palette: palette,
                        onPressed: bookmarkBusy ? null : onBookmark,
                        tooltip: bookmarkTooltip,
                        icon: bookmarked
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        active: bookmarked,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          key: bottomKey,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          left: 22,
          right: 22,
          bottom: visible ? 16 : -110,
          child: SafeArea(
            top: false,
            child: ReaderControlBar(
              palette: palette,
              isTopBar: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 章节信息 + 整本进度条
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 14, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            chapterLabel ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: palette.secondaryText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(bookProgress.clamp(0.0, 1.0) * 100).round()}%',
                          style: textTheme.labelMedium?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: palette.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ReaderProgressSlider(
                    palette: palette,
                    value: chapterProgress.clamp(0.0, 1.0),
                    onChangeEnd: onSliderSeek,
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 60,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          if (onPreviousChapter != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onPreviousChapter,
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).previousPageTooltip,
                              icon: Icons.skip_previous_rounded,
                            ),
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onTableOfContents,
                            tooltip: tableOfContentsTooltip,
                            icon: Icons.format_list_bulleted_rounded,
                          ),
                          if (onSwitchSource != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onSwitchSource,
                              tooltip: switchSourceTooltip ?? '',
                              icon: Icons.swap_horiz_rounded,
                            ),
                          if (onReadAloud != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onReadAloud,
                              tooltip: readAloudTooltip ?? '',
                              icon: readAloudActive
                                  ? Icons.graphic_eq_rounded
                                  : Icons.headphones_rounded,
                              active: readAloudActive,
                            ),
                          if (onAskAi != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onAskAi,
                              tooltip: askAiTooltip ?? '',
                              icon: Icons.auto_awesome_outlined,
                            ),
                          if (showSettingsAction)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onSettings,
                              tooltip: settingsTooltip,
                              icon: Icons.tune_rounded,
                            ),
                          if (onNextChapter != null)
                            ReaderControlIconButton(
                              palette: palette,
                              onPressed: onNextChapter,
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).nextPageTooltip,
                              icon: Icons.skip_next_rounded,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 章节进度滑块：内部持有本地拖拽值，展示型拖拽不会触发跳转，
/// 释放时通过 onChangeEnd 回传给调用方（用于整本进度定位）。
class _ReaderProgressSlider extends StatefulWidget {
  const _ReaderProgressSlider({
    required this.palette,
    required this.value,
    this.onChangeEnd,
  });

  final ReaderThemePalette palette;
  final double value;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_ReaderProgressSlider> createState() => _ReaderProgressSliderState();
}

class _ReaderProgressSliderState extends State<_ReaderProgressSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final value = _dragValue ?? widget.value;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 2.5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: widget.palette.accent,
        inactiveTrackColor: widget.palette.accent.withValues(alpha: 0.18),
        thumbColor: widget.palette.accent,
        overlayColor: widget.palette.accent.withValues(alpha: 0.12),
      ),
      child: Slider(
        value: value.clamp(0.0, 1.0),
        onChangeStart: (_) => setState(() => _dragValue = value),
        onChanged: (v) => setState(() => _dragValue = v),
        onChangeEnd: (v) {
          setState(() => _dragValue = null);
          widget.onChangeEnd?.call(v);
        },
      ),
    );
  }
}

class ReaderControlBar extends StatelessWidget {
  const ReaderControlBar({
    super.key,
    required this.palette,
    required this.isTopBar,
    required this.child,
  });

  final ReaderThemePalette palette;
  final bool isTopBar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 主流入放观感：顶部栏与底部栏统一用轻量圆角胶囊（radius 24）。顶部栏
    // 更贴边、底部栏略浮起，但都保持玻璃质感的半透明材质。
    final borderRadius = BorderRadius.circular(24);
    final blurEnabled = !GlassEffectConfig.shouldDisableBlur;
    // 不叠加预设，直接使用与悬浮导航栏/首页顶栏一致的标准玻璃参数
    final config = GlassEffectHelper.getReadingControlConfig(
      isTopBar: isTopBar,
      brightness: palette.brightness,
    );
    final surfaceOpacity = blurEnabled ? config['opacity']! : 1.0;
    final cleanSurface = blurEnabled
        ? GlassEffectConfig.chromeBaseColor(
            palette.controlBar,
            palette.brightness,
            lightBlend: 0.28,
          )
        : palette.controlBar;
    final highlight = blurEnabled
        ? Color.lerp(
            cleanSurface,
            Colors.white,
            palette.brightness == Brightness.dark ? 0.06 : 0.1,
          )!
        : cleanSurface;
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            highlight.withValues(
              alpha: (surfaceOpacity + (blurEnabled ? 0.08 : 0.0)).clamp(
                0.0,
                1.0,
              ),
            ),
            cleanSurface.withValues(
              alpha: (surfaceOpacity - (blurEnabled ? 0.02 : 0.0)).clamp(
                0.0,
                1.0,
              ),
            ),
          ],
        ),
        border: Border.all(
          color: blurEnabled
              ? Color.lerp(
                  palette.border,
                  Colors.white,
                  palette.brightness == Brightness.dark ? 0.16 : 0.14,
                )!.withValues(
                  alpha: palette.brightness == Brightness.light ? 0.28 : 0.54,
                )
              : palette.border,
          width: 1,
        ),
      ),
      child: Material(color: Colors.transparent, child: child),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: blurEnabled
                ? GlassEffectConfig.chromeShadowColor(
                    source: palette.shadow,
                    brightness: palette.brightness,
                    darkOpacity: 0.46,
                  )
                : palette.shadow.withValues(
                    alpha: palette.brightness == Brightness.dark ? 0.46 : 0.22,
                  ),
            blurRadius: blurEnabled && palette.brightness == Brightness.light
                ? 24
                : 32,
            spreadRadius: -5,
            offset: Offset(
              0,
              blurEnabled && palette.brightness == Brightness.light ? 8 : 16,
            ),
          ),
          if (!blurEnabled || palette.brightness == Brightness.dark)
            BoxShadow(
              color: palette.shadow.withValues(alpha: 0.10),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: blurEnabled
            ? BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: config['blur']!,
                  sigmaY: config['blur']!,
                ),
                child: panel,
              )
            : panel,
      ),
    );
  }
}

class ReaderControlIconButton extends StatelessWidget {
  const ReaderControlIconButton({
    super.key,
    required this.palette,
    required this.onPressed,
    required this.tooltip,
    required this.icon,
    this.active = false,
  });

  final ReaderThemePalette palette;
  final VoidCallback? onPressed;
  final String tooltip;
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final glassEnabled = !GlassEffectConfig.shouldDisableBlur;
    final cleanControlFill = glassEnabled
        ? GlassEffectConfig.chromeBaseColor(
            palette.controlFill,
            palette.brightness,
            lightBlend: 0.22,
          )
        : palette.controlFill;
    // 激活态（已书签 / 朗读中）用主题强调色点亮，未激活态保持中性玻璃填充。
    final foreground = active ? palette.accent : palette.text;
    final background = active
        ? palette.accent.withValues(alpha: glassEnabled ? 0.16 : 0.14)
        : cleanControlFill.withValues(
            alpha: glassEnabled
                ? (palette.brightness == Brightness.light ? 0.76 : 0.58)
                : 1.0,
          );
    final border = active
        ? palette.accent.withValues(alpha: glassEnabled ? 0.34 : 0.42)
        : glassEnabled
        ? Color.lerp(palette.border, Colors.white, 0.12)!.withValues(
            alpha: palette.brightness == Brightness.light ? 0.28 : 0.48,
          )
        : palette.border;
    return IconButton.filledTonal(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: background,
        minimumSize: const Size.square(44),
        maximumSize: const Size.square(44),
        padding: EdgeInsets.zero,
        side: BorderSide(color: border, width: 0.8),
        shape: const CircleBorder(),
      ),
    );
  }
}
