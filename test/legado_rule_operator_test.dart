import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' show Element;

import 'package:midu/book_sources/legado/legado_rule_engine.dart';

/// 针对本次「引擎增强」的定向回归：
/// 1) %% 运算符（对齐 Legado）逐行交错拼接；2) _splitTopLevel 对 []() 括号的
/// 平衡保护，避免 XPath/CSS 属性值里的 && / || 被误当成分隔符拆分。
void main() {
  final engine = LegadoRuleEngine(); // sandbox 为空即不触发 JS 路径

  test('%% 运算符：两条 @text/@href 列表按下标逐行交错', () async {
    final doc = LegadoRuleDocument.parse(
      '<div class="list">'
      '<a href="/1.html">第一章</a>'
      '<a href="/2.html">第二章</a>'
      '</div>',
      Uri.parse('https://example.com/toc'),
    );
    final values = await engine.evaluateList(doc, doc.value, 'a@text%%a@href');
    expect(values, [
      '第一章',
      '/1.html',
      '第二章',
      '/2.html',
    ]);
  });

  test('_splitTopLevel：CSS 属性值里的 && 不会被误拆', () async {
    final doc = LegadoRuleDocument.parse(
      '<div><span data-k="a&&b">值A</span><span>其它</span></div>',
      Uri.parse('https://example.com/'),
    );
    // 该规则只有一个候选；若 [data-k="a&&b"] 里的 && 被顶层拆分，
    // 选择器会断成两段导致求值为空，测试据此发现回归。
    final values = await engine.evaluateList(
      doc,
      doc.value,
      r'[data-k="a&&b"]@text',
    );
    expect(values, ['值A']);
  });

  test('_splitTopLevel：XPath 括号里的 || 不会被误拆', () async {
    final doc = LegadoRuleDocument.parse(
      '<ul><li>甲</li><li>乙</li></ul>',
      Uri.parse('https://example.com/'),
    );
    // xpath 规则：|| 是顶层 OR 分隔符（短路返回首个非空分支）；括号/引号内的
    // 分隔符受保护，整体算作一条候选。这里验证括号保护 + OR 短路均生效。
    final values = await engine.evaluateList(
      doc,
      doc.value,
      r'@xpath://li[text()="甲"]||//li[text()="乙"]',
    );
    expect(values, hasLength(1));
    final li = values.single;
    expect((li as Element).text, '甲');
  });

  test('%% 不拦截 JSON 路径规则（退化到常规列表语义）', () async {
    final doc = LegadoRuleDocument.parse(
      '{"a":"x","b":"y"}',
      Uri.parse('https://example.com/'),
    );
    // JSON 路径段以 $. 开头 → 不启用 %% 交错；$.a%%$.b 本身不是合法 JSON 路径，
    // 应返回空列表而不是抛错或把字面量 %% 当选择器匹配。
    final values = await engine.evaluateList(doc, doc.value, r'$.a%%$.b');
    expect(values, isA<List<Object?>>());
    expect(values, isEmpty);
  });
}