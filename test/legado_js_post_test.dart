// 验证「java.post(...).body()」预处理改写：
//   1. 字符串字面量 URL（相对）→ 对 baseUri resolve 后再 POST，body/headers
//      为其余表达式，逐项求值；
//   2. 动态自包含表达式 URL（仅依赖全局 baseUrl，脚本可求值）→ PHP，并验证
//      `.body()` 方法链被吸收、最终规则完成值可解析为章节列表。
// 依赖共用库 legado_ajax_rewrite.rewriteAjaxCalls + flutter_js 测试沙箱的
// _ajaxArgResolver，不依赖真实网络（桩 AjaxFetcher 返回假响应）。
import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_fjs_sandbox.dart';
import 'package:midu/book_sources/legado/legado_rule_engine.dart';

import 'helpers/flutter_js_sandbox.dart';

const String _postResp = '{"code":0,"data":[{"chapterid":"119696","chaptername":"第一章"}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('java.post(绝对字面量url, bodyexpr, {headers}) .body() 改写', () async {
    final sandbox = FlutterLegadoJsSandbox();
    await sandbox.init();
    const docUrl = 'https://m.example.com/comic/12345/';
    sandbox.setAjaxFetcher((url, {method = 'GET', headers = const {}, body}) async {
      expect(method, 'POST');
      expect(url, 'https://m.example.com/morechapter');
      expect(body, 'id=12345');
      expect('${headers?['Referer']}', docUrl);
      return _postResp;
    });

    final engine = LegadoRuleEngine(sandbox: sandbox);
    final doc = LegadoRuleDocument.parse('{}', Uri.parse(docUrl));
    // url 为字面量绝对地址，无需 resolve；body/headers 为表达式逐项求值。
    const rule = '''
      @js:
      p = java.post("https://m.example.com/morechapter", "id=" + "12345", {Referer: baseUrl}).body();
      d = JSON.parse(p);
      dir = d.data.map(x => ({text: x.chaptername, href: "https://m.example.com/" + x.chapterid + ".html"}));
      dir;
    ''';

    final items = await engine.evaluateList(doc, null, rule);
    await sandbox.dispose();

    expect(items, hasLength(1));
    final first = items.first as Map;
    expect(first['text'], '第一章');
    expect(first['href'], 'https://m.example.com/119696.html');
  });

  test('java.post(自包含动态表达式url,...).body() 改写并吸收方法链', () async {
    final sandbox = FlutterLegadoJsSandbox();
    await sandbox.init();
    const docUrl = 'https://m.example.com/book/999/';
    sandbox.setAjaxFetcher((url, {method = 'GET', headers = const {}, body}) async {
      expect(method, 'POST');
      // 自包含表达式（仅依赖全局 baseUrl）求值出绝对 URL
      expect(url, 'https://m.example.com/morechapter');
      expect(body, 'id=999');
      expect('${headers?['Referer']}', docUrl);
      return _postResp;
    });

    final engine = LegadoRuleEngine(sandbox: sandbox);
    final doc = LegadoRuleDocument.parse('{}', Uri.parse(docUrl));
    // url/body 全部用全局 baseUrl 派生的自包含表达式（仅字符串运算，避开
    // 脚本局部变量与正则转义），验证动态表达式场景的改写与 .body() 吸收。
    const rule = '''
      @js:
      p = java.post(baseUrl.replace("book/999/", "") + "morechapter", "id=" + baseUrl.split("/")[4], {Referer: baseUrl}).body();
      d = JSON.parse(p);
      dir = d.data.map(x => ({text: x.chaptername, href: baseUrl + x.chapterid + ".html"}));
      dir;
    ''';

    final items = await engine.evaluateList(doc, null, rule);
    await sandbox.dispose();

    expect(items, hasLength(1));
    final first = items.first as Map;
    expect(first['text'], '第一章');
    expect(first['href'], 'https://m.example.com/book/999/119696.html');
  });
}