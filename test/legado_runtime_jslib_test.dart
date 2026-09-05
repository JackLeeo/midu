// M1 对标 Legado：jsLib 预加载测试。
// 验证：jsLib 中声明的全局函数在同一沙箱上下文中可被后续 @js 规则直接调用
// （Legado 语义：jsLib 在搜索/详情/目录/正文规则执行前先注册一次）。
//
// preloadJsLib 语义等价实现：先用 runtime.evaluate 在「全局作用域」注册
// polyfill 与 jsLib（函数全局可见），再让 IIFE 包裹的规则（FlutterJsRuleTester
// 的 eval）引用这些全局。这正是 fjs 沙箱 preloadJsLib + evalJs 的对应行为。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';

import 'legado_js_sandbox_test.dart' show FlutterJsRuleTester;
import 'legado_js_sandbox_test.dart' as sandbox;

void main() {
  group('jsLib 预加载（flutter_js 上下文中验证）', () {
    late JavascriptRuntime runtime;
    late FlutterJsRuleTester tester;

    setUpAll(() async {
      await sandbox.prepareQuickJsLibrary();
      runtime = QuickJsRuntime2();
      tester = FlutterJsRuleTester(runtime);
      // preloadJsLib：全局注入 Legado polyfill（source/java.crypto stub），
      // 再注册 jsLib 公共函数。
      final prelude = '''
        if (typeof __vars === 'undefined') { __vars = {}; }
        if (typeof source === 'undefined') {
          source = {
            get: function(k){ return __vars[k] || ''; },
            put: function(k, v){ __vars[k] = v == null ? '' : String(v); },
            getString: function(k, d){ var s = __vars[k]; return (s === undefined || s === null || s === '') ? (d == null ? '' : String(d)) : String(s); },
            putString: function(k, v){ __vars[k] = v == null ? '' : String(v); }
          };
        }
        if (typeof java === 'undefined') { java = {}; }
        if (!java.crypto) {
          java.crypto = {
            md5Encode: function(){ return ''; },
            base64Encode: function(){ return ''; },
            base64Decode: function(){ return ''; }
          };
        }
      ''';
      final pre = runtime.evaluate(prelude);
      if (pre.isError) {
        throw StateError('polyfill 注入失败: ${pre.stringResult}');
      }
    });

    tearDownAll(() {
      runtime.dispose();
    });

    void preloadJsLib(String code) {
      final r = runtime.evaluate(code);
      if (r.isError) {
        throw StateError('jsLib 注册失败: ${r.stringResult}');
      }
    }

    test('jsLib 声明函数可被后续规则调用', () {
      preloadJsLib('function plus(a,b){ return a + b; } var G = 41;');
      final r = tester.eval('finalResult = plus(G, 1);');
      expect(r.trim(), '42');
    });

    test('jsLib 提供工具函数给正文清洗使用', () {
      preloadJsLib(
        'function cleanHtml(s){ return String(s == null ? \'\' : s).replace(/<[^>]*>/g, \'\'); }',
      );
      final r = tester.eval('finalResult = cleanHtml("<p>正文内容</p>");');
      expect(r.trim(), '正文内容');
    });

    test('jsLib 可访问 source 变量（source.put 全局）', () {
      preloadJsLib(
        'var __jsLib = function(){ source.put("jslibFlag", "1"); }; __jsLib();',
      );
      final r = tester.eval('finalResult = source.get("jslibFlag");');
      expect(r.trim(), '1');
    });

    test('jsLib 函数可与 result 寄存器配合', () {
      preloadJsLib(
        'function extractId(u){ return typeof u === "string" ? u.split("/").pop() : ""; }',
      );
      final r = tester.eval(
        'finalResult = extractId("https://x.com/book/123.html");',
      );
      expect(r.trim(), '123.html');
    });
  });
}