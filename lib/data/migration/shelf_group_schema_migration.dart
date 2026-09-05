// 文件说明：书架分组（ShelfGroup）数据模型迁移，对标 Legado 书架分组。
// 技术要点：分组实体一张表 + 书籍-分组多对多关联一张表（替代 Legado 的
// bitmask 单列，无 63 组上限且 SQL 语义更清晰）。
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ShelfGroupSchemaMigration {
  static Future<void> migrate(Database db) async {
    // 分组实体：name 唯一，sort_order 递增即可按展示顺序排列。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_groups(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_name TEXT NOT NULL UNIQUE,
        sort_order INTEGER NOT NULL DEFAULT 0,
        show INTEGER NOT NULL DEFAULT 1
      )
    ''');
    // 书籍-分组关联（多对多）：删书/删组时级联清理。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_group_links(
        book_id INTEGER NOT NULL,
        group_id INTEGER NOT NULL,
        PRIMARY KEY (book_id, group_id),
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE,
        FOREIGN KEY (group_id) REFERENCES book_groups (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_book_group_links_group '
      'ON book_group_links (group_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_book_group_links_book '
      'ON book_group_links (book_id)',
    );
  }
}