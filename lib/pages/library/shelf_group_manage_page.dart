// 文件说明：书架分组管理页（对标 Legado GroupManageDialog 的独立页形态）。
// 技术要点：分组增删改、显示/隐藏、拖拽排序；任一改动都会以 pop(true) 通知
//          书库页刷新分组标签条；service 可注入便于测试。
import 'package:flutter/material.dart';

import 'package:midu/services/library/shelf_group_service.dart';
import 'package:midu/utils/localization_extension.dart';

class ShelfGroupManagePage extends StatefulWidget {
  const ShelfGroupManagePage({super.key, this.service});

  final ShelfGroupService? service;

  @override
  State<ShelfGroupManagePage> createState() => _ShelfGroupManagePageState();
}

class _ShelfGroupManagePageState extends State<ShelfGroupManagePage> {
  late final ShelfGroupService _service;
  List<ShelfGroup>? _groups;
  Map<int, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ShelfGroupService();
    _load();
  }

  Future<void> _load() async {
    final groups = await _service.loadGroups();
    final counts = await _service.bookCountsForGroups(
      groups.map((g) => g.id).toSet(),
    );
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _counts = counts;
    });
  }

  void _changed() {
    // 标记有改动，pop 时以 true 通知书库页刷新。
    _dirty = true;
  }

  bool _dirty = false;

  Future<void> _createGroup() async {
    final name = await _promptGroupName();
    if (name == null || !mounted) return;
    final l10n = context.l10n;
    try {
      await _service.addGroup(name);
      _changed();
      await _load();
    } on ShelfGroupNameConflict catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.shelfGroupNameExists(error.name))),
      );
    } on ArgumentError {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.shelfGroupNameEmpty)));
    }
  }

  Future<void> _renameGroup(ShelfGroup group) async {
    final name = await _promptGroupName(initial: group.name);
    if (name == null || !mounted) return;
    final l10n = context.l10n;
    try {
      await _service.renameGroup(group.id, name);
      _changed();
      await _load();
    } on ShelfGroupNameConflict catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.shelfGroupNameExists(error.name))),
      );
    } on ArgumentError {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.shelfGroupNameEmpty)));
    }
  }

  Future<void> _toggleShown(ShelfGroup group) async {
    await _service.setGroupShown(group.id, !group.show);
    _changed();
    await _load();
  }

  Future<void> _deleteGroup(ShelfGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(context.l10n.shelfGroupDeleteTitle),
        content: Text(context.l10n.shelfGroupDeleteConfirm(group.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _service.deleteGroup(group.id);
    _changed();
    await _load();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final groups = _groups;
    if (groups == null) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final ordered = [...groups];
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    await _service.reorderGroups(ordered.map((g) => g.id).toList());
    _changed();
    await _load();
  }

  Future<String?> _promptGroupName({String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final l10n = context.l10n;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(initial == null ? l10n.shelfGroupNewGroup : l10n.shelfGroupRename),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: InputDecoration(hintText: l10n.shelfGroupNewGroup),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = _groups;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pop(_dirty);
        }
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          leading: BackButton(
            onPressed: () => Navigator.of(context).pop(_dirty),
          ),
          title: Text(context.l10n.shelfGroupManage),
          actions: [
            TextButton.icon(
              key: const ValueKey('shelf-group-manage-add'),
              onPressed: _createGroup,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(context.l10n.shelfGroupNewGroup),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: groups == null
            ? const Center(child: CircularProgressIndicator())
            : groups.isEmpty
            ? Center(
                child: Text(
                  context.l10n.shelfGroupEmptyHint,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            : ReorderableListView.builder(
                key: const ValueKey('shelf-group-manage-list'),
                itemCount: groups.length,
                onReorder: _reorder,
                itemBuilder: (context, index) =>
                    _buildGroupTile(groups[index]),
              ),
      ),
    );
  }

  Widget _buildGroupTile(ShelfGroup group) {
    final scheme = Theme.of(context).colorScheme;
    return ReorderableDelayedDragStartListener(
      key: ValueKey('shelf-group-${group.id}'),
      index: groupsIndexOf(group),
      child: ListTile(
        onTap: () => _renameGroup(group),
        leading: Icon(
          Icons.drag_indicator,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        title: Text(
          group.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: group.show ? null : scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(context.l10n.shelfGroupTabCount(_counts[group.id] ?? 0)),
        trailing: PopupMenuButton<_GroupAction>(
          tooltip: context.l10n.shelfGroupManage,
          onSelected: (action) {
            switch (action) {
              case _GroupAction.rename:
                _renameGroup(group);
              case _GroupAction.toggleShown:
                _toggleShown(group);
              case _GroupAction.delete:
                _deleteGroup(group);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _GroupAction.rename,
              child: Text(context.l10n.shelfGroupRename),
            ),
            PopupMenuItem(
              value: _GroupAction.toggleShown,
              child: Text(
                group.show
                    ? context.l10n.shelfGroupHide
                    : context.l10n.shelfGroupShow,
              ),
            ),
            PopupMenuItem(
              value: _GroupAction.delete,
              child: Text(
                context.l10n.shelfGroupDeleteTitle,
                style: TextStyle(color: scheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int groupsIndexOf(ShelfGroup group) => _groups?.indexOf(group) ?? 0;
}

enum _GroupAction { rename, toggleShown, delete }