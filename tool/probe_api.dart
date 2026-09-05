// 探测 猫眼看书 api.jxgtzxc.com 章节接口的鉴权需求。
// 用法: D:\flutter\bin\cache\dart-sdk\bin\dart.exe tool/probe_api.dart
import 'dart:convert';
import 'dart:io';

Future<String> _get(String url, {Map<String, String> headers = const {}}) async {
  final c = HttpClient();
  c.connectionTimeout = const Duration(seconds: 12);
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36');
  headers.forEach((k, v) => req.headers.set(k, v));
  final res = await req.close();
  final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
  c.close(force: true);
  return utf8.decode(bytes, allowMalformed: true);
}

Future<void> main() async {
  const base = 'http://api.jxgtzxc.com/novel/zbqYrb/chapters';
  const qs = {
    'device': '1', 'version': '1.0', 'brand': 'xiaomi', 'source': 'app',
    'client_name': 'legado', 'clientName': 'legado', 'channel': '1',
  };
  final q = qs.entries.map((e) => '${e.key}=${e.value}').join('&');
  print('== plain ==');
  try {
    print(_get(base).toString());
  } catch (e) { print('ERR $e'); }

  const headerSets = <String, Map<String, String>>{
    // header 大小写组合尝试
    'lower-h': {'device': '1', 'version': '1.0', 'brand': 'xiaomi', 'source': 'app', 'client-name': 'legado'},
    'camel': {'Device': '1', 'Version': '1.0', 'Brand': 'xiaomi', 'Source': 'app', 'Client-Name': 'legado'},
    'snake': {'device': '1', 'version': '1.0', 'brand': 'xiaomi', 'source': 'app', 'client_name': 'legado'},
    'common-app': {'device': 'Android', 'version': '2.5.4', 'brand': 'xiaomi', 'source': 'qidian', 'client_name': 'qidian_app'},
    'sn': {'sn': '1', 'deviceid': 'abc123', 'clientname': 'legado', 'client': 'legado'},
  };

  for (final entry in headerSets.entries) {
    print('\n== header: ${entry.key} ==');
    try {
      final r = await _get(base, headers: entry.value);
      final truncated = r.length > 300 ? r.substring(0, 300) : r;
      print(truncated.contains('4004') ? '4004:'+truncated : 'OK:<... '+truncated.substring(0, 200));
    } catch (e) { print('ERR $e'); }
  }

  // POST JSON body 携带鉴权字段
  print('\n== POST body ==');
  try {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 12);
    final req = await c.postUrl(Uri.parse(base));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set('client-name', 'legado');
    req.write(jsonEncode({
      'device': 'Android', 'version': '2.5.4', 'brand': 'xiaomi',
      'source': 'qidian', 'clientName': 'legado', 'client_name': 'legado',
      'novelId': 'zbqYrb',
    }));
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    c.close(force: true);
    final r = utf8.decode(bytes, allowMalformed: true);
    print(r.substring(0, r.length > 400 ? 400 : r.length));
  } catch (e) { print('ERR $e'); }
}