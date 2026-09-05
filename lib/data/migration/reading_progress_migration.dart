// 文件说明：阅读进度增强迁移——为 books 表添加最后阅读章节与时间字段。
// 技术要点：幂等 SQLite 迁移（先检查列是否存在再 ALTER）、forward-only、兼容历史数据库。
//
// 对齐 Legado `BookProgress`（durChapterIndex/durChapterTitle/durChapterTime）：
// - last_chapter_index：上次阅读的章节索引（0-based）
// - last_chapter_title：上次阅读的章节标题
// - last_read_at：上次阅读时间（epoch 毫秒，非 null 表示存在阅读记录）
//
// 设计原则：
// - 幂等：每条 ALTER TABLE ADD COLUMN 前先检查列是否已存在
// - 安全：只添加 nullable 列，不删除/不修改既有数据，旧版本代码自然兼容
// - forward-only：不提供 downgrade 路径
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ReadingProgressMigration {
  static const int migrationVersion = 24;

  static Future<void> migrate(DatabaseExecutor db) async {
    final info = await db.rawQuery('PRAGMA table_info(books)');
    final columns = info.map((row) => row['name'] as String).toSet();

    if (!columns.contains('last_chapter_index')) {
      await db.execute('ALTER TABLE books ADD COLUMN last_chapter_index INTEGER');
    }
    if (!columns.contains('last_chapter_title')) {
      await db.execute('ALTER TABLE books ADD COLUMN last_chapter_title TEXT');
    }
    if (!columns.contains('last_read_at')) {
      await db.execute('ALTER TABLE books ADD COLUMN last_read_at INTEGER');
    }

    // 加速书架"最近阅读"排序查询
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_books_last_read_at '
      'ON books(last_read_at)',
    );
  }
}