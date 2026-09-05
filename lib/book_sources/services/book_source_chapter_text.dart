import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../protocol/book_source_protocol.dart';
import '../../core/reader/reader_text_characters.dart';
import 'book_source_text_paginator.dart';
import 'replace_rule_service.dart';

const _bookSourceBlockTags = {'p', 'div', 'li', 'blockquote'};

/// Matches the opening of any HTML tag (`<p`, `</br`, `<img`, …) without
/// requiring a closing `>`. Plain-text bodies never legitimately contain this
/// sequence, so the presence of a tag opener is enough to route the payload
/// through the HTML extraction path.
final _htmlTagOpener = RegExp(r'</?[a-z][a-z0-9]*', caseSensitive: false);

/// Converts a source payload into canonical chapter text.
///
/// This adapter owns source-specific HTML extraction and repeated remote page
/// marker cleanup. It deliberately does not inject indentation or paragraph
/// spacing; those are display settings applied later by the shared reader
/// text pipeline.
///
/// The parsing path is chosen by inspecting the content itself, not the
/// declared `contentType`. Source declarations are unreliable in the wild:
/// plain text is frequently labelled `text/html` and well-formed HTML
/// occasionally arrives as `text/plain`. Probing the content routes each
/// payload through the semantically correct path so the shared layout layer
/// always receives properly paragraph-separated text, which is the only
/// signal it can use to apply first-line indentation.
String readableBookSourceChapterText(
  BookSourceChapterContent content, {
  String fallbackTitle = '',
  List<ReplaceRule> replaceRules = const [],
}) {
  final chapterTitles = <String>{
    if (content.title.trim().isNotEmpty) content.title,
    if (fallbackTitle.trim().isNotEmpty) fallbackTitle,
  };

  final paragraphs = _looksLikeHtml(content.content)
      ? _extractHtmlParagraphs(content.content)
      : _extractPlainTextParagraphs(content.content);

  final cleaned = removeRepeatedSourcePageMarkers(paragraphs);
  // 米读：把连续空行压成最多一个空行，并去掉首尾空行。部分书源正文里嵌了大量
  // 空 <p>/<br> 或多余换行（如书满屋单章 500+ 行空白），plain 路径下 splitReaderTextLines
  // 原样保留这些空行，导致阅读时出现大量空白段。这里统一折叠，不影响单个空行语义。
  final collapsed = _collapseBlankLines(cleaned);
  final canonical = _removeRepeatedLeadingChapterTitle(
    collapsed,
    chapterTitles,
  ).join('\n');
  // 全局替换净化：按启用的规则链顺序替换/删除广告推广等内容，再交给分页器。
  // 规则列表为空或全部禁用时原样返回，零开销。
  if (replaceRules.isEmpty) return canonical;
  return applyReplaceRules(canonical, replaceRules);
}

/// 折叠连续空行：非空行原样保留；空行只在两个非空行之间出现一次，且首尾空行剔除。
List<String> _collapseBlankLines(List<String> lines) {
  final out = <String>[];
  var pendingBlank = false;
  for (final line in lines) {
    if (line.trim().isEmpty) {
      if (!pendingBlank && out.isNotEmpty) {
        out.add('');
        pendingBlank = true;
      }
      continue;
    }
    pendingBlank = false;
    out.add(line);
  }
  if (out.isNotEmpty && out.last.isEmpty) out.removeLast();
  return out;
}

/// Normalizes chapters whose parsing cost is large enough to disturb reader
/// frames on a background isolate. Short plain-text chapters stay local to
/// avoid paying isolate startup and message-copy overhead.
Future<String> readableBookSourceChapterTextAsync(
  BookSourceChapterContent content, {
  String fallbackTitle = '',
  List<ReplaceRule> replaceRules = const [],
}) {
  final shouldUseWorker =
      _looksLikeHtml(content.content) || content.content.length >= 64 * 1024;
  final rulesJson = jsonEncode(replaceRules.map((rule) => rule.toJson()).toList());
  if (!shouldUseWorker) {
    return Future<String>.value(
      readableBookSourceChapterText(
        content,
        fallbackTitle: fallbackTitle,
        replaceRules: replaceRules,
      ),
    );
  }
  return compute(
    _readableBookSourceChapterTextInBackground,
    <String, String>{
      'bookId': content.bookId,
      'chapterId': content.chapterId,
      'title': content.title,
      'content': content.content,
      'contentType': content.contentType,
      'fallbackTitle': fallbackTitle,
      'replaceRulesJson': rulesJson,
    },
    debugLabel: 'normalize book-source chapter',
  ).onError(
    (_, _) =>
        readableBookSourceChapterText(
          content,
          fallbackTitle: fallbackTitle,
          replaceRules: replaceRules,
        ),
  );
}

