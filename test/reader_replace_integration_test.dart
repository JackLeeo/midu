// M3 对标 Legado：替换净化接入正文渲染管线集成测试。
// 验证：readableBookSourceChapterText / Async（isolate 路径）在应用替换净化后
// 仍产出正确段落文本，且现有分页器可继续正常分页（净化不应破坏正文结构）。
import 'package:flutter/material.dart' show TextStyle, TextDirection;
import 'package:flutter_test/flutter_test.dart';

import 'package:midu/book_sources/protocol/book_source_protocol.dart';
import 'package:midu/book_sources/services/book_source_chapter_text.dart';
import 'package:midu/book_sources/services/book_source_text_paginator.dart';
import 'package:midu/book_sources/services/replace_rule_service.dart';

BookSourceChapterContent _content({String html = _html}) {
  return BookSourceChapterContent(
    bookId: 'b1',
    chapterId: 'c1',
    title: '第一章 测试',
    content: html,
    contentType: 'text/html',
  );
}

const _html = '''
<html><body><div id="content">
<h3>第一章 测试</h3>
<p>正文第一段，引入剧情。</p>
<p>【长按识别二维码，快速加入】推广内容需要剔除</p>
<p>正文第二段继续推进。</p>
<div class="ad">这里是广告区块<div>内嵌推广文字</div></div>
<p>结尾段落。</p>
</div></body></html>
''';

const _adRules = [
  ReplaceRule(id: '1', name: '去推广行', pattern: r'^.*【长按识别二维码.*$', replacement: ''),
  ReplaceRule(id: '2', name: '去广告区', pattern: r'^.*广告区块.*$', replacement: ''),
];

void main() {
  test('替换净化后段落保留且正文完整', () {
    final text = readableBookSourceChapterText(
      _content(),
      fallbackTitle: '第一章 测试',
      replaceRules: _adRules,
    );
    expect(text.contains('【长按识别二维码'), isFalse);
    expect(text.contains('广告区块'), isFalse);
    expect(text.contains('正文第一段，引入剧情。'), isTrue);
    expect(text.contains('正文第二段继续推进。'), isTrue);
    expect(text.contains('结尾段落。'), isTrue);
  });

  test('无替换规则时行为不变', () {
    final text = readableBookSourceChapterText(
      _content(),
      fallbackTitle: '第一章 测试',
    );
    expect(text.contains('【长按识别二维码，快速加入】推广内容需要剔除'), isTrue);
    expect(text.contains('广告区块'), isTrue);
  });

  test('全局规则作用于朗读文本（async 路径）', () async {
    final text = await readableBookSourceChapterTextAsync(
      _content(),
      fallbackTitle: '第一章 测试',
      replaceRules: _adRules,
    );
    expect(text.contains('【长按识别二维码'), isFalse);
    expect(text.contains('广告区块'), isFalse);
  });

  test('净化后文本仍可正常分页', () {
    final text = readableBookSourceChapterText(
      _content(),
      fallbackTitle: '第一章 测试',
      replaceRules: _adRules,
    );
    final pages = paginateBookSourceText(
      text,
      width: 320,
      firstPageHeight: 480,
      pageHeight: 480,
      style: const TextStyle(fontSize: 16),
      textDirection: TextDirection.ltr,
    );
    expect(pages, isNotEmpty);
    expect(pages.fold<int>(0, (sum, p) => sum + (p.text?.length ?? 0)),
        greaterThan(0));
  });

  test('多行广告整行删除后不粘连相邻段落', () {
    const multiline = '''
第1段先写到这里。
【加群】双击屏幕或长按右上角助力
【加群】加入粉丝群聊剧情外传
第2段继续。
''';
    const rules = [
      ReplaceRule(id: '1', name: '去加群行', pattern: r'^.*【加群】.*$', replacement: ''),
    ];
    final text = applyReplaceRules(multiline, rules);
    expect(text.contains('【加群】'), isFalse);
    expect(text.contains('第1段先写到这里。'), isTrue);
    expect(text.contains('第2段继续。'), isTrue);
  });
}