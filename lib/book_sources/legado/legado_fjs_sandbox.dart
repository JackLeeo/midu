// 米读 Legado 书源 JS 运行时：基于 fjs 3.3.0 (Rust + QuickJS)
// fjs 3.x API（对齐 pub.dev/packages/fjs 3.3.0 文档）：
//   await LibFjs.init();
//   final engine = await JsEngine.create(builtins: JsBuiltinOptions.web());
//   await engine.init(bridge: (JsValue v) => JsResult.ok(JsValue.string('...')));
//   final r = await engine.eval(source: JsCode.code('1+2'));  // r.value
//   await engine.close();
//
// Legado 书源常用 polyfill：
//   1. document / $ (jQuery-lite) — 把当前 HTML 的 Dart 端 DOM 查询结果序列化后缓存到 JS 侧对象
//   2. java.crypto — MD5 / SHA1 / SHA256 / Base64 / AES / RC4（MD5/SHA/Base64 通过 bridge 回 Dart）
//   3. source.put / source.get — 跨请求变量缓存（沙箱级 Map，bridge 回 Dart）
//   4. JSON / atob / btoa — fjs 自带基础支持，如果缺失就 bridge
//   5. result / finalResult 寄存器 — JS 规则把结果写入这两个全局变量

import 'dart:convert';
import 'dart:typed_data';

import 'package:fjs/fjs.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:meta/meta.dart';

import 'legado_ajax_rewrite.dart';

/// Legado 书源 JS 沙箱统一接口。
///
/// 生产实现：[LegadoFjsSandbox]（fjs Rust + QuickJS，全端可用）。
/// 测试实现：flutter_js（QuickJS FFI），用于本机 flutter test 中执行真实
/// 书源的 @js / <js> 规则（见 test/helpers/flutter_js_sandbox.dart）。
abstract class LegadoJsSandbox {
  Future<void> init();

  Future<void> dispose();

  /// 读取规则 @put / source.put 存入的变量（跨规则/跨请求共享）。
  String? getSourceVar(String key);

  /// 写入规则 @put / source.put 变量。
  void putSourceVar(String key, String value);

  /// 执行一段 JS 规则（可带 @js: 或 <js>...</js> 标记），返回 result / finalResult 寄存器的字符串值。
  Future<String> evalJs(
    String rawCode, {
    String? docHtml,
    Uri? baseUri,
    Map<String, dynamic> extraGlobals = const {},
  });

  /// 预加载书源公共 JS 库（jsLib）：在首次 [evalJs] 前执行一次，注册全局函数。
  Future<void> preloadJsLib(String code) => Future.value();
}

/// FJS QuickJS 沙箱包装，提供 Legado 书源 JS 所需 polyfill。
///
/// 单沙箱实例应与 LegadoRuntime 生命周期绑定（对应一个注册源或全局复用）。
class LegadoFjsSandbox implements LegadoJsSandbox, AjaxFetcherSink {
  LegadoFjsSandbox();

  JsEngine? _engine;
  bool _inited = false;

  /// source.put/get 变量缓存（沙箱级），同时被规则引擎的 @put/@get 复用
  final Map<String, String> _sourceVars = <String, String>{};

  /// 读取规则 @put 存入的变量（跨规则/跨请求共享）。
  @override
  String? getSourceVar(String key) => _sourceVars[key];

  /// 写入规则 @put 变量。
  @override
  void putSourceVar(String key, String value) => _sourceVars[key] = value;

  /// 当前 HTML（用于 document 查询）
  String _currentHtml = '';
  Uri? _currentBaseUri;
  dom.Document? _domCache;

  /// JS 内 `java.ajax / java.connect` 的网络执行器。由运行时注入（复用请求层的
  /// 内容自适应解码）。为空时不做预取改写，相关调用回退为空串（现状行为）。
  ///
  /// QuickJS 的 bridge 回调是同步的，无法在同步桥里做异步 HTTP；因此采用
  /// 「eval 前源码改写」：在把规则交给引擎执行前，把 `java.ajax('URL'[,...])`
  /// 这类字面量调用先取回响应，内联成字符串字面量，再交给 JS。
  AjaxFetcher? _ajaxFetcher;

  /// 注入 [java.ajax] / [java.connect] 的网络执行器（幂等）。测试或未接入时可不设。
  @override
  void setAjaxFetcher(AjaxFetcher? fetcher) {
    _ajaxFetcher = fetcher;
  }

  static bool _libInited = false;

  @override
  Future<void> init() async {
    if (_inited) return;
    if (!_libInited) {
      await LibFjs.init();
      _libInited = true;
    }
    final engine = await JsEngine.create(
      builtins: const JsBuiltinOptions(
        console: false,
        fetch: false,
        timers: false,
      ),
    );
    _engine = engine;
    // Bridge：JS 侧通过 bridge({__cmd:'md5', value:'...'}) 调用 Dart 函数
    await engine.init(bridge: (JsValue input) {
      try {
        return JsResult.ok(_dispatchBridge(input));
      } catch (e) {
        return JsResult.ok(JsValue.string(''));
      }
    });
    await _injectLegadoGlobals(engine);
    _inited = true;
  }

  @override
  Future<void> dispose() async {
    final engine = _engine;
    if (engine != null) {
      try {
        await engine.close();
      } catch (_) {}
    }
    _engine = null;
    _inited = false;
    _sourceVars.clear();
    _domCache = null;
    _currentHtml = '';
    _currentBaseUri = null;
    _jsLibLoaded = false;
  }

  bool _jsLibLoaded = false;

