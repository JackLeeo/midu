// 临时诊断：统计《我师兄实在太稳健了》在真实网络下的聚合搜索响应源数。
// 复现用户报告「搜索源数从 80-96 骤降到 ~20」：直连 BookSourceAggregatedSearch
// 统计 respondedSourceCount / perSourceErrors / hits，判断是代码回归还是网络超时。
// 运行：flutter test test/probe_agg_search_count_test.dart -j 1
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/services/book_source_aggregated_search.dart';
import 'package:midu/book_sources/services/book_source_client.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  copyQuickJsDllIfNeeded();
  final rawPath = r'D:\gz\完美书源.已修复.json';
  test('aggregated search responded-source count', () async {
    HttpOverrides.global = null;
    final file = File(rawPath);
    final sources = parseLegadoSources(file.readAsStringSync())
        .sources
        .map((legado) => legado.toRegisteredSource())
        .toList();
    // ignore: avoid_print
    print('total sources = ${sources.length}');

    final search = BookSourceAggregatedSearch(BookSourceClient());
    final page = await search.search(
      sources,
      '我师兄实在太稳健了',
      perSourceTimeout: const Duration(seconds: 12),
    );
    // ignore: avoid_print
    print('RESULT sourceCount=${page.sourceCount} '
        'responded=${page.respondedSourceCount} '
        'hits=${page.hits.length} '
        'errors=${page.perSourceErrors.length}');
    // ignore: avoid_print
    print('hasMore=${page.hasMore}');
    // 统计错误类型分布
    final byKind = <String, int>{};
    for (final e in page.perSourceErrors.values) {
      final k = e.contains('timed out') || e.toLowerCase().contains('timeout')
          ? 'timeout'
          : e.startsWith('SocketException') || e.contains('Connection')
              ? 'connection'
              : 'other';
      byKind[k] = (byKind[k] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('error kinds: $byKind');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

void copyQuickJsDllIfNeeded() {}