import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:midu/l10n/app_localizations.dart';
import 'package:midu/pages/library/shelf_group_manage_page.dart';
import 'package:midu/services/library/shelf_group_service.dart';

import 'helpers/fake_shelf_group_service.dart';

void main() {
  late FakeShelfGroupService service;

  setUp(() {
    service = FakeShelfGroupService();
  });

  Future<void> pumpManagePage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ShelfGroupManagePage(service: service),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('lists groups with book counts', (tester) async {
    final fantasy = await service.addGroup('玄幻');
    final urban = await service.addGroup('都市');
    service.counts = {fantasy.id: 2, urban.id: 0};

    await pumpManagePage(tester);

    expect(find.text('Manage groups'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);
    expect(find.text('2 books'), findsOneWidget);
    expect(find.text('0 books'), findsOneWidget);
    expect(find.text('New group'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creates a group with the top action', (tester) async {
    await pumpManagePage(tester);

    await tester.tap(find.byKey(const ValueKey('shelf-group-manage-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '新书单');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('新书单'), findsOneWidget);
    expect(service.groups.single.name, '新书单');
  });

  testWidgets('renames, hides and deletes via the group menu', (tester) async {
    final group = await service.addGroup('旧书单');
    service.counts = {group.id: 1};
    await pumpManagePage(tester);

    // 重命名。
    Future<void> openMenu() async {
      await tester.tap(
        find.byWidgetPredicate((w) => w is PopupMenuButton),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    }

    await openMenu();
    await tester.tap(find.text('Rename group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '新书单');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('新书单'), findsOneWidget);
    final renamed = service.groups.single;
    expect(renamed.name, '新书单');
    expect(renamed.show, isTrue);

    // 隐藏分组：菜单项变为「显示分组」。
    await openMenu();
    await tester.tap(find.text('Hide group'));
    await tester.pumpAndSettle();
    expect(service.groups.single.show, isFalse);
    await openMenu();
    expect(find.text('Show group'), findsOneWidget);

    // 删除分组（先确认对话框）。
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Books in it will not be deleted'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(service.groups, isEmpty);
  });

  testWidgets('group names must be unique', (tester) async {
    await service.addGroup('玄幻');
    await service.addGroup('都市');
    await pumpManagePage(tester);

    await tester.tap(find.byKey(const ValueKey('shelf-group-manage-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '玄幻');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('already exists'), findsOneWidget);
    expect(service.groups, hasLength(2));
  });
}