// 真实健康检测链路全量诊断（flutter_js 沙箱 + 真实 HTTP）：
// 用 BookSourceClient + BookSourceHealthChecker 遍历 D:\gz\完美书源.json 全部源，
// 逐源执行 search→detail→catalog→content，统计各阶段失败分布，验证按源隔离修复后通过率。
//
// 运行：flutter test tool/diagnose_health_all_test.dart
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/models/registered_book_source.dart';
import 'package:midu/book_sources/services/book_source_client.dart';
import 'package:midu/book_sources/services/book_source_health_service.dart';

import '../test/helpers/flutter_js_sandbox.dart';

import 'package:test/test.dart';

void main() {
  test('全量健康检测：逐源 search→detail→catalog→content',
      () async {
    copyQuickJsDllIfNeeded();
    final sb = StringBuffer();
    BookSourceClient? client;
    try {
      final file = File(r'D:\gz\完美书源.json');
      if (!file.existsSync()) {
        fail('未找到书源文件');
        return;
      }
      final sources = parseLegadoSources(file.readAsStringSync()).sources
          .toList()
        ..sort((l, r) => r.lastUpdateTime.compareTo(l.lastUpdateTime));
      sb.writeln('total=${sources.length}');

      final registered = <RegisteredBookSource>[];
      var unsupported = 0;
      for (final s in sources) {
        final report = const LegadoCompatibilityScanner().scan(s);
        if (!report.canRun) {
          unsupported++;
          continue;
        }
        registered.add(s.toRegisteredSource());
      }
      sb.writeln('runnable=${registered.length} unsupported=$unsupported');

      client = BookSourceClient(
        sandboxFactory: (_) => FlutterLegadoJsSandbox(),
      );
      final checker = BookSourceHealthChecker(
        client: client,
        maxConcurrency: 12,
        probeQueries: const ['斗破苍穹', '诡秘之主', '完美世界'],
        stageTimeout: const Duration(seconds: 8),
      );
      final report = await checker.run(registered, onlyLegado: true);

      sb.writeln('');
      sb.writeln('===== 汇总 =====');
      sb.writeln('ok=${report.healthyCount} failed=${report.failedCount} '
          'total=${report.total}');

      final byStage = <HealthCheckStage, int>{};
      for (final r in report.failures) {
        byStage[r.stage] = (byStage[r.stage] ?? 0) + 1;
      }
      sb.writeln('失败阶段分布: ${byStage.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}');

      // 错误文案粗分类
      final errClass = <String, int>{};
      final unclassified = <HealthCheckResult>[];
      for (final r in report.failures) {
        final e = r.error ?? '';
        String cls;
        if (e.contains('400')) {
          cls = 'HTTP400';
        } else if (e.contains('超时')) {
          cls = '超时';
        } else if (e.contains('Could not connect') ||
            e.contains('Connection refused') ||
            e.contains('SocketException') ||
            e.contains('连接')) {
          cls = '连接失败';
        } else if (e.contains('搜索未返回') || e.contains('目录为空') ||
            e.contains('正文过短') || e.contains('未返回')) {
          cls = '数据为空';
        } else if (e.contains('unsupported')) {
          cls = '不支持';
        } else {
          cls = '其他';
          unclassified.add(r);
        }
        errClass[cls] = (errClass[cls] ?? 0) + 1;
      }
      sb.writeln('失败分类: ${errClass.entries.map((e) => '${e.key}=${e.value}').join(' ')}');

      sb.writeln('');
      sb.writeln('===== 健康源名单 =====');
      for (final r in report.results) {
        if (r.isHealthy) {
          sb.writeln('  OK [${r.latencyMs}ms] ${r.source.name}');
        }
      }
      sb.writeln('');
      sb.writeln('===== 其他错误明细（前120条） =====');
      var printed = 0;
      for (final r in unclassified) {
        if (printed++ >= 120) break;
        sb.writeln('  [${r.stage.name}] ${r.source.name} :: ${r.error}');
      }
    } catch (e, st) {
      sb.writeln('FATAL $e\n$st');
    } finally {
      client?.close();
    }
    final out = File(r'D:\gz\日志\_health_all_diag.txt');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(sb.toString());
    // ignore: avoid_print
    print(sb.toString());
  },
      timeout: const Timeout(Duration(minutes: 20)));
}