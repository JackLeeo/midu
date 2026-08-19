import 'package:flutter/material.dart';

import '../core/reader/reader_leaf_status.dart';
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
    this.onDownload,
    this.downloadTooltip,
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
  final VoidCallback? onDownload;
  final String? downloadTooltip;
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
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          left: 0,
          right: 0,
          top: visible ? 0 : -140,
          child: SafeArea(
            bottom: false,
            child: ReaderControlBar(
              palette: palette,
              isTopBar: true,
              child: SizedBox(
                height: 58,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
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
                      const SizedBox(width: 4),
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
                      const SizedBox(width: 4),
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
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          left: 0,
          right: 0,
          bottom: visible ? 0 : -120,
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
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
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
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 68,
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
                            label: '上一章',
                          ),
                        ReaderControlIconButton(
                          palette: palette,
                          onPressed: onTableOfContents,
                          tooltip: tableOfContentsTooltip,
                          icon: Icons.format_list_bulleted_rounded,
                          label: '目录',
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
                            label: '听书',
                          ),
                        if (onSwitchSource != null)
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onSwitchSource,
                            tooltip: switchSourceTooltip ?? '',
                            icon: Icons.swap_horiz_rounded,
                            label: '换源',
                          ),
                        if (onDownload != null)
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onDownload,
                            tooltip: downloadTooltip ?? '',
                            icon: Icons.download_rounded,
                            label: '缓存',
                          ),
                        if (showSettingsAction)
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onSettings,
                            tooltip: settingsTooltip,
                            icon: Icons.tune_rounded,
                            label: '设置',
                          ),
                        if (onNextChapter != null)
                          ReaderControlIconButton(
                            palette: palette,
                            onPressed: onNextChapter,
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).nextPageTooltip,
                            icon: Icons.skip_next_rounded,
                            label: '下一章',
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
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
    // 对齐主流阅读 App：顶栏/底栏为通栏实色背景，贴边无圆角、无悬浮阴影，
    // 仅用一条分割线把控制栏与正文区域区分开。
    final divider = Color.lerp(
      palette.border,
      palette.text,
      palette.brightness == Brightness.dark ? 0.10 : 0.05,
    )!.withValues(alpha: palette.brightness == Brightness.dark ? 0.35 : 0.18);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.controlBar,
        border: Border(
          top: isTopBar
              ? const BorderSide(width: 0)
              : BorderSide(color: divider, width: 1),
          bottom: isTopBar
              ? BorderSide(color: divider, width: 1)
              : const BorderSide(width: 0),
        ),
      ),
      child: Material(color: Colors.transparent, child: child),
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
    this.label,
    this.active = false,
  });

  final ReaderThemePalette palette;
  final VoidCallback? onPressed;
  final String tooltip;
  final IconData icon;
  final String? label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    // 主流阅读 App 的工具栏按钮：纯图标式，激活态用主题色点亮；可带中文标识。
    final foreground = active ? palette.accent : palette.text;
    if (label == null) {
      return IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon, size: 23),
        color: foreground,
        disabledColor: palette.secondaryText.withValues(alpha: 0.4),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(44),
          maximumSize: const Size.square(44),
          padding: EdgeInsets.zero,
        ),
      );
    }
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 23, color: foreground),
            const SizedBox(height: 3),
            Text(
              label!,
              style: TextStyle(
                fontSize: 10.5,
                height: 1,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
