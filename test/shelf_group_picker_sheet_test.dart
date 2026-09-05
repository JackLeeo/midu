import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:midu/l10n/app_localizations.dart';
import 'package:midu/pages/library/shelf_group_picker_sheet.dart';
import 'package:midu/services/library/shelf_group_service.dart';

/// 纯内存分组服务：widget 测试的 FakeAsync 环境无法完成 sqflite ffi 的真实
/// IO，DB 侧语义已由 shelf_group_service_test.dart 覆盖，这里只验证 UI。
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
    final index = groups.indexWhere((g) => g.id == groupId);
    groups[index] = groups[index].copyWith(name: name.trim());
  }

  @override
  Future<void> setGroupShown(int groupId, bool show) async {
    final index = groups.indexWhere((g) => g.id == groupId);
    groups[index] = groups[index].copyWith(show: show);
  }

  @override
  Future<void> deleteGroup(int groupId) async {
    groups.removeWhere((g) => g.id == groupId);
  }

  @override
  Future<void> reorderGroups(List<int> orderedIds) async {}

  @override
  Future<Map<int, int>> bookCountsForGroups(Set<int> groupIds) async => {
    for (final id in groupIds) id: counts[id] ?? 0,
  };
}

void main() {
  late FakeShelfGroupService service;

  setUp(() {
    service = FakeShelfGroupService();
  });

  Future<Future<Set<int>?>?> pumpPicker(
    WidgetTester tester, {
    Set<int> initiallyChecked = const {},
  }) async {
    Future<Set<int>?>? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  result = showShelfGroupPickerSheet(
                    context: context,
                    service: service,
                    initiallyChecked: initiallyChecked,
                  );
                },
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open picker'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return result;
  }

  bool checkedOf(WidgetTester tester, String name) =>
      tester
          .widget<Checkbox>(
            find.descendant(
              of: find.widgetWithText(InkWell, name),
              matching: find.byType(Checkbox),
            ),
          )
          .value ??
      false;

  testWidgets('shows every group with initial membership checked', (
    tester,
  ) async {
    final a = await service.addGroup('玄幻');
    final b = await service.addGroup('都市');

    final result = await pumpPicker(tester, initiallyChecked: {b.id});

    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);
    expect(checkedOf(tester, '玄幻'), isFalse);
    expect(checkedOf(tester, '都市'), isTrue);

    // 不改动直接确定，返回初始集合。
    await tester.tap(
      find.byKey(const ValueKey('shelf-group-picker-apply')),
    );
    await tester.pumpAndSettle();
    expect(await result, {b.id});
    expect(service.groups.map((g) => g.id), {a.id, b.id});
  });

  testWidgets('creating a group inline auto-checks it', (tester) async {
    await service.addGroup('已有分组');
    final result = await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('shelf-group-picker-new')));
    await tester.pumpAndSettle();
    expect(find.text('New group'), findsWidgets);

    await tester.enterText(find.byType(TextField).last, '收藏夹');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // 新分组立即出现在列表中且已勾选。
    expect(find.text('收藏夹'), findsOneWidget);
    final newGroup = service.groups.singleWhere((g) => g.name == '收藏夹');
    expect(checkedOf(tester, '收藏夹'), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('shelf-group-picker-apply')),
    );
    await tester.pumpAndSettle();
    expect(await result, {newGroup.id});
  });

  testWidgets('toggling a row changes the returned membership', (
    tester,
  ) async {
    final a = await service.addGroup('A组');
    final b = await service.addGroup('B组');
    final result = await pumpPicker(tester, initiallyChecked: {a.id});

    // 取消 A、勾选 B。
    await tester.tap(find.widgetWithText(InkWell, 'A组'));
    await tester.pump();
    await tester.tap(find.widgetWithText(InkWell, 'B组'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('shelf-group-picker-apply')),
    );
    await tester.pumpAndSettle();

    expect(await result, {b.id});
  });

  testWidgets('duplicate inline group name shows an error snackbar', (
    tester,
  ) async {
    await service.addGroup('重名');
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('shelf-group-picker-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '重名');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('already exists'), findsOneWidget);
    expect(service.groups, hasLength(1));
  });
}