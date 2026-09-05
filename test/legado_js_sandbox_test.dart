// Legado JS 规则本地执行测试（基于 flutter_js QuickJsRuntime2）。
//
// 目的：验证 @js / <js> 规则在本机 flutter test 中可执行（对齐 fjs 在 app 内的行为），
// 覆盖真实书源中常见的简单 JS 规则（字符串构建、result/finalResult 寄存器、source 变量）。
// 不依赖生产 fjs 的 Rust 构建链。
//
// 平台说明：
// - Windows：自动把包内 quickjs_c_bridge.dll 复制到测试工作目录供 FFI 加载；
// - macOS/Linux：分别使用系统 JavaScriptCore / QuickJS；
// - 若运行时无法加载，测试跳过（不影响其他测试）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';

/// 轻量 JS 规则测试器：在单个 QuickJS 上下文中执行规则，
/// 通过全局 __vars 对象维护 source.get/put 变量（跨 eval 持久），
/// 并注入 key/page/baseUrl/java stub 等全局。
class FlutterJsRuleTester {
  FlutterJsRuleTester(this.runtime);

  final JavascriptRuntime runtime;

  static const String _prelude = '''
    if (typeof __vars === 'undefined') { __vars = {}; }
    var source = {
      get: function(k){ return __vars[k] || ''; },
      put: function(k, v){ __vars[k] = v == null ? '' : String(v); },
      getString: function(k, d){ var s = __vars[k]; return (s === undefined || s === null || s === '') ? (d == null ? '' : String(d)) : String(s); },
      putString: function(k, v){ __vars[k] = v == null ? '' : String(v); }
    };
    // 对齐 fjs 沙箱：java.crypto 缺省 stub，未实现的方法返回空，规则不抛异常
    if (typeof java === 'undefined') { java = {}; }
    if (!java.crypto) {
      java.crypto = {
        md5Encode: function(){ return ''; },
        sha1Encode: function(){ return ''; },
        sha256Encode: function(){ return ''; },
        base64Encode: function(){ return ''; },
        base64Decode: function(){ return ''; },
        rc4Encrypt: function(){ return ''; },
        rc4Decrypt: function(){ return ''; }
      };
    }
  ''';

  String eval(String code, {String key = '', String page = '1', String baseUrl = ''}) {
    final body = code.trim();
    final trimmed = body.toLowerCase().startsWith('@js:')
        ? body.substring(4).trimLeft()
        : body;
    final stripped = trimmed
        .replaceFirst(RegExp(r'^\s*<js>\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*</js>\s*$', caseSensitive: false), '');
    final wrapped = '''
      (function(){
        var key = ${jsonEncode(key)};
        var page = ${jsonEncode(page)};
        var baseUrl = ${jsonEncode(baseUrl)};
        $_prelude
        var result = '';
        var finalResult = '';
        $stripped
        return JSON.stringify({ result: finalResult || result, vars: __vars });
      })()
    ''';
    final r = runtime.evaluate(wrapped);
    if (r.isError) {
      throw StateError('JS 错误: ${r.stringResult}');
    }
    final decoded = jsonDecode(r.stringResult);
    if (decoded is! Map) return '${decoded ?? ''}';
    return '${decoded['result'] ?? ''}';
  }

  String getVar(String k) {
    final r = runtime.evaluate('JSON.stringify({v: __vars[${jsonEncode(k)}] || ""})');
    final decoded = jsonDecode(r.stringResult);
    return '${(decoded as Map)['v'] ?? ''}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => prepareQuickJsLibrary());

  group('flutter_js QuickJS 基础', () {
    late JavascriptRuntime runtime;
    late FlutterJsRuleTester tester;

    setUpAll(() {
      runtime = QuickJsRuntime2();
      tester = FlutterJsRuleTester(runtime);
    });

    tearDownAll(() {
      runtime.dispose();
    });

    test('基础算术执行', () {
      final r = runtime.evaluate('1 + 1');
      expect(r.isError, isFalse);
      expect(r.stringResult, '2');
    });

    test('真实规则：@js URL 构建 + finalResult 寄存器', () {
      final url = tester.eval(
        r"finalResult = 'https://api.example.com/search?q=' + encodeURIComponent(key);",
        key: '斗破苍穹',
      );
      expect(
        url,
        'https://api.example.com/search?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9',
      );
    });

    test('真实规则：String 处理与 baseUrl 拼接', () {
      final result = tester.eval(
        r"finalResult = String(baseUrl).replace(/\/$/, '') + '/book/1.html';",
        baseUrl: 'https://books.example.com/',
      );
      expect(result, 'https://books.example.com/book/1.html');
    });

    test('真实规则：result 寄存器 + source.put/get 跨 eval', () {
      // 第一次 eval 存储变量
      tester.eval(r"source.put('bid', '123456'); finalResult = 'ok';");
      expect(tester.getVar('bid'), '123456');
      // 第二次 eval 读取变量构建 URL
      final url = tester.eval(
        r"finalResult = 'https://api.example.com/c?bid=' + source.get('bid');",
      );
      expect(url, 'https://api.example.com/c?bid=123456');
    });

    test('真实规则：java.crypto stub 不崩溃', () {
      final result = tester.eval(
        r"finalResult = java.crypto ? java.crypto.md5Encode('abc') : 'missing';",
      );
      expect(result, ''); // stub 返回空，规则不抛异常
    });

    test('真实规则：source.getString 带默认值', () {
      final result = tester.eval(
        r"finalResult = source.getString('not_set', 'fallback');",
      );
      expect(result, 'fallback');
    });
  });
}

/// 从 .dart_tool/package_config.json 解析 flutter_js 包根目录，把 quickjs
/// DLL 复制到 cwd 供 FFI 加载（Windows；供本文件与 legado_runtime_jslib_test
/// 共用）。非 Windows 平台为空操作。
Future<void> prepareQuickJsLibrary() async {
  if (!Platform.isWindows) return;
  final configFile = File(
    '${Directory.current.path}${Platform.pathSeparator}.dart_tool'
    '${Platform.pathSeparator}package_config.json',
  );
  if (!configFile.existsSync()) return;
  try {
    final config = jsonDecode(configFile.readAsStringSync()) as Map;
    final packages = config['packages'] as List? ?? const [];
    String? rootPath;
    for (final p in packages.whereType<Map>()) {
      if (p['name'] == 'flutter_js') {
        final raw = '${p['rootUri'] ?? ''}';
        if (raw.startsWith('file://')) {
          rootPath = Uri.parse(raw).toFilePath();
        } else if (raw.isNotEmpty) {
          rootPath = '${Directory.current.path}${Platform.pathSeparator}$raw';
        }
        break;
      }
    }
    if (rootPath == null) return;
    final dll = File(
      '$rootPath${Platform.pathSeparator}windows'
      '${Platform.pathSeparator}shared'
      '${Platform.pathSeparator}quickjs_c_bridge.dll',
    );
    if (dll.existsSync()) {
      try {
        dll.copySync(
          '${Directory.current.path}${Platform.pathSeparator}quickjs_c_bridge.dll',
        );
      } catch (e) {
        // ignore: avoid_print
        print('复制 DLL 失败（测试可能跳过）: $e');
      }
    }
  } catch (e) {
    // ignore: avoid_print
    print('解析 flutter_js 包路径失败（测试可能跳过）: $e');
  }
}
