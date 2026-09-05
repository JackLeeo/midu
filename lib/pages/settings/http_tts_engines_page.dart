// HTTP TTS 引擎（在线朗读）管理页：对标 Legado HttpTtsEditDialog + SpeakEngineDialog。
//
// 列出全部引擎（名称/URL/Content-Type/段落停顿/启停开关），支持新增、编辑、
// 删除、选中为当前朗读引擎与「测试合成」（真实请求音频接口）。配置字段与
// Legado HttpTTS 表一致：name/url/contentType/pauseDuration/concurrentRate/
// loginUrl/loginUi/header/jsLib/enabledCookieJar/loginCheckJs。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/http_tts_engine_service.dart';
import '../../widgets/code_editor_field.dart';
import '../../utils/localization_extension.dart';

class HttpTtsEnginesPage extends StatefulWidget {
  const HttpTtsEnginesPage({super.key});

  @override
  State<HttpTtsEnginesPage> createState() => _HttpTtsEnginesPageState();
}

class _HttpTtsEnginesPageState extends State<HttpTtsEnginesPage> {
  final HttpTtsEngineService _service = HttpTtsEngineService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    _service.ensureLoaded();
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor({HttpTtsEngine? engine}) async {
    final saved = await showDialog<HttpTtsEngine>(
      context: context,
      builder: (_) => _HttpTtsEngineEditorDialog(engine: engine),
    );
    if (saved == null) return;
    await _service.ensureLoaded();
    if (engine == null) {
      await _service.add(saved);
    } else {
      await _service.update(engine.id, saved);
    }
  }

