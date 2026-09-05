// 探测 noChapters / 强JS 失败源的站点连通性：确认哪些国内可直连（决定可否在线修复）。
import 'dart:io';

import 'package:dio/dio.dart';

void main() async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 8),
    followRedirects: true,
    maxRedirects: 5,
  ));
  final hosts = {
    '猪猪书网(net)': 'http://www.zzs5.net',
    '猪猪书网(com)': 'http://www.zzs5.com',
    '猪猪小说(info)': 'http://www.zzs5.info/',
    '随心看网': 'https://m.suixkan.com',
    '久久小说': 'http://m.9191net.com',
    '免费小说(freexiaoshuo)': 'http://www.freexiaoshuo.com',
    '四零二零(wrlwx)': 'http://www.wrlwx.com',
    '四零二零(wrltxt)': 'http://www.wrltxt.com',
    '溜达(com)': 'http://www.liudatxt.com',
    '溜达(la)': 'http://m.liudatxt.la',
    '刺猬猫(wap)': 'https://wap.ciweimao.com',
    '刺猬猫(www)': 'http://www.ciweimao.com',
    '图书迷网': 'https://www.tushumi.cc',
    '虫虫书屋': 'http://www.0794r.com',
    '一米小说': 'http://m.yimixs.net',
    '猫眼看书': 'http://download.maoyankanshu.la',
  };
  for (final e in hosts.entries) {
    final tag = e.key.padRight(20);
    try {
      final r = await dio.get<dynamic>(e.value, options: Options(
        responseType: ResponseType.plain,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        },
      ));
      print('$tag => HTTP ${r.statusCode} len=${(r.data as String).length}');
    } catch (err) {
      if (err is DioException) {
        final t = err.type.name;
        final code = err.response?.statusCode;
        print('$tag => FAIL $t ${code == null ? '' : 'HTTP $code'}');
      } else {
        print('$tag => FAIL $err');
      }
    }
  }
}