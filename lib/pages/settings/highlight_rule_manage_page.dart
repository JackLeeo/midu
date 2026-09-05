// 高亮规则管理页：对标 Legado HighlightRuleActivity + HighlightRuleEditDialog。
//
// 列出全部自动高亮规则（名称/匹配模式/作用范围/颜色/启停），支持新增、编辑、
// 删除与一键启停。阅读页渲染时共用 [HighlightRuleService.instance] 把匹配
// 文本自动着色。
import 'package:flutter/material.dart';

import '../../book_sources/services/highlight_rule_service.dart';
import '../../utils/localization_extension.dart';

class HighlightRulesPage extends StatefulWidget {
  const HighlightRulesPage({super.key});

  @override
  State<HighlightRulesPage> createState() => _HighlightRulesPageState();
}

class _HighlightRulesPageState extends State<HighlightRulesPage> {
  final HighlightRuleService _service = HighlightRuleService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onRulesChanged);
    _service.ensureLoaded();
  }

  @override
  void dispose() {
    _service.removeListener(_onRulesChanged);
    super.dispose();
  }

  void _onRulesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor({HighlightRule? rule}) async {
    final saved = await showDialog<HighlightRule>(
      context: context,
      builder: (_) => _HighlightRuleEditorDialog(rule: rule),
    );
    if (saved == null) return;
    if (rule == null) {
      await _service.add(saved);
    } else {
      await _service.update(rule.id, saved);
    }
  }

  Future<void> _confirmRemove(HighlightRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确认删除「${rule.name}」吗？'),
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
    if (confirmed == true) await _service.remove(rule.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rules = _service.rules;
    return Scaffold(
      appBar: AppBar(
        title: const Text('高亮规则'),
        actions: [
          IconButton(
            tooltip: '新增规则',
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('highlightRuleAddButton'),
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('新增规则'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.highlight_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '按规则自动匹配正文/标题文本并着色，用于人名、术语、'
                      '关键词的阅读辅助。规则在阅读页渲染时即时应用，不影响'
                      '已保存的划线笔记。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Column(
                  children: [
                    Icon(
                      Icons.highlight_off_outlined,
                      size: 44,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '暂无高亮规则\n点击右下角「新增规则」开始添加',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final rule in rules) _buildRuleCard(rule),
          ],
        ),
      ),
    );
  }

  Widget _buildRuleCard(HighlightRule rule) {
    final scheme = Theme.of(context).colorScheme;
    final color = _ruleColor(rule.styleHex);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: scheme.outlineVariant),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name.isEmpty ? '（未命名）' : rule.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: rule.enabled
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rule.pattern,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rule.isRegex ? '正则' : '字面'} · '
                      '${rule.applyToBody ? '正文' : ''}'
                      '${rule.applyToBody && rule.applyToTitle ? ' / ' : ''}'
                      '${rule.applyToTitle ? '标题' : ''}',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: rule.enabled,
                onChanged: (value) => _service.setEnabled(rule.id, value),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _openEditor(rule: rule);
                  if (value == 'remove') _confirmRemove(rule);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: const [
                        Icon(Icons.edit_outlined, size: 20),
                        SizedBox(width: 10),
                        Text('编辑'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: const [
                        Icon(Icons.delete_outline_rounded, size: 20),
                        SizedBox(width: 10),
                        Text('删除'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _ruleColor(String hex) {
    var normalized = hex.replaceAll('#', '').trim().toUpperCase();
    if (normalized.length == 8) normalized = normalized.substring(2);
    if (normalized.length != 6) return const Color(0xFFFFEB3B);
    final parsed = int.tryParse(normalized, radix: 16);
    return parsed == null ? const Color(0xFFFFEB3B) : Color(0xFF000000 | parsed);
  }
}

/// 高亮规则编辑对话框：名称 / 匹配模式 / 作用范围 / 颜色 / 启停。
class _HighlightRuleEditorDialog extends StatefulWidget {
  const _HighlightRuleEditorDialog({this.rule});

  final HighlightRule? rule;

  @override
  State<_HighlightRuleEditorDialog> createState() =>
      _HighlightRuleEditorDialogState();
}

class _HighlightRuleEditorDialogState extends State<_HighlightRuleEditorDialog> {
  static const List<Color> _palette = [
    Color(0xFFFFEB3B), // 黄
    Color(0xFFFF9800), // 橙
    Color(0xFF4CAF50), // 绿
    Color(0xFF03A9F4), // 蓝
    Color(0xFFE91E63), // 粉
    Color(0xFF9C27B0), // 紫
    Color(0xFF795548), // 棕
    Color(0xFF607D8B), // 蓝灰
  ];

  late final TextEditingController _nameController;
  late final TextEditingController _patternController;
  late bool _isRegex;
  late bool _applyToBody;
  late bool _applyToTitle;
  late String _styleHex;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _patternController = TextEditingController(text: rule?.pattern ?? '');
    _isRegex = rule?.isRegex ?? true;
    _applyToBody = rule?.applyToBody ?? true;
    _applyToTitle = rule?.applyToTitle ?? true;
    _styleHex = rule?.styleHex ?? 'FFEB3B';
    _enabled = rule?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _patternController.dispose();
    super.dispose();
  }

  void _save() {
    final pattern = _patternController.text.trim();
    if (pattern.isEmpty) return;
    if (_isRegex) {
      try {
        RegExp(pattern);
      } on FormatException {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正则表达式无效，请检查后重试。')),
        );
        return;
      }
    }
    Navigator.of(context).pop(
      HighlightRule(
        id: widget.rule?.id ?? HighlightRuleService.newId(),
        name: _nameController.text.trim(),
        pattern: pattern,
        isRegex: _isRegex,
        applyToBody: _applyToBody,
        applyToTitle: _applyToTitle,
        styleHex: _styleHex,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.rule == null ? '新增高亮规则' : '编辑高亮规则'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '规则名称',
                  hintText: '如：主角名高亮',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('highlightRulePatternField'),
                controller: _patternController,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '匹配内容',
                  hintText: r'正则：李(?:静|默|白)  或字面量：主角',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              Text('高亮颜色', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final color in _palette)
                    InkWell(
                      key: ValueKey(color.toARGB32()),
                      onTap: () => setState(() {
                        _styleHex = _hex(color);
                      }),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _styleHex == _hex(color)
                                ? scheme.primary
                                : scheme.outlineVariant,
                            width: _styleHex == _hex(color) ? 3 : 1,
                          ),
                        ),
                        child: _styleHex == _hex(color)
                            ? const Icon(
                                Icons.check_rounded,
                                size: 18,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('作用于正文'),
                value: _applyToBody,
                onChanged: (value) => setState(() => _applyToBody = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('作用于章节标题'),
                value: _applyToTitle,
                onChanged: (value) => setState(() => _applyToTitle = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('正则匹配'),
                value: _isRegex,
                onChanged: (value) => setState(() => _isRegex = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用该规则'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.bookSourcesCancel),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  static String _hex(Color color) => color
      .toARGB32()
      .toRadixString(16)
      .padLeft(8, '0')
      .substring(2)
      .toUpperCase();
}