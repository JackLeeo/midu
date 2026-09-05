// 内置浏览器页：对标 Legado WebViewActivity。
//
// 提供地址栏、前进/后退/刷新与「读取页面」——用 JS 回读 `document.outerHTML`
// 并通过 `Navigator.pop<String>` 返回给调用方（书源规则/书源编辑器「浏览器打开」
// 场景）。仅 Android/iOS 具备真实 WebView 运行时；其余平台显示明确的降级提示
// （复用 webview_guard 的条件导出，Web 目标不会 import dart:io）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/webview_guard/webview_platform.dart';

/// 打开内置浏览器。`initialUrl` 非空时自动加载；返回读取到的页面 HTML
/// （用户点了「读取页面」时）或 null（未读取直接返回）。
Future<String?> showInAppBrowser({
  required BuildContext context,
  String title = '内置浏览器',
  String? initialUrl,
}) async {
  final html = await Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => InAppBrowserPage(
        title: title,
        initialUrl: initialUrl,
      ),
    ),
  );
  return html;
}

class InAppBrowserPage extends StatefulWidget {
  const InAppBrowserPage({
    super.key,
    this.title = '内置浏览器',
    this.initialUrl,
  });

  final String title;
  final String? initialUrl;

  @override
  State<InAppBrowserPage> createState() => _InAppBrowserPageState();
}

class _InAppBrowserPageState extends State<InAppBrowserPage> {
  final TextEditingController _urlController = TextEditingController();
  WebViewController? _controller;
  String _currentUrl = '';
  String? _pageTitle;
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _loadError;

  bool get _webViewSupported => platformSupportsWebView();

  @override
  void initState() {
    super.initState();
    unawaited(_initWebView());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _initWebView() async {
    if (!_webViewSupported) return;
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(Colors.white);
    _controller = controller;
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() {
            _loading = true;
            _currentUrl = url;
            _loadError = null;
          });
        },
        onPageFinished: (url) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _currentUrl = url;
            _loadError = null;
          });
          unawaited(_syncNavigationState());
          unawaited(_syncPageTitle());
        },
        onWebResourceError: (error) {
          if (!mounted) return;
          _loadError = '页面加载失败：${error.errorCode}';
        },
      ),
    );
    if (!mounted) return;
    setState(() {});
    final initial = (widget.initialUrl ?? _urlController.text).trim();
    if (initial.isNotEmpty) {
      await _load(initial);
    }
  }

  Future<void> _syncNavigationState() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final canGoBack = await controller.canGoBack();
    final canGoForward = await controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
  }

  Future<void> _syncPageTitle() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    try {
      final result = await controller.runJavaScriptReturningResult(
        'document.title',
      );
      final title = result is String ? result.trim() : '';
      if (!mounted) return;
      if (title.isNotEmpty) {
        setState(() => _pageTitle = title);
      }
    } catch (_) {
      // 标题读取失败不影响浏览
    }
  }

  Uri? _normalizedUri(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    var text = trimmed;
    if (!text.contains('://') && !text.startsWith('about:')) {
      text = 'https://$text';
    }
    return Uri.tryParse(text);
  }

  Future<void> _load(String input) async {
    final controller = _controller;
    final uri = _normalizedUri(input);
    if (controller == null || uri == null) {
      if (!mounted) return;
      setState(() => _loadError = '地址无效');
      return;
    }
    _urlController.text = uri.toString();
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await controller.loadRequest(uri);
  }

  /// 读取当前页面 HTML 并通过 pop 返回（对标 WebViewActivity 的「回读页面」）。
  Future<void> _readPageAndReturn() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final result = await controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      final html = result is String ? result : result.toString();
      if (!mounted) return;
      Navigator.of(context).pop(html);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = '读取页面内容失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_webViewSupported) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.public_off_outlined, size: 56, color: scheme.outline),
                const SizedBox(height: 16),
                Text(
                  '当前平台不支持内置浏览器（仅 Android / iOS 可用）',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_pageTitle ?? widget.title),
        actions: [
          IconButton(
            tooltip: '读取页面并返回',
            icon: const Icon(Icons.assignment_return_outlined),
            onPressed: _loading ? null : () => unawaited(_readPageAndReturn()),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _urlController,
              textInputAction: TextInputAction.go,
              onSubmitted: (value) => unawaited(_load(value)),
              decoration: InputDecoration(
                hintText: '输入网址',
                prefixIcon: const Icon(Icons.link_rounded, size: 20),
                suffixIcon: IconButton(
                  tooltip: '跳转',
                  icon: _loading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded),
                  onPressed: () => unawaited(_load(_urlController.text)),
                ),
                isDense: true,
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_controller != null)
            WebViewWidget(controller: _controller!)
          else
            const Center(child: CircularProgressIndicator()),
          if (_loadError != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Material(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 18,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _loadError!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _webViewSupported
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: '后退',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _canGoBack
                          ? () => unawaited(_controller?.goBack())
                          : null,
                    ),
                    IconButton(
                      tooltip: '前进',
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: _canGoForward
                          ? () => unawaited(_controller?.goForward())
                          : null,
                    ),
                    IconButton(
                      tooltip: '刷新',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: _loading
                          ? null
                          : () => unawaited(_controller?.reload()),
                    ),
                    IconButton(
                      tooltip: '打开主页',
                      icon: const Icon(Icons.home_outlined),
                      onPressed: _currentUrl.isNotEmpty
                          ? () => unawaited(_load(_currentUrl))
                          : null,
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}