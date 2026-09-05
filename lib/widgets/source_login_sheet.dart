// 米读：书源登录表单（对标 Legado `SourceLoginDialog`）。
// 底部弹出表单，按 loginUi 动态渲染字段，提交后调用登录服务并校验结果。
import 'dart:async';

import 'package:flutter/material.dart';

import '../book_sources/legado/legado_book_source.dart';
import '../book_sources/legado/legado_runtime.dart';
import '../book_sources/models/registered_book_source.dart';
import '../book_sources/services/book_source_login_service.dart';
import '../utils/localization_extension.dart';

Future<void> showSourceLoginSheet({
  required BuildContext context,
  required LegadoRuntime runtime,
  required RegisteredBookSource source,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  enableDrag: true,
  showDragHandle: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  constraints: BoxConstraints(
    maxWidth: 720,
    maxHeight: MediaQuery.sizeOf(context).height * 0.8,
  ),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (sheetContext) => Padding(
    padding: EdgeInsets.only(
      bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
    ),
    child: SourceLoginSheet(runtime: runtime, source: source),
  ),
);

class SourceLoginSheet extends StatefulWidget {
  const SourceLoginSheet({
    super.key,
    required this.runtime,
    required this.source,
  });

  final LegadoRuntime runtime;
  final RegisteredBookSource source;

  @override
  State<SourceLoginSheet> createState() => _SourceLoginSheetState();
}

class _SourceLoginSheetState extends State<SourceLoginSheet> {
  final BookSourceLoginService _service = const BookSourceLoginService();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _toggleValues = {};
  bool _busy = false;
  String? _resultMessage;
  bool? _lastSuccess;
  late List<BookSourceLoginField> _fields;

  @override
  void initState() {
    super.initState();
    final legado = LegadoBookSource.fromJson(widget.source.sourceConfig!);
    _fields = BookSourceLoginService.parseFields(legado);
    _seedFromSaved();
  }

  Future<void> _seedFromSaved() async {
    final saved = await _service.loadSavedInfo(widget.source.id);
    if (!mounted) return;
    for (final field in _fields) {
      if (field.type == 'toggle') {
        _toggleValues[field.key!] = saved[field.key] ?? field.value ?? 'false';
      } else {
        _controllers[field.key]!.text = saved[field.key] ?? field.value ?? '';
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _resultMessage = null;
    });
    final form = <String, String>{};
    for (final field in _fields) {
      switch (field.type) {
        case 'password':
        case 'text':
        case 'select':
          form[field.key!] = _controllers[field.key]?.text ?? '';
        case 'toggle':
          form[field.key!] = _toggleValues[field.key] ?? 'false';
      }
    }
    final result = await _service.performLogin(
      runtime: widget.runtime,
      registered: widget.source,
      form: form,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastSuccess = result.success;
      _resultMessage = result.message;
    });
    if (result.success) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasHeader = widget.source.name.isNotEmpty;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasHeader)
              Text(
                '${l10n.sourceLoginTitle} · ${widget.source.name}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 16),
            if (_fields.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.sourceLoginNoFields,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            else
              for (final field in _fields) _buildField(context, field),
            if (_resultMessage != null && _lastSuccess == false)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _resultMessage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 18),
            FilledButton(
              key: const ValueKey('source-login-submit'),
              onPressed: _busy ? null : () => unawaited(_submit()),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _fields.isEmpty
                            ? l10n.sourceLoginDone
                            : l10n.sourceLoginSubmit,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(BuildContext context, BookSourceLoginField field) {
    final controller = _controllers[field.key];
    if (field.type == 'toggle') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.name),
        value: _toggleValues[field.key] == 'true',
        onChanged: _busy
            ? null
            : (v) => setState(() => _toggleValues[field.key!] = '$v'),
      );
    }
    if (field.type == 'select') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: controller?.text.isNotEmpty == true
              ? controller!.text
              : (field.options.isNotEmpty ? field.options.first : null),
          decoration: InputDecoration(labelText: field.name),
          items: [
            for (final option in field.options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: _busy ? null : (v) => controller?.text = v ?? '',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: field.password,
        enabled: !_busy,
        decoration: InputDecoration(
          labelText: field.name,
          hintText: field.hint,
        ),
      ),
    );
  }
}
