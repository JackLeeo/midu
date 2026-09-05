// 直连探测 searchEmpty 源：抓取 searchUrl 返回的原始响应，并核对 ruleSearch 的 bookList
// 能否命中。用于定位「搜索成功但解析为空」的真实原因。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  test('probe searchEmpty sources', () async {
    final dio = Dio();
    final headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };

    Future<void> probe(String name, String url, bool post,
        [Map<String, String>? postBody]) async {
      try {
        final op = Options(
          headers: headers,
          method: post ? 'POST' : 'GET',
          responseType: ResponseType.bytes,
        );
        late Response<List<int>> r;
        if (post) {
          r = await dio.request<List<int>>(
            url,
            options: op,
            data: postBody,
          );
        } else {
          r = await dio.get<List<int>>(url, options: op);
        }
        final bytes = r.data!;
        // 尝试 utf8 与 gbk
        var body = utf8.decode(bytes, allowMalformed: true);
        final status = r.statusCode;
        final ct = r.headers.value('content-type') ?? '';
        // 用 html 解析抓 bookList 候选
        final doc = html_parser.parse(body);
        var notes = <String>[];
        if (name == '五六中文' || name == '小说三千') {
          final lis = doc.querySelectorAll('li').length;
          final imgs = doc.querySelectorAll('img[src]').length;
          final tt = doc.querySelector('title')?.text ?? '';
          notes.add('li=$lis img=$imgs title=$tt');
        }
        print('==== $name | $status | ${ct.split(';').first} | bodyLen=${bytes.length}');
        print('  body前400: ${body.replaceAll(RegExp(r'\s+'), ' ').substring(0, (body.length < 400 ? body.length : 400))}');
        print('  $notes');
      } catch (e) {
        print('==== $name ERROR: $e');
      }
    }

    await probe(
        '五六中文',
        'https://www.56zw.com/modules/article/search.php?searchkey=%C3%C8%B1%A6&searchtype=articlename&page=1',
        false);
    await probe('得间',
        'https://www.idejian.com/search?keyword=%E7%9F%B3%E6%A6%B4%E8%8A%B1&page=1', false);
    await probe(
        '花生',
        'https://api.wan123x.com/search/getLike?keyword=%E8%90%8C%E5%AE%9D',
        false);
    // 群搜首页：检查 _token
    try {
      final r = await dio.get<List<int>>('http://www.qunxs.com/',
          options: Options(headers: headers, responseType: ResponseType.bytes));
      var body = utf8.decode(r.data!, allowMalformed: true);
      final idx = body.indexOf('_token');
      String? tok;
      final vm = RegExp(r'value="([^"]+)"').allMatches(body);
      print('==== 群搜 首页 len=${body.length} 含_token?=${idx >= 0}');
      // 打印包含 _token 的那一段
      if (idx >= 0) {
        print('  _token 上下文: ${body.substring(idx, (idx + 120 < body.length ? idx + 120 : body.length))}');
      }
      print('  全部 value 集合(前3): ${vm.take(3).map((m) => m.group(1)).toList()}');
    } catch (e) {
      print('==== 群搜 首页 ERROR: $e');
    }
  });
}