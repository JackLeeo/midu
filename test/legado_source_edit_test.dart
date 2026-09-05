// M1 对标 Legado：书源字段扩展 + 规则分片（RulePart）+ 编辑保存往返。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_rule_part.dart';
import 'package:midu/book_sources/services/book_source_registry.dart';

/// 一个最小可用的 Legado 书源 JSON。
Map<String, dynamic> _makeRaw({Map<String, dynamic>? extra}) {
  return {
    'bookSourceUrl': 'https://example.com',
    'bookSourceName': '测试源',
    'bookSourceGroup': '默认',
    'bookSourceComment': '注释',
    'searchUrl':
        'https://example.com/search?q={{key}}&page={{page}}',
    'ruleSearch': {
      'bookList': '.book-list li',
      'name': 'h3@text',
      'bookUrl': 'a@href',
    },
    'ruleToc': {
      'chapterList': '.chapter li',
      'name': 'a@text',
      'url': 'a@href',
    },
    'ruleContent': {'content': '#content@text'},
    ...?extra,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  group('LegadoBookSource 扩展字段', () {
    test('weight / concurrentRate / jsLib / header 读取', () {
      final source = LegadoBookSource.fromJson(
        _makeRaw(extra: {
          'weight': 100,
          'concurrentRate': 3,
          'jsLib': 'function foo(){ return 1; }',
          'header': {'User-Agent': 'TestUA'},
        }),
      );
      expect(source.weight, 100);
      expect(source.concurrentRate, 3);
      expect(source.jsLib, contains('foo'));
      expect(source.header['User-Agent'], 'TestUA');
    });

    test('缺省字段返回安全默认值', () {
      final source = LegadoBookSource.fromJson(_makeRaw());
      expect(source.weight, 0);
      expect(source.concurrentRate, 1);
      expect(source.jsLib, '');
      expect(source.header, isEmpty);
      expect(source.loginUrl, '');
      expect(source.think, '');
      expect(source.ruleRss, '');
    });

    test('header 支持字符串 JSON 形态', () {
      final source = LegadoBookSource.fromJson(
        _makeRaw(extra: {'header': '{"X-A":"1"}'}),
      );
      expect(source.header['X-A'], '1');
    });

    test('ruleRss 支持 Map / String / 空三种形态', () {
      final fromMap = LegadoBookSource.fromJson(
        _makeRaw(extra: {'ruleRss': {'rssUrl': 'https://x/feed', 'name': 'a@text'}}),
      );
      expect(fromMap.ruleRss, contains('rssUrl=https://x/feed'));
      final fromString = LegadoBookSource.fromJson(
        _makeRaw(extra: {'ruleRss': 'https://x/feed'}),
      );
      expect(fromString.ruleRss, 'https://x/feed');
    });

    test('toJson 保留全部原始字段', () {
      final raw = _makeRaw(extra: {'weight': 5});
      final source = LegadoBookSource.fromJson(raw);
      expect(source.toJson()['bookSourceUrl'], 'https://example.com');
      expect(source.toJson()['weight'], 5);
    });

    test('copyWithRaw 重新校验并保留扩展字段', () {
      final source = LegadoBookSource.fromJson(_makeRaw());
      final next = source.copyWithRaw(_makeRaw(extra: {'bookSourceName': '改名'}));
      expect(next.name, '改名');
      expect(next.url, 'https://example.com');
    });
  });

  group('LegadoRulePart 规则分片往返', () {
    test('@js:/@put:/@get:/@xpath: 分片无损重组', () {
      const rule = r'@put:{gid:$.data.gid}&&@js:var r = 1; r + baseUrl';
      final parts = splitLegadoRule(rule);
      expect(parts, hasLength(2));
      expect(parts[0].type, 'put');
      expect(parts[1].type, 'js');
      final joined = joinLegadoRule(parts);
      expect(joined, rule);
    });

    test('普通选择器 + @xpath: 混用', () {
      const rule = '@xpath://li[contains(text(),"甲")]@text';
      final parts = splitLegadoRule(rule);
      expect(parts.single.type, 'xpath');
      expect(joinLegadoRule(parts), rule);
    });

    test('| 分隔的 || 保持分隔符', () {
      const rule = 'a@href||@js:location.href';
      final parts = splitLegadoRule(rule);
      expect(parts, hasLength(2));
      expect(parts[1].separator, '||');
      expect(joinLegadoRule(parts), rule);
    });

    test('正则 :rule 形态', () {
      const rule = ':((?:第|章).*)&&.replace("A","B")';
      final parts = splitLegadoRule(rule);
      // 正则段 type=regex；.replace() 属于文本段
      expect(parts.first.type, 'regex');
      expect(joinLegadoRule(parts), isNotEmpty);
    });
  });

  group('BookSourceRegistry.updateSourceConfig', () {
    test('保存后启用状态与配置更新', () async {
      final registry = BookSourceRegistry();
      final raw = _makeRaw();
      final source = LegadoBookSource.fromJson(raw).toRegisteredSource(
        enabled: true,
      );
      await registry.upsert(source);

      final nextRaw = _makeRaw(extra: {'bookSourceName': '改名源', 'weight': 7});
      final updated = await registry.updateSourceConfig(source, nextRaw);
      expect(updated, hasLength(1));
      expect(updated.single.name, '改名源');
      expect(updated.single.enabled, isTrue);
      expect((updated.single.sourceConfig?['weight']), 7);

      await registry.remove(updated.single.id);
    });

    test('不存在的源抛出异常', () async {
      final registry = BookSourceRegistry();
      final source = LegadoBookSource.fromJson(_makeRaw()).toRegisteredSource(
        enabled: true,
      );
      expect(
        () => registry.updateSourceConfig(source, _makeRaw()),
        throwsA(isA<Exception>()),
      );
    });
  });
}