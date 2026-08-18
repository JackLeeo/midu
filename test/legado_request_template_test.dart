// LegadoRequestTemplate 请求解析测试：字符集感知变量编码 + 分页追加语法。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:midu/book_sources/legado/legado_request.dart';

void main() {
  final base = Uri.parse('https://www.example.com/');

  group('变量展开（字符集感知）', () {
    test('UTF-8 站点：{{key}} 按 UTF-8 百分号编码', () {
      final req = LegadoRequestTemplate.parse(
        '/search?q={{key}}',
        baseUri: base,
        variables: const {'key': '斗破苍穹', 'page': '1'},
      );
      expect(req.url.toString(), contains('q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9'));
      expect(req.method, LegadoRequestMethod.get);
    });

    test('GBK 站点：{{key}} 按 GBK 字节百分号编码（书满屋形态）', () {
      final req = LegadoRequestTemplate.parse(
        '/s.php,{"charset":"gbk","method":"post","body":"s={{key}}&type=articlename"}',
        baseUri: base,
        variables: const {'key': '斗破苍穹', 'page': '1'},
      );
      expect(req.method, LegadoRequestMethod.post);
      // 斗破苍穹 GBK 字节 → 百分比编码，绝不含 UTF-8 的 %E6%96%97 前缀
      expect(req.body, isNot(contains('%E6%96%97')));
      expect(req.body, startsWith('s=%'));
      // 解码回 GBK 应该得到原词
      final decoded = gbk_bytes.decode(_percentDecode(req.body!));
      expect(decoded, 's=斗破苍穹&type=articlename');
      expect(req.headers['Content-Type'], contains('gbk'));
    });

    test('分页追加语法：page=1 移除 <,xxx>，page=2 保留内部内容', () {
      final page1 = LegadoRequestTemplate.parse(
        '/waps.php?searchkey={{key}}&page=<,{{page}}>',
        baseUri: base,
        variables: const {'key': 'k', 'page': '1'},
      );
      expect(page1.url.toString(), contains('page='));
      expect(page1.url.toString(), isNot(contains('%3C')));
      expect(page1.url.toString(), isNot(contains('page=,1')));

      final page2 = LegadoRequestTemplate.parse(
        '/waps.php?searchkey={{key}}&page=<,{{page}}>',
        baseUri: base,
        variables: const {'key': 'k', 'page': '2'},
      );
      expect(page2.url.toString(), contains('page=2'));
    });

    test('POST body 内 {{key}} 同样按 UTF-8 编码（奇书网站形态）', () {
      final req = LegadoRequestTemplate.parse(
        '/search.php,{"method":"POST","body":"searchkey={{key}}"}',
        baseUri: base,
        variables: const {'key': '斗破苍穹', 'page': '1'},
      );
      expect(req.method, LegadoRequestMethod.post);
      expect(req.body, 'searchkey=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9');
    });

    test('未提供的变量保持 {{...}} 原样并抛 unsupported template', () {
      expect(
        () => LegadoRequestTemplate.parse(
          '/search?q={{key}}',
          baseUri: base,
          variables: const {},
        ),
        throwsA(isA<Object>()),
      );
    });
  });
}

/// 百分号解码为字节序列（+ → 空格）。
List<int> _percentDecode(String input) {
  final out = <int>[];
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '%' && i + 2 < input.length) {
      out.add(int.parse(input.substring(i + 1, i + 3), radix: 16));
      i += 3;
    } else if (ch == '+') {
      out.add(0x20);
      i++;
    } else {
      out.addAll(utf8.encode(ch));
      i++;
    }
  }
  return out;
}

