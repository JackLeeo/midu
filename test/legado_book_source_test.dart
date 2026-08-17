import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';

Map<String, dynamic> _source({
  String name = 'Declarative source',
  String url = 'https://books.example',
  int type = 0,
  bool cookies = false,
  String contentRule = '#content@text',
}) => {
  'bookSourceName': name,
  'bookSourceUrl': url,
  'bookSourceType': type,
  'enabledCookieJar': cookies,
  'searchUrl': '/search?q={{key}}',
  'ruleSearch': {'bookList': '.book', 'bookUrl': 'a@href', 'name': 'a@text'},
  'ruleBookInfo': {'name': 'h1@text'},
  'ruleToc': {
    'chapterList': '.chapters a',
    'chapterName': 'text',
    'chapterUrl': 'href',
  },
  'ruleContent': {'content': contentRule},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('parses object, list, wrappers, BOM, and isolates bad items', () {
    final object = parseLegadoSources(jsonEncode(_source()));
    expect(object.sources, hasLength(1));

    final list = parseLegadoSources(
      '\ufeff${jsonEncode([
        _source(),
        {'bookSourceName': 'Broken'},
        'not-an-object',
      ])}',
    );
    expect(list.sources, hasLength(1));
    expect(list.errors, hasLength(2));

    final wrapper = parseLegadoSources(
      jsonEncode({
        'sources': [_source(name: 'Wrapped')],
      }),
    );
    expect(wrapper.sources.single.name, 'Wrapped');
  });

  test('deduplicates by source URL and accepts nested URL bundles', () {
    final parsed = parseLegadoSources(
      jsonEncode([_source(name: 'Old'), _source(name: 'New')]),
    );
    expect(parsed.sources.single.name, 'New');

    final nested = parseLegadoSources(
      jsonEncode({
        'sourceUrls': [
          'https://example.org/a.json',
          'https://example.org/b.json',
        ],
      }),
    );
    expect(nested.sourceUrls, hasLength(2));
  });

  test('preflight distinguishes runnable, partial, and blocked sources', () {
    const scanner = LegadoCompatibilityScanner();
    final supported = scanner.scan(LegadoBookSource.fromJson(_source()));
    expect(supported.level, LegadoCompatibilityLevel.supported);

    // 图片/漫画源：可以搜索与进入详情，但正文为图片链（阅读体验由上层处理）
    final image = scanner.scan(
      LegadoBookSource.fromJson(_source(type: 2, name: 'Images')),
    );
    expect(image.level, LegadoCompatibilityLevel.partial);
    expect(image.canRun, isTrue);

    // audio/video 类源不可作为文本书源运行
    for (final raw in [
      _source(type: 1, name: 'Audio'),
      _source(type: 4, name: 'Video'),
    ]) {
      expect(
        scanner.scan(LegadoBookSource.fromJson(raw)).level,
        LegadoCompatibilityLevel.unsupported,
      );
    }

    // 缺少搜索或阅读规则 → unsupported
    final noSearch = LegadoBookSource.fromJson(
      _source()..['searchUrl'] = '',
    );
    expect(
      scanner.scan(noSearch).level,
      LegadoCompatibilityLevel.unsupported,
    );

    // cookie 与 JS 规则通过 cookie jar / fjs 沙箱可运行 → partial 且 canRun
    for (final raw in [
      _source(cookies: true, name: 'Cookies'),
      _source(contentRule: '@js:result', name: 'Script'),
    ]) {
      final report = scanner.scan(LegadoBookSource.fromJson(raw));
      expect(report.level, LegadoCompatibilityLevel.partial);
      expect(report.canRun, isTrue);
    }
  });

  test('metadata comments do not get interpreted as executable rules', () {
    final source = LegadoBookSource.fromJson({
      ..._source(),
      'bookSourceComment':
          '// Error: failed to connect to an old mirror during testing',
    });

    expect(const LegadoCompatibilityScanner().scan(source).canRun, isTrue);
  });

  test('malformed serialized rules are unsupported instead of crashing', () {
    final raw = _source();
    raw['ruleToc'] = '{not-json';
    final source = LegadoBookSource.fromJson(raw);

    expect(source.rule('ruleToc'), isEmpty);
    expect(
      const LegadoCompatibilityScanner().scan(source).level,
      LegadoCompatibilityLevel.unsupported,
    );
  });

  test('registered compatible source round-trips with config', () {
    final registered = LegadoBookSource.fromJson(
      _source(),
    ).toRegisteredSource();
    final restored = RegisteredBookSource.fromJson(registered.toJson());

    expect(restored.sourceProtocol, BookSourceProtocolKind.legado);
    expect(restored.sourceConfig?['bookSourceName'], 'Declarative source');
    expect(restored.enabled, isFalse);
  });

  test(
    'registry exposes compatible imports without live verification',
    () async {
      final source = LegadoBookSource.fromJson(_source()).toRegisteredSource();
      SharedPreferences.setMockInitialValues({
        'open_reading_book_sources_v1': jsonEncode([source.toJson()]),
      });

      // 兼容性扫描通过（capabilities 非空）的 Legado 源直接可见，无需网络验证
      final loaded = await BookSourceRegistry().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, source.id);
    },
  );

  test(
    'imported Legado source runs without extra toggle',
    () async {
      final registry = BookSourceRegistry();
      final original = LegadoBookSource.fromJson(
        _source(),
      ).toRegisteredSource(enabled: true);
      await registry.upsertAll([original]);
      await registry.setEnabled(original.id, true);

      final updated = LegadoBookSource.fromJson(
        _source(name: 'Updated'),
      ).toRegisteredSource(enabled: true);
      final saved = await registry.upsertAll([updated]);
      expect(saved.single.name, 'Updated');
      expect(saved.single.enabled, isTrue);
      // 兼容性扫描通过的源无需 additionalSourceProtocols 开关即可运行
      expect(await registry.loadRunnable(), hasLength(1));
    },
  );
}
