// flutter_js（QuickJS FFI）版 Legado JS 沙箱：用于本机 flutter test 中执行
// 真实书源的 @js / <js> 规则（生产使用 fjs，见 legado_fjs_sandbox.dart）。
//
// 语义对齐 LegadoFjsSandbox：
//   - source.put/get、cache.put/get、java.put/get（均持久化到 Dart 侧变量 Map）；
//   - java.crypto / java.String / java.util 桩（未实现方法返回空，规则不抛异常）；
//   - result/finalResult 寄存器：JS 赋值优先，其次脚本完成值（裸表达式结尾）；
//   - 中段 @js: 规则通过 extraGlobals['result'] 注入左侧提取结果；
//   - document / $ 尽力而为：提供 baseURI/body HTML 与返回空集的查询桩。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';

/// Windows 下把 flutter_js 包内的 quickjs DLL 复制到测试 cwd（FFI 加载需要）。
/// 在测试 setUpAll 中调用；非 Windows 平台自动跳过。
void copyQuickJsDllIfNeeded() {
  if (!Platform.isWindows) return;
  try {
    final configFile = File(
      '${Directory.current.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}package_config.json',
    );
    if (!configFile.existsSync()) return;
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
      dll.copySync(
        '${Directory.current.path}${Platform.pathSeparator}quickjs_c_bridge.dll',
      );
    }
  } catch (_) {
    // 复制失败时测试会因 FFI 加载失败而跳过，这里静默
  }
}

/// flutter_js 版 [LegadoJsSandbox]。
///
/// 变量在 Dart 侧维护（跨 eval 持久），每次 eval 通过 __vars 进出 JS 上下文。
class FlutterLegadoJsSandbox implements LegadoJsSandbox {
  FlutterLegadoJsSandbox() : _runtime = QuickJsRuntime2();

  final JavascriptRuntime _runtime;
  final Map<String, String> _vars = <String, String>{};
  bool _inited = false;

  /// 最近一次 JS 执行失败的错误信息（无则 null），用于测试诊断。
  String? lastError;

  @override
  Future<void> init() async {
    _inited = true;
  }

  @override
  Future<void> dispose() async {
    _runtime.dispose();
    _vars.clear();
    _inited = false;
  }

  @override
  String? getSourceVar(String key) => _vars[key];

  @override
  void putSourceVar(String key, String value) => _vars[key] = value;

  /// 对齐 LegadoFjsSandbox 的 polyfill（变量/寄存器由 evalJs 包装注入）。
  static const String _prelude = '''
    var source = {
      get: function(k){ return __vars[k] || ''; },
      put: function(k, v){ __vars[k] = v == null ? '' : String(v); },
      getString: function(k, d){ var s = __vars[k]; return (s === undefined || s === null || s === '') ? (d == null ? '' : String(d)) : String(s); },
      putString: function(k, v){ __vars[k] = v == null ? '' : String(v); }
    };
    var cache = {
      put: function(k, v){ __vars[k] = v == null ? '' : String(v); },
      get: function(k){ return __vars[k] || ''; }
    };
    var java = {};
    java.crypto = {
      md5Encode:        function(){ return ''; },
      md5Encode16:      function(){ return ''; },
      sha1Encode:       function(){ return ''; },
      sha256Encode:     function(){ return ''; },
      base64Encode:     function(){ return ''; },
      base64Decode:     function(){ return ''; },
      aesEncrypt:       function(){ return ''; },
      aesDecrypt:       function(){ return ''; },
      rc4Encrypt:       function(){ return ''; },
      rc4Decrypt:       function(){ return ''; }
    };
    java.String = {
      format: function(pattern) {
        var args = Array.prototype.slice.call(arguments, 1);
        var i = 0;
        return String(pattern == null ? '' : pattern).replace(/%[sd]/g, function(){ return args[i++] != null ? String(args[i-1]) : ''; });
      },
      join: function(arr, sep) { return Array.isArray(arr) ? arr.join(sep == null ? '' : sep) : ''; },
      split: function(str, sep, limit) { return (str == null ? '' : String(str)).split(sep, limit); }
    };
    java.util = {
      Arrays: {
        copyOfRange: function(arr, from, to) { return Array.isArray(arr) ? arr.slice(from, to) : []; },
        toString: function(arr) { return Array.isArray(arr) ? JSON.stringify(arr) : '[]'; }
      }
    };
    java.log = function(){ return ''; };
    java.put = function(k, v){ __vars[k] = v == null ? '' : String(v); return ''; };
    java.get = function(k){ return __vars[k] || ''; };
    java.getString = function(k, d){ var s = __vars[k]; return (s === undefined || s === null || s === '') ? (d == null ? '' : String(d)) : String(s); };
    if (typeof bridge === 'undefined') { bridge = function(){ return ''; }; }
    if (typeof document === 'undefined') { document = {}; }
    document.baseURI = __baseUrl;
    document.body = { innerHTML: __docHtml, outerHTML: __docHtml };
    document.documentElement = document.body;
    document.innerHTML = __docHtml;
    document.outerHTML = __docHtml;
    document.querySelector = function(){ return null; };
    document.querySelectorAll = function(){ return []; };
    if (typeof \$ === 'undefined') {
      \$ = function(){ var a = []; a.get = function(){ return null; }; a.eq = function(){ return []; }; a.size = function(){ return 0; }; return a; };
    }
  ''';

