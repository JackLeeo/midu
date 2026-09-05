// 文件说明：书源可视化编辑页（对标 Legado BookSourceEditActivity）。
// 技术要点：把一条 Legado 书源 JSON 拆成「源信息 / 搜索 / 发现 / 详情 / 目录 /
// 正文 / 其他」七个 tab 表单化编辑；规则字段用多行文本框，保存时整体回写
// raw JSON 并经 LegadoBookSource.fromJson 强校验，保证非规则字段（weight/
// header/jsLib 等）也一并保留。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../book_sources/legado/legado_book_source.dart';
import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_registry.dart';
import '../../pages/browser/browser_page.dart';
import '../../widgets/code_editor_field.dart';
import '../../widgets/side_toast.dart';

/// 书源编辑页：接收一个已注册源（或新建模板），按 tab 编辑后调
/// [BookSourceRegistry.updateSourceConfig] 持久化。
class BookSourceEditPage extends StatefulWidget {
  const BookSourceEditPage({
    super.key,
    this.source,
    this.initialRaw,
  }) : assert(source != null || initialRaw != null,
            'Either a registered source or raw JSON is required');

  /// 已注册书源（编辑模式）。
  final RegisteredBookSource? source;

  /// 新建模式的初始原始 JSON（应为 Legado 书源对象）。
  final Map<String, dynamic>? initialRaw;

  @override
  State<BookSourceEditPage> createState() => _BookSourceEditPageState();
}

class _BookSourceEditPageState extends State<BookSourceEditPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final BookSourceRegistry _registry = BookSourceRegistry();

  late Map<String, dynamic> _raw;
  late final _EditSession _session;

  @override
  void initState() {
    super.initState();
    _raw = widget.initialRaw != null
        ? Map<String, dynamic>.from(widget.initialRaw!)
        : _rawFromRegistered(widget.source!);
    _session = _EditSession.fromRaw(_raw);
    _tabController = TabController(
      length: _EditTab.values.length,
      vsync: this,
    );
  }

  Map<String, dynamic> _rawFromRegistered(RegisteredBookSource source) {
    final config = source.sourceConfig ?? const <String, dynamic>{};
    // 若 sourceConfig 已直接携带 Legado 原始字段，用它；否则用最小模板。
    if (config.containsKey('bookSourceUrl')) {
      return Map<String, dynamic>.from(config);
    }
    return {
      'bookSourceUrl': source.apiBaseUrl.toString(),
      'bookSourceName': source.name,
      'bookSourceGroup': '',
      'bookSourceComment': source.description,
    };
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final nextRaw = _session.toRaw();
    Navigator.of(context).pop(true);
    try {
      if (widget.source != null) {
        await _registry.updateSourceConfig(widget.source!, nextRaw);
      } else {
        // 新建：以兼容源形式注册（capabilities 由 toRegisteredSource 推导）。
        var source = LegadoBookSource.fromJson(nextRaw);
        var registered = source.toRegisteredSource(enabled: true);
        await _registry.upsert(registered);
      }
      if (mounted) {
        SideToast.show(
          context,
          '书源「${_session.name}」已保存',
          kind: SideToastKind.success,
        );
      }
    } catch (error) {
      if (mounted) {
        SideToast.show(
          context,
          '保存失败：$error',
          kind: SideToastKind.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source != null ? '编辑书源' : '新建书源'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: _EditTab.values
              .map((tab) => Tab(text: tab.label))
              .toList(growable: false),
        ),
        actions: [
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          for (final tab in _EditTab.values)
            _EditTabView(tab: tab, session: _session),
        ],
      ),
    );
  }
}

/// 编辑会话：持有可变 raw 的字段读写，供七个 tab 共同编辑。
class _EditSession {
  _EditSession.fromRaw(Map<String, dynamic> raw) : _raw = raw {
    // 规则字段展开为独立可编辑项。
    for (final ruleField in _ruleFields) {
      final value = _raw[ruleField];
      if (value is Map && value.isNotEmpty) {
        _ruleMap[ruleField] = Map<String, String>.from(
          value.map((key, value) => MapEntry('$key', '$value')),
        );
      } else if (value is String && value.isNotEmpty) {
        _ruleMap[ruleField] = {'': value};
      }
    }
  }

