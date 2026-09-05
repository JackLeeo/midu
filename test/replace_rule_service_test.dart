// M3 对标 Legado：替换净化规则服务测试。
// 覆盖：模型序列化往返、applyReplaceRules 的 regex/plain/顺序/删除语义、
// 服务 CRUD/启停/排序/持久化（SharedPreferences mock）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:midu/book_sources/services/replace_rule_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ReplaceRule 模型', () {
    test('toJson/fromJson 往返无损', () {
      const rule = ReplaceRule(
        id: 'rr_1',
        name: '去广告',
        pattern: r'^.*推广.*$',
        replacement: '',
        isRegex: true,
        enabled: true,
      );
      final restored = ReplaceRule.fromJson(rule.toJson());
      expect(restored.id, 'rr_1');
      expect(restored.name, '去广告');
      expect(restored.pattern, r'^.*推广.*$');
      expect(restored.isRegex, isTrue);
      expect(restored.enabled, isTrue);
    });

    test('缺省字段回退默认值', () {
      final rule = ReplaceRule.fromJson(const {
        'id': 'x',
        'name': 'n',
        'pattern': 'p',
      });
      expect(rule.isRegex, isTrue);
      expect(rule.enabled, isTrue);
      expect(rule.replacement, '');
    });
  });

  group('applyReplaceRules', () {
    test('空规则 / 空文本原样返回', () {
      expect(applyReplaceRules('', const []), '');
      expect(applyReplaceRules('正文', const []), '正文');
      expect(
        applyReplaceRules('正文', const [ReplaceRule(id: '1', name: '', pattern: '')]),
        '正文',
      );
    });

    test('正则替换删除广告行（多行锚点）', () {
      const rules = [
        ReplaceRule(
          id: '1',
          name: '去广告行',
          pattern: r'^.*【推书】看最新章节.*$',
          replacement: '',
        ),
      ];
      const input = '第一章\n'
          '这是正文第一行内容。\n'
          '【推书】看最新章节内容请下载App\n'
          '这是正文第二行内容。';
      final result = applyReplaceRules(input, rules);
      expect(result.contains('【推书】'), isFalse);
      expect(result.contains('这是正文第一行内容。'), isTrue);
      expect(result.contains('这是正文第二行内容。'), isTrue);
    });

    test('替换文本支持 \$1 分组引用', () {
      const rules = [
        ReplaceRule(
          id: '1',
          name: '网页提示换行',
          pattern: r'([\s\S]*?)\s*本站提示(.*)',
          replacement: r'$1',
        ),
      ];
      final result = applyReplaceRules('正文内容本站提示，快去充值余额吧', rules);
      expect(result, '正文内容');
    });

    test('普通字符串模式精确替换', () {
      const rules = [
        ReplaceRule(
          id: '1',
          name: '替换站点名',
          pattern: 'XX小说网',
          replacement: '梦里书屋',
          isRegex: false,
        ),
      ];
      expect(applyReplaceRules('欢迎来到XX小说网阅读', rules), '欢迎来到梦里书屋阅读');
    });

    test('按顺序逐条执行，后规则作用于前规则结果', () {
      const rules = [
        ReplaceRule(
          id: '1',
          name: '先删括号',
          pattern: r'\(.*?\)',
          replacement: '',
        ),
        ReplaceRule(
          id: '2',
          name: '再合并逗号',
          pattern: ',{2,}',
          replacement: ',',
        ),
      ];
      // 第一条把 (..) 删掉后出现 ",,"；第二条再压缩为单个逗号。
      final result = applyReplaceRules('a(段落删除)b,,c', rules);
      expect(result, 'ab,c');
    });

    test('关闭的规则跳过，非法正则不破坏正文', () {
      const rules = [
        ReplaceRule(
          id: '1',
          name: '关闭的规则',
          pattern: '广告',
          replacement: '',
          enabled: false,
        ),
        ReplaceRule(
          id: '2',
          name: '非法正则',
          pattern: r'([a-z',
          replacement: '',
        ),
      ];
      const input = '含广告的正文';
      expect(applyReplaceRules(input, rules), input);
    });
  });

  group('ReplaceRuleService', () {
    test('add/update/remove/setEnabled/move 持久化', () async {
      final service = ReplaceRuleService();
      await service.ensureLoaded();
      await service.add(
        const ReplaceRule(id: 'a', name: '规则A', pattern: 'A'),
      );
      await service.add(
        const ReplaceRule(id: 'b', name: '规则B', pattern: 'B'),
      );
      expect(service.rules.map((r) => r.id), ['a', 'b']);

      await service.update('a', const ReplaceRule(id: 'a', name: '规则A2', pattern: 'A2'));
      expect(service.rules.first.name, '规则A2');

      await service.setEnabled('b', false);
      expect(service.enabledRules.map((r) => r.id), ['a']);

      await service.move(1, 0); // b 移到最前
      expect(service.rules.map((r) => r.id), ['b', 'a']);

      await service.remove('a');
      expect(service.rules.map((r) => r.id), ['b']);
    });

    test('持久化到 SharedPreferences 可重载', () async {
      final service = ReplaceRuleService();
      await service.add(
        const ReplaceRule(id: 'a', name: '规则A', pattern: r'^广告$'),
      );
      await service.add(
        const ReplaceRule(id: 'b', name: '规则B', pattern: 'x', enabled: false),
      );

      final reloaded = ReplaceRuleService();
      await reloaded.ensureLoaded();
      expect(reloaded.rules, hasLength(2));
      expect(reloaded.rules[0].id, 'a');
      expect(reloaded.rules[1].enabled, isFalse);
    });

    test('newId 生成唯一 id', () {
      final ids = {ReplaceRuleService.newId(), ReplaceRuleService.newId()};
      expect(ids, hasLength(2));
    });

    test('enabledRules 保持执行顺序', () async {
      final service = ReplaceRuleService();
      await service.add(const ReplaceRule(id: '1', name: '', pattern: 'P1'));
      await service.add(const ReplaceRule(id: '2', name: '', pattern: 'P2', enabled: false));
      await service.add(const ReplaceRule(id: '3', name: '', pattern: 'P3'));
      expect(service.enabledRules.map((r) => r.id), ['1', '3']);
    });
  });
}