  @override
  Future<String> evalJs(
    String rawCode, {
    String? docHtml,
    Uri? baseUri,
    Map<String, dynamic> extraGlobals = const {},
  }) async {
    if (!_inited) await init();
    lastError = null;
    final code = _stripJsTag(rawCode);
    if (code.trim().isEmpty) return '';

    // 注入额外全局（result/finalResult 是特殊寄存器，包装内处理）
    final globalsCode = StringBuffer();
    var preResult = '';
    for (final entry in extraGlobals.entries) {
      if (entry.key == 'result' || entry.key == 'finalResult') {
        if (entry.key == 'result' && entry.value is String) {
          preResult = entry.value as String;
        }
        continue;
      }
      globalsCode
        ..write('var ${entry.key} = ')
        ..write(_literal(entry.value))
        ..write(';\n');
    }

    final wrapped = '''
      (function(){
        var __vars = ${jsonEncode(_vars)};
        var __docHtml = ${jsonEncode(docHtml ?? '')};
        var __baseUrl = ${jsonEncode(baseUri?.toString() ?? '')};
        var key = '';
        var page = '1';
        var baseUrl = __baseUrl;
        $_prelude
        $globalsCode
        var result = '';
        var finalResult = '';
        ${preResult.isEmpty ? '' : 'result = ${jsonEncode(preResult)};'}
        var __error = '';
        var __completion = '';
        try {
          var __v = eval(${jsonEncode(code)});
          if (__v !== undefined && __v !== null) __completion = String(__v);
        } catch(e) { __error = String(e); }
        return JSON.stringify({ result: finalResult || __completion || result, vars: __vars, error: __error });
      })()
    ''';
    final r = _runtime.evaluate(wrapped);
    if (r.isError) {
      lastError = r.stringResult;
      return '';
    }
    final decoded = jsonDecode(r.stringResult);
    if (decoded is! Map) return '';
    final vars = decoded['vars'];
    if (vars is Map) {
      _vars.clear();
      for (final entry in vars.entries) {
        _vars['${entry.key}'] = '${entry.value}';
      }
    }
    final err = decoded['error'];
    if (err is String && err.isNotEmpty) lastError = err;
    final res = decoded['result'];
    return res == null ? '' : '$res';
  }

  static String _stripJsTag(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('@js:')) s = s.substring(4);
    s = s.replaceFirst(RegExp(r'^\s*<js>\s*', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'\s*</js>\s*$', caseSensitive: false), '');
    return s;
  }

  static String _literal(Object? value) {
    if (value == null) return 'null';
    if (value is bool || value is num) return '$value';
    return jsonEncode('$value');
  }
}