  Future<void> _confirmRemove(HttpTtsEngine engine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除语音引擎'),
        content: Text('确认删除「${engine.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.bookSourcesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.bookSourcesConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) await _service.remove(engine.id);
  }

  Future<void> _testEngine(HttpTtsEngine engine) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HttpTtsTestDialog(engine: engine),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final engines = _service.engines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音引擎 (HTTP TTS)'),
        actions: [
          IconButton(
            tooltip: '新增引擎',
            onPressed: () => unawaited(_openEditor()),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: engines.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.record_voice_over_outlined,
                      size: 56,
                      color: scheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '尚未配置 HTTP TTS 引擎\n新增一个引擎即可在朗读面板中使用在线朗读',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => unawaited(_openEditor()),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('新增引擎'),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: engines.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final engine = engines[index];
                final active = engine.id == _service.activeEngineId;
                return Card(
                  elevation: 0,
                  color: active
                      ? scheme.primaryContainer.withValues(alpha: 0.45)
                      : scheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: active ? scheme.primary : scheme.outlineVariant,
                      width: active ? 1.2 : 1,
                    ),
                  ),
                  child: ListTile(
                    leading: Radio<String?>(
                      value: engine.id,
                      groupValue: _service.activeEngineId,
                      onChanged: (id) => unawaited(_service.setActive(id)),
                    ),
                    title: Text(
                      engine.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      _subtitle(engine),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '测试合成',
                          icon: const Icon(Icons.play_arrow_rounded, size: 22),
                          onPressed: () => unawaited(_testEngine(engine)),
                        ),
                        IconButton(
                          tooltip: '编辑',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => unawaited(
                            _openEditor(engine: engine),
                          ),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 20,
                            color: scheme.error,
                          ),
                          onPressed: () => unawaited(_confirmRemove(engine)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _subtitle(HttpTtsEngine engine) {
    final lines = <String>[
      engine.url.trim().isEmpty ? '（未配置 URL）' : engine.url.trim(),
      if (engine.contentType?.trim().isNotEmpty == true)
        'Content-Type: ${engine.contentType!.trim()}',
      if (engine.pauseDuration > 0) '段落停顿 ${engine.pauseDuration}ms',
      if (engine.enabledCookieJar) '启用 Cookie 登录',
    ];
    return lines.join(' · ');
  }
}

/// 语法测试对话框：自执行一次音频合成请求并展示结果。
class _HttpTtsTestDialog extends StatefulWidget {
  const _HttpTtsTestDialog({required this.engine});

  final HttpTtsEngine engine;

  @override
  State<_HttpTtsTestDialog> createState() => _HttpTtsTestDialogState();
}

class _HttpTtsTestDialogState extends State<_HttpTtsTestDialog> {
  final HttpTtsAudioFetcher _fetcher = HttpTtsAudioFetcher();
  bool _running = true;
  String? _resultText;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _fetcher.close();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _resultText = null;
    });
    try {
      final audio = await _fetcher.fetchAudio(
        engine: widget.engine,
        text: '测试语音合成',
        rate: 0.5,
      );
      if (!mounted) return;
      final contentType = widget.engine.contentType?.trim();
      setState(() {
        _success = true;
        _running = false;
        _resultText =
            '成功获取 ${(audio.length / 1024).toStringAsFixed(1)} KB 音频数据'
            '${contentType == null || contentType.isEmpty ? '' : '\nContent-Type: $contentType'}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _success = false;
        _running = false;
        _resultText = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('测试语音合成'),
      content: SizedBox(
        width: 420,
        child: _running
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                  SizedBox(width: 14),
                  Text('正在请求「测试语音合成」音频…'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _success
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        color: _success
                            ? Colors.green.shade600
                            : Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _success ? '合成成功' : '合成失败',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(_resultText ?? '', style: const TextStyle(height: 1.5)),
                ],
              ),
      ),
      actions: [
        if (!_running) ...[
          TextButton(
            onPressed: () => unawaited(_run()),
            child: const Text('重试'),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.bookSourcesConfirm),
        ),
      ],
    );
  }
}

/// 引擎编辑对话框：字段与 Legado HttpTtsEditDialog 一致。
class _HttpTtsEngineEditorDialog extends StatefulWidget {
  const _HttpTtsEngineEditorDialog({this.engine});

  final HttpTtsEngine? engine;

  @override
  State<_HttpTtsEngineEditorDialog> createState() =>
      _HttpTtsEngineEditorDialogState();
}

class _HttpTtsEngineEditorDialogState extends State<_HttpTtsEngineEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _contentType;
  late final TextEditingController _pauseDuration;
  late final TextEditingController _loginUrl;
  late final TextEditingController _loginUi;
  late final TextEditingController _header;
  late final TextEditingController _jsLib;
  late final TextEditingController _loginCheckJs;
  bool _enabledCookieJar = false;

  @override
  void initState() {
    super.initState();
    final engine = widget.engine;
    _name = TextEditingController(text: engine?.name ?? '');
    _url = TextEditingController(text: engine?.url ?? '');
    _contentType = TextEditingController(text: engine?.contentType ?? '');
    _pauseDuration = TextEditingController(
      text: engine?.pauseDuration == null || engine!.pauseDuration == 0
          ? ''
          : '${engine.pauseDuration}',
    );
    _loginUrl = TextEditingController(text: engine?.loginUrl ?? '');
    _loginUi = TextEditingController(text: engine?.loginUi ?? '');
    _header = TextEditingController(text: engine?.header ?? '');
    _jsLib = TextEditingController(text: engine?.jsLib ?? '');
    _loginCheckJs = TextEditingController(text: engine?.loginCheckJs ?? '');
    _enabledCookieJar = engine?.enabledCookieJar ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _contentType.dispose();
    _pauseDuration.dispose();
    _loginUrl.dispose();
    _loginUi.dispose();
    _header.dispose();
    _jsLib.dispose();
    _loginCheckJs.dispose();
    super.dispose();
  }

  HttpTtsEngine _buildEngine() {
    final existing = widget.engine;
    return HttpTtsEngine(
      id: existing?.id ?? HttpTtsEngineService.newId(),
      name: _name.text.trim(),
      url: _url.text.trim(),
      contentType: _contentType.text.trim().isEmpty
          ? null
          : _contentType.text.trim(),
      pauseDuration:
          int.tryParse(_pauseDuration.text.trim())?.clamp(0, 10000) ?? 0,
      concurrentRate: existing?.concurrentRate ?? '0',
      loginUrl: _loginUrl.text.trim().isEmpty ? null : _loginUrl.text.trim(),
      loginUi: _loginUi.text.trim().isEmpty ? null : _loginUi.text.trim(),
      header: _header.text.trim().isEmpty ? null : _header.text.trim(),
      jsLib: _jsLib.text.trim().isEmpty ? null : _jsLib.text.trim(),
      enabledCookieJar: _enabledCookieJar,
      loginCheckJs: _loginCheckJs.text.trim().isEmpty
          ? null
          : _loginCheckJs.text.trim(),
      lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _editCode(String field) async {
    final controller = _controllerFor(field);
    final result = await showJsCodeEditor(
      context: context,
      title: '编辑 ${_fieldLabel(field)}',
      initialCode: controller.text,
      variableGroups: kHttpTtsVariableGroups,
    );
    if (result == null) return;
    controller.text = result;
    setState(() {});
  }

  Future<void> _testCurrent() async {
    final engine = _buildEngine();
    if (engine.url.trim().isEmpty) {
      _toast('请先填写引擎 URL');
      return;
    }
    final fetcher = HttpTtsAudioFetcher();
    try {
      final audio = await fetcher.fetchAudio(
        engine: engine,
        text: '测试语音合成',
        rate: 0.5,
      );
      if (!mounted) return;
      _toast('合成成功：${(audio.length / 1024).toStringAsFixed(1)} KB');
    } catch (error) {
      if (!mounted) return;
      _toast('合成失败：$error');
    } finally {
      fetcher.close();
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  TextEditingController _controllerFor(String field) => switch (field) {
        'url' => _url,
        'loginUrl' => _loginUrl,
        'loginUi' => _loginUi,
        'header' => _header,
        'jsLib' => _jsLib,
        'loginCheckJs' => _loginCheckJs,
        _ => _url,
      };

  String _fieldLabel(String field) => switch (field) {
        'url' => '请求 URL',
        'loginUrl' => '登录 URL',
        'loginUi' => '登录 UI',
        'header' => '请求头',
        'jsLib' => 'JS 库',
        'loginCheckJs' => '登录检查 JS',
        _ => field,
      };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.engine == null ? '新增语音引擎' : '编辑语音引擎'),
      scrollable: true,
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _textField(_name, '名称', hint: '如：Edge 在线语音'),
            const SizedBox(height: 10),
            _fieldWithCode(
              _url,
              '请求 URL 模板',
              hint: 'https://api.example.com/tts?text={{speakText}}&speed={{speakSpeed}}',
              field: 'url',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _textField(
                    _contentType,
                    'Content-Type 正则',
                    hint: 'audio/mpeg（留空不校验）',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _textField(
                    _pauseDuration,
                    '段落停顿 (ms)',
                    hint: '0-10000',
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _fieldWithCode(
              _header,
              '请求头',
              hint: '{"Authorization":"Bearer XXX"} 或 键: 值 每行一条',
              field: 'header',
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用会话 Cookie（登录确认）'),
              subtitle: const Text('开启后先请求登录 URL 建立会话再合成音频'),
              value: _enabledCookieJar,
              onChanged: (value) => setState(() => _enabledCookieJar = value),
            ),
            if (_enabledCookieJar) ...[
              const SizedBox(height: 4),
              _fieldWithCode(
                _loginUrl,
                '登录 URL',
                hint: 'https://api.example.com/login',
                field: 'loginUrl',
              ),
              const SizedBox(height: 10),
              _fieldWithCode(
                _loginCheckJs,
                '登录检查 JS',
                hint: 'response.code == 500 ? "500" : ""（返回 500 视为登录失败）',
                field: 'loginCheckJs',
              ),
            ],
            const SizedBox(height: 10),
            _fieldWithCode(
              _jsLib,
              'JS 库（可选）',
              hint: '合成前预加载的公共脚本',
              field: 'jsLib',
            ),
            const SizedBox(height: 10),
            _fieldWithCode(
              _loginUi,
              '登录 UI（JSON，保留）',
              hint: '第三方登录表单描述（仅存留）',
              field: 'loginUi',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _testCurrent,
          child: const Text('测试合成'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.bookSourcesCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _buildEngine()),
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboardType,
  }) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    maxLines: keyboardType == TextInputType.number ? 1 : null,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _fieldWithCode(
    TextEditingController controller,
    String label, {
    String? hint,
    required String field,
  }) => TextField(
    controller: controller,
    maxLines: 2,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
      suffixIcon: IconButton(
        tooltip: '代码编辑器',
        icon: const Icon(Icons.code_rounded, size: 20),
        onPressed: () => unawaited(_editCode(field)),
      ),
    ),
  );
}

/// 语音引擎字段可插入的 Legado 变量分组。
const List<JsVariableGroup> kHttpTtsVariableGroups = [
  JsVariableGroup('朗读变量', [
    JsVariableItem('朗读文本', '{{speakText}}', '当前段落文本（URL 百分号编码）'),
    JsVariableItem('语速', '{{speakSpeed}}', '语速整数（0.1 → 6，1.0 → 15）'),
  ]),
  JsVariableGroup('URL/请求变量', [
    JsVariableItem('基础地址', '{{baseUrl}}', '当前引擎根地址'),
    JsVariableItem('来源URL', '{{sourceUrl}}', '引擎 URL 根地址'),
    JsVariableItem('请求体变量', '{{form}}', '表单键值对 JSON'),
  ]),
  JsVariableGroup('存储变量', [
    JsVariableItem('写入变量', '@put:{name:value}', '保存到引擎变量空间'),
    JsVariableItem('读取变量', '@get:{name}', '读取已存变量'),
  ]),
  JsVariableGroup('JS 片段', [
    JsVariableItem('JS 规则', '@js:', '执行 JS 规则并返回结果'),
    JsVariableItem('JS 块', '<js>...</js>', '内嵌 JS 代码块'),
  ]),
];