String _readableBookSourceChapterTextInBackground(Map<String, String> values) {
  final rules = <ReplaceRule>[
    for (final raw in _decodeRulesList(values['replaceRulesJson'] ?? '[]'))
      ReplaceRule.fromJson(raw),
  ];
  return readableBookSourceChapterText(
    BookSourceChapterContent(
      bookId: values['bookId']!,
      chapterId: values['chapterId']!,
      title: values['title']!,
      content: values['content']!,
      contentType: values['contentType']!,
    ),
    fallbackTitle: values['fallbackTitle']!,
    replaceRules: rules,
  );
}

/// 解析规则 JSON（换行/注释容错：解析失败返回空列表，等价于不净化）。
List<Map<String, dynamic>> _decodeRulesList(String raw) {
  if (raw.isEmpty || raw == '[]') return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  } on FormatException {
    return const [];
  }
}

bool _looksLikeHtml(String content) => _htmlTagOpener.hasMatch(content);

/// Preserves the source's own line structure: BOM is stripped and every hard
/// Unicode line break is folded to a canonical paragraph boundary, while
/// leading whitespace and blank lines remain available to downstream logic.
List<String> _extractPlainTextParagraphs(String raw) {
  final normalized = raw.replaceFirst('\uFEFF', '');
  return splitReaderTextLines(normalized);
}

/// Walks the parsed fragment and emits one canonical paragraph per block
/// boundary, `<br>`, or literal newline found inside a text node. Runs of
/// non-newline whitespace inside a segment are collapsed into a single
/// space.
List<String> _extractHtmlParagraphs(String raw) {
  final fragment = html_parser.parseFragment(raw.replaceFirst('\uFEFF', ''));
  final paragraphs = <String>[];
  final segment = StringBuffer();

  void flush() {
    final text = segment.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) paragraphs.add(text);
    segment.clear();
  }

  void walk(Iterable<dom.Node> nodes) {
    for (final child in nodes) {
      if (child is dom.Element) {
        if (_bookSourceBlockTags.contains(child.localName)) {
          flush();
          walk(child.nodes);
          flush();
          continue;
        }
        if (child.localName == 'br') {
          flush();
          continue;
        }
        walk(child.nodes);
      } else if (child is dom.Text) {
        // A literal newline inside a text node is the common shape for
        // sources that dump mostly-plain paragraphs inside a wrapping tag
        // (e.g. a chapter with one stray inline `<img>`/`<b>` and every
        // other paragraph separated only by `\n`). Treat it like an
        // implicit `<br>` so those paragraphs still get split instead of
        // being silently glued together by the `\s+` collapse in flush().
        final lines = splitReaderTextLines(child.data);
        for (var i = 0; i < lines.length; i++) {
          if (i > 0) flush();
          segment.write(lines[i]);
        }
      }
    }
  }

  walk(fragment.nodes);
  flush();
  // Degenerate payloads (image-only chapters, unclosed tags, comments) may
  // yield no extractable text; fall back to whatever the fragment exposes as
  // plain text so the reader never renders a blank page.
  if (paragraphs.isEmpty) {
    final fallback = fragment.text?.trim() ?? '';
    if (fallback.isNotEmpty) return [fallback];
  }
  return paragraphs;
}

List<String> _removeRepeatedLeadingChapterTitle(
  List<String> values,
  Set<String> chapterTitles,
) {
  final titleKeys = chapterTitles
      .map(_chapterTitleKey)
      .where((value) => value.isNotEmpty)
      .toSet();
  if (values.isEmpty || titleKeys.isEmpty) return values;
  final firstContentIndex = values.indexWhere(
    (value) => value.trim().isNotEmpty,
  );
  if (firstContentIndex < 0 ||
      !titleKeys.contains(_chapterTitleKey(values[firstContentIndex]))) {
    return values;
  }
  var bodyStart = firstContentIndex + 1;
  while (bodyStart < values.length && values[bodyStart].trim().isEmpty) {
    bodyStart++;
  }
  return values.sublist(bodyStart);
}

String _chapterTitleKey(String value) => value
    .replaceFirst(RegExp(r'^\s*#{1,6}\s*'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
