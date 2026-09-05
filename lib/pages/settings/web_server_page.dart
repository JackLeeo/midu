// 文件说明：Web 管理服务器设置页（对标 Legado Web 服务入口）。
// 技术要点：启停状态卡片 + 端口输入 + 令牌（复制/重新生成）+ 接口文档；
// 服务实例可注入（widget 测试），默认从 Provider 取 WebConsoleService。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/web_server/web_console_service.dart';
import '../../utils/localization_extension.dart';

class WebServerPage extends StatefulWidget {
  const WebServerPage({super.key, this.service});

  final WebConsoleService? service;

  @override
  State<WebServerPage> createState() => _WebServerPageState();
}

class _WebServerPageState extends State<WebServerPage> {
  late final WebConsoleService _service;
  final TextEditingController _portController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? context.read<WebConsoleService>();
    _service.addListener(_onChanged);
    unawaited(_load());
  }

  Future<void> _load() async {
    await _service.restore();
    if (!mounted) return;
    setState(() {
      _portController.text = '${_service.desiredPort}';
    });
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      if (_portController.text != '${_service.desiredPort}') {
        _portController.text = '${_service.desiredPort}';
      }
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    _portController.dispose();
    super.dispose();
  }

  Future<void> _applyPort() async {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null) {
      _portController.text = '${_service.desiredPort}';
      return;
    }
    await _service.setPort(parsed);
  }

  Future<void> _copyToken() async {
    await Clipboard.setData(ClipboardData(text: _service.token));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.webServerCopied)),
    );
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    if (_service.isRunning) {
      await _service.stop();
    } else {
      await _applyPort();
      final ok = await _service.start();
      if (!ok && mounted && _service.lastError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${context.l10n.webServerStartFailed}: ${_service.lastError}')),
        );
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final running = _service.isRunning;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.webServerTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statusCard(scheme, l10n, running),
            const SizedBox(height: 16),
            _portCard(scheme, l10n),
            const SizedBox(height: 16),
            _tokenCard(scheme, l10n),
            const SizedBox(height: 16),
            _endpointCard(scheme, l10n),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('web-server-toggle-button'),
              onPressed: _busy ? null : _toggle,
              icon: Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded),
              label: Text(running ? l10n.webServerStop : l10n.webServerStart),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(
    ColorScheme scheme,
    AppLocalizations l10n,
    bool running,
  ) {
    final error = _service.lastError;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              running ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
              color: running ? scheme.primary : scheme.onSurfaceVariant,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    running ? l10n.webServerStatusRunning : l10n.webServerStatusStopped,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    running ? 'http://127.0.0.1:${_service.port}' : '—',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _portCard(ColorScheme scheme, AppLocalizations l10n) {
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.webServerPortLabel,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('web-server-port-field'),
              controller: _portController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: '18181',
                helperText: l10n.webServerPortHint,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => unawaited(_applyPort()),
              onEditingComplete: () => unawaited(_applyPort()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tokenCard(ColorScheme scheme, AppLocalizations l10n) {
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.webServerTokenLabel,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.webServerTokenHint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _service.token.isEmpty ? '…' : _service.token,
              style: TextStyle(
                fontFamily: 'monospace',
                color: scheme.onSurface,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('web-server-copy-token-button'),
                  onPressed: _service.token.isEmpty ? null : _copyToken,
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(l10n.webServerCopy),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const ValueKey('web-server-regenerate-token-button'),
                  onPressed: () => unawaited(_service.regenerateToken()),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(l10n.webServerRegenerate),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _endpointCard(ColorScheme scheme, AppLocalizations l10n) {
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.webServerEndpointTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.webServerEndpointHint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}