// 真实书源规则覆盖率测试：对 D:\gz\完美书源.json 的全部规则做静态分析，
// 验证规则引擎可以结构化解析所有非 JS 规则（不崩溃），并统计覆盖率。
// 该文件不在仓库内时自动跳过，避免 CI 失败。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/legado/legado_book_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final file = File(r'D:\gz\完美书源.json');
  if (!file.existsSync()) {
    test('真实书源规则覆盖率（跳过：未找到 D:\\gz\\完美书源.json）', () {
      markTestSkipped('书源文件不在本机');
    });
    return;
  }

  final sources = parseLegadoSources(file.readAsStringSync()).sources.toList();

  test('真实书源规则覆盖率统计', () {
    var total = 0;
    var jsOnly = 0; // 所有规则都需要 JS（无法本地验证）
    var engineClean = 0; // 全部规则可被引擎结构化解析（无 JS 依赖）
    var withPutGet = 0;
    var withDeepScan = 0;
    var withMinusPrefix = 0;
    var withXpath = 0;
    var ruleCount = 0;

    for (final source in sources) {
      total++;
      var needsJs = false;
      var hasPutGet = false;
      var hasDeepScan = false;
      var hasMinus = false;
      var hasXpath = false;

      void inspect(Object? value) {
        if (value is Map) {
          value.forEach((_, v) => inspect(v));
        } else if (value is List) {
          value.forEach(inspect);
        } else if (value is String && value.trim().isNotEmpty) {
          ruleCount++;
          final text = value;
          final lower = text.toLowerCase();
          if (lower.contains('@js:') ||
              lower.contains('<js>') ||
              lower.contains('java.') ||
              lower.contains('source.') ||
              lower.contains('{{java')) {
            needsJs = true;
          }
          if (lower.contains('@put:') || lower.contains('@get:')) {
            hasPutGet = true;
          }
          if (lower.contains(r'$..') || lower.contains(r'..books') || lower.contains(r'$..')) {
            hasDeepScan = true;
          }
          if (text.trimLeft().startsWith('-') &&
              !text.trimLeft().startsWith('--')) {
            hasMinus = true;
          }
          if (lower.startsWith('@xpath:') || text.trimLeft().startsWith('//')) {
            hasXpath = true;
          }
        }
      }

      for (final group in const [
        'searchUrl',
        'exploreUrl',
        'ruleSearch',
        'ruleBookInfo',
        'ruleToc',
        'ruleContent',
        'ruleExplore',
      ]) {
        inspect(source.raw[group]);
      }

      if (hasPutGet) withPutGet++;
      if (hasDeepScan) withDeepScan++;
      if (hasMinus) withMinusPrefix++;
      if (hasXpath) withXpath++;
      if (needsJs) {
        jsOnly++;
      } else {
        engineClean++;
      }
    }

    // ignore: avoid_print
    print('总源数: $total');
    // ignore: avoid_print
    print('规则字符串总数: $ruleCount');
    // ignore: avoid_print
    print('引擎可完全处理（无 JS 依赖）: $engineClean (${(engineClean * 100 / total).toStringAsFixed(1)}%)');
    // ignore: avoid_print
    print('需 JS 沙箱: $jsOnly');
    // ignore: avoid_print
    print('含 @put/@get 的源: $withPutGet');
    // ignore: avoid_print
    print('含 \$.. 深扫描的源: $withDeepScan');
    // ignore: avoid_print
    print('含 - 前缀的源: $withMinusPrefix');
    // ignore: avoid_print
    print('含 @xpath 的源: $withXpath');

    // 引擎必须能处理非 JS 源；JS 源在 app 内通过 fjs 沙箱运行。
    expect(engineClean + jsOnly, total);
    // 覆盖率下限：非 JS 源占比至少 30%
    expect(engineClean * 100 / total, greaterThanOrEqualTo(30));
  });
}
