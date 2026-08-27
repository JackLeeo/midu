// 文件说明：在线书源漫画章节渲染器。章节正文是一张张图片 URL（imageUrls），
// 这里按需拉取原始字节、PageView 横向翻页、InteractiveViewer 捏合缩放，
// 复用服务端图源请求层（含 Referer/UA）而非走本地文件。整页图不参与文本排版。
//
// 区别于 paged_image_reader.dart：那是本地 CBZ/PDF 整本书的独立阅读页，自带
// 完整 Chrome；这里只是普通 Widget，嵌入到书源阅读器的主体里，复用外层的
// 阅读器顶栏/主题/章节导航。

import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/reader/reader_tap_zones.dart';
import '../../utils/localization_extension.dart';

/// 网络漫画单章查看器。
///
/// [imageUrls] 是该章全部页图的完整 URL；[loadPage] 按页索引返回图片字节
/// （调用方负责走书源请求层并做缓存）。翻到最后一页后再翻会触发
/// [onEndReached]，供外层进入下一章。
class NetworkComicViewer extends StatefulWidget {
  const NetworkComicViewer({
    super.key,
    required this.imageUrls,
    required this.loadPage,
    this.initialPage = 0,
    this.onEndReached,
    this.background = const Color(0xFF111111),
  });

  final List<String> imageUrls;
  final Future<Uint8List> Function(int index) loadPage;
  final int initialPage;
  final VoidCallback? onEndReached;
  final Color background;

  @override
  State<NetworkComicViewer> createState() => _NetworkComicViewerState();
}

class _NetworkComicViewerState extends State<NetworkComicViewer> {
  static const int _pageCacheLimit = 8;

  late final PageController _pageController;
  late int _currentPage;
  bool _zoomed = false;

  final LinkedHashMap<int, Uint8List> _pageCache = LinkedHashMap();
  final Map<int, Future<Uint8List>> _pendingPages = {};
  final Set<int> _failedPages = {};

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage.clamp(0, widget.imageUrls.length - 1);
    _pageController = PageController(initialPage: _currentPage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<Uint8List> _load(int index) {
    final cached = _pageCache.remove(index);
    if (cached != null) {
      _pageCache[index] = cached; // 触碰后移到末尾（LRU 最新）。
      return Future.value(cached);
    }
    final pending = _pendingPages[index];
    if (pending != null) return pending;
    final future = widget.loadPage(index);
    _pendingPages[index] = future;
    future
        .then((bytes) {
          if (bytes.isEmpty) {
            _failedPages.add(index);
          } else {
            _failedPages.remove(index);
            _pageCache[index] = bytes;
          }
          while (_pageCache.length > _pageCacheLimit) {
            _pageCache.remove(_pageCache.keys.first);
          }
        })
        .catchError((Object _) {
          _failedPages.add(index);
          _pendingPages.remove(index);
        })
        .whenComplete(() {
          _pendingPages.remove(index);
          if (mounted) setState(() {});
        });
    return future;
  }

  void _goTo(int target, {bool animate = true}) {
    final clamped = target.clamp(0, widget.imageUrls.length - 1);
    if (clamped == _currentPage || !_pageController.hasClients) return;
    if (animate) {
      _pageController.animateToPage(
        clamped,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(clamped);
    }
  }

  void _handleTap(Offset position, Size size) {
    if (_zoomed) return;
    switch (ReaderTapZones.defaults.actionAt(position, size)) {
      case ReaderTapZoneAction.previousPage:
        if (_currentPage == 0) return;
        _goTo(_currentPage - 1);
      case ReaderTapZoneAction.nextPage:
        if (_currentPage == widget.imageUrls.length - 1) {
          widget.onEndReached?.call();
          return;
        }
        _goTo(_currentPage + 1);
      case ReaderTapZoneAction.menu:
        widget.onEndReached?.call();
      case ReaderTapZoneAction.previousChapter:
      case ReaderTapZoneAction.nextChapter:
      case ReaderTapZoneAction.none:
        break;
    }
  }

  Widget _buildPage(int index) {
    if (_failedPages.contains(index)) {
      return ColoredBox(
        color: const Color(0xFF1A1A1A),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_rounded,
                color: Colors.white38,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                '图片加载失败',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  _failedPages.remove(index);
                  setState(() => _load(index));
                },
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    return FutureBuilder<Uint8List>(
      future: _load(index),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return const ColoredBox(
            color: Color(0xFF1A1A1A),
            child: Center(
              child: CircularProgressIndicator(color: Colors.white54),
            ),
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stack) {
            _failedPages.add(index);
            return const Icon(Icons.broken_image_rounded, color: Colors.white38);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          return GestureDetector(
            onTapUp: (details) => _handleTap(details.localPosition, size),
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.imageUrls.length,
                  onPageChanged: (index) {
                    if (_currentPage == index) return;
                    setState(() => _currentPage = index);
                    // 预载相邻页。
                    if (index + 1 < widget.imageUrls.length) _load(index + 1);
                    if (index - 1 >= 0) _load(index - 1);
                  },
                  itemBuilder: (context, index) {
                    return Center(
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 6,
                        clipBehavior: Clip.none,
                        panEnabled: _zoomed,
                        scaleEnabled: true,
                        onInteractionStart: (_) {
                          if (!_zoomed) setState(() => _zoomed = true);
                        },
                        onInteractionEnd: (_) {
                          if (_zoomed) setState(() => _zoomed = false);
                        },
                        child: _buildPage(index),
                      ),
                    );
                  },
                ),
                // 页码指示。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x99000000),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '${_currentPage + 1} / ${widget.imageUrls.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}