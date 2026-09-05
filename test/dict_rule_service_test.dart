// 词典规则服务单元测试：模型往返 + 列表 CRUD + 持久化。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/services/dict_rule_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DictRule 模型', () {
    test('toJson / fromJson 往返保留全部字段', () {
      final rule = DictRule(
        id: 'dr_1',
        name: '百度汉语',
        urlRule: 'https://hanyu.baidu.com/s?wd={{key}}',
        showRule: '.content@text',
        enabled: true,
      );
      final restored = DictRule.fromJson(rule.toJson());
      expect(restored.id, 'dr_1');
      expect(restored.name, '百度汉语');
      expect(restored.urlRule, contains('{{key}}'));
      expect(restored.showRule, '.content@text');
      expect(restored.enabled, isTrue);
    });

    test('缺省字段返回安全默认值', () {
      final rule = DictRule.fromJson(const {'id': 'x'});
      expect(rule.name, '');
      expect(rule.urlRule, '');
      expect(rule.showRule, '');
      expect(rule.enabled, isTrue);
    });

    test('copyWith 仅覆盖指定字段且保留 id', () {
      final rule = DictRule(
        id: 'dr_2',
        name: 'A',
        urlRule: 'url',
      );
      final next = rule.copyWith(name: 'B', enabled: false);
      expect(next.id, 'dr_2');
      expect(next.name, 'B');
      expect(next.urlRule, 'url');
      expect(next.enabled, isFalse);
    });
  });

  group('DictRuleService CRUD', () {
    test('新增/更新/启停/删除并持久化', () async {
      final service = DictRuleService();
      await service.ensureLoaded();
      expect(service.rules, isEmpty);

      final rule = DictRule(
        id: DictRuleService.newId(),
        name: '规则1',
        urlRule: 'https://a.com/dict?w={{key}}',
      );
      await service.add(rule);
      expect(service.rules, hasLength(1));
      expect(service.enabledRules, hasLength(1));

      await service.setEnabled(rule.id, false);
      expect(service.enabledRules, isEmpty);
      expect(service.rules.single.enabled, isFalse);

      await service.update(rule.id, rule.copyWith(name: '规则1-改'));
      expect(service.rules.single.name, '规则1-改');

      await service.remove(rule.id);
      expect(service.rules, isEmpty);
    });

    test('多实例共享同一份持久化存储', () async {
      final a = DictRuleService();
      await a.add(
        DictRule(
          id: DictRuleService.newId(),
          name: '共享',
          urlRule: 'https://x.test/{{key}}',
        ),
      );
      final b = DictRuleService();
      await b.ensureLoaded();
      expect(b.rules, hasLength(1));
      expect(b.rules.single.name, '共享');
    });

    test('newId 生成的 id 唯一', () {
      final ids = {for (var i = 0; i < 100; i++) DictRuleService.newId()};
      expect(ids, hasLength(100));
    });
  });
}