  /// 预加载书源公共 JS 库（jsLib）。与规则执行共享同一引擎与全局作用域，
  /// 保证 jsLib 中声明的函数可被后续所有 @js 规则直接调用（Legado javsscript
  /// 语义：jsLib 在搜索/详情/目录/正文规则执行前先注册一次）。
  @override
  Future<void> preloadJsLib(String code) async {
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) return;
    if (!_inited) await init();
    final engine = _engine!;
    if (_jsLibLoaded) return;
    _jsLibLoaded = true;
    await _safeEval(engine, _stripJsTag(trimmedCode));
  }

  /// 执行一段 JS 规则（可带 @js: 或 <js>...</js> 标记），返回 result / finalResult 寄存器的字符串值。
  ///
  /// 执行前会把 docHtml 同步到 JS 侧的 document 对象。
  @override
  Future<String> evalJs(
    String rawCode, {
    String? docHtml,
    Uri? baseUri,
    Map<String, dynamic> extraGlobals = const {},
  }) async {
    if (!_inited) await init();
    final engine = _engine!;
    final stripped = transpileTemplateLiterals(_stripJsTag(rawCode));

    if (docHtml != null) {
      _currentHtml = docHtml;
      _currentBaseUri = baseUri;
      _domCache = html_parser.parse(docHtml);
    }
    await _syncDocumentBindings(engine);

    // 先注入一个「暂定 result」（取左侧提取结果，否则取当前文档 HTML/JSON 文本），
    // 使动态 java.ajax(expr) 的参数求值（依赖 result / JSON.parse 的表达式）能拿到值。
    final provisionalResult = (extraGlobals['result'] is String &&
            (extraGlobals['result'] as String).isNotEmpty)
        ? extraGlobals['result'] as String
        : docHtml ?? '';
    if (provisionalResult.isNotEmpty) {
      await _safeEval(engine, 'result = ${jsonEncode(provisionalResult)};');
    }
    // java.ajax / java.connect 预处理：把调用先取回响应再给 JS（见 [_rewriteAjaxCalls]）。
    // 动态第一参数（如 JSON.parse(result).data.xxx）由内部 [_ajaxArgResolver] 求值出 URL。
    final code = await _rewriteAjaxCalls(stripped);
    if (code.trim().isEmpty) return '';

    // 设置全局额外变量（例如 search keyword、page；result/finalResult 是
    // 特殊寄存器，稍后注入，避免被注册表重置覆盖）
    for (final entry in extraGlobals.entries) {
      if (entry.key == 'result' || entry.key == 'finalResult') continue;
      final jsCode = _assignmentExpr(entry.key, entry.value);
      await _safeEval(engine, jsCode);
    }
    // 清空 result/finalResult 寄存器
    await _safeEval(engine, 'var result = ""; var finalResult = "";');
    // 中段 @js: 规则：左侧提取结果作为 result 注入（JS 内可直接读 result，
    // 如 coverUrl "a@href\n@js:var id=result.match(...)"）。
    final preResult = extraGlobals['result'];
    if (preResult is String && preResult.isNotEmpty) {
      await _safeEval(engine, 'result = ${jsonEncode(preResult)};');
    }

    // 执行规则：寄存器优先；寄存器为空时用脚本完成值兜底。
    // 大量真实规则以裸表达式结尾（`https://...` 模板字符串、so+JSON.stringify(post)、
    // `uData;`），其完成值才是最终结果，仅靠 finalResult/result 寄存器会丢值。
    Object? completion;
    try {
      final ev = await engine.eval(source: JsCode.code(code));
      completion = ev.value;
    } catch (_) {
      // 规则执行失败不抛错，返回空让下游 fallback 接管
    }
    // 读取结果：finalResult 优先；其次脚本完成值（裸表达式结尾，如
    // `https://...` 模板字符串 / so+JSON.stringify(post) / `uData;`）；
    // 最后回落 result（中段 @js: 注入的左侧提取结果，JS 未改动时透传）。
    final fr = await _safeEval(
      engine,
      'typeof finalResult !== "undefined" && finalResult !== null ? String(finalResult) : ""',
    );
    if (fr != null && '$fr'.isNotEmpty) return '$fr';
    final cs = _completionString(completion);
    if (cs.isNotEmpty) return cs;
    final rr = await _safeEval(
      engine,
      'typeof result !== "undefined" && result !== null ? String(result) : ""',
    );
    return rr == null ? '' : '$rr';
  }

  // ========= Bridge 分发 =========

  /// JS 侧统一入口：bridge({__cmd:'md5', value:'...'}) 或 bridge('__cmd', arg1, arg2)。
  JsValue _dispatchBridge(JsValue input) {
    try {
      // JsValue_Object → 按 JSON map 解析
      if (input is JsValue_Object || input is JsValue_String) {
        final str = _js2string(input);
        // 先尝试解析 JSON 格式：{"__cmd":"md5","value":"xxx"}
        if (str.startsWith('{')) {
          try {
            final map = jsonDecode(str) as Map<String, dynamic>;
            final cmd = '${map['__cmd'] ?? map['cmd'] ?? ''}';
            if (cmd.isNotEmpty) {
              final args = (map['args'] as List?) ??
                  [map['value'], map['k'], map['iv'], map['m'], map['p'], map['pad'], map['out']];
              return _routeCmd(cmd, args);
            }
          } catch (_) {}
        }
      }
      // 如果 JS 侧只是传 string，当作 __cmd 返回空
      return JsValue.string('');
    } catch (_) {
      return JsValue.string('');
    }
  }

  JsValue _routeCmd(String cmd, List<Object?> args) {
    switch (cmd) {
      case 'md5':
        return _s(_hash(md5, _argS(args, 0)));
      case 'sha1':
        return _s(_hash(sha1, _argS(args, 0)));
      case 'sha256':
        return _s(_hash(sha256, _argS(args, 0)));
      case 'btoa':
        try {
          return _s(base64Encode(utf8.encode(_argS(args, 0))));
        } catch (_) {
          return _s('');
        }
      case 'atob':
        try {
          final bytes = base64Decode(_argS(args, 0).replaceAll(RegExp(r'\s'), ''));
          return _s(utf8.decode(bytes, allowMalformed: true));
        } catch (_) {
          return _s('');
        }
      case 'rc4':
        {
          final dir = _argS(args, 2) == 'dec' ? false : true;
          return _s(_rc4(_argS(args, 0), _argS(args, 1), dir));
        }
      case 'aes_encrypt':
        {
          final out = _argS(args, 6);
          return _s(
            _aes(_argS(args, 0), _argS(args, 1), _argS(args, 2), _argS(args, 3), true, out),
          );
        }
      case 'aes_decrypt':
        {
          return _s(
            _aes(_argS(args, 0), _argS(args, 1), _argS(args, 2), _argS(args, 3), false, _argS(args, 6)),
          );
        }
      case 'json_parse':
        try {
          final r = jsonDecode(_argS(args, 0));
          // JSON 化回字符串——JS 侧再 parse 一次，避免深度 JsValue 构造
          return _s(jsonEncode(r));
        } catch (_) {
          return _s('null');
        }
      case 'json_stringify':
        try {
          return _s(jsonEncode(_argS(args, 0)));
        } catch (_) {
          return _s('');
        }
      case 'source_get':
        return _s(_sourceVars[_argS(args, 0)] ?? '');
      case 'source_put':
        {
          _sourceVars[_argS(args, 0)] = _argS(args, 1);
          return _s('');
        }
      case 'doc_query':
        {
          final selector = _argS(args, 0);
          final mode = _argS(args, 1); // first | all
          final res = _docQuery(selector, mode);
          return _s(jsonEncode(res));
        }
      case 'doc_html':
        return _s(_currentHtml);
      case 'doc_baseuri':
        return _s(_currentBaseUri?.toString() ?? '');
      case 'jsoup_query':
        // 在「传入的 HTML 字符串」上做 CSS 查询（用于 org.Jsoup.parse(html).select）
        return _s(jsonEncode(_jsoupQuery(_argS(args, 0), _argS(args, 1), _argS(args, 2))));
      default:
        return _s('');
    }
  }

  // ========= Polyfill 注入（注入时把 bridge 封装成友好的 JS 函数） =========

  Future<void> _injectLegadoGlobals(JsEngine engine) async {
    // 注入辅助：__dart(cmd, a, b, ...) 作为 bridge 的方便封装（可变参数）
    await _safeEval(engine, r'''
      var __dart = function(cmd) {
        try {
          var args = Array.prototype.slice.call(arguments, 1);
          var payload = JSON.stringify({__cmd: String(cmd), args: args});
          var r = typeof bridge === 'function' ? bridge(payload) : '';
          return (r === undefined || r === null) ? '' : String(r);
        } catch(e) { return ''; }
      };
      // JSON 兜底（fjs 自带，此处仅在缺失时兜底）
      if (typeof JSON === 'undefined') {
        JSON = {
          parse: function(s){ var x = __dart('json_parse', s); return x ? eval('(' + x + ')') : null; },
          stringify: function(o){ return __dart('json_stringify', o === undefined ? null : o); }
        };
      }
      if (typeof atob === 'undefined') { atob = function(s){ return __dart('atob', s); }; }
      if (typeof btoa === 'undefined') { btoa = function(s){ return __dart('btoa', s); }; }

      // URL 编解码兜底（书源对 URL 参数做 encodeURIComponent/escape 很常见）。
      // fjs 若已提供则不改；用正则近似实现，保证源规则里的编码调用不抛 NotFound。
      if (typeof encodeURIComponent === 'undefined') {
        encodeURIComponent = function(s){
          return String(s == null ? '' : s).replace(/[^A-Za-z0-9\-_.!~*'()]/g, function(c){
            return '%' + (c.charCodeAt(0) < 0x80
                ? c.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0')
                : encodeURIComponent(c));
          });
        };
      }
      if (typeof decodeURIComponent === 'undefined') {
        decodeURIComponent = function(s){
          try {
            s = String(s == null ? '' : s);
            var bytes = [];
            var i, len;
            for (i = 0; i < s.length; i++) {
              var ch = s.charAt(i);
              if (ch === '%') {
                var hex = s.substr(i + 1, 2);
                bytes.push(parseInt(hex, 16));
                i += 2;
              } else {
                var b = ch.charCodeAt(0);
                if (b >= 0x80) bytes.push(240, 159, 128, 130); // 非 US-ASCII 逐字保底
                else bytes.push(b);
              }
            }
            // UTF-8 → 字符串
            var out = '';
            for (i = 0; i < bytes.length; i++) {
              var b0 = bytes[i];
              if (b0 < 0x80) { out += String.fromCharCode(b0); continue; }
              if (b0 >= 0xC0 && b0 < 0xE0) {
                out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i+1] & 0x3F)); i += 1;
              } else if (b0 >= 0xE0) {
                out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i+1] & 0x3F) << 6) | (bytes[i+2] & 0x3F)); i += 2;
              } else out += String.fromCharCode(b0);
            }
            return out;
          } catch(e){ return String(s); }
        };
      }
      if (typeof escape === 'undefined') {
        escape = function(s){
          return String(s == null ? '' : s).replace(/[^A-Za-z0-9\-_.!~*'()@]/g, function(c){
            var code = c.charCodeAt(0);
            return (code < 0x100 ? '%' : '%u') + code.toString(16).toUpperCase().padStart(code < 0x100 ? 2 : 4, '0');
          });
        };
      }
      if (typeof unescape === 'undefined') {
        unescape = function(s){
          return String(s == null ? '' : s)
              .replace(/%u([0-9A-Fa-f]{4})/g, function(_, h){ return String.fromCharCode(parseInt(h, 16)); })
              .replace(/%([0-9A-Fa-f]{2})/g, function(_, h){ return String.fromCharCode(parseInt(h, 16)); });
        };
      }

      // 当前处理上下文（章节/条目 JSON，供 java.getString('$.field') 解析）：
      // contextJson 全局由规则引擎按每次 eval 注入（字符串时为 JSON 文本）。
      var __ctx = function(){
        if (typeof contextJson === 'undefined' || contextJson == null) return null;
        if (typeof contextJson === 'object') return contextJson;
        try { return JSON.parse(contextJson); } catch(e){ return null; }
      };
      // 统一取值：key 以 $. 开头时按 JSONPath 从当前上下文解析；否则走变量缓存。
      var __getStr = function(k, d){
        var dflt = (d === undefined || d === null) ? '' : String(d);
        if (typeof k === 'string' && k.length > 1 && k.charAt(0) === '$' &&
            (k.charAt(1) === '.' || k.charAt(1) === '[')) {
          var o = __ctx();
          if (o == null) return dflt;
          var parts = k.charAt(1) === '['
              ? k.replace(/[\[]/g, '.').replace(/[\]]/g, '.')
              : k.substring(1);
          var pArr = parts.split('.');
          var i;
          for (i = 0; i < pArr.length; i++) {
            var p = pArr[i].trim();
            if (p === '') continue;
            if (o == null) return dflt;
            o = o[p];
            if (o === undefined || o === null) return dflt;
          }
          return o === undefined || o === null ? dflt : String(o);
        }
        var s = __dart('source_get', k);
        return (s === undefined || s === null || s === '') ? dflt : String(s);
      };

      // java.*
      java = {};
      java.crypto = {
        md5Encode:        function(s){ return __dart('md5', s == null ? '' : String(s)); },
        md5Encode16:      function(s){ var h = __dart('md5', s == null ? '' : String(s)); return h && h.length === 32 ? h.substring(8, 24) : ''; },
        sha1Encode:       function(s){ return __dart('sha1', s == null ? '' : String(s)); },
        sha256Encode:     function(s){ return __dart('sha256', s == null ? '' : String(s)); },
        base64Encode:     function(s){ return __dart('btoa', s == null ? '' : String(s)); },
        base64Decode:     function(s){ return __dart('atob', s == null ? '' : String(s)); },
        aesEncrypt:       function(s, k, iv, m, p, pad, out){ return __dart('aes_encrypt', s==null||s===undefined?'':String(s), k==null||k===undefined?'':String(k), iv==null||iv===undefined?'':String(iv), m==null||m===undefined?'':String(m), p==null||p===undefined?'':String(p), pad==null||pad===undefined?'':String(pad), out==null||out===undefined?'':String(out)); },
        aesDecrypt:       function(s, k, iv, m, p, pad, out){ return __dart('aes_decrypt', s==null||s===undefined?'':String(s), k==null||k===undefined?'':String(k), iv==null||iv===undefined?'':String(iv), m==null||m===undefined?'':String(m), p==null||p===undefined?'':String(p), pad==null||pad===undefined?'':String(pad), out==null||out===undefined?'':String(out)); },
        // 米读：Legado 源常用 aesBase64Encode/Decode+ToString（如猫眼看书章节 URL 解密）。
        // 参数序为 (data, key, mode, iv)——与 aesEncrypt/Decrypt 的 (data,key,iv,mode) 不同，
        // 故此处显式对位：iv 送入第 3 参、mode 送入第 4 参；Decode 侧 data 为 base64/hex。
        aesBase64DecodeToString: function(s, k, m, iv, p, pad){ return __dart('aes_decrypt', s==null||s===undefined?'':String(s), k==null||k===undefined?'':String(k), iv==null||iv===undefined?'':String(iv), m==null||m===undefined?'':String(m), p==null||p===undefined?'':String(p), pad==null||pad===undefined?'':String(pad), ''); },
        aesBase64EncodeToString: function(s, k, m, iv, p, pad){ return __dart('aes_encrypt', s==null||s===undefined?'':String(s), k==null||k===undefined?'':String(k), iv==null||iv===undefined?'':String(iv), m==null||m===undefined?'':String(m), p==null||p===undefined?'':String(p), pad==null||pad===undefined?'':String(pad), 'base64'); },
        rc4Encrypt:       function(s, k){ return __dart('rc4', s, k, 'enc'); },
        rc4Decrypt:       function(s, k){ return __dart('rc4', s, k, 'dec'); }
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
      // java.log 为副作用调用，返回空即可；put/get 复用 source 变量缓存，
      // 使依赖 java.put/java.get 跨请求存取的规则也能工作。
      // 注意：Legado 中 java.put / source.put 均返回「刚存入的值」。部分源的
      // 内联拼接依赖此返回值，如得间目录：&bid=" + java.put('bid', ...) 期望
      // 返回所存的值；若返回空串会导致 URL 缺参。故这里必须返回存入的 v。
      java.log = function(){ return ''; };
      java.put = function(k, v){ var sv = v == null ? '' : String(v); __dart('source_put', k, sv); return sv; };
      java.get = function(k){ return __getStr(k); };
      java.getString = function(k, d){ return __getStr(k, d); };

      // 顶层 crypto 别名：Legado 引擎把加解密函数同时暴露在 java.* 顶层
      // （如 java.md5Encode / java.base64Encode）。规则常用 java.md5Encode(...)。
      java.md5Encode = java.crypto.md5Encode;
      java.md5Encode16 = java.crypto.md5Encode16;
      java.sha1Encode = java.crypto.sha1Encode;
      java.sha256Encode = java.crypto.sha256Encode;
      java.base64Encode = java.crypto.base64Encode;
      java.base64Decode = java.crypto.base64Decode;
      java.aesEncrypt = java.crypto.aesEncrypt;
      java.aesDecrypt = java.crypto.aesDecrypt;
      java.rc4Encrypt = java.crypto.rc4Encrypt;
      java.rc4Decrypt = java.crypto.rc4Decrypt;

      // java.ajax / java.connect 无法在同步 bridge 里发网络请求，由 eval 前的
      // 预处理改写为内联响应；此处仅作未被改写场景的兜底（返回空串）。
      java.ajax = function(url, options){ return ''; };
      java.connect = function(url, options){ return ''; };
      java.post = function(url, body, options){
        // Legado 的 java.post 返回 Connection.Response，规则里常随后调用
        // .body()/.text() 取响应体；未被改写时兜底为空串（返回对象避免 TypeError）。
        return { body: function(){ return ''; }, text: function(){ return ''; },
                 html: function(){ return ''; }, bodyAsBytes: function(){ return ''; } };
      };
      java.http = function(){ return ''; };

      // source / cache
      source = {
        put: function(k, v){ var sv = v == null ? '' : String(v); __dart('source_put', k, sv); return sv; },
        get: function(k){ return __getStr(k); },
        getString: function(k, d){ return __getStr(k, d); },
        putString: function(k, v){ var sv = v == null ? '' : String(v); __dart('source_put', k, sv); return sv; },
        // Legado source.getKey()/setKey()：返回/设置书源 URL（bookSourceUrl）。
        getKey: function(){ return __dart('doc_baseuri'); },
        setKey: function(url){ return url == null ? '' : String(url); }
      };
      cache = {
        put: function(k, v){ var sv = v == null ? '' : String(v); __dart('source_put', k, sv); return sv; },
        get: function(k){ return __getStr(k); }
      };

      // 全局 __hydrate：把 Dart 端返回的节点 JSON 列表包装成 JS 节点对象数组。
      // 供 document.querySelectorAll 与 org.Jsoup.parse(...).select(...) 共用。
      var __hydrate = function(jsonStr) {
        var list;
        try { list = JSON.parse(jsonStr || '[]'); } catch(e) { list = []; }
        if (!Array.isArray(list)) return [];
        function wrap(n) {
          if (!n || typeof n !== 'object') return null;
          return {
            innerHTML:    n.innerHTML  || '',
            outerHTML:    n.outerHTML  || '',
            html:         function(){ return n.innerHTML || ''; },
            outerHtml:    function(){ return n.outerHTML || ''; },
            text:         n.text || '',
            textStr:      n.text || '',
            ownText:      n.ownText || '',
            data:         n.text || '',
            className:    (n.attrs && n.attrs['class']) || '',
            id:           (n.attrs && n.attrs['id'])    || '',
            tagName:      n.tagName || '',
            attr:         function(k){ return (n.attrs && n.attrs[k]) || ''; },
            getAttribute: function(k){ return (n.attrs && n.attrs[k]) || ''; },
            children:     Array.isArray(n.children) ? n.children.map(wrap) : [],
            parent:       function(){ return null; },
            parents:      function(){ return []; },
            remove:       function(){ return []; },
            get:          function(i){ return (i == null) ? this : (wrap(n.children && n.children[i]) || null); }
          };
        }
        return list.map(wrap).filter(function(x){ return x != null; });
      };

      // 把一个节点数组包装成 org.jsoup 的 Elements 对象（可链式 .attr/.text/...）。
      var __jsoupSelect = function(nodes){
        var arr = nodes || [];
        arr.attr      = function(k){ return arr.length ? (arr[0].attr ? arr[0].attr(k) : '') : ''; };
        arr.text      = function(){ return arr.map(function(n){ return n.text || ''; }).join(' ').trim(); };
        arr.textStr   = function(){ return arr.text(); };
        arr.eachText  = function(){ return arr.map(function(n){ return n.text || ''; }); };
        arr.eachAttr  = function(k){ return arr.map(function(n){ return n.attr ? n.attr(k) : ''; }); };
        arr.html      = function(){ return arr.map(function(n){ return n.innerHTML || ''; }).join(''); };
        arr.outerHtml = function(){ return arr.map(function(n){ return n.outerHTML || ''; }).join(''); };
        arr.size      = function(){ return arr.length; };
        arr.first     = function(){ return arr.length ? [arr[0]] : []; };
        arr.last      = function(){ return arr.length ? [arr[arr.length - 1]] : []; };
        arr.get       = function(i){ return i == null ? arr : (arr[i] || null); };
        arr.eq        = function(i){ var n = arr[i]; return n ? [n] : []; };
        arr.remove    = function(){ return arr; };
        arr.addClass  = function(){ return arr; };
        arr.val       = function(){ return arr.attr('value'); };
        return arr;
      };

      // org.jsoup / org.Jsoup：许多书源用 Jsoup.parse(html).select(css) 解析任意
      // 抓到的 HTML 片段（如拉去 CSRF token）。通过 bridge 在 Dart 端用 html 包
      // 解析给定 HTML 并做 CSS 查询。
      org = {
        jsoup: {
          Jsoup: {
            parse: function(html){
              var h = String(html == null ? '' : html);
              return {
                select: function(css){
              var q = (typeof __dart === 'function') ? __dart('jsoup_query', h, String(css||''), 'all') : '';
              return __jsoupSelect(__hydrate(q));
            },
                title: function(){ return ''; },
                body: function(){ return { html: function(){ return h; } }; },
                text: function(){ return ''; }
              };
            },
            connect: function(){ return { get: function(){ return ''; }, timeout: function(){ return this; }, header: function(){ return this; }, ignoreContentType: function(){ return this; } }; }
          }
        }
      };
    ''');
  }

  /// 在每次 evalJs(带 docHtml) 后，同步 document 对象到 JS 侧。
  ///
  /// 实现策略：
  ///  - document.HTML = 整段 HTML 字符串
  ///  - document.querySelector(sel) / querySelectorAll(sel) 通过 bridge 回 Dart 端 html 包查询，
  ///    返回包装 JS 对象（innerText / innerHTML / attr / children / ...）
  Future<void> _syncDocumentBindings(JsEngine engine) async {
    await _safeEval(engine, r'''
      (function() {
        if (typeof document === 'undefined') document = {};
        document.baseURI = __dart('doc_baseuri');
        // Legado 书源 JS 全局 baseUrl = 当前文档 URL。书源在 {{...}}/@js 中常直接
        // 使用（如 {{baseUrl.match(/(\d+).$/)[1]}}、java.put("url", baseUrl)）。
        baseUrl = __dart('doc_baseuri');
        document.body = { innerHTML: __dart('doc_html'), outerHTML: __dart('doc_html') };
        document.documentElement = document.body;
        document.innerHTML = document.body.innerHTML;
        document.outerHTML = document.body.outerHTML;
        document.title = '';

        function _hydrate(jsonStr) {
          try {
            var list = JSON.parse(jsonStr || '[]');
            if (!Array.isArray(list)) return [];
          } catch(e) { return []; }
          var list = JSON.parse(jsonStr || '[]');
          function wrap(n){
            if (!n || typeof n !== 'object') return null;
            return {
              innerHTML:  n.innerHTML  || '',
              outerHTML:  n.outerHTML  || '',
              text:       n.text       || '',
              ownText:    n.ownText    || '',
              className:  (n.attrs && n.attrs['class']) || '',
              id:         (n.attrs && n.attrs['id'])    || '',
              tagName:    n.tagName    || '',
              attr:       function(k){ return (n.attrs && n.attrs[k]) || ''; },
              getAttribute:function(k){ return (n.attrs && n.attrs[k]) || ''; },
              children:   Array.isArray(n.children) ? n.children.map(wrap) : [],
              path:       n.path || ''
            };
          }
          return list.map(wrap);
        }

        document.querySelector = function(sel){
          var list = _hydrate(__dart('doc_query', String(sel||''), 'first'));
          return list && list.length ? list[0] : null;
        };
        document.querySelectorAll = function(sel){
          return _hydrate(__dart('doc_query', String(sel||''), 'all'));
        };

        // $ / jQuery-lite
        if (typeof $ === 'undefined') {
          $ = function(sel){
            if (typeof sel !== 'string') return [];
            var arr = document.querySelectorAll(sel);
            arr.html  = function(){ return arr.length ? arr[0].innerHTML : ''; };
            arr.text  = function(){ return arr.map(function(n){return n.text||'';}).join(' '); };
            arr.attr  = function(k){ return arr.length ? (arr[0].attr ? arr[0].attr(k) : '') : ''; };
            arr.get   = function(i){ return i == null ? arr : (arr[i] || null); };
            arr.eq    = function(i){ var n = arr[i]; return n ? [n] : []; };
            arr.size  = function(){ return arr.length; };
            arr.first = function(){ return arr.length ? [arr[0]] : []; };
            arr.last  = function(){ return arr.length ? [arr[arr.length-1]] : []; };
            return arr;
          };
        }
      })();
    ''');
  }

  // ========= 辅助方法 =========

  static String _assignmentExpr(String name, Object? value) {
    if (value == null) return 'var $name = null;';
    if (value is bool || value is num) return 'var $name = $value;';
    return 'var $name = ${jsonEncode('$value')};';
  }

  static String _stripJsTag(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('@js:')) s = s.substring(4);
    s = s.replaceFirst(RegExp(r'^\s*<js>\s*', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'\s*</js>\s*$', caseSensitive: false), '');
    return s;
  }

  static Future<Object?> _safeEval(JsEngine engine, String code) async {
    try {
      final r = await engine.eval(source: JsCode.code(code));
      return r.value;
    } catch (_) {
      return null;
    }
  }

  /// 动态 [java.ajax] 第一参数求值：在已注入 `result`/`baseUrl` 等全局的引擎里
  /// 求值表达式（如 `JSON.parse(result).data.chapter_list_link`），返回 URL 字符串。
  /// 求值失败或结果为空返回 null（调用方会原样保留该调用，走 JS 兜底）。
  Future<String?> _ajaxArgResolver(String expr) async {
    final engine = _engine;
    if (engine == null) return null;
    final r = await _safeEval(engine, 'String($expr)');
    if (r == null) return null;
    final s = '$r'.trim();
    return s.isEmpty ? null : s;
  }

  static String _js2string(JsValue v) {
    try {
      if (v is JsValue_String) return v.asString ?? '';
      if (v is JsValue_None) return '';
      if (v is JsValue_Boolean) return v.asBoolean?.toString() ?? '';
      if (v is JsValue_Float || v is JsValue_Integer) {
        return (v.asFloat ?? v.asInteger ?? 0).toString();
      }
      if (v is JsValue_Array || v is JsValue_Object) {
        // 数组/对象：Dart 侧拥有完整的 value 结构，直接序列化为 JSON。
        // 若在 dispatch 里（v 为 JsValue_Object 且内容是 "cmd" 桥接）不在此分支。
        try {
          return jsonEncode(v.value);
        } catch (_) {
          return v.asString ?? '';
        }
      }
      // 其它（bigint / date / symbol / function 等）：透过 value 兜底
      return v.asString ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 完成值 → 字符串：字符串类型原样提取；数组/对象序列化为 JSON 字符串。
  /// JS 规则以 `list` 数组结尾（如中文书城 chapterList 的 `list.push(...)` 结构
  /// 其完成值即章节对象数组），此前 asString 会退化成 "[object Object]，需要
  /// 正确的 JSON 序列化才能被下游 jsonDecode 识别为章节列表。
  static String _completionString(Object? completion) {
    if (completion is! JsValue) return '';
    if (completion is JsValue_Array || completion is JsValue_Object) {
      try {
        return jsonEncode(completion.value);
      } catch (_) {
        return '';
      }
    }
    return _js2string(completion);
  }

  static String _argS(List<Object?> args, int i) {
    if (i < 0 || i >= args.length) return '';
    final a = args[i];
    if (a == null) return '';
    if (a is String) return a;
    return '$a';
  }

  static JsValue _s(String v) => JsValue.string(v);

  static String _hash(Hash hash, String s) {
    try {
      return hash.convert(utf8.encode(s)).toString();
    } catch (_) {
      return '';
    }
  }

  static String _rc4(String data, String key, bool encrypt) {
    try {
      final bytes = encrypt ? utf8.encode(data) : base64Decode(data.replaceAll(RegExp(r'\s'), ''));
      final k = utf8.encode(key);
      final sbox = List<int>.generate(256, (i) => i);
      var j = 0;
      for (var i = 0; i < 256; i++) {
        j = (j + sbox[i] + k[i % k.length]) & 0xFF;
        final t = sbox[i];
        sbox[i] = sbox[j];
        sbox[j] = t;
      }
      var i = 0;
      j = 0;
      final out = List<int>.filled(bytes.length, 0);
      for (var idx = 0; idx < bytes.length; idx++) {
        i = (i + 1) & 0xFF;
        j = (j + sbox[i]) & 0xFF;
        final t = sbox[i];
        sbox[i] = sbox[j];
        sbox[j] = t;
        out[idx] = bytes[idx] ^ sbox[(sbox[i] + sbox[j]) & 0xFF];
      }
      return encrypt ? base64Encode(out) : utf8.decode(out, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  // ========= java.ajax / java.connect 预处理改写（委托共用库） =========

  /// 把规则里的 `java.ajax('URL')` / `java.connect('URL', {options})` 字面量调用
  /// 先取回响应，改写为内联字符串字面量后交给 JS 执行；动态第一参数（如
  /// `JSON.parse(result).data.xxx`）通过 [_ajaxArgResolver] 先求值出 URL。实现见
  /// 共用库 [rewriteAjaxCalls]（生产/测试沙箱复用同一份逻辑）。
  Future<String> _rewriteAjaxCalls(String code) {
    return rewriteAjaxCalls(
      code,
      baseUri: _currentBaseUri,
      fetcher: _ajaxFetcher,
      evalArg: _ajaxArgResolver,
    );
  }

  // ========= AES（点加密，ECB/CBC + PKCS7/无填充） =========

  /// Legado 源 AES 加密，支持 ECB/CBC、PKCS7/无填充；key/iv 自动识别 hex 或 utf8。
  /// 仅覆盖主流用法（ECB/CBC）；其它模式（CFB/OFB/CTR）回退空串（不劣于旧行为）。
  /// 供单元测试直接验证 AES 解密（对齐 `java.aesBase64DecodeToString` 的
  /// 参数序 (data, key, mode, iv)，返回解密后的 UTF-8 明文字符串）。
  /// 不依赖 JS 引擎，仅执行底层 AES 逻辑。
  @visibleForTesting
  String aesBase64DecodeToString(
    String data,
    String key,
    String mode,
    String iv,
  ) =>
      _aes(data, key, iv, mode, false, '');

  String _aes(String data, String key, String iv, String modeStr, bool encrypt, String out) {
    try {
      final mode = _aesMode(modeStr);
      if (mode != 'ECB' && mode != 'CBC') return '';
      final padded = _aesPadded(modeStr);
      if (mode != 'ECB' && iv.trim().isEmpty) return '';
      final k = _aesKeyBytes(key);
      final ivBytes = mode == 'ECB' ? Uint8List(0) : _aesKeyBytes(iv);
      final input = encrypt
          ? Uint8List.fromList(utf8.encode(data))
          : _aesDecodeInput(data);
      final processed = _aesExec(mode, k, ivBytes, padded, encrypt, input);
      if (encrypt) {
        final hexEnc = processed
            .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
            .join();
        return out.trim().toLowerCase() == 'base64'
            ? base64Encode(processed)
            : hexEnc;
      }
      return utf8.decode(processed, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  Uint8List _aesDecodeInput(String data) {
    final trimmed = data.trim();
    final isHex = trimmed.isNotEmpty &&
        trimmed.length % 2 == 0 &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed);
    if (isHex) return _hexToBytes(trimmed);
    return Uint8List.fromList(base64Decode(trimmed.replaceAll(RegExp(r'\s'), '')));
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// 解析模式串：`AES/CBC/PKCS7Padding`、`CBC`、`ECB`、`CBCNoPadding` 等。
  static String _aesMode(String m) {
    final s = m.trim().toUpperCase().replaceFirst('AES/', '');
    final first = s.split('/').first;
    for (final candidate in ['ECB', 'CBC', 'CFB', 'OFB', 'CTR']) {
      if (first.contains(candidate)) return candidate;
    }
    return s.contains('ECB') ? 'ECB' : 'CBC';
  }

  static bool _aesPadded(String m) {
    final s = m.trim().toUpperCase();
    return !s.contains('NOPADDING') && !s.endsWith('NO');
  }

  static Uint8List _aesKeyBytes(String s) {
    final t = s.trim();
    if (t.isNotEmpty &&
        (t.length == 32 || t.length == 48 || t.length == 64) &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(t)) {
      return _hexToBytes(t);
    }
    return Uint8List.fromList(utf8.encode(t));
  }

  /// 执行一次 AES 加/解密。
  ///
  ///  - 带填充（PKCS7）：用 [PaddedBlockCipherImpl]，输入可任意长。
  ///  - 无填充：底层块密码需 16 字节对齐；解密时自动去除尾部的 0 填充
  ///    （部分 Legado 源无 PKCS7，但明文短于块长时用 0 补齐）。
  Uint8List _aesExec(
    String mode,
    Uint8List key,
    Uint8List iv,
    bool padded,
    bool encrypt,
    Uint8List input,
  ) {
    final aes = AESEngine();
    if (padded) {
      final PaddedBlockCipher cipher;
      final CipherParameters params;
      if (mode == 'ECB') {
        cipher = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(aes));
        params = KeyParameter(key);
      } else {
        cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(aes));
        params = ParametersWithIV(KeyParameter(key), iv);
      }
      cipher.init(encrypt, PaddedBlockCipherParameters(params, null));
      return cipher.process(input);
    }

    // NoPadding：逐 16 字节块处理。
    final BlockCipher cipher;
    final CipherParameters params;
    if (mode == 'ECB') {
      cipher = ECBBlockCipher(aes);
      params = KeyParameter(key);
    } else {
      cipher = CBCBlockCipher(aes);
      params = ParametersWithIV(KeyParameter(key), iv);
    }
    cipher.init(encrypt, params);
    final out = Uint8List(input.lengthInBytes);
    for (var off = 0; off < input.lengthInBytes; off += 16) {
      cipher.processBlock(input, off, out, off);
    }
    if (!encrypt) {
      var end = out.length;
      while (end > 16 && out[end - 1] == 0) {
        end--;
      }
      return out.sublist(0, end);
    }
    return out;
  }

  /// 在「任意传入的 HTML 字符串」上做 CSS 查询（org.Jsoup.parse(html).select 用）。
  /// 与 [_docQuery] 的区别：不依赖沙箱当前文档，而是解析传入的 HTML 片段。
  List<Map<String, dynamic>> _jsoupQuery(String html, String selector, String mode) {
    if (html.trim().isEmpty || selector.trim().isEmpty) return const [];
    final dom.Document doc;
    try {
      doc = html_parser.parse(html);
    } catch (_) {
      return const [];
    }
    List<dom.Element> result;
    try {
      if (mode == 'first') {
        final f = doc.querySelector(selector);
        result = f == null ? const [] : [f];
      } else {
        result = doc.querySelectorAll(selector);
      }
    } catch (_) {
      return const [];
    }
    return result.asMap().entries.map((e) => _nodeToMap(e.value, '/${e.key}')).toList(growable: false);
  }

  List<Map<String, dynamic>> _docQuery(String selector, String mode) {
    final document = _domCache;
    if (document == null || selector.trim().isEmpty) return const [];
    List<dom.Element> result;
    try {
      if (mode == 'first') {
        final f = document.querySelector(selector);
        result = f == null ? const [] : [f];
      } else {
        result = document.querySelectorAll(selector);
      }
    } catch (_) {
      return const [];
    }
    return result.asMap().entries.map((e) => _nodeToMap(e.value, '/${e.key}')).toList(growable: false);
  }

  Map<String, dynamic> _nodeToMap(dom.Node n, String path) {
    final attrs = n is dom.Element ? Map<String, String>.from(n.attributes) : <String, String>{};
    final children = n.nodes.whereType<dom.Element>().toList();
    final ownText = n.nodes.whereType<dom.Text>().map((t) => t.data).join(' ').trim();
    return <String, dynamic>{
      'innerHTML': n is dom.Element ? n.innerHtml : '',
      'outerHTML': n is dom.Element ? n.outerHtml : '',
      'text': n is dom.Element ? n.text : (n.text ?? ''),
      'ownText': ownText,
      'attrs': attrs,
      'tagName': n is dom.Element ? n.localName?.toUpperCase() ?? '' : '',
      'path': path,
      'children': children.asMap().entries.map((e) => _nodeToMap(e.value, '$path/${e.key}')).toList(growable: false),
    };
  }
}
