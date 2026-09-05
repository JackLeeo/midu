import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_source_import_service.dart';
import 'package:midu/book_sources/legado/legado_source_verifier.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_health_service.dart';
import 'package:midu/book_sources/services/book_source_import_analyzer.dart';
import 'package:midu/book_sources/services/book_source_login_service.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';
import 'package:midu/pages/book_sources/book_source_debug_page.dart';
import 'package:midu/pages/book_sources/book_source_edit_page.dart';
import 'package:midu/utils/debug_logger.dart';
import 'package:midu/utils/layout_helper.dart';
import 'package:midu/utils/localization_extension.dart';
import 'package:midu/utils/page_style_helper.dart';
import 'package:midu/utils/source_protocol_meta.dart';
import 'package:midu/widgets/side_toast.dart';
import 'package:midu/widgets/source_cover_image.dart';
import 'package:midu/widgets/source_login_sheet.dart';

/// Low-frequency configuration for online content providers.
///
/// Discovery remains user-facing; adding, enabling and removing providers lives
/// here so technical configuration does not interrupt the book-browsing flow.
class BookSourceManagementPage extends StatefulWidget {
  const BookSourceManagementPage({super.key});

  @override
  State<BookSourceManagementPage> createState() =>
      _BookSourceManagementPageState();
}

class _BookSourceManagementPageState extends State<BookSourceManagementPage> {
  final BookSourceRegistry _registry = BookSourceRegistry();
  BookSourceClient? _client;
  LegadoSourceImportService? _importService;
  BookSourceImportAnalyzer? _importAnalyzer;
  LegadoSourceVerifier? _sourceVerifier;

  BookSourceClient get _sourceClient => _client ??= BookSourceClient();
  LegadoSourceImportService get _additionalImportService =>
      _importService ??= LegadoSourceImportService();
  BookSourceImportAnalyzer get _sourceImportAnalyzer => _importAnalyzer ??=
      BookSourceImportAnalyzer(additionalImporter: _additionalImportService);
  LegadoSourceVerifier get _additionalSourceVerifier =>
      _sourceVerifier ??= LegadoSourceVerifier();

