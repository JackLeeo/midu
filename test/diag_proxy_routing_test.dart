// 诊断：flutter 测试进程里 dart:io 是否走 TUN/代理，能到达被墙域名。
// 枚举返回值：200=可达、非200=服务端返回、异常=网络层被拦截/未路由。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _targets = <String>[
  'https://ixdzs8.com/bsearch?q=test', // 爱下网书
  'https://www.56zw.com/modules/article/search.php?searchkey=test',
  'https://www.97k.cc', // 就去看
  'https://h5.reader.qq.com', // 企鹅读书
];

void main() {
  test('dart:io TUN 路由诊断', () async {
    for (final url in _targets) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close().timeout(const Duration(seconds: 12));
        // ignore: avoid_print
        print('$url => ${res.statusCode}');
        await res.drain<void>();
        client.close();
      } catch (e) {
        // ignore: avoid_print
        print('$url => ERROR $e');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}