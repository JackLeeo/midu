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
import 'package:midu/book_sources/legado/legado_ajax_rewrite.dart';

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
class FlutterLegadoJsSandbox implements LegadoJsSandbox, AjaxFetcherSink {
  FlutterLegadoJsSandbox() : _runtime = QuickJsRuntime2();

  final JavascriptRuntime _runtime;
  final Map<String, String> _vars = <String, String>{};
  bool _inited = false;

  /// 最近一次 JS 执行失败的错误信息（无则 null），用于测试诊断。
  String? lastError;

  /// 最近一次 eval 生成的完整包装代码（调试用）。
  String? debugLastWrapped;

  /// 最近一次传给 eval 的改写后规则代码（调试用）。
  String? debugLastRewritten;

  /// 最近一次 evaluate 是否整体编译失败（外层，非规则内异常）。
  bool debugCompileFailed = false;

  /// java.ajax / java.connect 网络执行器。本地 QuickJS 无 JS→Dart 异步桥，
  /// 采用「eval 前源码改写」预取响应并内联（同生产 fjs 沙箱，见
  /// [legado_ajax_rewrite.rewriteAjaxCalls]）。
  AjaxFetcher? _ajaxFetcher;

  @override
  void setAjaxFetcher(AjaxFetcher? fetcher) => _ajaxFetcher = fetcher;

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

  /// 预加载书源公共 JS 库（jsLib）：在全局作用域执行一次，声明函数对后续
  /// evalJs 可见（QuickJS 共享 global，等价于生产 fjs 沙箱的 preloadJsLib）。
  @override
  Future<void> preloadJsLib(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return;
    if (!_inited) await init();
    final r = _runtime.evaluate(_stripJsTag(trimmed));
    if (r.isError) lastError = r.stringResult;
  }

  @override
  String? getSourceVar(String key) => _vars[key];

  @override
  void putSourceVar(String key, String value) => _vars[key] = value;