  static const _ruleFields = [
    'ruleSearch',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
    'ruleExplore',
    'ruleRss',
    'ruleImage',
    'ruleThink',
  ];

  final Map<String, dynamic> _raw;
  final Map<String, Map<String, String>> _ruleMap = {};

  String get name => _str('bookSourceName');
  String get group => _str('bookSourceGroup');
  String get url => _str('bookSourceUrl');

  String _str(String key) {
    final value = _raw[key];
    return value is String ? value : '';
  }

  void setStr(String key, String value) {
    _raw[key] = value;
  }

  void addRulePair(String field, String key, String value) {
    _ruleMap.putIfAbsent(field, () => {});
    _ruleMap[field]![key] = value;
  }

  void removeRulePair(String field, String key) {
    _ruleMap[field]?.remove(key);
  }

  String ruleValue(String field) {
    final pairs = _ruleMap[field];
    if (pairs == null || pairs.isEmpty) return '';
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('&&');
  }

  List<MapEntry<String, String>> rulePairs(String field) =>
      _ruleMap[field]?.entries.toList() ?? const [];

  Map<String, dynamic> toRaw() {
    final result = Map<String, dynamic>.from(_raw);
    for (final field in _ruleFields) {
      final pairs = _ruleMap[field];
      if (pairs == null || pairs.isEmpty) continue;
      result[field] = pairs.entries
          .map((e) => '${e.key}=${e.value}')
          .join('&&');
    }
    return result;
  }
}

enum _EditTab {
  info('源信息'),
  search('搜索'),
  explore('发现'),
  detail('详情'),
  toc('目录'),
  content('正文'),
  other('其他');

  final String label;
  const _EditTab(this.label);
}

class _EditTabView extends StatefulWidget {
  const _EditTabView({required this.tab, required this.session});

  final _EditTab tab;
  final _EditSession session;

  @override
  State<_EditTabView> createState() => _EditTabViewState();
}

class _EditTabViewState extends State<_EditTabView> {
  _EditTab get tab => widget.tab;
  _EditSession get session => widget.session;
  String get _field => _fieldForTab(tab);

