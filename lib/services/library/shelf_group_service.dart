// 文件说明：书架分组服务，对标 Legado 书架分组（多本书可归入多个分组）。
// 技术要点：分组实体 book_groups + 多对多关联 book_group_links；
//          databaseProvider 可注入，便于测试使用内存库。
import 'package:midu/services/core/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 书架分组实体（对标 Legado BookGroup 的精简形态）。
class ShelfGroup {
  const ShelfGroup({
    required this.id,
    required this.name,
    required this.sortOrder,
    this.show = true,
  });

  factory ShelfGroup.fromMap(Map<String, dynamic> map) {
    return ShelfGroup(
      id: map['id'] as int,
      name: map['group_name'] as String,
      sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
      show: ((map['show'] as num?)?.toInt() ?? 1) != 0,
    );
  }

  final int id;
  final String name;
  final int sortOrder;
  final bool show;

  ShelfGroup copyWith({String? name, int? sortOrder, bool? show}) {
    return ShelfGroup(
      id: id,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      show: show ?? this.show,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'group_name': name,
    'sort_order': sortOrder,
    'show': show ? 1 : 0,
  };
}

/// 书架分组服务：分组增删改查 / 排序 / 书籍归组。
class ShelfGroupService {
  ShelfGroupService({Future<Database> Function()? databaseProvider})
    : _databaseProvider = databaseProvider ?? (() => DatabaseService().database);

  final Future<Database> Function() _databaseProvider;

  Future<Database> get _database => _databaseProvider();

  /// 按展示顺序加载全部分组（含隐藏组，管理页用）。
  Future<List<ShelfGroup>> loadGroups() async {
    final db = await _database;
    final maps = await db.query(
      'book_groups',
      orderBy: 'sort_order ASC, id ASC',
    );
    return maps.map(ShelfGroup.fromMap).toList(growable: false);
  }

  /// 新建分组；返回创建后的实体。重名时抛 [ShelfGroupNameConflict]。
  Future<ShelfGroup> addGroup(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '分组名不能为空');
    }
    final db = await _database;
    final exists = await db.query(
      'book_groups',
      where: 'group_name = ?',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      throw ShelfGroupNameConflict(trimmed);
    }
    final nextOrder = await _nextSortOrder(db);
    final id = await db.insert('book_groups', {
      'group_name': trimmed,
      'sort_order': nextOrder,
      'show': 1,
    });
    return ShelfGroup(id: id, name: trimmed, sortOrder: nextOrder);
  }

  Future<int> _nextSortOrder(Database db) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next FROM book_groups',
    );
    return (rows.first['next'] as num?)?.toInt() ?? 0;
  }

  /// 重命名分组；重名抛 [ShelfGroupNameConflict]。
  Future<void> renameGroup(int groupId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '分组名不能为空');
    }
    final db = await _database;
    final exists = await db.query(
      'book_groups',
      where: 'group_name = ? AND id != ?',
      whereArgs: [trimmed, groupId],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      throw ShelfGroupNameConflict(trimmed);
    }
    await db.update(
      'book_groups',
      {'group_name': trimmed},
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  /// 删除分组（关联书籍自动解除归组，不删除书籍本身）。
  Future<void> deleteGroup(int groupId) async {
    final db = await _database;
    await db.delete('book_groups', where: 'id = ?', whereArgs: [groupId]);
  }

  /// 按给定顺序整体重排分组（对标 Legado 分组拖拽排序）。
  Future<void> reorderGroups(List<int> orderedIds) async {
    final db = await _database;
    await db.transaction((txn) async {
      for (var index = 0; index < orderedIds.length; index += 1) {
        await txn.update(
          'book_groups',
          {'sort_order': index},
          where: 'id = ?',
          whereArgs: [orderedIds[index]],
        );
      }
    });
  }

  /// 切换分组显示/隐藏。隐藏组在书库分组条中不展示（管理页仍可见）。
  Future<void> setGroupShown(int groupId, bool show) async {
    final db = await _database;
    await db.update(
      'book_groups',
      {'show': show ? 1 : 0},
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  /// 分组内书籍 id 集合。
  Future<Set<int>> bookIdsInGroup(int groupId) async {
    final db = await _database;
    final rows = await db.query(
      'book_group_links',
      columns: ['book_id'],
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    return rows.map((row) => row['book_id'] as int).toSet();
  }

  /// 一本书归属的分组 id 集合。
  Future<Set<int>> groupIdsForBook(int bookId) async {
    final db = await _database;
    final rows = await db.query(
      'book_group_links',
      columns: ['group_id'],
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    return rows.map((row) => row['group_id'] as int).toSet();
  }

  /// 多本书籍-多分组的全量归组（对标 Legado 的 group 位掩码语义）：
  /// 先清除这批书的所有归属，再写入目标分组。已存在的组合写幂等。
  Future<void> setBooksGroups({
    required Set<int> bookIds,
    required Set<int> groupIds,
  }) async {
    if (bookIds.isEmpty) return;
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'book_group_links',
        where: 'book_id IN (${List.filled(bookIds.length, '?').join(',')})',
        whereArgs: bookIds.toList(),
      );
      if (groupIds.isEmpty) return;
      for (final bookId in bookIds) {
        for (final groupId in groupIds) {
          try {
            await txn.insert('book_group_links', {
              'book_id': bookId,
              'group_id': groupId,
            });
          } on DatabaseException {
            // UNIQUE 冲突：组合已存在，幂等跳过。
          }
        }
      }
    });
  }

  /// 把书籍加入/移出单个分组（增量语义，用于分组内挑选）。
  Future<void> addBooksToGroup({
    required Set<int> bookIds,
    required int groupId,
  }) async {
    if (bookIds.isEmpty) return;
    final db = await _database;
    await db.transaction((txn) async {
      for (final bookId in bookIds) {
        try {
          await txn.insert('book_group_links', {
            'book_id': bookId,
            'group_id': groupId,
          });
        } on DatabaseException {
          // 幂等跳过已存在的组合。
        }
      }
    });
  }

  Future<void> removeBooksFromGroup({
    required Set<int> bookIds,
    required int groupId,
  }) async {
    if (bookIds.isEmpty) return;
    final db = await _database;
    await db.delete(
      'book_group_links',
      where: 'group_id = ? AND book_id IN (${List.filled(bookIds.length, '?').join(',')})',
      whereArgs: [groupId, ...bookIds],
    );
  }

  /// 显示中分组的书籍数（管理页角标）。
  Future<int> bookCountForGroup(int groupId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM book_group_links WHERE group_id = ?',
      [groupId],
    );
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  /// 多组一次性计数（避免管理页逐组查询）。
  Future<Map<int, int>> bookCountsForGroups(Set<int> groupIds) async {
    if (groupIds.isEmpty) return const {};
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT group_id, COUNT(*) AS count FROM book_group_links '
      'WHERE group_id IN (${List.filled(groupIds.length, '?').join(',')}) '
      'GROUP BY group_id',
      groupIds.toList(),
    );
    return {
      for (final row in rows) (row['group_id'] as int): (row['count'] as num).toInt(),
    };
  }
}

/// 分组名重复（对标 Legado 分组名唯一约束）。
class ShelfGroupNameConflict implements Exception {
  const ShelfGroupNameConflict(this.name);

  final String name;

  @override
  String toString() => '已存在同名分组「$name」';
}