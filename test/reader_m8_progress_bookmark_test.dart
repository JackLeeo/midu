// M8 阅读进度与书签管理专项测试：
// 1. ReadingProgressMigration v24 幂等迁移（last_chapter_index/title/last_read_at + 索引）
// 2. Book 模型新字段 toMap/fromMap/copyWith 序列化往返
// 3. BookDao.updateReadingPosition 回写最后阅读章节与时间
// 4. BookmarkDao 备注编辑 + BookmarkManagerPage 展示/编辑/删除交互
//
// 数据库测试沿用仓库既有约定（home_dashboard_page_test.dart）：
// - setUpAll 内 sqfliteFfiInit + 替换默认 factory + mock path_provider 通道
// - testWidgets 内真实 IO（SQLite FFI isolate、DAO）统一包在 tester.runAsync 中

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midu/data/migration/reading_progress_migration.dart';
import 'package:midu/l10n/app_localizations.dart';
import 'package:midu/models/book.dart';
import 'package:midu/models/bookmark.dart';
import 'package:midu/pages/library/bookmark_manager_page.dart';
import 'package:midu/services/books/book_dao.dart';
import 'package:midu/services/books/bookmark_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final databaseDirectory = await Directory.systemTemp.createTemp(
      'm8-progress-bookmark-',
    );
    addTearDown(() async {
      try {
        await databaseDirectory.delete(recursive: true);
      } catch (_) {
        // DatabaseService 单例仍持有打开的 SQLite 连接（Windows 文件锁），
        // 清理失败可忽略，不影响测试结果。
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => databaseDirectory.path,
        );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReadingProgressMigration (v24)', () {
    test('向后端对齐新增 last_* 列并可重复执行（幂等）', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT NOT NULL)',
      );

      await ReadingProgressMigration.migrate(db);
      await ReadingProgressMigration.migrate(db);

      final columns = await db.rawQuery('PRAGMA table_info(books)');
      expect(
        columns.map((row) => row['name']),
        containsAll(<String>[
          'last_chapter_index',
          'last_chapter_title',
          'last_read_at',
        ]),
      );
      expect(
        columns.where((row) => row['name'] == 'last_read_at').first['type'],
        'INTEGER',
      );

      final indexes = await db.rawQuery('PRAGMA index_list(books)');
      expect(
        indexes.map((row) => row['name']),
        contains('idx_books_last_read_at'),
      );
    });

    test('不破坏既有列', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE books(id INTEGER PRIMARY KEY, currentPage INTEGER)',
      );

      await ReadingProgressMigration.migrate(db);

      final columns = await db.rawQuery('PRAGMA table_info(books)');
      expect(columns.map((row) => row['name']), contains('currentPage'));
      expect(columns.map((row) => row['name']), contains('last_read_at'));
    });
  });

  group('Book 模型 last_* 字段', () {
    test('toMap/fromMap 往返保留阅读进度字段', () {
      final book = Book(
        id: 7,
        title: '示例小说',
        filePath: '/tmp/book.txt',
        format: 'txt',
        lastChapterIndex: 12,
        lastChapterTitle: '第十二章 风起',
        lastReadAt: 1725000000000,
      );

      final restored = Book.fromMap(book.toMap());
      expect(restored.lastChapterIndex, 12);
      expect(restored.lastChapterTitle, '第十二章 风起');
      expect(restored.lastReadAt, 1725000000000);
      expect(restored.hasReadProgress, isTrue);
    });

    test('无阅读记录时 hasReadProgress 为 false', () {
      final book = Book(
        title: '未读',
        filePath: '/tmp/unread.txt',
        format: 'txt',
      );
      expect(book.hasReadProgress, isFalse);
      expect(book.progress, 0);
    });

    test('copyWith 更新最后阅读字段', () {
      final book = Book(
        title: '示例',
        filePath: '/tmp/b.txt',
        format: 'txt',
      );
      final updated = book.copyWith(
        lastChapterIndex: 3,
        lastChapterTitle: '第4章',
        lastReadAt: 999,
      );
      expect(updated.lastChapterIndex, 3);
      expect(updated.lastChapterTitle, '第4章');
      expect(updated.lastReadAt, 999);
      expect(updated.hasReadProgress, isTrue);
    });
  });

  group('BookDao 进度回写', () {
    test('updateReadingPosition 写配置并持久化可读', () async {
      final dao = BookDao();
      final book = Book(
        title: '回写测试',
        filePath: '/tmp/write-back.txt',
        format: 'txt',
        contentHash: 'write-back-${DateTime.now().microsecondsSinceEpoch}',
      );
      final id = await dao.insertBook(book);

      await dao.updateReadingPosition(
        id,
        lastChapterIndex: 5,
        lastChapterTitle: '第五章',
        readingProgress: 0.42,
      );

      final loaded = await dao.getBookById(id);
      expect(loaded, isNotNull);
      expect(loaded!.lastChapterIndex, 5);
      expect(loaded.lastChapterTitle, '第五章');
      expect(loaded.lastReadAt, isNotNull);
      expect(loaded.readingProgress, closeTo(0.42, 0.001));

      await dao.deleteBook(id);
    });

    test('updateBookCanonicalLocator 可选择回写章节字段', () async {
      final dao = BookDao();
      final book = Book(
        title: '定位回写',
        filePath: '/tmp/locator.txt',
        format: 'txt',
        contentHash: 'locator-write-${DateTime.now().microsecondsSinceEpoch}',
      );
      final id = await dao.insertBook(book);

      await dao.updateBookCanonicalLocator(
        id,
        '{"chapterId":"c1","offset":120}',
        null,
        'sig-1',
        6,
        readingProgress: 0.5,
        lastChapterIndex: 6,
        lastChapterTitle: '第六章',
      );

      final loaded = await dao.getBookById(id);
      expect(loaded!.lastChapterTitle, '第六章');
      expect(loaded.lastReadAt, isNotNull);

      await dao.deleteBook(id);
    });
  });

  group('BookmarkDao 备注编辑', () {
    test('updateBookmarkNote 更新备注并可读回', () async {
      final dao = BookmarkDao();
      final bookDao = BookDao();
      final book = Book(
        title: '备注书签',
        filePath: '/tmp/note-book.txt',
        format: 'txt',
        contentHash: 'note-bookmark-${DateTime.now().microsecondsSinceEpoch}',
      );
      final bookId = await bookDao.insertBook(book);
      addTearDown(() => bookDao.deleteBook(bookId));

      final bookmark = Bookmark(
        bookId: bookId,
        pageNumber: 3,
        chapterIndex: 2,
        chapterTitle: '第三章',
        excerpt: '示例摘录',
        note: '旧备注',
      );
      final bookmarkId = await dao.insertBookmark(bookmark);
      expect(bookmarkId, greaterThan(0));

      await dao.updateBookmarkNote(bookmarkId, '新的备注内容');

      final bookmarks = await dao.getBookmarksForBook(bookId);
      expect(bookmarks, hasLength(1));
      expect(bookmarks.first.note, '新的备注内容');
      expect(bookmarks.first.chapterTitle, '第三章');
    });
  });

  group('BookmarkManagerPage 交互', () {
    Widget buildApp(Book book) {
      return MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookmarkManagerPage(book: book),
      );
    }

    testWidgets('展示书签、编辑备注菜单与对话框', (tester) async {
      final bookDao = BookDao();
      final bookmarkDao = BookmarkDao();
      final bookId = await tester.runAsync(() async {
        final book = Book(
          title: '管理页测试',
          author: '作者',
          filePath: '/tmp/mgr.txt',
          format: 'txt',
          contentHash: 'mgr-${DateTime.now().microsecondsSinceEpoch}',
        );
        final id = await bookDao.insertBook(book);
        await bookmarkDao.insertBookmark(
          Bookmark(
            bookId: id,
            pageNumber: 1,
            chapterIndex: 0,
            chapterTitle: '第一章 起',
            excerpt: '这是摘录文本',
            note: '',
          ),
        );
        return id;
      });

      final fullBook = await tester.runAsync(() => bookDao.getBookById(bookId!));
      await tester.pumpWidget(buildApp(fullBook!));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pumpAndSettle();

      // 书签标题展示
      expect(find.text('第一章 起'), findsOneWidget);
      expect(find.text('这是摘录文本'), findsOneWidget);

      // 打开菜单并选择编辑
      final editMenu = find.byIcon(Icons.more_vert).last;
      await tester.tap(editMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑').last);
      await tester.pumpAndSettle();

      // 对话框可见，输入备注并保存
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-manager-note-editor')),
        '我的新备注',
      );
      await tester.tap(find.text('保存'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pumpAndSettle();

      expect(find.text('我的新备注'), findsOneWidget);

      // 持久化校验
      final stored = await tester.runAsync(
        () => bookmarkDao.getBookmarksForBook(bookId!),
      );
      expect(stored!.first.note, '我的新备注');
    });

    testWidgets('删除书签后列表为空态', (tester) async {
      final bookDao = BookDao();
      final bookmarkDao = BookmarkDao();
      final bookId = await tester.runAsync(() async {
        final book = Book(
          title: '删除测试',
          filePath: '/tmp/del.txt',
          format: 'txt',
          contentHash: 'del-mgr-${DateTime.now().microsecondsSinceEpoch}',
        );
        final id = await bookDao.insertBook(book);
        await bookmarkDao.insertBookmark(
          Bookmark(
            bookId: id,
            pageNumber: 9,
            chapterIndex: 8,
            chapterTitle: '第九章',
            excerpt: '待删除',
          ),
        );
        return id;
      });

      final fullBook = await tester.runAsync(() => bookDao.getBookById(bookId!));
      await tester.pumpWidget(buildApp(fullBook!));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pumpAndSettle();
      expect(find.text('第九章'), findsOneWidget);

      // 打开菜单并删除
      final deleteMenu = find.byIcon(Icons.more_vert).last;
      await tester.tap(deleteMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      await tester.pumpAndSettle();

      expect(find.text('第九章'), findsNothing);
      final remaining = await tester.runAsync(
        () => bookmarkDao.getBookmarksForBook(bookId!),
      );
      expect(remaining, isEmpty);
    });
  });
}