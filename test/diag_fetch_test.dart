// 抓取并打印目标页面 HTML，用于校正书源选择器/规则。
// 用法：flutter test test/diag_fetch_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:gbk_codec/gbk_codec.dart';

final _ua =
    'Mozilla/5.0 (Linux; Android 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Mobile Safari/537.36';

String _decode(List<int> bytes) {
  final u = utf8.decode(bytes, allowMalformed: true);
  if (!u.contains('\uFFFD')) return u;
  try {
    return gbk.decode(bytes);
  } catch (_) {
    return u;
  }
}

Future<String> fetch(String url) async {
  final c = HttpClient();
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, _ua);
  final resp = await req.close();
  final bytes = await resp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
  final status = resp.statusCode;
  c.close();
  final text = _decode(bytes);
  print('==== URL=$url status=$status len=${text.length} ====');
  return text;
}

Future<String> fetchHead(String url) async {
  final c = HttpClient();
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, _ua);
  final resp = await req.close();
  final bytes = await resp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
  final status = resp.statusCode;
  c.close();
  final text = _decode(bytes);
  print('==== URL=$url status=$status len=${text.length} ====');
  return text.length > 1500 ? text.substring(0, 1500) : text;
}

void dumpRules(RegisteredBookSource? s) {
  if (s == null) {
    print('  (源未找到)');
    return;
  }
  final cfg = s.sourceConfig ?? const {};
  for (final key in const ['ruleToc', 'ruleContent', 'ruleBookInfo', 'ruleExplore']) {
    final v = cfg[key];
    print('  $key=${v is String ? v : jsonEncode(v)}');
  }
}

