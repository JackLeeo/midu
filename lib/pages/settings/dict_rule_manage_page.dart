// 词典规则管理页：对标 Legado DictRuleActivity + DictRuleEditDialog。
//
// 列出全部词典规则（名称/urlRule/showRule/启停），支持新增、编辑、删除、
// 一键启停与「测试查词」（真实请求词典接口并渲染释义）。阅读页长按选词后
// 共用 [DictRuleService.instance] 的同一份规则执行查词。
import 'package:flutter/material.dart';

import '../../book_sources/services/dict_rule_service.dart';
import '../../utils/localization_extension.dart';

class DictRulesPage extends StatefulWidget {
  const DictRulesPage({super.key});

  @override
  State<DictRulesPage> createState() => _DictRulesPageState();
}

class _DictRulesPageState extends State<DictRulesPage> {
  final DictRuleService _service = DictRuleService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onRulesChanged);
    _service.ensureLoaded();
  }

  @override
  void dispose() {
    _service.removeListener(_onRulesChanged);
    _service.closeEngine();
    super.dispose();
  }

  void _onRulesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor({DictRule? rule}) async {
    final saved = await showDialog<DictRule>(
      context: context,
      builder: (_) => _DictRuleEditorDialog(rule: rule),
    );
    if (saved == null) return;
    if (rule == null) {
      await _service.add(saved);
    } else {
      await _service.update(rule.id, saved);
    }
  }

  Future<void> _confirmRemove(DictRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除词典'),
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

  Future<void> _testLookup() async {
    final controller = TextEditingController();
    final word = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('测试查词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '输入单词/词语',
            hintText: '如：book',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.bookSourcesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('查词'),
          ),
        ],
      ),
    );
    if (word == null || word.isEmpty || !mounted) return;
    final active = _service.enabledRules;
    if (active.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有启用的词典规则，请先新增并启用。')),
      );
      return;
    }
    await showDictLookupSheet(context, word: word, ruleIds: null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rules = _service.rules;
    return Scaffold(
      appBar: AppBar(
        title: const Text('词典规则'),
        actions: [
          IconButton(
            tooltip: '测试查词',
            onPressed: rules.any((r) => r.enabled) ? _testLookup : null,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '新增词典',
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('dictRuleAddButton'),
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('新增词典'),
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
                    Icons.menu_book_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '阅读时长按选择文本调起词典查询：urlRule 为词典接口模板'
                      r'（{{key}} 替换词条），showRule 为释义抽取规则（选择器 / '
                      'JSONPath / @js:，&& 分隔多条）。',
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
                      Icons.menu_book_outlined,
                      size: 44,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '暂无词典规则\n点击右下角「新增词典」开始添加',
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

  Widget _buildRuleCard(DictRule rule) {
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
                          Icons.menu_book_rounded,
                          size: 18,
                          color: scheme.primary,
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
                      'url: ${rule.urlRule}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (rule.showRule.trim().isNotEmpty)
                      Text(
                        'show: ${rule.showRule}',
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
              Switch.adaptive(
                value: rule.enabled,
                onChanged: (value) => _service.setEnabled(rule.id, value),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _openEditor(rule: rule);
                  if (value == 'test') {
                    showDictLookupSheet(
                      context,
                      word: 'book',
                      ruleIds: [rule.id],
                    );
                  }
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
                    value: 'test',
                    child: Row(
                      children: const [
                        Icon(Icons.search_rounded, size: 20),
                        SizedBox(width: 10),
                        Text('测试'),
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
}

/// 词典规则编辑对话框：名称 / urlRule / showRule / 是否启用。
class _DictRuleEditorDialog extends StatefulWidget {
  const _DictRuleEditorDialog({this.rule});

  final DictRule? rule;

  @override
  State<_DictRuleEditorDialog> createState() => _DictRuleEditorDialogState();
}

class _DictRuleEditorDialogState extends State<_DictRuleEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlRuleController;
  late final TextEditingController _showRuleController;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _urlRuleController = TextEditingController(text: rule?.urlRule ?? '');
    _showRuleController = TextEditingController(text: rule?.showRule ?? '');
    _enabled = rule?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlRuleController.dispose();
    _showRuleController.dispose();
    super.dispose();
  }

  void _save() {
    final urlRule = _urlRuleController.text.trim();
    if (urlRule.isEmpty) return;
    Navigator.of(context).pop(
      DictRule(
        id: widget.rule?.id ?? DictRuleService.newId(),
        name: _nameController.text.trim(),
        urlRule: urlRule,
        showRule: _showRuleController.text.trim(),
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.rule == null ? '新增词典规则' : '编辑词典规则'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '词典名称',
                  hintText: '如：百度汉语',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('dictRuleUrlField'),
                controller: _urlRuleController,
                maxLines: 2,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: '请求规则 (urlRule)',
                  hintText: r'https://hanyu.baidu.com/s?wd={{key}}',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _showRuleController,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '解析规则 (showRule)',
                  hintText: r'如：.content@text  或 @js: JSON.parse(result).data',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用该词典'),
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
}

/// 弹出查词结果底部面板（供阅读页长按选词与设置页测试共用）。
Future<void> showDictLookupSheet(
  BuildContext context, {
  required String word,
  List<String>? ruleIds,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    constraints: BoxConstraints(
      maxWidth: 720,
      maxHeight: MediaQuery.sizeOf(context).height * 0.75,
    ),
    builder: (_) => DictLookupSheet(word: word, ruleIds: ruleIds),
  );
}

/// 查词结果面板：展示词条、全部启用规则的结果（支持切换规则）。
/// [ruleIds] 非空时仅查询指定规则；为空时查询全部启用规则。
class DictLookupSheet extends StatefulWidget {
  const DictLookupSheet({super.key, required this.word, this.ruleIds});

  final String word;
  final List<String>? ruleIds;

  @override
  State<DictLookupSheet> createState() => _DictLookupSheetState();
}

class _DictLookupSheetState extends State<DictLookupSheet> {
  final DictRuleService _service = DictRuleService.instance;
  bool _loading = false;
  String? _error;
  int? _selectedIndex;
  List<DictRule>? _rules;
  List<DictLookupResult> _results = const [];
  final Map<String, bool> _loadedForRule = {};

  @override
  void initState() {
    super.initState();
    _rules = widget.ruleIds == null
        ? _service.enabledRules
        : [
            for (final id in widget.ruleIds!)
              if (_service.rules.any((r) => r.id == id))
                _service.rules.firstWhere((r) => r.id == id),
          ];
    _selectedIndex = _rules!.isEmpty ? null : 0;
    _search();
  }

  Future<void> _search() async {
    final rules = _rules;
    if (rules == null || rules.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = List.filled(rules.length, DictLookupResult(word: widget.word, entries: const []));
    });
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      if (_loadedForRule[rule.id] == true) continue;
      try {
        final result = await _service.lookup(widget.word, rule);
        if (!mounted) return;
        _loadedForRule[rule.id] = true;
        setState(() {
          _results[i] = result;
        });
      } catch (error) {
        if (!mounted) return;
        _loadedForRule[rule.id] = true;
        setState(() {
          _error = '$error';
          _results[i] = DictLookupResult(word: widget.word, entries: const []);
        });
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final rules = _rules ?? const <DictRule>[];
    final index = _selectedIndex ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.word,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          if (rules.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < rules.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          rules[i].name.isEmpty ? '词典 ${i + 1}' : rules[i].name,
                        ),
                        selected: i == index,
                        onSelected: rules[i].enabled
                            ? (_) => setState(() => _selectedIndex = i)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Expanded(child: _buildResult(index)),
        ],
      ),
    );
  }

  Widget _buildResult(int index) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading && index >= _results.length) {
      return const Center(child: CircularProgressIndicator());
    }
    final result = index < _results.length ? _results[index] : null;
    if (_error != null && (result == null || result.isEmpty)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
        ),
      );
    }
    if (result == null || (result.isEmpty && _loading)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (result.isEmpty) {
      return Center(
        child: Text(
          '未查到释义',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final lines = result.rawPreview.trim().isNotEmpty
        ? [result.rawPreview]
        : result.entries;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SelectableText(
                lines[i],
                style: const TextStyle(height: 1.6),
              ),
            ),
        ],
      ),
    );
  }
}