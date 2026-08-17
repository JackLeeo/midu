// 真实 runtime 搜索诊断（需要 fjs.dll 可加载 + 网络环境）：
// dart run tool/diagnose_live.dart
import 'dart:io';

import 'package:midu/book_sources/legado/legado_book_source.dart';
import 'package:midu/book_sources/legado/legado_runtime.dart';

Future<void> main() async {
  final sb = StringBuffer();
  final runtime = LegadoRuntime();
  try {
    final sources = parseLegadoSources(
      File(r'D:\gz\完美书源.json').readAsStringSync(),
    ).sources
        .toList()
      ..sort((l, r) => r.lastUpdateTime.compareTo(l.lastUpdateTime));
    sb.writeln('total=${sources.length}');
    final targets = <String>[
      '起点书评',
      '鸠摩搜书',
      '书趣阁网',
      '舟默途桐',
      '新御书屋',
      '望书阁',
      '玄幻阁',
      '笔趣阁',
      '顶点中文',
      '爱笔楼',
      '看书吧',
      '福书村',
    ];
    var i = 0;
    for (final source in sources) {
      final name = '${source.name}';
      if (!targets.any((t) => name.contains(t))) continue;
      i++;
      final report = const LegadoCompatibilityScanner().scan(source);
      if (!report.canRun) {
        sb.writeln('SKIP(unsupported) $name');
        continue;
      }
      final registered = source.toRegisteredSource();
      try {
        final page = await runtime
            .search(registered, '斗破苍穹')
            .timeout(const Duration(seconds: 25));
        sb.writeln(
            'SEARCH-OK $name books=${page.items.length} first=${page.items.isEmpty ? "" : page.items.first.title}');
      } catch (e, st) {
        sb.writeln('SEARCH-FAIL $name :: $e\n  $st'.split('\n').take(3).join('\n'));
      }
    }
    sb.writeln('matched=$i');
  } catch (e, st) {
    sb.writeln('FATAL $e\n$st');
  } finally {
    runtime.close();
  }
  final out = File(r'D:\gz\日志\_runtime_out.txt');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(sb.toString());
  stdout.writeln(sb.toString());
}
