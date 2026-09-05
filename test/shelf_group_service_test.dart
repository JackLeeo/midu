import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:midu/data/migration/shelf_group_schema_migration.dart';
import 'package:midu/services/library/shelf_group_service.dart';

void main() {
  late Database database;
  late ShelfGroupService service;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('PRAGMA foreign_keys = ON');
    await database.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        filePath TEXT
      )
    ''');
    await ShelfGroupSchemaMigration.migrate(database);
    // 种子书籍（外键引用目标）。
    for (final id in [1, 2, 3]) {
      await database.insert('books', {
        'id': id,
        'title': '书$id',
        'filePath': '/book$id.txt',
      });
    }
    service = ShelfGroupService(databaseProvider: () async => database);
  });

  tearDown(() => database.close());

  test('新建分组按序排列且分组名唯一', () async {
    final first = await service.addGroup('玄幻');
    final second = await service.addGroup('都市');
    expect(first.name, '玄幻');
    expect(second.sortOrder, greaterThan(first.sortOrder));
    expect(await service.loadGroups(), hasLength(2));
    expect(
      () => service.addGroup('玄幻'),
      throwsA(isA<ShelfGroupNameConflict>()),
    );
  });

  test('空分组名被拒绝', () async {
    expect(
      () => service.addGroup('   '),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('分组重命名与隐藏', () async {
    final group = await service.addGroup('旧名');
    await service.renameGroup(group.id, '新名');
    expect((await service.loadGroups()).single.name, '新名');

    await service.setGroupShown(group.id, false);
    final hidden = await service.loadGroups();
    expect(hidden.single.show, isFalse);
  });

  test('reorderGroups 按给定顺序重排 sort_order', () async {
    final a = await service.addGroup('甲');
    final b = await service.addGroup('乙');
    final c = await service.addGroup('丙');
    await service.reorderGroups([c.id, a.id, b.id]);
    final groups = await service.loadGroups();
    expect(groups.map((g) => g.id).toList(), [c.id, a.id, b.id]);
    expect(groups.map((g) => g.sortOrder).toList(), [0, 1, 2]);
  });

  test('多对多归组：setBooksGroups 全量替换语义', () async {
    final groupA = await service.addGroup('A');
    final groupB = await service.addGroup('B');
    await service.setBooksGroups(bookIds: {1, 2}, groupIds: {groupA.id});
    expect(await service.bookIdsInGroup(groupA.id), {1, 2});
    expect(await service.groupIdsForBook(1), {groupA.id});

    // 全量替换：书 1 从 A 组移入 B 组。
    await service.setBooksGroups(bookIds: {1}, groupIds: {groupB.id});
    expect(await service.groupIdsForBook(1), {groupB.id});
    expect(await service.bookIdsInGroup(groupA.id), {2});
    expect(await service.bookIdsInGroup(groupB.id), {1});

    // 清空归组。
    await service.setBooksGroups(bookIds: {2}, groupIds: const {});
    expect(await service.groupIdsForBook(2), isEmpty);
  });

  test('addBooksToGroup / removeBooksFromGroup 增量语义幂等', () async {
    final group = await service.addGroup('收藏');
    await service.addBooksToGroup(bookIds: {1, 2}, groupId: group.id);
    // 幂等：重复添加同一批书不产生重复关联。
    await service.addBooksToGroup(bookIds: {1, 2}, groupId: group.id);
    expect(await service.bookIdsInGroup(group.id), {1, 2});
    await service.removeBooksFromGroup(bookIds: {1}, groupId: group.id);
    expect(await service.bookIdsInGroup(group.id), {2});
  });

  test('删除分组级联清理关联且不影响书籍', () async {
    final group = await service.addGroup('分组');
    await service.setBooksGroups(bookIds: {1}, groupIds: {group.id});
    await service.deleteGroup(group.id);
    expect(await service.loadGroups(), isEmpty);
    // 关联表应被级联清理（外键开启时）。
    final rows = await database.query(
      'book_group_links',
      where: 'book_id = ?',
      whereArgs: [1],
    );
    expect(rows, isEmpty);
  });

  test('分组书籍计数', () async {
    final group = await service.addGroup('计数');
    await service.setBooksGroups(bookIds: {1, 2, 3}, groupIds: {group.id});
    expect(await service.bookCountForGroup(group.id), 3);
    expect(
      await service.bookCountsForGroups({group.id}),
      {group.id: 3},
    );
  });
}