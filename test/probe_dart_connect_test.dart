// 定位 Dart 传输层对 curl 可达主机的真实连接错误（对比 curl 的 200/301/403）。
// 运行: flutter test test/probe_dart_connect_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_request.dart';
import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart transport connect to reachable hosts', () async {
    HttpOverrides.global = null;
    final file = File(r'D:\gz\完美书源.已修复.json');
    final decoded = jsonDecode(file.readAsStringSync());
    final list = (decoded is List) ? decoded : (decoded as Map)['sources'] as List;
    final targets = <String>[]; // 名称子串
    for (final t in ['品如漫画', '磅磅', '四零二零', '图书迷网', '虫虫书屋', '一米小说']) {
      targets.add(t);
    }
    final names = list
        .where((s) => targets.any((t) => '${(s as Map)['bookSourceName']}'.contains(t)))
        .map((s) => (s as Map))
        .toList();
    for (final m in names) {
      final transport = LegadoHttpTransport(requestTimeout: const Duration(seconds: 30));
      final root = '${m['bookSourceUrl']}';
      final hosts = root.split('##').first.trim();
      final urls = [hosts, '$hosts/search'];
      for (final u in urls) {
        final sw = Stopwatch()..start();
        try {
          final resp = await transport.send(LegadoRequestTemplate(
            url: Uri.parse(u),
            method: LegadoRequestMethod.get,
            headers: const {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'},
            charset: 'utf-8',
          ));
          print('${m['bookSourceName']} :: GET $u -> ${resp.body.length}B in ${sw.elapsedMilliseconds}ms');
        } catch (e) {
          print('${m['bookSourceName']} :: GET $u -> ERR(${sw.elapsedMilliseconds}ms) ${e.runtimeType}: $e');
        }
      }
      transport.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}