  /// 对齐 LegadoFjsSandbox 的 polyfill（变量/寄存器由 evalJs 包装注入）。
  static const String _prelude = '''
    var __b64 = function(s){
      if (s == null) return ''; var bytes = [];
      for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); if (c < 128) bytes.push(c); else if (c < 2048) bytes.push(192 | (c >> 6), 128 | (c & 63)); else bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63)); }
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', out = '', i;
      for (i = 0; i < bytes.length; i += 3) {
        var b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
        out += chars[b0 >> 2] + chars[((b0 & 3) << 4) | (b1 >> 4)] + chars[((b1 & 15) << 2) | (b2 >> 6)] + chars[b2 & 63];
      }
      var pad = 3 - (bytes.length % 3 || 3); return pad === 3 ? out : out.substring(0, out.length - pad) + '='.repeat(pad);
    };
    var __b64d = function(s){
      if (s == null) return '';
      s = String(s).replace(/[^A-Za-z0-9+\/=]/g, '');
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', idx = {};
      for (var i = 0; i < chars.length; i++) idx[chars[i]] = i;
      var bytes = [], bit = 0, val = 0;
      for (var j = 0; j < s.length; j++) {
        if (s[j] === '=') break;
        val = (val << 6) | idx[s[j]]; bit += 6;
        if (bit >= 8) { bit -= 8; bytes.push((val >> bit) & 255); }
      }
      // 按 UTF-8 解码（与生产 fjs 沙箱 atob 的 Dart utf8.decode 对齐），
      // 避免正文等 base64 中文被逐字节映射成 Latin-1 乱码。
      var out = '', k = 0;
      while (k < bytes.length) {
        var b = bytes[k++];
        if (b < 0x80) { out += String.fromCharCode(b); continue; }
        var cp, need;
        if (b >= 0xF0) { cp = b & 0x07; need = 3; }
        else if (b >= 0xE0) { cp = b & 0x0F; need = 2; }
        else if (b >= 0xC0) { cp = b & 0x1F; need = 1; }
        else { out += '?'; continue; }
        var ok = true, extra;
        for (extra = 0; extra < need; extra++) {
          if (k >= bytes.length) { ok = false; break; }
          var nb = bytes[k++];
          if ((nb & 0xC0) !== 0x80) { ok = false; k--; break; }
          cp = (cp << 6) | (nb & 0x3F);
        }
        if (!ok) { out += '?'; continue; }
        out += String.fromCodePoint(cp);
      }
      return out;
    };
    var __sha256 = function(s){
      if (s == null) return '';
      var bytes = __utf8(s), i;
      var originalLen = bytes.length * 8;
      bytes.push(0x80);
      while (bytes.length % 64 !== 56) bytes.push(0);
      for (i = 0; i < 8; i++) bytes.push(i < 4 ? (originalLen >>> (24 - 8 * i)) & 255 : 0);
      var K = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
               0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
               0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
               0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
               0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
               0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
               0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
               0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
      var H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
      function R(x, n){ return (x >>> n) | (x << (32 - n)); }
      for (var off = 0; off < bytes.length; off += 64) {
        var w = [];
        for (i = 0; i < 16; i++) w[i] = (bytes[off + 4 * i] << 24) | (bytes[off + 4 * i + 1] << 16) | (bytes[off + 4 * i + 2] << 8) | bytes[off + 4 * i + 3];
        for (i = 16; i < 64; i++) {
          var s0 = R(w[i - 15], 7) ^ R(w[i - 15], 18) ^ (w[i - 15] >>> 3);
          var s1 = R(w[i - 2], 17) ^ R(w[i - 2], 19) ^ (w[i - 2] >>> 10);
          w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
        }
        var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], hh = H[7];
        for (i = 0; i < 64; i++) {
          var S1 = R(e, 6) ^ R(e, 11) ^ R(e, 25);
          var ch = (e & f) ^ (~e & g);
          var t1 = (hh + S1 + ch + K[i] + w[i]) | 0;
          var S0 = R(a, 2) ^ R(a, 13) ^ R(a, 22);
          var maj = (a & b) ^ (a & c) ^ (b & c);
          var t2 = (S0 + maj) | 0;
          hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
        }
        H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
        H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + hh) | 0;
      }
      var out = '';
      for (i = 0; i < 8; i++) {
        var x = H[i] >>> 0;
        out += (x >>> 24 & 255).toString(16).padStart(2, '0') + (x >>> 16 & 255).toString(16).padStart(2, '0') +
               (x >>> 8 & 255).toString(16).padStart(2, '0') + (x & 255).toString(16).padStart(2, '0');
      }
      return out;
    };
    var __utf8 = function(s){ var b=[],i; for(i=0;i<s.length;i++){var c=s.charCodeAt(i); if(c<128)b.push(c); else if(c<2048)b.push(192|(c>>6),128|(c&63)); else if(c>=55296&&c<57344){var c2=s.charCodeAt(++i); var v=0x10000+((c&1023)<<10)+(c2&1023); b.push(240|(v>>18),128|((v>>12)&63),128|((v>>6)&63),128|(v&63));} else b.push(224|(c>>12),128|((c>>6)&63),128|(c&63));} return b; };
    var __sha1 = function(s){
      if (s == null) return '';
      var msg = __utf8(s), ml = msg.length * 8, h = [0x67452301,0xEFCDAB89,0x98BADCFE,0x10325476,0xC3D2E1F0];
      var l = Math.ceil((ml+65)/512)*64, p = new Array(l).fill(0);
      for (var i=0;i<msg.length;i++) p[i]=msg[i];
      p[msg.length]=0x80;
      for (var k=0;k<8;k++) p[l-1-k]=(ml>>>8*k)&255;
      for (var off=0; off<l; off+=64) {
        var w=[];
        for (var j=0;j<16;j++) w[j]=(p[off+4*j]<<24)|(p[off+4*j+1]<<16)|(p[off+4*j+2]<<8)|p[off+4*j+3];
        for (j=16;j<80;j++){var t=w[j-3]^w[j-8]^w[j-14]^w[j-16]; w[j]=(t<<1)|(t>>>31);}
        var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4];
        for (j=0;j<80;j++){var f,K; if(j<20){f=(b&c)|(~b&d); K=0x5A827999;} else if(j<40){f=b^c^d; K=0x6ED9EBA1;} else if(j<60){f=(b&c)|(b&d)|(c&d); K=0x8F1BBCDC;} else {f=b^c^d; K=0xCA62C1D6;}
          var tmp=((a<<5)|(a>>>27))+f+e+K+w[j]; e=d; d=c; c=(b<<30)|(b>>>2); b=a; a=tmp;}
        h[0]=(h[0]+a)>>>0; h[1]=(h[1]+b)>>>0; h[2]=(h[2]+c)>>>0; h[3]=(h[3]+d)>>>0; h[4]=(h[4]+e)>>>0;
      }
      var out=''; for (var m=0;m<5;m++){out += ((h[m]>>>24)&255).toString(16).padStart(2,'0')+((h[m]>>>16)&255).toString(16).padStart(2,'0')+((h[m]>>>8)&255).toString(16).padStart(2,'0')+(h[m]&255).toString(16).padStart(2,'0');}
      return out;
    };
    var __md5 = function(s){
      if (s == null) return '';
      var bytes = __utf8(s), j;
      var bitLenLo = (bytes.length * 8) >>> 0;
      bytes.push(0x80);
      while (bytes.length % 64 !== 56) bytes.push(0);
      for (j = 0; j < 8; j++) bytes.push(j < 4 ? (bitLenLo >>> (8 * j)) & 255 : 0);
      var S = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
      var K = [0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391];
      var A = 0x67452301, B = 0xefcdab89, C = 0x98badcfe, D = 0x10325476;
      function rot(x, n){ return (x << n) | (x >>> (32 - n)); }
      for (var off = 0; off < bytes.length; off += 64) {
        var M = [];
        for (j = 0; j < 16; j++) M[j] = bytes[off + 4 * j] | (bytes[off + 4 * j + 1] << 8) | (bytes[off + 4 * j + 2] << 16) | (bytes[off + 4 * j + 3] << 24);
        var a = A, b = B, c = C, d = D;
        for (j = 0; j < 64; j++) {
          var F, g;
          if (j < 16) { F = (b & c) | (~b & d); g = j; }
          else if (j < 32) { F = (d & b) | (~d & c); g = (5 * j + 1) & 15; }
          else if (j < 48) { F = b ^ c ^ d; g = (3 * j + 5) & 15; }
          else { F = c ^ (b | ~d); g = (7 * j) & 15; }
          F = (F + a + K[j] + M[g]) | 0;
          a = d; d = c; c = b;
          b = (b + rot(F, S[j])) | 0;
        }
        A = (A + a) | 0; B = (B + b) | 0; C = (C + c) | 0; D = (D + d) | 0;
      }
      function toHex(x){
        x = x >>> 0;
        return (x % 256).toString(16).padStart(2, '0') +
               (((x >>> 8) % 256)).toString(16).padStart(2, '0') +
               (((x >>> 16) % 256)).toString(16).padStart(2, '0') +
               (((x >>> 24) % 256)).toString(16).padStart(2, '0');
      }
      return toHex(A) + toHex(B) + toHex(C) + toHex(D);
    };
    var __gfMul = function(a,b){
      var poly = 0x11b, r = 0;
      a = a & 255; b = b & 255;
      while (b) {
        if (b & 1) r ^= a;
        b >>>= 1;
        a <<= 1;
        if (a & 0x100) a ^= poly;
      }
      return r & 255;
    };
    var __gfPow = function(a,n){
      var r = 1;
      while (n > 0) {
        if (n & 1) r = __gfMul(r, a);
        a = __gfMul(a, a);
        n >>>= 1;
      }
      return r;
    };
    var __rotl8 = function(v,n){
      n = n & 7;
      return ((v << n) & 255) | ((v & 255) >>> (8 - n));
    };
    var __sbox = [];
    var __invSbox = [];
    (function(){
      var x, inv, sb;
      for (x = 0; x < 256; x++) {
        inv = (x === 0) ? 0 : __gfPow(x, 254);
        sb = inv ^ __rotl8(inv,1) ^ __rotl8(inv,2) ^ __rotl8(inv,3) ^ __rotl8(inv,4) ^ 0x63;
        __sbox[x] = sb;
      }
      for (x = 0; x < 256; x++) __invSbox[__sbox[x]] = x;
    })();
    var __rconByte = function(i){
      var RC = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36];
      return (i >= 0 && i < 10) ? RC[i] : 0;
    };
    var __aesExpandKey = function(key){
      var Nk = key.length / 4;
      var Nr = Nk + 6;
      var w = [], rkeys = [], i, r;
      for (i = 0; i < Nk; i++) w.push([key[4*i], key[4*i+1], key[4*i+2], key[4*i+3]]);
      for (i = Nk; i < 4*(Nr+1); i++) {
        var temp = w[i-1].slice();
        if (i % Nk === 0) {
          temp = [__sbox[temp[1]] ^ __rconByte(i/Nk - 1), __sbox[temp[2]], __sbox[temp[3]], __sbox[temp[0]]];
        } else if (Nk > 6 && i % Nk === 4) {
          temp = [__sbox[temp[0]], __sbox[temp[1]], __sbox[temp[2]], __sbox[temp[3]]];
        }
        var prev = w[i-Nk];
        w.push([prev[0]^temp[0], prev[1]^temp[1], prev[2]^temp[2], prev[3]^temp[3]]);
      }
      for (r = 0; r <= Nr; r++) rkeys.push([].concat(w[4*r], w[4*r+1], w[4*r+2], w[4*r+3]));
      return { rkeys: rkeys, Nr: Nr };
    };
    var __addRoundKey = function(s, rk){ for (var i = 0; i < 16; i++) s[i] ^= rk[i]; };
    var __subBytes = function(s, tbl){ for (var i = 0; i < 16; i++) s[i] = tbl[s[i]]; };
    var __invSubBytes = function(s){ for (var i = 0; i < 16; i++) s[i] = __invSbox[s[i]]; };
    var __shiftRows = function(s){
      var t;
      t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t;
      t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t;
      t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
    };
    var __invShiftRows = function(s){
      var t;
      t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
      t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t;
      t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
    };
    var __mixColumns = function(s){
      for (var c = 0; c < 4; c++) {
        var o = c * 4;
        var a = s[o], b = s[o+1], d = s[o+2], e = s[o+3];
        var g2 = function(x){ return __gfMul(x, 2); };
        var g3 = function(x){ return __gfMul(x, 3); };
        s[o]   = g2(a) ^ g3(b) ^ d ^ e;
        s[o+1] = a ^ g2(b) ^ g3(d) ^ e;
        s[o+2] = a ^ b ^ g2(d) ^ g3(e);
        s[o+3] = g3(a) ^ b ^ d ^ g2(e);
      }
    };
    var __invMixColumns = function(s){
      for (var c = 0; c < 4; c++) {
        var o = c * 4;
        var a = s[o], b = s[o+1], d = s[o+2], e = s[o+3];
        s[o]   = __gfMul(a,14) ^ __gfMul(b,11) ^ __gfMul(d,13) ^ __gfMul(e,9);
        s[o+1] = __gfMul(a,9)  ^ __gfMul(b,14) ^ __gfMul(d,11) ^ __gfMul(e,13);
        s[o+2] = __gfMul(a,13) ^ __gfMul(b,9)  ^ __gfMul(d,14) ^ __gfMul(e,11);
        s[o+3] = __gfMul(a,11) ^ __gfMul(b,13) ^ __gfMul(d,9)  ^ __gfMul(e,14);
      }
    };
    var __aesEncryptBlock = function(rk, blk){
      var s = blk.slice(), r;
      __addRoundKey(s, rk.rkeys[0]);
      for (r = 1; r < rk.Nr; r++) {
        __subBytes(s, __sbox);
        __shiftRows(s);
        __mixColumns(s);
        __addRoundKey(s, rk.rkeys[r]);
      }
      __subBytes(s, __sbox);
      __shiftRows(s);
      __addRoundKey(s, rk.rkeys[rk.Nr]);
      return s;
    };
    var __aesDecryptBlock = function(rk, blk){
      var s = blk.slice(), r;
      __addRoundKey(s, rk.rkeys[rk.Nr]);
      for (r = rk.Nr - 1; r >= 1; r--) {
        __invShiftRows(s);
        __invSubBytes(s);
        __addRoundKey(s, rk.rkeys[r]);
        __invMixColumns(s);
      }
      __invShiftRows(s);
      __invSubBytes(s);
      __addRoundKey(s, rk.rkeys[0]);
      return s;
    };
    var __utf8Decode = function(bytes){
      var out = '', k = 0;
      while (k < bytes.length) {
        var b = bytes[k++];
        if (b < 0x80) { out += String.fromCharCode(b); continue; }
        var cp, need;
        if (b >= 0xF0) { cp = b & 0x07; need = 3; }
        else if (b >= 0xE0) { cp = b & 0x0F; need = 2; }
        else if (b >= 0xC0) { cp = b & 0x1F; need = 1; }
        else { out += '?'; continue; }
        var ok = true, extra;
        for (extra = 0; extra < need; extra++) {
          if (k >= bytes.length) { ok = false; break; }
          var nb = bytes[k++];
          if ((nb & 0xC0) !== 0x80) { ok = false; k--; break; }
          cp = (cp << 6) | (nb & 0x3F);
        }
        if (!ok) { out += '?'; continue; }
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) { out += '?'; continue; }
        out += String.fromCodePoint(cp);
      }
      return out;
    };
    var __b64dBytes = function(s){
      s = String(s).replace(/[^A-Za-z0-9+\/=]/g, '');
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', idx = {};
      for (var i = 0; i < chars.length; i++) idx[chars[i]] = i;
      var bytes = [], bit = 0, val = 0;
      for (var j = 0; j < s.length; j++) {
        if (s[j] === '=') break;
        val = (val << 6) | idx[s[j]]; bit += 6;
        if (bit >= 8) { bit -= 8; bytes.push((val >> bit) & 255); }
      }
      return bytes;
    };
    var __b64Bytes = function(bytes){
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', out = '', i;
      for (i = 0; i < bytes.length; i += 3) {
        var b0 = bytes[i], b1 = i+1 < bytes.length ? bytes[i+1] : 0, b2 = i+2 < bytes.length ? bytes[i+2] : 0;
        out += chars[b0 >> 2] + chars[((b0 & 3) << 4) | (b1 >> 4)] + chars[((b1 & 15) << 2) | (b2 >> 6)] + chars[b2 & 63];
      }
      var pad = 3 - (bytes.length % 3 || 3);
      return pad === 3 ? out : out.substring(0, out.length - pad) + '='.repeat(pad);
    };
    var __aesParseKey = function(s){
      var t = String(s).trim();
      if ((t.length === 32 || t.length === 48 || t.length === 64) && /^[0-9a-fA-F]+\$/.test(t)) {
        var out = [];
        for (var i = 0; i < t.length; i += 2) out.push(parseInt(t.substring(i, i+2), 16));
        return out;
      }
      return __utf8(t);
    };
    var __aesParseMode = function(m){
      var s = String(m).trim().toUpperCase();
      if (s.indexOf('AES/') === 0) s = s.substring(4);
      var first = s.split('/')[0];
      if (first.indexOf('ECB') >= 0) return 'ECB';
      if (first.indexOf('CBC') >= 0) return 'CBC';
      return s.indexOf('ECB') >= 0 ? 'ECB' : 'CBC';
    };
    var __aesPadded = function(m){
      var s = String(m).trim().toUpperCase();
      return s.indexOf('NOPADDING') < 0 && s.substr(s.length - 2) !== 'NO';
    };
    var __aesCore = function(data, key, mode, iv, encrypt, out){
      try {
        var modeName = __aesParseMode(mode);
        if (modeName !== 'ECB' && modeName !== 'CBC') return '';
        var padded = __aesPadded(mode);
        if (modeName !== 'ECB' && String(iv).trim() === '') return '';
        var k = __aesParseKey(key);
        if (k.length !== 16 && k.length !== 24 && k.length !== 32) return '';
        var rk = __aesExpandKey(k);
        var input, i;
        if (encrypt) {
          var cnt = __utf8(String(data == null ? '' : data));
          if (padded) {
            var plen = 16 - (cnt.length % 16);
            for (i = 0; i < plen; i++) cnt.push(plen);
          } else {
            while (cnt.length % 16 !== 0) cnt.push(0);
          }
          input = cnt;
        } else {
          var raw = String(data == null ? '' : data).trim();
          var isHex = raw.length % 2 === 0 && /^[0-9a-fA-F]+\$/.test(raw);
          var tmp = [];
          if (isHex) {
            for (i = 0; i < raw.length; i += 2) tmp.push(parseInt(raw.substring(i, i+2), 16));
          } else {
            tmp = __b64dBytes(raw);
          }
          input = tmp;
        }
        var ivBytes = modeName === 'ECB' ? [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0] : __aesParseKey(iv);
        var prev = ivBytes.slice();
        var outBytes = [], ofs;
        for (ofs = 0; ofs < input.length; ofs += 16) {
          var block = input.slice(ofs, ofs + 16);
          while (block.length < 16) block.push(0);
          var res;
          if (modeName === 'CBC') {
            if (encrypt) {
              for (i = 0; i < 16; i++) block[i] ^= prev[i];
              res = __aesEncryptBlock(rk, block);
              prev = res.slice();
            } else {
              var dec = __aesDecryptBlock(rk, block);
              res = [];
              for (i = 0; i < 16; i++) res[i] = dec[i] ^ prev[i];
              prev = block.slice();
            }
          } else {
            res = encrypt ? __aesEncryptBlock(rk, block) : __aesDecryptBlock(rk, block);
          }
          for (i = 0; i < 16; i++) outBytes.push(res[i]);
        }
        if (encrypt) {
          if (String(out).trim().toLowerCase() === 'base64') return __b64Bytes(outBytes);
          return outBytes.map(function(b){ return ('0' + b.toString(16)).slice(-2); }).join('');
        }
        if (padded) {
          var last = outBytes[outBytes.length - 1];
          if (last >= 1 && last <= 16 && outBytes.length >= last) {
            outBytes.splice(outBytes.length - last, last);
          } else {
            while (outBytes.length > 0 && outBytes[outBytes.length-1] === 0) outBytes.pop();
          }
        } else {
          while (outBytes.length > 0 && outBytes[outBytes.length-1] === 0) outBytes.pop();
        }
        return __utf8Decode(outBytes);
      } catch (e) { return '__AES_ERR__' + String(e); }
    };
    var __ctx = function(){
      if (typeof contextJson === 'undefined' || contextJson == null) return null;
      if (typeof contextJson === 'object') return contextJson;
      try { return JSON.parse(contextJson); } catch(e){ return null; }
    };
    var __getStr = function(k, d){
      var dflt = (d === undefined || d === null) ? '' : String(d);
      if (typeof k === 'string' && k.length > 1 && k.charAt(0) === '\$' &&
          (k.charAt(1) === '.' || k.charAt(1) === '[')) {
        var o = __ctx();
        if (o == null) return dflt;
        var pArr = k.charAt(1) === '['
            ? k.replace(/[\[]/g, '.').replace(/[\]]/g, '.').split('.')
            : k.substring(1).split('.');
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
      var s = __vars[k];
      return (s === undefined || s === null || s === '') ? dflt : String(s);
    };
    var source = {
      get: function(k){ return __getStr(k); },
      put: function(k, v){ __vars[k] = v == null ? '' : String(v); return v == null ? '' : String(v); },
      getString: function(k, d){ return __getStr(k, d); },
      putString: function(k, v){ __vars[k] = v == null ? '' : String(v); },
      getKey: function(){ return baseUrl; },
      setKey: function(url){ return ''; }
    };
    var cache = {
      put: function(k, v){ __vars[k] = v == null ? '' : String(v); },
      get: function(k){ return __getStr(k); }
    };
    var java = {};
    java.crypto = {
      md5Encode:        __md5,
      md5Encode16:      function(s){ var h = __md5(s == null ? '' : String(s)); return h && h.length === 32 ? h.substring(8, 24) : ''; },
      sha1Encode:       __sha1,
      sha256Encode:     __sha256,
      base64Encode:     function(s){ return __b64(s == null ? '' : String(s)); },
      base64Decode:     function(s){ return __b64d(s == null ? '' : String(s)); },
      aesEncrypt:       function(data, key, iv, mode, p, pad, out){ return __aesCore(String(data==null||data===undefined?'':data), String(key==null||key===undefined?'':key), String(mode==null||mode===undefined?'':mode), String(iv==null||iv===undefined?'':iv), true, String(out==null||out===undefined?'':out)); },
      aesDecrypt:       function(data, key, iv, mode, p, pad, out){ return __aesCore(String(data==null||data===undefined?'':data), String(key==null||key===undefined?'':key), String(mode==null||mode===undefined?'':mode), String(iv==null||iv===undefined?'':iv), false, String(out==null||out===undefined?'':out)); },
      aesBase64DecodeToString: function(data, key, mode, iv, p, pad){ return __aesCore(String(data==null||data===undefined?'':data), String(key==null||key===undefined?'':key), String(mode==null||mode===undefined?'':mode), String(iv==null||iv===undefined?'':iv), false, ''); },
      aesBase64EncodeToString: function(data, key, mode, iv, p, pad){ return __aesCore(String(data==null||data===undefined?'':data), String(key==null||key===undefined?'':key), String(mode==null||mode===undefined?'':mode), String(iv==null||iv===undefined?'':iv), true, 'base64'); },
      rc4Encrypt:       function(){ return ''; },
      rc4Decrypt:       function(){ return ''; }
    };
    // 顶层 crypto 别名（Legado 引擎同时暴露在 java.* 顶层），规则常用
    // java.md5Encode(...)、java.base64Encode(...)。
    java.md5Encode = java.crypto.md5Encode;
    java.md5Encode16 = java.crypto.md5Encode16;
    java.sha1Encode = java.crypto.sha1Encode;
    java.sha256Encode = java.crypto.sha256Encode;
    java.base64Encode = java.crypto.base64Encode;
    java.base64Decode = java.crypto.base64Decode;
    java.aesEncrypt = java.crypto.aesEncrypt;
    java.aesDecrypt = java.crypto.aesDecrypt;
    java.aesBase64DecodeToString = java.crypto.aesBase64DecodeToString;
    java.aesBase64EncodeToString = java.crypto.aesBase64EncodeToString;
    java.rc4Encrypt = java.crypto.rc4Encrypt;
    java.rc4Decrypt = java.crypto.rc4Decrypt;
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
    java.put = function(k, v){ __vars[k] = v == null ? '' : String(v); return v == null ? '' : String(v); };
    java.get = function(k){ return __getStr(k); };
    java.getString = function(k, d){ return __getStr(k, d); };
    java.ajax = function(url, options){ return ''; };
    java.connect = function(url, options){ return ''; };
    java.post = function(url, body, options){
      return { body: function(){ return ''; }, text: function(){ return ''; },
               html: function(){ return ''; }, bodyAsBytes: function(){ return ''; } };
    };
    java.http = function(){ return ''; };
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
    // org.jsoup：Jsoup.parse(html).select(css) 解析任意抓取的 HTML 片段。
    // 本地测试无 JS→Dart 查询桥，select 走守卫返回空 Elements（结构不抛错，属性为空）；
    // 生产 fjs 沙箱通过 bridge jsoup_query 在 Dart 端真实解析（见 legado_fjs_sandbox.dart）。
    var __jsoupQuery = function(html, css, mode){
      if (typeof __dart === 'function') return __dart('jsoup_query', String(html==null?'':html), String(css||''), mode||'all');
      return '';
    };
    var __hydrate = function(jsonStr){
      var list;
      try { list = JSON.parse(jsonStr || '[]'); } catch(e) { list = []; }
      if (!Array.isArray(list)) return [];
      function wrap(n){
        if (!n || typeof n !== 'object') return null;
        return {
          innerHTML: n.innerHTML || '', outerHTML: n.outerHTML || '',
          html: function(){ return n.innerHTML || ''; }, outerHtml: function(){ return n.outerHTML || ''; },
          text: n.text || '', textStr: n.text || '', ownText: n.ownText || '', data: n.text || '',
          className: (n.attrs && n.attrs['class']) || '', id: (n.attrs && n.attrs['id']) || '', tagName: n.tagName || '',
          attr: function(k){ return (n.attrs && n.attrs[k]) || ''; }, getAttribute: function(k){ return (n.attrs && n.attrs[k]) || ''; },
          children: Array.isArray(n.children) ? n.children.map(wrap) : [],
          parent: function(){ return null; }, parents: function(){ return []; }, remove: function(){ return []; }
        };
      }
      return list.map(wrap).filter(function(x){ return x != null; });
    };
    var __jsoupSelect = function(nodes){
      var a = nodes || [];
      a.attr = function(k){ return a.length ? (a[0].attr ? a[0].attr(k) : '') : ''; };
      a.text = function(){ return a.map(function(n){ return n.text || ''; }).join(' ').trim(); };
      a.textStr = function(){ return a.text(); };
      a.eachText = function(){ return a.map(function(n){ return n.text || ''; }); };
      a.eachAttr = function(k){ return a.map(function(n){ return n.attr ? n.attr(k) : ''; }); };
      a.html = function(){ return a.map(function(n){ return n.innerHTML || ''; }).join(''); };
      a.outerHtml = function(){ return a.map(function(n){ return n.outerHTML || ''; }).join(''); };
      a.size = function(){ return a.length; };
      a.first = function(){ return a.length ? [a[0]] : []; };
      a.last = function(){ return a.length ? [a[a.length - 1]] : []; };
      a.get = function(i){ return i == null ? a : (a[i] || null); };
      a.eq = function(i){ var n = a[i]; return n ? [n] : []; };
      a.remove = function(){ return a; };
      a.addClass = function(){ return a; };
      return a;
    };
    org = {
      jsoup: {
        Jsoup: {
          parse: function(html){
            var h = String(html == null ? '' : html);
            return {
              select: function(css){
                if (typeof __dart === 'function') return __jsoupSelect(__hydrate(__jsoupQuery(h, css, 'all')));
                return __jsoupSelect(__jsoupLocal(h, String(css || '')));
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
    // 本地无 JS→Dart 查询桥时的回退：仅支持「tag[attr=value]」这种简单属性选择器，
    // 从 HTML 里抓取匹配元素（如 input[name=_token] 取 CSRF token）。返回节点数组。
  ''' +
      _jsoupLocalCode;