Future<void> main() async {
  final jsonPath = Platform.environment['VERIFY_BOOK_SOURCES_JSON'] ?? 'D:/gz/完美书源.json';
  final raw = File(jsonPath).readAsStringSync();
  final decoded = jsonDecode(raw);
  final list = decoded is List
      ? decoded.cast<Map<String, dynamic>>()
      : (decoded['bookSourceList'] as List).cast<Map<String, dynamic>>();
  RegisteredBookSource? find(String needle) {
    for (final m in list) {
      try {
        final s = LegadoBookSource.fromJson(m).toRegisteredSource();
        final name = s.name
            .replaceFirst(RegExp(r'^[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\s]+', unicode: true), '');
        if (name.contains(needle)) return s;
      } catch (_) {}
    }
    return null;
  }

  print('\n########## 群小说网 chapter');
  final qx = await fetch('http://www.qunxs.com/txt/29769/15567356.html');
  print('--- CHUNK (群小说网) ---\n$qx\n--- END CHUNK (群小说网) ---');

  print('\n########## 小说三千 chapter 两段式(cookie)');
  final c2 = HttpClient();
  var cookie = '';
  try {
    final pr = await c2.postUrl(Uri.parse('http://www.xs3000.com/index/read_cookie'));
    pr.headers.set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded');
    pr.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    pr.headers.set('Referer', 'http://www.xs3000.com/index/read/id/6249250.html');
    pr.add(utf8.encode('id=6249250'));
    final pResp = await pr.close();
    final sc = pResp.headers[HttpHeaders.setCookieHeader] ?? const [];
    final parts = <String>[];
    for (final v in sc) { final eq = v.indexOf('='); final semi = v.indexOf(';'); if (eq > 0) { var name = v.substring(0, eq); var val = semi > eq ? v.substring(eq + 1, semi) : v.substring(eq + 1); parts.add('$name=$val'); } }
    cookie = parts.join('; ');
    await pResp.drain();
    // ignore: avoid_print
    print('cookie POST status=${pResp.statusCode} setCookie=$sc');
  } catch (e) {
    // ignore: avoid_print
    print('cookie POST ERR $e');
  }
  final gr = await c2.getUrl(Uri.parse('http://www.xs3000.com/index/read/id/6249250.html'));
  gr.headers.set('User-Agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
  gr.headers.set('Referer', 'http://www.xs3000.com/index/chapter/id/1794.html');
  gr.headers.set('X-Requested-With', 'XMLHttpRequest');
  if (cookie.isNotEmpty) gr.headers.set('Cookie', cookie);
  final gResp = await gr.close();
  final gb = await gResp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
  c2.close();
  final gt = _decode(gb);
  // ignore: avoid_print
  print('==== cookie GET status=${gResp.statusCode} len=${gt.length} ====');
  final m = RegExp(r'<div class="read-content">([\s\S]*?)</div>').firstMatch(gt);
  // ignore: avoid_print
  print(m == null ? '(read-content 缺失)' : ('read-content 内容: ${m.group(1)?.trim().length ?? 0} 字'));

  // 无 .html 的移动端点
  final c3 = HttpClient();
  final mr = await c3.getUrl(Uri.parse('http://www.xs3000.com/index/read/id/6249250'));
  mr.headers.set('User-Agent',
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36');
  mr.headers.set('Referer', 'http://www.xs3000.com/index/chapter/id/1794.html');
  final mResp = await mr.close();
  final mbytes = await mResp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
  c3.close();
  final mt = _decode(mbytes);
  // ignore: avoid_print
  print('==== mobile GET status=${mResp.statusCode} len=${mt.length} ====');
  final mm = RegExp(r'read-content">([\s\S]*?)</div>').firstMatch(mt);
  // ignore: avoid_print
  print(mm == null ? '(mobile read-content 缺失)' : ('mobile read-content 内容: ${mm.group(1)?.trim().length ?? 0} 字'));
  // 移动端正文容器探测
  for (final cls in ['nr1', 'chapter', 'content', 'read-content', 'booktxt', 'cont', 'text']) {
    final hits = RegExp('<div[^>]*class="[^"]*$cls[^"]*"[^>]*>', caseSensitive: false).allMatches(mt).length;
    // ignore: avoid_print
    print('  [mobile] 容器 class=$cls 出现 $hits 次');
  }
  final bodyP = RegExp(r'<p>[\s\S]{0,30}').allMatches(mt).length;
  // ignore: avoid_print
  print('  [mobile] <p> 标签数=$bodyP');
  final ci = mt.indexOf('read-content');
  // ignore: avoid_print
  print('  [mobile] read-content 附近: ${ci >= 0 ? mt.substring(ci, (ci + 400).clamp(0, mt.length)) : "N/A"}');

  // 群小说网 第2页 URL 验证
  print('\n########## 群小说网 分页 _2.html');
  final q2 = await fetch('http://www.qunxs.com/txt/29769/15567356_2.html');
  // ignore: avoid_print
  print('--- CHUNK (群小说网第2页 head) ---\n${q2.length > 3000 ? q2.substring(0, 3000) : q2}\n--- END ---');

  // 小说三千 xszj.min.js 源码（浏览器 UA）
  print('\n########## 小说三千 xszj.min.js');
  final c4 = HttpClient();
  final jr = await c4.getUrl(Uri.parse('http://www.xs3000.com/Public/js/xszj.min.js'));
  jr.headers.set('User-Agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
  jr.headers.set('Referer', 'http://www.xs3000.com/index/read/id/6249250.html');
  final jResp = await jr.close();
  final jb = await jResp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
  c4.close();
  final jt = _decode(jb);
  // ignore: avoid_print
  print('==== xszj.min.js status=${jResp.statusCode} len=${jt.length} ====');
  // 提取 /index/ 相关端点
  final urls = RegExp(r'/index/[a-z_]+').allMatches(jt).map((m) => m.group(0)!).toSet().toList();
  // ignore: avoid_print
  print('  [xszj] index 端点: $urls');
  final aj = RegExp(r"url:\s*[^,}]{3,80}").allMatches(jt).map((m) => m.group(0)!.trim()).toSet().toList();
  // ignore: avoid_print
  print('  [xszj] ajax url 片段: ${aj.take(12).toList()}');
  // ignore: avoid_print
  print('  [xszj] 含 read_cookie 次数: ${'read_cookie'.allMatches(jt).length}');

  // 小说三千 完整流程：目录页(设cookie) → 正文页
  print('\n########## 小说三千 完整流程');
  final c5 = HttpClient();
  var jar5 = <String, String>{};
  Future<String> get5(String url, String referer) async {
    final req = await c5.getUrl(Uri.parse(url));
    req.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    if (referer.isNotEmpty) req.headers.set('Referer', referer);
    if (jar5.isNotEmpty) req.headers.set('Cookie', jar5.values.join('; '));
    final resp = await req.close();
    final sc = resp.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    for (final v in sc) {
      final eq = v.indexOf('='); final semi = v.indexOf(';');
      if (eq > 0) {
        final name = v.substring(0, eq);
        final val = semi > eq ? v.substring(eq + 1, semi) : v.substring(eq + 1);
        jar5[name] = '$name=$val';
      }
    }
    final bytes = await resp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    // ignore: avoid_print
    print('  [flow] GET $url -> ${resp.statusCode} len=${bytes.length}');
    return _decode(bytes);
  }
  try {
    await get5('http://www.xs3000.com/index/chapter/id/1794.html', 'http://www.xs3000.com/index/book/id/1794.html');
    final body = await get5('http://www.xs3000.com/index/read/id/6249250.html', 'http://www.xs3000.com/index/chapter/id/1794.html');
    final m5 = RegExp(r'read-content">([\s\S]*?)</div>').firstMatch(body);
    // ignore: avoid_print
    print('  [flow] read-content 内容: ${m5 == null ? '缺失' : '${m5.group(1)?.trim().length ?? 0} 字'}');
    // ignore: avoid_print
    print('  [flow] <p> 标签数: ${RegExp(r'<p>').allMatches(body).length}');
    // ignore: avoid_print
    print('  [flow] 含正文关键字: ${RegExp('重返十八岁|第1章|chapter').hasMatch(body)}');
    final ci5 = body.indexOf('read-content');
    // ignore: avoid_print
    print('  [flow] read-content 附近: ${ci5 >= 0 ? body.substring(ci5, (ci5 + 300).clamp(0, body.length)) : 'N/A'}');
  } finally {
    c5.close();
  }
}

final gbk = _Gbk();
class _Gbk {
  String encode(String s) {
    final bytes = gbk_bytes.encode(s);
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write('%');
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }

  String decode(List<int> bytes) {
    // 简易 GBK 解码：双字节高位映射到 GB2312 区间（够看结构即可）
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i] & 0xFF;
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
      } else if (i + 1 < bytes.length) {
        sb.write('\uFFFD');
        i += 2;
      } else {
        i++;
      }
    }
    return sb.toString();
  }
}