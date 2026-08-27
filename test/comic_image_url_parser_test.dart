import 'package:flutter_test/flutter_test.dart';
import 'package:midu/book_sources/services/comic_image_url_parser.dart';

void main() {
  group('extractContentImageUrls', () {
    test('无引号 <img> 列表（全免漫画 ruleContent 的拼接形态）', () {
      const content =
          '\n<img src=https://cdn.example.com/1.jpg>\n'
          '<img src=https://cdn.example.com/2.jpg>\n'
          '<img src=https://cdn.example.com/3.jpg>';
      expect(
        extractContentImageUrls(content),
        [
          'https://cdn.example.com/1.jpg',
          'https://cdn.example.com/2.jpg',
          'https://cdn.example.com/3.jpg',
        ],
      );
    });

    test('无引号 <img> 且 URL 含未编码空格（kaimanhua 章节图形态）', () {
      const content =
          '\n<img src=https://hw-chapter2.kaimanhua.com/comic/Y/ 妖者为王/1.jpg>\n'
          '<img src=https://hw-chapter2.kaimanhua.com/comic/Y/ 妖者为王/2.jpg>\n'
          '<img src=https://hw-chapter2.kaimanhua.com/comic/Y/ 妖者为王/3.jpg>';
      final urls = extractContentImageUrls(content);
      expect(urls, hasLength(3));
      for (final url in urls) {
        // 空格必须编码为 %20、中文路径被规范化，且不再含裸空格，
        // 否则下游 Uri.parse 抛 FormatException、图片加载失败。
        expect(url.contains(' '), isFalse);
        expect(url.startsWith('https://hw-chapter2.kaimanhua.com/comic/Y/%20'),
            isTrue);
        expect(url.endsWith('.jpg'), isTrue);
      }
      expect(urls.first, contains('%E5%A6%96'));
    });

    test('带引号 <img>（品如漫画 .main_img@html 形态）', () {
      const content =
          '<img src="/uploads/page1.jpg" class="main_img"/>\n'
          '<img src="/uploads/page2.jpg" class="main_img"/>';
      expect(
        extractContentImageUrls(content, baseUrl: 'https://m.rumanhua.com'),
        [
          'https://m.rumanhua.com/uploads/page1.jpg',
          'https://m.rumanhua.com/uploads/page2.jpg',
        ],
      );
    });

    test('相对路径 <img> 用章节 URL 拼成绝对地址', () {
      const content =
          '<p><img src="/pic/01.jpg"></p>\n<div><img src="/pic/02.jpg"></div>';
      expect(
        extractContentImageUrls(
          content,
          baseUrl: 'https://m.rumanhua.com/chapter/123.html',
        ),
        [
          'https://m.rumanhua.com/pic/01.jpg',
          'https://m.rumanhua.com/pic/02.jpg',
        ],
      );
    });

    test('JSON images 数组', () {
      const content =
          '{"images":["https://a.com/1.jpg","https://a.com/2.jpg"]}';
      expect(
        extractContentImageUrls(content),
        ['https://a.com/1.jpg', 'https://a.com/2.jpg'],
      );
    });

    test('嵌套 JSON data.images', () {
      const content =
          '{"data":{"images":["https://a.com/1.jpg","https://a.com/2.jpg"]}}';
      expect(
        extractContentImageUrls(content),
        ['https://a.com/1.jpg', 'https://a.com/2.jpg'],
      );
    });

    test('纯 URL 列表（换行分隔）', () {
      const content = 'https://a.com/1.jpg\nhttps://a.com/2.jpg\nhttps://a.com/3.jpg';
      expect(
        extractContentImageUrls(content),
        ['https://a.com/1.jpg', 'https://a.com/2.jpg', 'https://a.com/3.jpg'],
      );
    });

    test('Markdown 图片语法 ![](url)', () {
      const content = '![第1页](https://a.com/1.jpg)\n![第2页](https://a.com/2.jpg)';
      expect(
        extractContentImageUrls(content),
        ['https://a.com/1.jpg', 'https://a.com/2.jpg'],
      );
    });

    test('小说正文里单张装饰图不误判为漫画', () {
      const content =
          '<p>第一章 风起</p>\n<p>夜幕降临，远处传来一声剑鸣。</p>\n'
          '<img src="https://site.example.com/logo.png">\n'
          '<p>他抬起头，望向天际。</p>';
      expect(extractContentImageUrls(content), isEmpty);
    });

    test('普通文本正文不误判', () {
      const content = '第一章 相遇\n他沿着长街走，两旁的梧桐叶在风里沙沙作响。';
      expect(extractContentImageUrls(content), isEmpty);
    });

    test('相对路径无 baseUrl 时无法拼接则返回空', () {
      const content =
          '<img src="/pic/01.jpg">\n<img src="/pic/02.jpg">';
      expect(extractContentImageUrls(content), isEmpty);
    });

    test('空正文返回空', () {
      expect(extractContentImageUrls(''), isEmpty);
      expect(extractContentImageUrls('   '), isEmpty);
    });
  });
}