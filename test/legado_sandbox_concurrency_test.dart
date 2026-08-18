// 验证 BookSourceClient 按源隔离 Legado runtime：
// 健康检测/聚合搜索 8 并发请求不同源时，各源使用独立 runtime，
// 不会共享 JS 引擎与 @put/@get 变量空间（此前共享单例导致解析失败）。
import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/legado/legado_runtime.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/services/book_source_client.dart';

RegisteredBookSource _source(String id, String host) {
  return RegisteredBookSource(
    id: id,
    name: id,
    description: '',
    manifestUrl: Uri.parse('https://$host'),
    apiBaseUrl: Uri.parse('https://$host'),
    protocolVersion: 'legado-3',
    languages: const [],
    capabilities: const {'search', 'detail', 'catalog', 'content'},
    enabled: true,
    addedAt: DateTime.utc(2026, 7, 1),
    sourceProtocol: BookSourceProtocolKind.legado,
    sourceConfig: {
      'bookSourceName': id,
      'bookSourceUrl': 'https://$host',
      'bookSourceType': 0,
      'searchUrl': '/search?q={{key}}',
      'ruleSearch': {
        'bookList': '.grid@tr!0',
        'name': 'a@text',
        'bookUrl': 'a@href',
      },
      'ruleBookInfo': {'name': 'h1@text'},
      'ruleToc': {'chapterList': '#list dd@a'},
      'ruleContent': {'content': 'id.content@textNodes'},
    },
  );
}

void main() {
  test('不同源使用独立 runtime，同一源复用同一 runtime', () {
    final client = BookSourceClient();
    try {
      final a = _source('legado.a', 'a.test');
      final b = _source('legado.b', 'b.test');
      final runtimeA1 = client.legadoRuntimeForSource(a);
      final runtimeA2 = client.legadoRuntimeForSource(a);
      final runtimeB = client.legadoRuntimeForSource(b);
      expect(identical(runtimeA1, runtimeA2), isTrue,
          reason: '同一源应复用同一 runtime');
      expect(identical(runtimeA1, runtimeB), isFalse,
          reason: '不同源必须隔离为独立 runtime');
    } finally {
      client.close();
    }
  });
}
