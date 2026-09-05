// 文件说明：书架分组多选弹层（对标 Legado GroupSelectDialog）。
// 技术要点：勾选即为最终归属（全量替换语义由调用方 setBooksGroups 执行）、
//          支持内联新建分组并自动勾选；service 可注入便于测试。
import 'package:flutter/material.dart';

import 'package:midu/services/library/shelf_group_service.dart';
import 'package:midu/utils/localization_extension.dart';

/// 弹出分组多选弹层，返回最终要归属的分组 id 集合；取消时返回 null。
Future<Set<int>?> showShelfGroupPickerSheet({
  required BuildContext context,
  required ShelfGroupService service,
  required Set<int> initiallyChecked,
}) {
  return showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => _ShelfGroupPickerSheet(
      service: service,
      initiallyChecked: initiallyChecked,
    ),
  );
}

class _ShelfGroupPickerSheet extends StatefulWidget {
  const _ShelfGroupPickerSheet({
    required this.service,
    required this.initiallyChecked,
  });

  final ShelfGroupService service;
  final Set<int> initiallyChecked;

  @override
  State<_ShelfGroupPickerSheet> createState() => _ShelfGroupPickerSheetState();
}

class _ShelfGroupPickerSheetState extends State<_ShelfGroupPickerSheet> {
  late final Set<int> _checked;
  List<ShelfGroup>? _groups;

  @override
  void initState() {
    super.initState();
    _checked = {...widget.initiallyChecked};
    widget.service.loadGroups().then((groups) {
      if (mounted) setState(() => _groups = groups);
    });
  }

  Future<void> _createGroup() async {
    final name = await _promptGroupName();
    if (name == null || !mounted) return;
    final l10n = context.l10n;
    try {
      final group = await widget.service.addGroup(name);
      if (!mounted) return;
      setState(() {
        _groups = [...?_groups, group];
        _checked.add(group.id);
      });
    } on ShelfGroupNameConflict catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.shelfGroupNameExists(error.name))),
      );
    } on ArgumentError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.shelfGroupNameEmpty)),
      );
    }
  }

  Future<String?> _promptGroupName() {
    final controller = TextEditingController();
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final l10n = context.l10n;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.shelfGroupNewGroup),
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
    final l10n = context.l10n;
    final groups = _groups;
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + safeBottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                l10n.shelfGroupMoveTo,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            if (groups == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (groups.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    l10n.shelfGroupEmptyHint,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final group in groups) _buildGroupRow(group),
                  ],
                ),
              ),
            _buildNewGroupTile(),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('shelf-group-picker-apply'),
                    onPressed: () => Navigator.of(context).pop(_checked),
                    child: Text(l10n.shelfGroupAssigned),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupRow(ShelfGroup group) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          if (!_checked.remove(group.id)) {
            _checked.add(group.id);
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.folder_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Checkbox(
              value: _checked.contains(group.id),
              onChanged: (value) {
                setState(() {
                  if (value ?? false) {
                    _checked.add(group.id);
                  } else {
                    _checked.remove(group.id);
                  }
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewGroupTile() {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return InkWell(
      key: const ValueKey('shelf-group-picker-new'),
      borderRadius: BorderRadius.circular(12),
      onTap: _createGroup,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Text(
              l10n.shelfGroupNewGroup,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}