  /// __jsoupLocal 的 JS 源码（raw 字符串，避免 `\$`/`\\s` 被 Dart 字符串转义）。
  static const String _jsoupLocalCode = r'''
    var __jsoupLocal = function(html, css){
      var m = String(css).match(/^\s*([a-zA-Z][a-zA-Z0-9]*)\[([a-zA-Z0-9_-]+)=([^\]]+)\]\s*$/);
      if (!m) return [];
      var tag = m[1], attr = m[2], val = m[3].replace(/^["']|["']$/g, '');
      var esc = function(s){ return s.replace(/([.*+?^${}()|[\]\\])/g, '\\$1'); };
      var re = new RegExp('<' + esc(tag) + '\\b[^>]*\\b' + esc(attr) + '\\s*=\\s*["\']' + esc(val) + '["\']', 'i');
      var f = html.match(re);
      if (!f) return [];
      var attrs = {};
      var am = RegExp('([a-zA-Z][a-zA-Z0-9:_-]*)\\s*=\\s*["\']([^"\']*)["\']', 'g');
      var t;
      while ((t = am.exec(f[0])) !== null) { attrs[t[1]] = t[2]; }
      return [{
        innerHTML: f[0], outerHTML: f[0], text: '', ownText: '',
        attrs: attrs, tagName: tag.toUpperCase(), children: []
      }];
    };
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
    final code = transpileTemplateLiterals(_stripJsTag(rawCode));
    if (code.trim().isEmpty) return '';

    // 先算暂定 result（左侧提取结果，否则取当前文档 HTML/JSON 文本），供动态
    // java.ajax(expr) 的第一参数求值使用（expr 常为 JSON.parse(result).data.xxx）。
    final provisional = (extraGlobals['result'] is String &&
            (extraGlobals['result'] as String).isNotEmpty)
        ? extraGlobals['result'] as String
        : (docHtml ?? '');

    // java.ajax / java.connect 预处理：把字面量调用先取回响应再给 JS（见
    // [legado_ajax_rewrite.rewriteAjaxCalls]，生产/测试沙箱共用）。动态第一参数
    // 通过 [_ajaxArgResolver] 在独立小上下文里先求值出 URL。
    final rewritten = await rewriteAjaxCalls(
      code,
      baseUri: baseUri,
      fetcher: _ajaxFetcher,
      evalArg: (expr) async => _ajaxArgResolver(expr, provisional, _vars, baseUri),
    );

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
          var __v = eval(${jsonEncode(rewritten)});
          if (__v !== undefined && __v !== null) {
            // 完成值为数组/对象时按 JSON 序列化，避免 String(__v) 退化成
            // "[object Object]..." 堆叠串（如中文书城 chapterList 以 `.map(...)
            // 对象数组` 结尾）；标量走 String()。
            __completion = (Object.prototype.toString.call(__v) === '[object Array]' || (typeof __v === 'object' && __v !== null))
                ? JSON.stringify(__v)
                : String(__v);
          }
        } catch(e) { __error = String(e); }
        return JSON.stringify({ result: finalResult || __completion || result, vars: __vars, error: __error });
      })()
    ''';
    final r = _runtime.evaluate(wrapped);
    debugLastWrapped = wrapped.toString();
    debugLastRewritten = rewritten.toString();
    if (r.isError) {
      debugCompileFailed = true;
      lastError = r.stringResult;
      return '';
    }
    debugCompileFailed = false;
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

