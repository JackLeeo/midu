import 'package:midu/services/library/shelf_group_service.dart';

/// 纯内存分组服务，供 widget 测试使用：FakeAsync 环境无法完成 sqflite ffi
/// 的真实 IO；DB 侧语义由 shelf_group_service_test.dart 覆盖，这里只负责 UI。
class FakeShelfGroupService extends ShelfGroupService {
  FakeShelfGroupService();

  final List<ShelfGroup> groups = [];
  Map<int, int> counts = const {};
  int _nextId = 1;

  @override
  Future<List<ShelfGroup>> loadGroups() async => List.unmodifiable(groups);

  @override
  Future<ShelfGroup> addGroup(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '分组名不能为空');
    }
    if (groups.any((g) => g.name == trimmed)) {
      throw ShelfGroupNameConflict(trimmed);
    }
    final group = ShelfGroup(
      id: _nextId++,
      name: trimmed,
      sortOrder: groups.length,
    );
    groups.add(group);
    return group;
  }

  @override
  Future<void> renameGroup(int groupId, String name) async {
    final index = _indexOf(groupId);
    groups[index] = groups[index].copyWith(name: name.trim());
  }

  @override
  Future<void> setGroupShown(int groupId, bool show) async {
    final index = _indexOf(groupId);
    groups[index] = groups[index].copyWith(show: show);
  }

  @override
  Future<void> deleteGroup(int groupId) async {
    groups.removeWhere((g) => g.id == groupId);
  }

  @override
  Future<void> reorderGroups(List<int> orderedIds) async {
    final byId = {for (final g in groups) g.id: g};
    final reordered = orderedIds
        .map((id) => byId[id])
        .whereType<ShelfGroup>()
        .toList();
    groups
      ..clear()
      ..addAll(reordered);
  }

  @override
  Future<Map<int, int>> bookCountsForGroups(Set<int> groupIds) async => {
    for (final id in groupIds) id: counts[id] ?? 0,
  };

  int _indexOf(int groupId) => groups.indexWhere((g) => g.id == groupId);
}