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

/// 跑一轮全量健康检测，把汇总 + 明细写入 [outPath]，返回「ok=failed=total」摘要串。
/// [bridgeOn] 控制是否给沙箱接入 java.ajax / java.connect（对照 bridge 贡献）。
Future<String> runHealthOnce(
  List<RegisteredBookSource> registered, {
  required bool bridgeOn,
  required String outPath,
}) async {
  final sb = StringBuffer();
  BookSourceClient? client;
  HealthCheckReport? report;
  try {
    client = BookSourceClient(
      sandboxFactory: (_) => FlutterLegadoJsSandbox(),
      enableAjaxBridge: bridgeOn,
    );
    final checker = BookSourceHealthChecker(
      client: client,
      maxConcurrency: 12,
      probeQueries: const ['斗破苍穹', '诡秘之主', '完美世界'],
      stageTimeout: const Duration(seconds: 8),
    );
    report = await checker.run(registered, onlyLegado: true);

    sb.writeln('');
    sb.writeln('===== 汇总 =====');
    sb.writeln('ok=${report.healthyCount} failed=${report.failedCount} '
        'total=${report.total}');

    final byStage = <HealthCheckStage, int>{};
    for (final r in report.failures) {
      byStage[r.stage] = (byStage[r.stage] ?? 0) + 1;
    }
    sb.writeln('失败阶段分布: ${byStage.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}');

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
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(sb.toString());
  // ignore: avoid_print
  print(sb.toString());
  return 'ok=${report?.healthyCount ?? 0} '
      'failed=${report?.failedCount ?? 0} '
      'total=${report?.total ?? registered.length}';
}

void main() {
  test('全量健康检测：bridge off vs on 通过率对比（逐源 search→detail→catalog→content）',
      () async {
    copyQuickJsDllIfNeeded();
    final file = File(r'D:\gz\完美书源.json');
    if (!file.existsSync()) {
      fail('未找到书源文件');
      return;
    }
    final sources = parseLegadoSources(file.readAsStringSync()).sources
        .toList()
      ..sort((l, r) => r.lastUpdateTime.compareTo(l.lastUpdateTime));
    print('total=${sources.length}');

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
    print('runnable=${registered.length} unsupported=$unsupported');

    // 轮 1：关闭 java.ajax / java.connect bridge（对照基线）
    final before = await runHealthOnce(
      registered,
      bridgeOn: false,
      outPath: r'D:\gz\日志\_health_bridge_off.txt',
    );
    // 轮 2：开启 bridge
    final after = await runHealthOnce(
      registered,
      bridgeOn: true,
      outPath: r'D:\gz\日志\_health_bridge_on.txt',
    );

    print('');
    print('===== BEFORE(bridge off) => $before');
    print('===== AFTER (bridge on ) => $after');
  },
      timeout: const Timeout(Duration(minutes: 40)));
}