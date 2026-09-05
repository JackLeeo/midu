// M2 对标 Legado：书源调试记录器 + 运行时调试辅助测试。
//
// 覆盖：
// - BookSourceDebugRecorder 环形缓冲 / request↔response order 关联 / clear / 通知；
// - LegadoRuntime.debugEvalJs（JS 单测走 flutter_js 沙箱）；
// - LegadoRuntime.debugEvaluateRule（HTML + 规则求值，不联网）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/services/book_source_debug_recorder.dart';
import 'package:midu/book_sources/services/book_source_client.dart';

import 'helpers/flutter_js_sandbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('BookSourceDebugRecorder', () {
    test('请求与响应写入并共享 order', () {
      final recorder = BookSourceDebugRecorder();
      final order = recorder.recordRequest(
        stage: BookSourceDebugStage.search,
        sourceName: '测试源',
        url: 'https://example.com/search?q=1',
        method: 'GET',
        headers: const {'User-Agent': 'Test'},
      );
      expect(order, greaterThan(0));
      recorder.recordResponse(
        stage: BookSourceDebugStage.search,
        sourceName: '测试源',
        order: order,
        statusCode: 200,
        url: 'https://example.com/search?q=1',
        elapsedMs: 123,
        preview: '<html>…',
      );
      final entries = recorder.entries;
      expect(entries, hasLength(2));
      expect(entries[0].kind, BookSourceDebugKind.request);
      expect(entries[0].url, 'https://example.com/search?q=1');
      expect(entries[0].method, 'GET');
      expect(entries[0].requestHeaders?['User-Agent'], 'Test');
      expect(entries[1].kind, BookSourceDebugKind.response);
      expect(entries[1].order, order); // 与请求同一序号
      expect(entries[1].statusCode, 200);
      expect(entries[1].elapsedMs, 123);
    });

    test('环形缓冲超过上限丢弃最旧', () {
      final recorder = BookSourceDebugRecorder();
      final overflow = BookSourceDebugRecorder.maxEntries + 10;
      for (var i = 0; i < overflow; i++) {
        recorder.recordInfo(
          stage: BookSourceDebugStage.raw,
          sourceName: 's',
          message: '第 $i 条',
        );
      }
      expect(recorder.length, BookSourceDebugRecorder.maxEntries);
      // 最旧的被丢弃，最新的还在
      expect(recorder.entries.first.message, '第 10 条');
      expect(recorder.entries.last.message, '第 ${overflow - 1} 条');
    });

    test('clear 清空全部条目并重置序号', () {
      final recorder = BookSourceDebugRecorder();
      recorder
          .recordInfo(stage: BookSourceDebugStage.raw, sourceName: 's', message: 'a');
      recorder.recordInfo(
        stage: BookSourceDebugStage.raw,
        sourceName: 's',
        message: 'b',
      );
      recorder.clear();
      expect(recorder.isEmpty, isTrue);
      // 清空后新序号从头计
      final order = recorder.recordRequest(
        stage: BookSourceDebugStage.raw,
        sourceName: 's',
        url: 'https://x/',
        method: 'GET',
      );
      expect(order, 1);
    });

    test('写入触发 notifyListeners', () {
      final recorder = BookSourceDebugRecorder();
      var notified = 0;
      void listener() => notified++;
      recorder.addListener(listener);
      recorder.recordInfo(
        stage: BookSourceDebugStage.raw,
        sourceName: 's',
        message: 'x',
      );
      expect(notified, 1);
      recorder.clear();
      expect(notified, 2);
      recorder.removeListener(listener);
      recorder.recordInfo(
        stage: BookSourceDebugStage.raw,
        sourceName: 's',
        message: 'y',
      );
      expect(notified, 2);
    });

    test('错误条目携带状态/耗时/URL', () {
      final recorder = BookSourceDebugRecorder();
      recorder.recordError(
        stage: BookSourceDebugStage.toc,
        sourceName: 's',
        message: '连接失败',
        statusCode: 503,
        elapsedMs: 8,
        url: 'https://x/toc',
      );
      final entry = recorder.entries.single;
      expect(entry.kind, BookSourceDebugKind.error);
      expect(entry.statusCode, 503);
      expect(entry.elapsedMs, 8);
      expect(entry.url, 'https://x/toc');
      expect(entry.message, '连接失败');
    });
  });

  group('调试辅助（flutter_js 沙箱）', () {
    setUpAll(() {
      copyQuickJsDllIfNeeded();
    });

    LegadoRuntime runtimeWith(BookSourceDebugRecorder recorder) =>
        LegadoRuntime(
          sandbox: FlutterLegadoJsSandbox(),
          debugRecorder: recorder,
          enableAjaxBridge: false,
        );

    test('debugEvalJs 执行 JS 并写入 ruleResult 日志', () async {
      final recorder = BookSourceDebugRecorder();
      final runtime = runtimeWith(recorder);
      final result = await runtime.debugEvalJs(
        code: 'finalResult = 1 + 2;',
        sourceName: '测试源',
      );
      expect(result.trim(), '3');
      expect(recorder.entries.last.kind, BookSourceDebugKind.ruleResult);
      expect(recorder.entries.last.message, '3');
      runtime.close();
    });

    test('debugEvalJs 支持 @js: 前缀与 baseUrl 注入', () async {
      final recorder = BookSourceDebugRecorder();
      final runtime = runtimeWith(recorder);
      final result = await runtime.debugEvalJs(
        code: '@js:finalResult = baseUrl + "/book/1";',
        sourceName: '测试源',
        baseUri: Uri.parse('https://example.com/'),
      );
      expect(result.trim(), 'https://example.com//book/1');
      runtime.close();
    });

    test('debugEvaluateRule 对 HTML 求 CSS 选择器', () async {
      final recorder = BookSourceDebugRecorder();
      final runtime = runtimeWith(recorder);
      const html = '''
        <ul class="book-list">
          <li class="item"><h3><a href="/a/1">第一章 测试</a></h3><p>作者甲</p></li>
          <li class="item"><h3><a href="/a/2">第二章 继续</a></h3><p>作者乙</p></li>
        </ul>
      ''';
      final values = await runtime.debugEvaluateRule(
        html,
        Uri.parse('https://example.com/list'),
        '.book-list .item a@text',
      );
      expect(values, hasLength(2));
      expect(values.first, '第一章 测试');
      expect(values.last, '第二章 继续');
      runtime.close();
    });

    test('debugEvaluateRule 空规则/异常不抛错返回空列表', () async {
      final recorder = BookSourceDebugRecorder();
      final runtime = runtimeWith(recorder);
      expect(await runtime.debugEvaluateRule('x', Uri.parse('https://x/'), '  '),
          isEmpty);
      // 畸形规则不应抛异常
      final values = await runtime.debugEvaluateRule(
        '{ not-json',
        Uri.parse('https://x/'),
        r'@xpath://li@text',
      );
      expect(values, isA<List<Object?>>());
      runtime.close();
    });

    test('BookSourceClient 注入 recorder 可透传到按源 runtime', () {
      final recorder = BookSourceDebugRecorder();
      final client = BookSourceClient(debugRecorder: recorder);
      final source = LegadoBookSource.fromJson(_makeRaw())
          .toRegisteredSource(enabled: true);
      final runtime = client.legadoRuntimeForSource(source);
      expect(runtime.debugRecorder, same(recorder));
      client.close();
    });
  });
}

Map<String, dynamic> _makeRaw() {
  return {
    'bookSourceUrl': 'https://example.com',
    'bookSourceName': '调试源',
    'searchUrl': 'https://example.com/search?q={{key}}&page={{page}}',
    'ruleSearch': {'bookList': '.book-list li', 'name': 'h3@text', 'bookUrl': 'a@href'},
    'ruleToc': {'chapterList': '.chapter li', 'name': 'a@text', 'url': 'a@href'},
    'ruleContent': {'content': '#content@text'},
  };
}