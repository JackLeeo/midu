// 替换净化规则管理页：对标 Legado ReplaceRuleListActivity。
//
// 列出全部替换净化规则（名称/启停/正则开关），支持新增、编辑、删除、上移/
// 下移排布（执行顺序）与一键启停。规则保存在 SharedPreferences，阅读页共享
// [ReplaceRuleService.instance] 在同一份规则链上执行净化。
import 'package:flutter/material.dart';
import 'package:midu/book_sources/services/replace_rule_service.dart';
import 'package:midu/utils/localization_extension.dart';

class ReplaceRulesPage extends StatefulWidget {
  const ReplaceRulesPage({super.key});

  @override
  State<ReplaceRulesPage> createState() => _ReplaceRulesPageState();
}

class _ReplaceRulesPageState extends State<ReplaceRulesPage> {
  final ReplaceRuleService _service = ReplaceRuleService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onRulesChanged);
    // 主动加载一次（幂等），确保列表进入即可展示持久化规则。
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

  Future<void> _openEditor({ReplaceRule? rule}) async {
    final saved = await showDialog<ReplaceRule>(
      context: context,
      builder: (_) => _ReplaceRuleEditorDialog(rule: rule),
    );
    if (saved == null) return;
    if (rule == null) {
      await _service.add(saved);
    } else {
      await _service.update(rule.id, saved);
    }
  }

  Future<void> _confirmRemove(ReplaceRule rule) async {
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
        title: const Text('替换净化'),
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
        key: const Key('replaceRuleAddButton'),
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
                    Icons.auto_fix_high_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '按顺序对任意书源的正文/朗读文本应用替换与删除，常用去广告、'
                      r'去推广段。正则规则支持多行匹配（行锚点 ^ $ 命中整行）与 '
                      r'$1 分组引用；替换为空表示删除匹配内容。',
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
                      Icons.auto_fix_off_rounded,
                      size: 44,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '暂无替换净化规则\n点击右下角「新增规则」开始添加',
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
              for (var i = 0; i < rules.length; i++)
                _buildRuleCard(rules[i], i, rules.length),
          ],
        ),
      ),
    );
  }

  Widget _buildRuleCard(ReplaceRule rule, int index, int total) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          rule.isRegex
                              ? Icons.functions_rounded
                              : Icons.text_fields_rounded,
                          size: 18,
                          color: rule.isRegex ? scheme.primary : scheme.tertiary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
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
                        ),
                      ],
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
                  ],
                ),
              ),
              IconButton(
                tooltip: '上移',
                onPressed: index == 0 ? null : () => _service.move(index, index - 1),
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
              ),
              IconButton(
                tooltip: '下移',
                onPressed: index == total - 1
                    ? null
                    : () => _service.move(index, index + 1),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
              ),
              Switch.adaptive(
                value: rule.enabled,
                onChanged: (value) => _service.setEnabled(rule.id, value),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _openEditor(rule: rule);
                  if (value == 'copy') {
                    _openEditor(
                      rule: ReplaceRule(
                        id: ReplaceRuleService.newId(),
                        name: '${rule.name}（副本）',
                        pattern: rule.pattern,
                        replacement: rule.replacement,
                        isRegex: rule.isRegex,
                        enabled: rule.enabled,
                      ),
                    );
                  }
                  if (value == 'remove') _confirmRemove(rule);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined, size: 18),
                        const SizedBox(width: 8),
                        const Text('编辑'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'copy',
                    child: Row(
                      children: [
                        const Icon(Icons.copy_outlined, size: 18),
                        const SizedBox(width: 8),
                        const Text('复制'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 18,
                            color: scheme.error),
                        const SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: scheme.error)),
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
}

/// 规则编辑对话框：名称 / 匹配模式（正则或字面量）/ 替换文本 / 是否启用。
class _ReplaceRuleEditorDialog extends StatefulWidget {
  const _ReplaceRuleEditorDialog({this.rule});

  final ReplaceRule? rule;

  @override
  State<_ReplaceRuleEditorDialog> createState() =>
      _ReplaceRuleEditorDialogState();
}

class _ReplaceRuleEditorDialogState extends State<_ReplaceRuleEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _patternController;
  late final TextEditingController _replacementController;
  late bool _isRegex;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _patternController = TextEditingController(text: rule?.pattern ?? '');
    _replacementController =
        TextEditingController(text: rule?.replacement ?? '');
    _isRegex = rule?.isRegex ?? true;
    _enabled = rule?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _patternController.dispose();
    _replacementController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pattern = _patternController.text.trim();
    if (pattern.isEmpty) return;
    final rule = ReplaceRule(
      id: widget.rule?.id ?? ReplaceRuleService.newId(),
      name: _nameController.text.trim(),
      pattern: pattern,
      replacement: _replacementController.text,
      isRegex: _isRegex,
      enabled: _enabled,
    );
    // 校验正则合法性，非法时提示而不是静默保存失效规则。
    if (_isRegex) {
      try {
        RegExp(pattern);
      } on FormatException {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正则表达式无效，请检查后重试。')),
        );
        return;
      }
    }
    Navigator.of(context).pop(rule);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.rule == null ? '新增替换净化规则' : '编辑替换净化规则'),
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
                  hintText: '如：去顶部推广段',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('replaceRulePatternField'),
                controller: _patternController,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '匹配内容',
                  hintText: r'正则：^.*广告.*$  或字面量：本站为您提供',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _replacementController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '替换为',
                  hintText: _isRegex ? r'支持 $1 分组引用；留空删除' : '留空删除',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('正则匹配'),
                      subtitle: Text(
                        _isRegex
                            ? r'按正则表达式匹配（多行，行锚点 ^ $ 可用）'
                            : '按普通字符串精确匹配',
                      ),
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
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '效果预览：',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('replaceRuleSaveButton'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}