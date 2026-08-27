import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/pages/book_sources/book_sources_page.dart';

void main() {
  test('all-source scope searches every enabled source', () {
    final sources = [
      _source('source-a', enabled: true),
      _source('source-b', enabled: false),
      _source('source-c', enabled: true),
    ];

    final targets = BookSourcesPage.searchTargets(sources, null);

    expect(targets.map((source) => source.id), ['source-a', 'source-c']);
  });

  test('single-source scope searches only the selected enabled source', () {
    final sources = [
      _source('source-a', enabled: true),
      _source('source-b', enabled: true),
    ];

    final targets = BookSourcesPage.searchTargets(sources, 'source-b');

    expect(targets.map((source) => source.id), ['source-b']);
  });

  test('single-source scope never searches a disabled source', () {
    final sources = [_source('source-a', enabled: false)];

    expect(BookSourcesPage.searchTargets(sources, 'source-a'), isEmpty);
  });

  test('mapConcurrent caps peak parallelism at the limit', () async {
    var active = 0;
    var peak = 0;
    final task = (_) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
    };

    await BookSourcesPage.mapConcurrent(
      List<int>.generate(10, (i) => i),
      3,
      task,
    );

    // 同一时刻最多 3 个任务并行；结果全部跑完。
    expect(peak, 3);
  });

  test('mapConcurrent runs every input exactly once and keeps order', () async {
    final results = await BookSourcesPage.mapConcurrent(
      List<int>.generate(10, (i) => i),
      4,
      (i) async {
        await Future<void>.delayed(Duration(milliseconds: (10 - i)));
        return i * 2;
      },
    );

    expect(results, List<int>.generate(10, (i) => i * 2));
  });

  test('mapConcurrent errorValue covers per-item failures', () async {
    final results = await BookSourcesPage.mapConcurrent(
      List<int>.generate(5, (i) => i),
      2,
      (i) async {
        if (i.isOdd) throw StateError('boom $i');
        return i;
      },
      errorValue: (i, _) => -1,
    );

    expect(results, [0, -1, 2, -1, 4]);
  });
}

RegisteredBookSource _source(String id, {required bool enabled}) {
  return RegisteredBookSource(
    id: id,
    name: id,
    description: '',
    manifestUrl: Uri.parse('https://example.org/$id/source.json'),
    apiBaseUrl: Uri.parse('https://example.org/$id/api/'),
    protocolVersion: '1.0',
    languages: const ['zh-CN'],
    capabilities: const {'search'},
    enabled: enabled,
    addedAt: DateTime.utc(2026, 7, 12),
  );
}