  static String _fieldForTab(_EditTab tab) => switch (tab) {
    _EditTab.search => 'ruleSearch',
    _EditTab.explore => 'ruleExplore',
    _EditTab.detail => 'ruleBookInfo',
    _EditTab.toc => 'ruleToc',
    _EditTab.content => 'ruleContent',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: switch (tab) {
        _EditTab.info => _buildInfoFields(context),
        _EditTab.search => _buildRuleFields(_field),
        _EditTab.explore => _buildRuleFields(_field),
        _EditTab.detail => _buildRuleFields(_field),
        _EditTab.toc => _buildRuleFields(_field),
        _EditTab.content => _buildRuleFields(_field),
        _EditTab.other => _buildOtherFields(context),
      },
    );
  }

  List<Widget> _buildInfoFields(BuildContext context) {
    return [
      _TextRow(
        title: '书源名称',
        hint: 'bookSourceName',
        value: session.name,
        onChanged: (value) => session.setStr('bookSourceName', value),
      ),
      _TextRow(
        title: '站点地址',
        hint: 'https://example.com',
        value: session.url,
        onChanged: (value) => session.setStr('bookSourceUrl', value),
        actions: [
          IconButton(
            tooltip: '内置浏览器打开',
            icon: const Icon(Icons.public_rounded, size: 20),
            onPressed: () {
              final url = session.url.trim();
              if (url.isEmpty) return;
              unawaited(
                showInAppBrowser(
                  context: context,
                  title: '站点：${session.name}',
                  initialUrl: url,
                ),
              );
            },
          ),
        ],
      ),
      _TextRow(
        title: '分组',
        hint: '默认',
        value: session.group,
        onChanged: (value) => session.setStr('bookSourceGroup', value),
      ),
      _TextRow(
        title: '备注',
        hint: 'bookSourceComment',
        value: session._str('bookSourceComment'),
        onChanged: (value) => session.setStr('bookSourceComment', value),
      ),
      _TextRow(
        title: '权重',
        hint: '0',
        value: session._str('weight'),
        onChanged: (value) => session.setStr('weight', value),
      ),
      _TextRow(
        title: '自定义请求头 (JSON)',
        hint: '{"User-Agent": "..."}',
        value: session._str('header'),
        onChanged: (value) => session.setStr('header', value),
      ),
      _TextRow(
        title: '登录 URL',
        hint: 'loginUrl',
        value: session._str('loginUrl'),
        onChanged: (value) => session.setStr('loginUrl', value),
      ),
      _TextRow(
        title: '登录校验 JS',
        hint: 'loginCheckJs',
        value: session._str('loginCheckJs'),
        onChanged: (value) => session.setStr('loginCheckJs', value),
        actions: [
          _JsFieldActions(
            field: 'loginCheckJs',
            session: session,
            rebuild: () => setState(() {}),
          ),
        ],
      ),
      _TextRow(
        title: 'JS 库',
        hint: 'jsLib',
        value: session._str('jsLib'),
        onChanged: (value) => session.setStr('jsLib', value),
        actions: [
          _JsFieldActions(
            field: 'jsLib',
            session: session,
            rebuild: () => setState(() {}),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildRuleFields(String field) {
    final pairs = session.rulePairs(field);
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          _fieldHint(field),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ),
      for (final pair in pairs)
        _RulePairTile(
          field: field,
          pair: pair,
          session: session,
        ),
      if (pairs.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            '（空规则）',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _addRulePair,
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加规则片段'),
      ),
    ];
  }

  void _addRulePair() {
    // 若当前字段只有一个空 key 的规则，就地编辑；否则新增一条。
    final pairs = session.rulePairs(_field);
    if (pairs.length == 1 && pairs.first.key.isEmpty) {
      return;
    }
    setState(() {
      session.addRulePair(_field, '', '');
    });
  }

  List<Widget> _buildOtherFields(BuildContext context) {
    const fields = [
      'ruleRss',
      'ruleImage',
      'ruleThink',
      'ruleChapterList',
    ];
    return [
      for (final field in fields) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            _fieldHint(field),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        _EditField(
          key: ValueKey(field),
          value: session.ruleValue(field),
          onChanged: (value) {
            session.addRulePair(field, '', value);
          },
        ),
        const SizedBox(height: 14),
      ],
    ];
  }

  String _fieldHint(String field) => switch (field) {
    'ruleSearch' => '搜索规则（bookList/name/bookUrl/author/intro，JSON 或片段）',
    'ruleExplore' => '发现/分类规则（bookList 数组 + 分类配置）',
    'ruleBookInfo' => '详情规则（bookUrl/coverUrl/intro/kind 等）',
    'ruleToc' => '目录规则（chapterList/name/url 等）',
    'ruleContent' => '正文规则（content/nextContentUrl/think 等）',
    'ruleRss' => 'RSS 规则（rssUrl + 条目规则）',
    'ruleImage' => '漫画图片规则（imageUrls）',
    'ruleThink' => '段评规则（think）',
    'ruleChapterList' => '章节目录规则（兼容 ruleToc）',
    _ => field,
  };
}

class _RulePairTile extends StatefulWidget {
  const _RulePairTile({
    required this.field,
    required this.pair,
    required this.session,
  });

  final String field;
  final MapEntry<String, String> pair;
  final _EditSession session;

  @override
  State<_RulePairTile> createState() => _RulePairTileState();
}

class _RulePairTileState extends State<_RulePairTile> {
  late final TextEditingController _keyController;
  late final TextEditingController _valueController;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: widget.pair.key);
    _valueController = TextEditingController(text: widget.pair.value);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keyController,
                    decoration: const InputDecoration(
                      labelText: '键（如 bookList / chapter1）',
                      isDense: true,
                    ),
                    onChanged: (value) {
                      widget.session.addRulePair(
                        widget.field,
                        value.trim(),
                        _valueController.text,
                      );
                    },
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () {
                    widget.session.removeRulePair(
                      widget.field,
                      widget.pair.key,
                    );
                    setState(() {});
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            TextField(
              controller: _valueController,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: '规则值',
                alignLabelWithHint: true,
              ),
              onChanged: (value) {
                widget.session.addRulePair(
                  widget.field,
                  _keyController.text.trim(),
                  value,
                );
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => unawaited(_openJsEditor(context)),
                  icon: const Icon(Icons.code_rounded, size: 16),
                  label: const Text('JS 编辑'),
                ),
                TextButton.icon(
                  onPressed: () => unawaited(_insertVariable(context)),
                  icon: const Icon(Icons.data_object_outlined, size: 16),
                  label: const Text('变量'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openJsEditor(BuildContext context) async {
    final result = await showJsCodeEditor(
      context: context,
      title: '编辑规则值',
      initialCode: _valueController.text,
    );
    if (result == null || result == _valueController.text) return;
    _valueController.text = result;
    widget.session.addRulePair(
      widget.field,
      _keyController.text.trim(),
      result,
    );
    setState(() {});
  }

  Future<void> _insertVariable(BuildContext context) async {
    final selected = await showLegadoVariablePicker(context);
    if (selected == null) return;
    _valueController.text = '${_valueController.text}$selected';
    widget.session.addRulePair(
      widget.field,
      _keyController.text.trim(),
      _valueController.text,
    );
    setState(() {});
  }
}

class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
    this.actions = const [],
  });

  final String title;
  final String hint;
  final String value;
  final ValueChanged<String> onChanged;

  /// 行尾操作（如「JS 编辑器」按钮）。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: TextEditingController(text: value),
              decoration: InputDecoration(
                labelText: title,
                hintText: hint,
              ),
              onChanged: onChanged,
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 书源 JS 类字段（loginCheckJs / jsLib 等）的行尾操作：
/// 「JS 编辑器」打开语法高亮全屏编辑；「插入变量」弹出 Legado 变量列表追加。
class _JsFieldActions extends StatelessWidget {
  const _JsFieldActions({
    required this.field,
    required this.session,
    required this.rebuild,
  });

  final String field;
  final _EditSession session;
  final VoidCallback rebuild;

  Future<void> _openJsEditor(BuildContext context) async {
    final result = await showJsCodeEditor(
      context: context,
      title: '编辑 $field',
      initialCode: session._str(field),
    );
    if (result == null || result == session._str(field)) return;
    session.setStr(field, result);
    rebuild();
  }

  Future<void> _insertVariable(BuildContext context) async {
    final selected = await showLegadoVariablePicker(context);
    if (selected == null) return;
    session.setStr(field, '${session._str(field)}$selected');
    rebuild();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'JS 编辑器',
          onPressed: () => unawaited(_openJsEditor(context)),
          icon: const Icon(Icons.code_rounded, size: 20),
        ),
        IconButton(
          tooltip: '插入变量',
          onPressed: () => unawaited(_insertVariable(context)),
          icon: const Icon(Icons.data_object_outlined, size: 20),
        ),
      ],
    );
  }
}

/// 弹出 Legado 书源变量选择面板，返回选中的插入文本（取消返回 null）。
Future<String?> showLegadoVariablePicker(BuildContext context) {
  String? selected;
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        shrinkWrap: true,
        children: [
          for (final group in kLegadoSourceVariableGroups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(
                group.title,
                style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Theme.of(sheetContext).colorScheme.primary,
                ),
              ),
            ),
            for (final item in group.items)
              ListTile(
                dense: true,
                leading: const Icon(Icons.add_rounded, size: 20),
                title: Text(item.label),
                trailing: Text(
                  item.insertText,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
                onTap: () {
                  selected = item.insertText;
                  Navigator.pop(sheetContext, selected);
                },
              ),
          ],
        ],
      ),
    ),
  );
}

class _EditField extends StatelessWidget {
  const _EditField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: TextEditingController(text: value),
      maxLines: 4,
      minLines: 2,
      onChanged: onChanged,
    );
  }
}