  /// 动态 [java.ajax] 第一参数求值：在独立小上下文（注入暂定 result / baseUrl /
  /// __vars）里求值表达式（如 `JSON.parse(result).data.chapter_list_link`），
  /// 返回 URL 字符串；失败或为空返回 null。
  String? _ajaxArgResolver(
    String expr,
    String provisionalResult,
    Map<String, String> vars,
    Uri? baseUri,
  ) {
    if (!_inited) return null;
    final wrapper = '''
      (function(){
        var __vars = ${jsonEncode(vars)};
        var __baseUrl = ${jsonEncode(baseUri?.toString() ?? '')};
        var baseUrl = __baseUrl;
        var result = ${jsonEncode(provisionalResult)};
        // 群搜/果文等源在 ajax 第一参数用 source.getKey()/source.getString(...)：
        // 计算动态 URL 时需要它们能被求值，故补最小桩。
        var source = {
          getKey: function(){ return __baseUrl; },
          setKey: function(u){ return u == null ? '' : String(u); },
          get: function(k){ return __vars[k] || ''; },
          getString: function(k, d){ var s = __vars[k]; return (s === undefined || s === null || s === '') ? (d == null ? '' : String(d)) : String(s); },
          put: function(k, v){ __vars[k] = v == null ? '' : String(v); return v == null ? '' : String(v); }
        };
        var java = {
          get: function(k){ return __vars[k] || ''; },
          getString: function(k, d){ var s = __vars[k]; return (s === undefined || s === null || s === '') ? (d == null ? '' : String(d)) : String(s); },
          put: function(k, v){ __vars[k] = v == null ? '' : String(v); return v == null ? '' : String(v); }
        };
        var __v;
        try { __v = eval(${jsonEncode(expr)}); }
        catch(e) { return JSON.stringify({o: null}); }
        return JSON.stringify({o: (__v === undefined || __v === null) ? '' : String(__v)});
      })()
    ''';
    final r = _runtime.evaluate(wrapper);
    if (r.isError) return null;
    try {
      final d = jsonDecode(r.stringResult) as Map;
      final v = d['o'];
      return (v is String && v.isNotEmpty) ? v : null;
    } catch (_) {
      return null;
    }
  }

  static String _literal(Object? value) {
    if (value == null) return 'null';
    if (value is bool || value is num) return '$value';
    return jsonEncode('$value');
  }
}
