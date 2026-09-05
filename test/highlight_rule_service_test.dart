// 高亮规则服务单元测试：模型往返 + CRUD + 自动高亮匹配引擎。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/services/highlight_rule_service.dart';

HighlightRule _rule({
  String id = 'h1',
  required String pattern,
  bool isRegex = true,
  bool applyToBody = true,
  bool applyToTitle = true,
  String styleHex = 'FFEB3B',
  bool enabled = true,
}) => HighlightRule(
  id: id,
  name: '规则',
  pattern: pattern,
  isRegex: isRegex,
  applyToBody: applyToBody,
  applyToTitle: applyToTitle,
  styleHex: styleHex,
  enabled: enabled,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HighlightRule 模型', () {
    test('toJson / fromJson 往返保留全部字段', () {
      final rule = HighlightRule(
        id: 'hx',
        name: '主角',
        pattern: '李\\w+',
        isRegex: false,
        styleHex: '4CAF50',
      );
      final restored = HighlightRule.fromJson(rule.toJson());
      expect(restored.id, 'hx');
      expect(restored.name, '主角');
      expect(restored.pattern, '李\\w+');
      expect(restored.styleHex, '4CAF50');
      expect(restored.isRegex, isFalse);
    });

    test('缺省字段返回安全默认值', () {
      final rule = HighlightRule.fromJson(const {'id': 'x'});
      expect(rule.name, '');
      expect(rule.pattern, '');
      expect(rule.applyToBody, isTrue);
      expect(rule.applyToTitle, isTrue);
      expect(rule.styleHex, 'FFEB3B');
      expect(rule.enabled, isTrue);
    });
  });

  group('matchAutoHighlightRanges 匹配引擎', () {
    const text = '林晚推开窗，林晚看到月光。';

    test('正则规则命中全部位置', () {
      final ranges = matchAutoHighlightRanges(
        text,
        [_rule(pattern: '林晚')],
      );
      expect(ranges, hasLength(2));
      expect(ranges!.first.start, 0);
      expect(ranges[0].end, 2);
      expect(ranges[1].start, text.indexOf('林晚', 2));
    });

    test('字面量规则命中全部位置', () {
      final ranges = matchAutoHighlightRanges(
        text,
        [_rule(pattern: '月光', isRegex: false)],
      );
      expect(ranges, hasLength(1));
      expect(ranges.single.styleHex, 'FFEB3B');
    });

    test('applyToBody=false 时正文不命中', () {
      final ranges = matchAutoHighlightRanges(
        text,
        [_rule(pattern: '林晚', applyToBody: false)],
      );
      expect(ranges, isEmpty);
    });

    test('非法正则静默跳过，不影响其他规则', () {
      final ranges = matchAutoHighlightRanges(
        text,
        [
          _rule(pattern: '[', id: 'bad'),
          _rule(pattern: '林晚'),
        ],
      );
      expect(ranges, isNotEmpty);
    });

    test('重叠区间合并为最大跨度', () {
      final ranges = matchAutoHighlightRanges(
        text,
        [
          _rule(pattern: '林晚', styleHex: 'FFEB3B'),
          _rule(pattern: '晚推'),
        ],
      );
      // 0..2 与 1..3 合并为 0..3；第二处「林晚」6..8 独立保留。
      expect(ranges, hasLength(2));
      expect(ranges[0].start, 0);
      expect(ranges[0].end, 3);
      expect(ranges[0].styleHex, 'FFEB3B');
      expect(ranges[1].start, text.indexOf('林晚', 2));
    });

    test('标题命中映射回正文偏移', () {
      final body = '第一章 林晚\n正文内容';
      final ranges = matchAutoHighlightRanges(
        body,
        [_rule(pattern: '林晚', applyToBody: false, applyToTitle: true)],
        title: '林晚',
        titleOffsetInText: body.indexOf('林晚'),
      );
      expect(ranges.single.start, 4);
      expect(ranges.single.end, 6);
    });

    test('禁用规则不参与匹配', () {
      final ranges = matchAutoHighlightRanges(
        text,
        [_rule(pattern: '林晚', enabled: false)],
      );
      expect(ranges, isEmpty);
    });
  });

  group('HighlightRuleService CRUD', () {
    test('新增/启停/更新/删除并持久化', () async {
      final service = HighlightRuleService();
      await service.ensureLoaded();
      final rule = _rule(pattern: 'x');
      await service.add(rule);
      expect(service.rules, hasLength(1));
      expect(service.enabledRules, hasLength(1));

      await service.setEnabled(rule.id, false);
      expect(service.enabledRules, isEmpty);

      await service.update(rule.id, rule.copyWith(styleHex: '4CAF50'));
      expect(service.rules.single.styleHex, '4CAF50');

      await service.remove(rule.id);
      expect(service.rules, isEmpty);
    });

    test('多实例共享同一份持久化存储', () async {
      final a = HighlightRuleService();
      await a.add(_rule(pattern: 'y'));
      final b = HighlightRuleService();
      await b.ensureLoaded();
      expect(b.rules, hasLength(1));
    });
  });
}