  List<RegisteredBookSource> _sources = const [];
  final Set<String> _selectedSourceIds = {};
  bool _loading = true;
  bool _selectionMode = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSources());
  }

  Future<void> _loadSources() async {
    final sources = await _registry.load();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _client?.close();
    _importService?.close();
    _sourceVerifier?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const additionalProtocolsEnabled = true; // 米读：Legado 原生支持，始终启用
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.bookSourceManagementTitle),
        actions: [
          IconButton(
            tooltip: '健康检查',
            onPressed: _runHealthCheck,
            icon: const Icon(Icons.health_and_safety_outlined),
          ),
          IconButton(
            tooltip: '新建书源',
            onPressed: _showNewSourceDialog,
            icon: const Icon(Icons.note_add_outlined),
          ),
          IconButton(
            tooltip: context.l10n.bookSourcesAdd,
            onPressed: _showAddSourceDialog,
            icon: const Icon(Icons.add_link_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: PageStyleHelper.backgroundGradient(context),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.l10n.bookSourceManagementSubtitle,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.l10n.bookSourcesManageTitle,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _showAddSourceDialog,
                            icon: const Icon(Icons.add_rounded),
                            label: Text(context.l10n.bookSourcesAdd),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            key: const Key('bookSourcesSelectionModeButton'),
                            tooltip: context.l10n.bookSourcesSelect,
                            onPressed: () => setState(() {
                              _selectionMode = !_selectionMode;
                              _selectedSourceIds.clear();
                            }),
                            icon: Icon(
                              _selectionMode
                                  ? Icons.close_rounded
                                  : Icons.checklist_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_selectionMode) ...[
                        _buildBulkActions(additionalProtocolsEnabled),
                        const SizedBox(height: 12),
                      ],
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(36),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_sources.isEmpty)
                        _buildNoSourcesCard()
                      else
                        ..._buildSourceGroups(additionalProtocolsEnabled),
                      const SizedBox(height: 22),
                      _buildProtocolCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoSourcesCard() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _panelDecoration(radius: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.travel_explore_rounded, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.bookSourcesNoSourcesTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  context.l10n.bookSourcesNoSourcesDescription,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSourceGroups(bool additionalProtocolsEnabled) {
    final orsp = _sources
        .where((source) => source.sourceProtocol == BookSourceProtocolKind.orsp)
        .toList(growable: false);
    final legado = _sources
        .where((source) => source.sourceProtocol != BookSourceProtocolKind.orsp)
        .toList(growable: false);
    // 按 Legado 分组名聚合（对标 bookSourceGroup），保持各源在 _sources 中的
    // 现有顺序；分组间的先后按首次出现顺序。
    final legadoByGroup = <String, List<RegisteredBookSource>>{};
    for (final source in legado) {
      legadoByGroup.putIfAbsent(source.group, () => []).add(source);
    }
    return [
      if (orsp.isNotEmpty)
        ..._buildSourceGroup(
          title: context.l10n.bookSourcesProtocolGroupOrsp,
          sources: orsp,
          additionalProtocolsEnabled: additionalProtocolsEnabled,
          groupKey: 'protocol:orsp',
        ),
      for (final entry in legadoByGroup.entries)
        ..._buildSourceGroup(
          title: entry.key,
          sources: entry.value,
          additionalProtocolsEnabled: additionalProtocolsEnabled,
          groupKey: 'group:${entry.key}',
        ),
    ];
  }

  Widget _buildBulkActions(bool additionalProtocolsEnabled) {
    final allIds = _sources.map((source) => source.id).toSet();
    final allSelected =
        allIds.isNotEmpty && _selectedSourceIds.containsAll(allIds);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => setState(() {
            if (allSelected) {
              _selectedSourceIds.clear();
            } else {
              _selectedSourceIds
                ..clear()
                ..addAll(allIds);
            }
          }),
          icon: Icon(
            allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
          ),
          label: Text(
            allSelected
                ? context.l10n.bookSourcesClearSelection
                : context.l10n.bookSourcesSelectAll,
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: _selectedSourceIds.isEmpty
              ? null
              : () => _setSelectedSourcesEnabled(
                  true,
                  additionalProtocolsEnabled,
                ),
          icon: const Icon(Icons.toggle_on_outlined),
          label: Text(context.l10n.bookSourcesEnableSelected),
        ),
        OutlinedButton.icon(
          onPressed: _selectedSourceIds.isEmpty
              ? null
              : () => _setSelectedSourcesEnabled(
                  false,
                  additionalProtocolsEnabled,
                ),
          icon: const Icon(Icons.toggle_off_outlined),
          label: Text(context.l10n.bookSourcesDisableSelected),
        ),
        TextButton.icon(
          onPressed: _selectedSourceIds.isEmpty ? null : _removeSelectedSources,
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(context.l10n.bookSourcesDeleteSelected),
        ),
      ],
    );
  }

  void _toggleSourceSelection(RegisteredBookSource source) {
    setState(() {
      if (!_selectedSourceIds.add(source.id)) {
        _selectedSourceIds.remove(source.id);
      }
    });
  }

  Future<void> _setSelectedSourcesEnabled(
    bool enabled,
    bool additionalProtocolsEnabled,
  ) async {
    final allowedIds = _sources
        .where(
          (source) =>
              _selectedSourceIds.contains(source.id) &&
              (!enabled ||
                  source.sourceProtocol == BookSourceProtocolKind.orsp ||
                  additionalProtocolsEnabled),
        )
        .map((source) => source.id);
    final sources = await _registry.setEnabledAll(allowedIds, enabled);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _removeSelectedSources() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesDeleteSelected),
        content: Text(
          context.l10n.bookSourcesDeleteSelectedMessage(
            _selectedSourceIds.length,
          ),
        ),
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
    if (confirmed != true) return;
    final sources = await _registry.removeAll(_selectedSourceIds);
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _selectedSourceIds.clear();
      _selectionMode = false;
    });
  }

  List<Widget> _buildSourceGroup({
    required String title,
    required List<RegisteredBookSource> sources,
    required bool additionalProtocolsEnabled,
    required String groupKey,
  }) {
    final allEnabled = sources.every((s) => s.enabled);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (!_selectionMode) ...[
              // 组内一键启停（对标 Legado 分组开关）。
              if ((sources.every(
                    (s) =>
                        s.capabilities.isNotEmpty ||
                        s.sourceProtocol == BookSourceProtocolKind.orsp,
                  )))
                TextButton(
                  key: Key('groupToggle-$groupKey'),
                  onPressed: () => _setGroupEnabled(sources, !allEnabled),
                  child: Text(allEnabled ? '停用' : '启用'),
                ),
              if (sources.any(
                (s) => s.sourceProtocol != BookSourceProtocolKind.orsp,
              ))
                PopupMenuButton<String>(
                  key: Key('groupMenu-$groupKey'),
                  tooltip: '分组操作',
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (value) => _onGroupAction(title, sources, value),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'sortName',
                      child: Row(
                        children: [
                          Icon(Icons.sort_by_alpha_rounded),
                          SizedBox(width: 10),
                          Text('按名称排序'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'sortWeight',
                      child: Row(
                        children: [
                          Icon(Icons.tune_rounded),
                          SizedBox(width: 10),
                          Text('按权重排序'),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'renameGroup',
                      child: Row(
                        children: [
                          Icon(Icons.drive_file_rename_outline_rounded),
                          SizedBox(width: 10),
                          Text('重命名分组'),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
            const SizedBox(width: 6),
            Text(
              '${sources.length}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      if (_selectionMode ||
          sources.any(
            (s) => s.sourceProtocol == BookSourceProtocolKind.orsp,
          ))
        ...sources.map(
          (source) => _buildSourceCard(
            source,
            additionalProtocolsEnabled: additionalProtocolsEnabled,
          ),
        )
      else
        // Legado 分组支持拖拽排序（对标 Legado 书源重排）。
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: sources.length,
          onReorderItem: (oldIndex, newIndex) =>
              _reorderInGroup(sources, oldIndex, newIndex),
          itemBuilder: (context, index) {
            final source = sources[index];
            return KeyedSubtree(
              key: ValueKey('bookSourceCard-${source.id}'),
              child: _buildSourceCard(
                source,
                additionalProtocolsEnabled: additionalProtocolsEnabled,
                dragIndex: index,
              ),
            );
          },
        ),
    ];
  }

  /// 组内一键启停：切换组内全部源的启停状态。
  Future<void> _setGroupEnabled(
    List<RegisteredBookSource> sources,
    bool enabled,
  ) async {
    final next = await _registry.setEnabledAll(
      sources.map((s) => s.id),
      enabled,
    );
    if (!mounted) return;
    setState(() => _sources = next);
  }

  /// 组操作：排序 / 重命名分组。
  Future<void> _onGroupAction(
    String title,
    List<RegisteredBookSource> sources,
    String value,
  ) async {
    if (value == 'sortName' || value == 'sortWeight') {
      setState(() {
        _sources.sort((a, b) {
          final ag = _groupRankOf(a);
          final bg = _groupRankOf(b);
          if (ag != bg) return ag.compareTo(bg);
          if (value == 'sortWeight') {
            final r = b.weight.compareTo(a.weight);
            if (r != 0) return r;
          }
          return a.name.compareTo(b.name);
        });
      });
      await _registry.sortSources(_sources.map((s) => s.id));
      return;
    }
    if (value == 'renameGroup') {
      final newGroup = await _promptGroupName(title);
      if (newGroup == null || newGroup == title) return;
      var next = _sources;
      for (final source in sources) {
        next = await _registry.setGroup(source.id, newGroup);
      }
      if (!mounted) return;
      setState(() => _sources = next);
    }
  }

  int _groupRankOf(RegisteredBookSource source) {
    if (source.sourceProtocol == BookSourceProtocolKind.orsp) return 0;
    final groups = _sources
        .where((s) => s.sourceProtocol != BookSourceProtocolKind.orsp)
        .map((s) => s.group)
        .toSet();
    return 1 + groups.toList().indexOf(source.group);
  }

  /// 拖拽重排：将 [oldIndex] 的源移动到 [newIndex]（群组内），再序列化全量顺序。
  Future<void> _reorderInGroup(
    List<RegisteredBookSource> groupSources,
    int oldIndex,
    int newIndex,
  ) async {
    final groupIds = groupSources.map((s) => s.id).toList(growable: false);
    final moved = groupIds.removeAt(oldIndex);
    // onReorderItem 已对下移情形修正过 newIndex，直接插入即可。
    groupIds.insert(newIndex.clamp(0, groupIds.length), moved);
    final movedIds = groupIds.toSet();
    // 按视觉顺序重建全量列表：组外源保持原位，组内以新顺序填入。
    final byId = {for (final source in _sources) source.id: source};
    var cursor = 0;
    final ordered = <RegisteredBookSource>[
      for (final source in _sources)
        if (movedIds.contains(source.id))
          byId[groupIds[cursor++]]!
        else
          source,
    ];
    final saved = await _registry.sortSources(ordered.map((s) => s.id));
    if (!mounted) return;
    setState(() => _sources = saved);
  }

  Widget _buildSourceCard(
    RegisteredBookSource source, {
    required bool additionalProtocolsEnabled,
    int? dragIndex,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final canEnable =
        source.capabilities.isNotEmpty &&
        (source.sourceProtocol == BookSourceProtocolKind.orsp ||
            additionalProtocolsEnabled);
    final selected = _selectedSourceIds.contains(source.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 640;
          return Container(
            key: ValueKey('bookSourceCard-${source.id}'),
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 18,
              compact ? 16 : 14,
              compact ? 10 : 8,
              compact ? 12 : 14,
            ),
            decoration: _panelDecoration(radius: 20),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_selectionMode)
                            Checkbox(
                              value: selected,
                              onChanged: (_) => _toggleSourceSelection(source),
                            )
                          else
                            _buildSourceIcon(source, size: 52),
                          const SizedBox(width: 13),
                          Expanded(child: _buildSourceSummary(source)),
                          if (dragIndex != null && !_selectionMode)
                            _buildDragHandle(dragIndex, source),
                          _buildSourceMenu(source),
                        ],
                      ),
                      if (source.capabilities.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _buildCapabilityChips(source),
                      ],
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.only(left: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainer.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source.enabled
                                    ? context.l10n.bookSourcesEnabled
                                    : context.l10n.bookSourcesDisabled,
                                style: TextStyle(
                                  color: source.enabled
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Switch.adaptive(
                              value: source.enabled,
                              onChanged: !canEnable
                                  ? null
                                  : (enabled) =>
                                        _setSourceEnabled(source, enabled),
                            ),
                            if (source.sourceProtocol ==
                                BookSourceProtocolKind.orsp)
                              IconButton(
                                tooltip: context.l10n.bookSourcesRefresh,
                                onPressed: () => _refreshSource(source),
                                icon: const Icon(Icons.refresh_rounded),
                              ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      if (_selectionMode)
                        Checkbox(
                          value: selected,
                          onChanged: (_) => _toggleSourceSelection(source),
                        )
                      else
                        _buildSourceIcon(source),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSourceSummary(source),
                            if (source.capabilities.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              _buildCapabilityChips(source),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        source.enabled
                            ? context.l10n.bookSourcesEnabled
                            : context.l10n.bookSourcesDisabled,
                        style: TextStyle(
                          color: source.enabled
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!_selectionMode)
                        Switch.adaptive(
                          value: source.enabled,
                          onChanged: !canEnable
                              ? null
                              : (enabled) => _setSourceEnabled(source, enabled),
                        ),
                      if (!_selectionMode &&
                          source.sourceProtocol == BookSourceProtocolKind.orsp)
                        IconButton(
                          tooltip: context.l10n.bookSourcesRefresh,
                          onPressed: () => _refreshSource(source),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      if (dragIndex != null && !_selectionMode)
                        _buildDragHandle(dragIndex, source),
                      if (!_selectionMode) _buildSourceMenu(source),
                    ],
                  ),
          );
        },
      ),
    );
  }

  /// 拖拽排序手柄：由 [ReorderableDragStartListener] 接管长按/指针拖拽。
  Widget _buildDragHandle(int index, RegisteredBookSource source) {
    return ReorderableDragStartListener(
      index: index,
      child: IconButton(
        key: Key('bookSourceDragHandle-${source.id}'),
        tooltip: '拖拽排序',
        icon: const Icon(Icons.drag_indicator_rounded),
        onPressed: null,
      ),
    );
  }

  Widget _buildSourceSummary(RegisteredBookSource source) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          source.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          source.description.isEmpty
              ? source.apiBaseUrl.host
              : source.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildCapabilityChips(RegisteredBookSource source) {
    final scheme = Theme.of(context).colorScheme;
    final capabilities = source.capabilities.toList()..sort();
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: capabilities
          .map(
            (capability) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                capability,
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildSourceMenu(RegisteredBookSource source) {
    return PopupMenuButton<String>(
      tooltip: context.l10n.bookSourcesRemove,
      onSelected: (value) {
        if (value == 'edit') _openSourceEditor(source);
        if (value == 'debug') _openSourceDebug(source);
        if (value == 'login') _openSourceLogin(source);
        if (value == 'rights') _showSourceRightsDialog(source);
        if (value == 'group') _editSourceGroup(source);
        if (value == 'weight') _editSourceWeight(source);
        if (value == 'remove') _confirmRemoveSource(source);
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              const Icon(Icons.edit_outlined),
              const SizedBox(width: 10),
              const Text('编辑书源'),
            ],
          ),
        ),
        if (source.sourceProtocol == BookSourceProtocolKind.legado) ...[
          if (BookSourceLoginService.hasLogin(
            LegadoBookSource.fromJson(source.sourceConfig!),
          ))
            PopupMenuItem(
              value: 'login',
              child: Row(
                children: [
                  const Icon(Icons.login_outlined),
                  const SizedBox(width: 10),
                  const Text('登录'),
                ],
              ),
            ),
          PopupMenuItem(
            value: 'debug',
            child: Row(
              children: [
                const Icon(Icons.bug_report_outlined),
                const SizedBox(width: 10),
                const Text('调试书源'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'group',
            child: Row(
              children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 10),
                const Text('设置分组'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'weight',
            child: Row(
              children: [
                const Icon(Icons.tune_rounded),
                const SizedBox(width: 10),
                const Text('设置权重'),
              ],
            ),
          ),
        ],
        if (source.sourceProtocol == BookSourceProtocolKind.orsp)
          PopupMenuItem(
            value: 'rights',
            child: Text(context.l10n.bookSourcesRightsDetails),
          ),
        PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              const Icon(Icons.delete_outline_rounded),
              const SizedBox(width: 10),
              Text(context.l10n.bookSourcesRemove),
            ],
          ),
        ),
      ],
    );
  }

  /// 设置书源分组：快速选择已有分组 + 输入新分组名。
  Future<void> _editSourceGroup(RegisteredBookSource source) async {
    final existing = <String>{
      for (final s in _sources)
        if (s.sourceProtocol == BookSourceProtocolKind.legado) s.group,
    }.toList()..sort();
    final textController = TextEditingController();
    final group = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('设置分组 — ${source.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('已有分组：'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final name in existing)
                      ChoiceChip(
                        label: Text(name),
                        selected: source.group == name,
                        onSelected: (_) =>
                            Navigator.pop(context, name),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: textController,
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: '新建分组名',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty) {
                      Navigator.pop(context, value.trim());
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.bookSourcesCancel),
            ),
            FilledButton(
              onPressed: () {
                final text = textController.text.trim();
                if (text.isNotEmpty) Navigator.pop(context, text);
              },
              child: const Text('使用新分组'),
            ),
          ],
        ),
      ),
    );
    if (group == null) return;
    final next = await _registry.setGroup(source.id, group);
    if (!mounted) return;
    setState(() => _sources = next);
  }

  /// 设置书源权重：0 表示清除（恢复默认不参与加权）。
  Future<void> _editSourceWeight(RegisteredBookSource source) async {
    final controller = TextEditingController(text: '${source.weight}');
    final weight = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('设置权重 — ${source.name}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '权重（越大越优先，0 表示不加权）',
            helperText: '对标 Legado bookSource.weight',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.bookSourcesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(controller.text.trim()) ?? 0),
            child: Text(context.l10n.bookSourcesConfirm),
          ),
        ],
      ),
    );
    if (weight == null) return;
    final next = await _registry.setWeight(source.id, weight);
    if (!mounted) return;
    setState(() => _sources = next);
  }

  /// 输入新分组名（用于重命名分组）。
  Future<String?> _promptGroupName(String current) async {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '分组名',
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
            child: Text(context.l10n.bookSourcesConfirm),
          ),
        ],
      ),
    );
  }

  /// 打开书源调试页（仅 Legado 源；请求/响应日志 + 五分区调试）。
  Future<void> _openSourceDebug(RegisteredBookSource source) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BookSourceDebugPage(source: source),
      ),
    );
  }

  /// 弹出书源登录表单（仅 Legado 源；按 loginUi 动态渲染字段并执行登录，
  /// 登录信息/Cookie 持久化）。复用共享客户端按源隔离的 runtime，保证登录态
  /// 与正常阅读请求共享同一 Cookie 会话。
  Future<void> _openSourceLogin(RegisteredBookSource source) {
    return showSourceLoginSheet(
      context: context,
      runtime: _sourceClient.legadoRuntimeForSource(source),
      source: source,
    );
  }

  /// 打开书源编辑页（Legado 或 ORSP 源均可用编辑页直接改 sourceConfig）。
  Future<void> _openSourceEditor(RegisteredBookSource source) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookSourceEditPage(source: source),
      ),
    );
    await _loadSources();
  }

  /// 打开「新建书源」页（空模板，仅 Legado 字段）。
  void _showNewSourceDialog() {
    Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookSourceEditPage(
          initialRaw: {
            'bookSourceUrl': '',
            'bookSourceName': '',
            'bookSourceGroup': '',
            'bookSourceComment': '',
          },
        ),
      ),
    ).then((_) => _loadSources());
  }

  Widget _buildSourceIcon(RegisteredBookSource source, {double size = 48}) {
    final scheme = Theme.of(context).colorScheme;
    final initial = source.name.characters.firstOrNull?.toUpperCase() ?? '?';
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    if (source.iconUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.29),
      child: SourceCoverImage(
        url: source.iconUrl!,
        fallback: fallback,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildProtocolCard() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _panelDecoration(radius: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.api_rounded, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.bookSourcesProtocolTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.bookSourcesProtocolDescription,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _showProtocolDialog,
                      icon: const Icon(Icons.schema_outlined, size: 18),
                      label: Text(context.l10n.bookSourcesProtocolDetails),
                    ),
                    TextButton.icon(
                      onPressed: _openProtocolRepository,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: Text(context.l10n.bookSourcesProtocolRepository),
                    ),
                    TextButton.icon(
                      onPressed: _openRightsReport,
                      icon: const Icon(Icons.report_outlined, size: 18),
                      label: Text(context.l10n.bookSourcesRightsReport),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _panelDecoration({required double radius}) {
    final palette = PageStyleHelper.palette(context);
    return BoxDecoration(
      color: palette.card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: palette.border),
    );
  }

  Future<void> _setSourceEnabled(
    RegisteredBookSource source,
    bool enabled,
  ) async {
    final sources = await _registry.setEnabled(source.id, enabled);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _refreshSource(RegisteredBookSource source) async {
    try {
      final sources = await _registry.refresh(source, _sourceClient);
      if (!mounted) return;
      setState(() => _sources = sources);
      showSideToast(
        context,
        context.l10n.bookSourcesRefreshed,
        kind: SideToastKind.success,
      );
    } on BookSourceProtocolException {
      if (!mounted) return;
      showSideToast(
        context,
        context.l10n.bookSourcesRefreshFailed,
        kind: SideToastKind.error,
      );
    } catch (_) {
      if (!mounted) return;
      showSideToast(
        context,
        context.l10n.bookSourcesRefreshFailed,
        kind: SideToastKind.error,
      );
    }
  }

  // ===== 健康检查 =====

  Future<void> _runHealthCheck() async {
    final legadoSources = _sources
        .where((s) => s.sourceProtocol == BookSourceProtocolKind.legado)
        .toList();
    if (legadoSources.isEmpty) {
      showSideToast(
        context,
        '暂无可检查的 Legado 书源',
        kind: SideToastKind.error,
      );
      return;
    }
    final checker = BookSourceHealthChecker(client: _sourceClient);
    final report = await showDialog<HealthCheckReport>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _HealthCheckProgressDialog(
        checker: checker,
        sources: legadoSources,
      ),
    );
    if (!mounted || report == null) return;
    if (report.total == 0) {
      showSideToast(
        context,
        '暂无可检查的 Legado 书源',
        kind: SideToastKind.error,
      );
      return;
    }
    _showHealthCheckResultDialog(report);
  }

  void _showHealthCheckResultDialog(HealthCheckReport report) {
    final scheme = Theme.of(context).colorScheme;
    final failures = report.failures;
    final passed = report.results.where((r) => r.isHealthy).toList();
    final blockedIds = <String>{};

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => Dialog(
          backgroundColor: scheme.surfaceContainerHigh,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.34),
                ),
                borderRadius: BorderRadius.circular(28),
              ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.health_and_safety_rounded,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '健康检查结果',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _summaryChip('总数 ${report.total}', scheme.primary),
                            _summaryChip(
                              '通过 ${report.healthyCount}',
                              Colors.green,
                            ),
                            _summaryChip(
                              '失败 ${report.failedCount}',
                              scheme.error,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Divider(
                        height: 1,
                        color: scheme.outline.withValues(alpha: 0.2),
                      ),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 460),
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            shrinkWrap: true,
                            children: [
                              if (failures.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 28,
                                  ),
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.check_circle_rounded,
                                        color: Colors.green,
                                        size: 48,
                                      ),
                                      const SizedBox(height: 10),
                                      const Text('全部书源通过检查'),
                                    ],
                                  ),
                                )
                              else ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 8,
                                  ),
                                  child: Text(
                                    '失败 (${failures.length})',
                                    style: TextStyle(
                                      color: scheme.error,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                ...failures.map(
                                  (r) => _buildFailureCard(
                                    r,
                                    blocked: blockedIds.contains(r.source.id),
                                    scheme: scheme,
                                    onBlock: () async {
                                      await BookSourceBlocklistStore.instance
                                          .block(r.source.id);
                                      if (!context.mounted) return;
                                      setState(
                                        () => blockedIds.add(r.source.id),
                                      );
                                      showSideToast(
                                        context,
                                        '已屏蔽「${r.source.name}」7 天',
                                        kind: SideToastKind.success,
                                      );
                                    },
                                  ),
                                ),
                              ],
                              if (passed.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                _buildPassedSection(passed, scheme),
                              ],
                            ],
                          ),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: scheme.outline.withValues(alpha: 0.2),
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: failures.isEmpty ||
                                        blockedIds.length >= failures.length
                                    ? null
                                    : () async {
                                        for (final r in failures) {
                                          if (!blockedIds
                                              .contains(r.source.id)) {
                                            await BookSourceBlocklistStore
                                                .instance
                                                .block(r.source.id);
                                          }
                                        }
                                        if (!context.mounted) return;
                                        setState(
                                          () => blockedIds.addAll(
                                            failures.map((r) => r.source.id),
                                          ),
                                        );
                                        showSideToast(
                                          context,
                                          '已屏蔽全部失败书源 7 天',
                                          kind: SideToastKind.success,
                                        );
                                      },
                                icon: const Icon(Icons.block_rounded),
                                label: Text('全部屏蔽（${failures.length}）'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('关闭'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
  }

  Widget _summaryChip(String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildFailureCard(
    HealthCheckResult r, {
    required bool blocked,
    required ColorScheme scheme,
    required Future<void> Function() onBlock,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.error.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline_rounded,
                color: scheme.error,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.source.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _stageLabel(r.stage),
                  style: TextStyle(
                    color: scheme.error,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            r.error ?? '未知错误',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.4,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (r.latencyMs != null)
                Text(
                  '${r.latencyMs}ms',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              const Spacer(),
              if (blocked)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '已屏蔽 7 天',
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: onBlock,
                  icon: const Icon(Icons.shield_outlined, size: 16),
                  label: const Text('暂时屏蔽7天'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPassedSection(
    List<HealthCheckResult> passed,
    ColorScheme scheme,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ExpansionTile(
        initiallyExpanded: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.green.withValues(alpha: 0.32)),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.green.withValues(alpha: 0.32)),
        ),
        backgroundColor: Colors.green.withValues(alpha: 0.08),
        collapsedBackgroundColor: Colors.green.withValues(alpha: 0.08),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        title: Row(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              color: Colors.green,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              '${passed.length} 个源通过检查',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        children: passed
            .map(
              (r) => ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14),
                leading: Icon(
                  Icons.check_rounded,
                  color: Colors.green,
                  size: 18,
                ),
                title: Text(
                  r.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: r.latencyMs != null
                    ? Text(
                        '${r.latencyMs}ms',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      )
                    : null,
              ),
            )
            .toList(),
      ),
    );
  }

  String _stageLabel(HealthCheckStage stage) {
    switch (stage) {
      case HealthCheckStage.init:
        return '初始化';
      case HealthCheckStage.search:
        return '搜索';
      case HealthCheckStage.detail:
        return '书籍详情';
      case HealthCheckStage.catalog:
        return '章节目录';
      case HealthCheckStage.content:
        return '章节正文';
      case HealthCheckStage.done:
        return '成功';
    }
  }

  Future<void> _confirmRemoveSource(RegisteredBookSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesRemoveTitle),
        content: Text(context.l10n.bookSourcesRemoveMessage),
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
    if (confirmed != true) return;
    final sources = await _registry.remove(source.id);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _showSourceRightsDialog(RegisteredBookSource source) async {
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.bookSourcesRightsDetails),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _rightsField(
                  context.l10n.bookSourcesOperator,
                  source.operatorName,
                ),
                _rightsField(
                  context.l10n.bookSourcesContentLicense,
                  source.contentLicense,
                ),
                _rightsField(
                  context.l10n.bookSourcesRightsStatement,
                  source.rightsStatement,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.bookSourcesRightsUnverifiedNotice,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (source.contactUrl != null)
                      TextButton.icon(
                        onPressed: () => _openExternalUrl(source.contactUrl!),
                        icon: const Icon(
                          Icons.contact_support_outlined,
                          size: 18,
                        ),
                        label: Text(context.l10n.bookSourcesContactOperator),
                      ),
                    TextButton.icon(
                      onPressed: _openRightsReport,
                      icon: const Icon(Icons.report_outlined, size: 18),
                      label: Text(context.l10n.bookSourcesRightsReport),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.bookSourcesClose),
          ),
        ],
      ),
    );
  }

  Widget _rightsField(String label, String value) {
    final displayed = value.trim().isEmpty
        ? context.l10n.bookSourcesRightsNotProvided
        : value.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          SelectableText(displayed, style: const TextStyle(height: 1.4)),
        ],
      ),
    );
  }

  Future<void> _showAddSourceDialog() async {
    final controller = TextEditingController();
    var connecting = false;
    var responsibilityAccepted = false;
    var mode = _AddSourceMode.link;
    BookSourceImportAnalysis? analysis;
    var verificationCompleted = 0;
    var verificationTotal = 0;
    var verificationAvailable = 0;
    String? errorText;

    Future<void> analyzeLink(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      setRouteState(() {
        connecting = true;
        errorText = null;
      });
      try {
        final result = await _sourceImportAnalyzer.analyzeUrl(controller.text);
        if (!routeContext.mounted) return;
        setRouteState(() {
          analysis = result;
          connecting = false;
        });
      } catch (error) {
        if (!routeContext.mounted) return;
        setRouteState(() {
          connecting = false;
          errorText = error.toString();
        });
      }
    }

    Future<void> chooseFile(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.size > LegadoSourceImportService.maxImportBytes) {
        setRouteState(() => errorText = 'Source file exceeds 64 MiB.');
        return;
      }
      final bytes = file.bytes;
      if (bytes == null) {
        setRouteState(() => errorText = 'Could not read source file.');
        return;
      }
      setRouteState(() {
        connecting = true;
        errorText = null;
        analysis = null;
      });
      try {
        final detected = _sourceImportAnalyzer.analyzeBytes(bytes);
        if (!routeContext.mounted) return;
        setRouteState(() {
          analysis = detected;
          connecting = false;
        });
      } catch (error) {
        if (!routeContext.mounted) return;
        setRouteState(() {
          connecting = false;
          errorText = error.toString();
        });
      }
    }

    Future<void> addDetected(
      BuildContext routeContext,
      StateSetter setRouteState,
    ) async {
      final noWorkingSourcesMessage = context.l10n.bookSourcesNoWorkingSources;
      final detected = analysis;
      if (detected == null) return;
      if (detected.kind == BookSourceImportKind.additional &&
          !_additionalProtocolsEnabled()) {
        setRouteState(() {
          errorText = context.l10n.bookSourcesAdvancedFeatureRequired;
        });
        return;
      }
      setRouteState(() {
        connecting = true;
        errorText = null;
      });
      try {
        late final List<RegisteredBookSource> sources;
        var importedAdditionalCount = 0;
        if (detected.kind == BookSourceImportKind.orsp) {
          sources = await _registry.upsert(detected.sources.single);
        } else {
          // 米读：导入时不做网络验证，直接导入所有兼容性扫描通过的源。
          // 网络验证太慢且会过滤掉大量源（DNS被墙/服务器关闭/搜索词不匹配）。
          // 用户可后续通过书源健康检查手动验证并屏蔽失效源。
          final preview = detected.additionalPreview!;
          const scanner = LegadoCompatibilityScanner();
          final importList = <RegisteredBookSource>[];
          final rejectedList = <String>[];
          for (final source in preview.sources) {
            final report = scanner.scan(source);
            if (report.canRun) {
              importList.add(source.toRegisteredSource(enabled: true));
            } else {
              rejectedList.add('${source.name} (${source.url}): ${report.level.name}');
            }
          }
          DebugLogger.instance.log('import', '导入结果', details: {
            'total': preview.sources.length,
            'imported': importList.length,
            'rejected': rejectedList.length,
            'rejectedSamples': rejectedList.take(10).toList(),
            'parseErrors': preview.errors.length,
          });
          if (importList.isEmpty) {
            throw BookSourceProtocolException(noWorkingSourcesMessage);
          }
          importedAdditionalCount = importList.length;
          sources = await _registry.upsertAll(importList);
        }
        if (!mounted || !routeContext.mounted) return;
        Navigator.pop(routeContext);
        setState(() => _sources = sources);
        showSideToast(
          context,
          detected.kind == BookSourceImportKind.orsp
              ? '${context.l10n.bookSourcesAdded}: ${detected.sources.single.name}'
              : context.l10n.additionalSourcesImported(importedAdditionalCount),
          kind: SideToastKind.success,
        );
      } catch (error) {
        if (!routeContext.mounted) return;
        setRouteState(() {
          connecting = false;
          errorText = error.toString();
        });
      }
    }

    Widget buildPanel(
      BuildContext routeContext,
      StateSetter setRouteState, {
      required bool sheet,
    }) {
      return _AddBookSourcePanel(
        controller: controller,
        connecting: connecting,
        responsibilityAccepted: responsibilityAccepted,
        mode: mode,
        analysis: analysis,
        verificationCompleted: verificationCompleted,
        verificationTotal: verificationTotal,
        verificationAvailable: verificationAvailable,
        errorText: errorText,
        sheet: sheet,
        onModeChanged: (value) => setRouteState(() {
          mode = value;
          analysis = null;
          errorText = null;
        }),
        onResponsibilityChanged: (value) =>
            setRouteState(() => responsibilityAccepted = value),
        onCancel: () => Navigator.pop(routeContext),
        onAnalyzeLink: () => analyzeLink(routeContext, setRouteState),
        onChooseFile: () => chooseFile(routeContext, setRouteState),
        onAdd: () => addDetected(routeContext, setRouteState),
      );
    }

    if (LayoutHelper.isMobile(context)) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) => AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.92,
              ),
              child: buildPanel(sheetContext, setSheetState, sheet: true),
            ),
          ),
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        barrierDismissible: !connecting,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
              child: buildPanel(dialogContext, setDialogState, sheet: false),
            ),
          ),
        ),
      );
    }
    controller.dispose();
  }

  bool _additionalProtocolsEnabled() {
    return true; // 米读：Legado 原生支持，始终启用
  }

  void _showProtocolDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bookSourcesProtocolDialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.bookSourcesProtocolDialogBody,
                style: const TextStyle(height: 1.5),
              ),
              const SizedBox(height: 18),
              SelectableText(
                openReadingSourceProtocolRepositoryUrl,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: _openProtocolRepository,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(context.l10n.bookSourcesProtocolRepositoryOpen),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.bookSourcesClose),
          ),
        ],
      ),
    );
  }

  Future<void> _openProtocolRepository() async {
    final opened = await _openExternalUrl(
      Uri.parse(openReadingSourceProtocolRepositoryUrl),
    );
    if (!opened && mounted) {
      showSideToast(
        context,
        context.l10n.bookSourcesProtocolRepositoryOpenFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openRightsReport() async {
    final opened = await _openExternalUrl(
      Uri.parse(openReadingRightsReportUrl),
    );
    if (!opened && mounted) {
      showSideToast(
        context,
        context.l10n.bookSourcesRightsReportOpenFailed,
        kind: SideToastKind.error,
      );
    }
  }

  Future<bool> _openExternalUrl(Uri url) {
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }
}

enum _AddSourceMode { link, file }

class _AddBookSourcePanel extends StatelessWidget {
  final TextEditingController controller;
  final bool connecting;
  final bool responsibilityAccepted;
  final _AddSourceMode mode;
  final BookSourceImportAnalysis? analysis;
  final int verificationCompleted;
  final int verificationTotal;
  final int verificationAvailable;
  final String? errorText;
  final bool sheet;
  final ValueChanged<_AddSourceMode> onModeChanged;
  final ValueChanged<bool> onResponsibilityChanged;
  final VoidCallback onCancel;
  final VoidCallback onAnalyzeLink;
  final VoidCallback onChooseFile;
  final VoidCallback onAdd;

  const _AddBookSourcePanel({
    required this.controller,
    required this.connecting,
    required this.responsibilityAccepted,
    required this.mode,
    required this.analysis,
    required this.verificationCompleted,
    required this.verificationTotal,
    required this.verificationAvailable,
    required this.errorText,
    required this.sheet,
    required this.onModeChanged,
    required this.onResponsibilityChanged,
    required this.onCancel,
    required this.onAnalyzeLink,
    required this.onChooseFile,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, sheet ? 4 : 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.bookSourcesAdd,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<_AddSourceMode>(
              key: const Key('bookSourceAddMode'),
              segments: [
                ButtonSegment(
                  value: _AddSourceMode.link,
                  icon: const Icon(Icons.link_rounded),
                  label: Text(context.l10n.bookSourcesImportLink),
                ),
                ButtonSegment(
                  value: _AddSourceMode.file,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(context.l10n.additionalSourcesChooseFile),
                ),
              ],
              selected: {mode},
              onSelectionChanged: connecting
                  ? null
                  : (selection) => onModeChanged(selection.first),
            ),
            const SizedBox(height: 20),
            if (mode == _AddSourceMode.link) ...[
              TextField(
                key: const Key('bookSourceUnifiedUrlField'),
                controller: controller,
                enabled: !connecting,
                autofocus: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: context.l10n.bookSourcesUrlLabel,
                  hintText: context.l10n.bookSourcesUrlHint,
                  prefixIcon: const Icon(Icons.link_rounded),
                  border: const OutlineInputBorder(),
                ),
              ),
            ] else
              OutlinedButton.icon(
                key: const Key('bookSourceChooseJsonButton'),
                onPressed: connecting ? null : onChooseFile,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(context.l10n.additionalSourcesChooseFile),
              ),
            if (analysis case final detected?) ...[
              const SizedBox(height: 14),
              _DetectedSourceSummary(analysis: detected),
            ],
            if (errorText != null) ...[
              const SizedBox(height: 10),
              Text(errorText!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, size: 21, color: scheme.primary),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      context.l10n.bookSourcesNoOfficialSourcesNotice,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('bookSourceResponsibilityCheckbox'),
              value: responsibilityAccepted,
              enabled: !connecting,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                context.l10n.bookSourcesResponsibilityAck,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              onChanged: connecting
                  ? null
                  : (value) => onResponsibilityChanged(value ?? false),
            ),
            if (connecting) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(context.l10n.bookSourcesConnecting),
                ],
              ),
              if (verificationTotal > 0) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: verificationCompleted / verificationTotal,
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.bookSourcesVerificationProgress(
                    verificationCompleted,
                    verificationTotal,
                    verificationAvailable,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: connecting ? null : onCancel,
                    child: Text(context.l10n.bookSourcesCancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('bookSourceConnectButton'),
                    onPressed: connecting || !responsibilityAccepted
                        ? null
                        : analysis == null
                        ? mode == _AddSourceMode.link
                              ? onAnalyzeLink
                              : null
                        : onAdd,
                    child: Text(
                      analysis == null
                          ? context.l10n.bookSourcesAnalyze
                          : context.l10n.bookSourcesConfirm,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetectedSourceSummary extends StatelessWidget {
  const _DetectedSourceSummary({required this.analysis});

  final BookSourceImportAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = analysis.additionalPreview;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            analysis.kind == BookSourceImportKind.orsp
                ? context.l10n.bookSourcesDetectedOrsp
                : context.l10n.bookSourcesDetectedAdditional,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          if (analysis.kind == BookSourceImportKind.orsp)
            Text(analysis.sources.single.name)
          else if (preview != null)
            Text(
              context.l10n.additionalSourcesPreview(
                preview.supported + preview.partial, // 可导入/可使用（含 JS 增强）
                preview.partial,
                preview.unsupported,
              ),
            ),
        ],
      ),
    );
  }
}

class _HealthCheckProgressDialog extends StatefulWidget {
  const _HealthCheckProgressDialog({
    required this.checker,
    required this.sources,
  });

  final BookSourceHealthChecker checker;
  final List<RegisteredBookSource> sources;

  @override
  State<_HealthCheckProgressDialog> createState() =>
      _HealthCheckProgressDialogState();
}

class _HealthCheckProgressDialogState extends State<_HealthCheckProgressDialog> {
  int _completed = 0;
  int _total = 0;
  int _healthy = 0;
  String? _currentId;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final report = await widget.checker.run(
        widget.sources,
        onlyLegado: false,
        onProgress: (completed, total, healthy, currentId) {
          if (!mounted) return;
          setState(() {
            _completed = completed;
            _total = total;
            _healthy = healthy;
            _currentId = currentId;
          });
        },
      );
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      Navigator.of(context).pop(report);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = _total > 0 ? _completed / _total : 0.0;
    String? currentName;
    if (_currentId != null) {
      for (final s in widget.sources) {
        if (s.id == _currentId) {
          currentName = s.name;
          break;
        }
      }
    }
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.health_and_safety_rounded,
            color: scheme.primary,
            size: 40,
          ),
          const SizedBox(height: 12),
          Text(
            '健康检查进行中',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$_completed / $_total'),
              Text(
                '通过 $_healthy',
                style: TextStyle(color: scheme.primary),
              ),
            ],
          ),
          if (currentName != null) ...[
            const SizedBox(height: 8),
            Text(
              '正在检查：$currentName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ],
      ),
    );
  }
}
