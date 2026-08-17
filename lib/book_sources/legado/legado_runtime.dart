import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'legado_book_source.dart';
import 'legado_fjs_sandbox.dart';
import 'legado_request.dart';
import 'legado_rule_engine.dart';

class LegadoRuntime {
  LegadoRuntime({LegadoTransport? transport, LegadoFjsSandbox? sandbox})
    : _transport = transport ?? LegadoHttpTransport(),
      _sandbox = sandbox ?? LegadoFjsSandbox(),
      _rules = LegadoRuleEngine(sandbox: sandbox ?? LegadoFjsSandbox());

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;

  final LegadoTransport _transport;
  final LegadoFjsSandbox _sandbox;
  final LegadoRuleEngine _rules;
  bool _sandboxInited = false;

  Future<void> _ensureSandbox() async {
    if (_sandboxInited) return;
    await _sandbox.init();
    _sandboxInited = true;
  }

  void close({bool force = true}) {
    final transport = _transport;
    if (transport is LegadoHttpTransport) transport.close(force: force);
    _sandbox.dispose();
    _sandboxInited = false;
  }

  Future<BookSourceSearchPage> search(
    RegisteredBookSource registered,
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final response = await _request(
      source,
      source.searchUrl,
      variables: {'key': query.trim(), 'page': '$page'},
    );
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final rule = source.rule('ruleSearch');
    final contexts = await _rules.evaluateList(
      document,
      null,
      _requiredRule(rule, 'bookList'),
    );
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(document, context, rule);
      if (book != null) books.add(book);
    }
    return BookSourceSearchPage(
      items: books.take(pageSize).toList(growable: false),
      page: page,
      pageSize: pageSize,
      hasMore: books.length > pageSize,
    );
  }

  Future<BookSourceBook> getBook(
    RegisteredBookSource registered,
    String bookId,
  ) async {
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final response = await _request(source, bookId);
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final rule = source.rule('ruleBookInfo');
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(document, null, init)).firstOrNull;
    final title = await _value(document, context, rule, 'name');
    if (title.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return a book title.',
      );
    }
    return BookSourceBook(
      id: response.finalUri.toString(),
      title: title,
      author: await _value(document, context, rule, 'author'),
      description: await _value(document, context, rule, 'intro'),
      coverUrl: await _uriValue(document, context, rule, 'coverUrl'),
      categories: _splitCategories(await _value(document, context, rule, 'kind')),
      status: _nullable(await _value(document, context, rule, 'status')),
      latestChapter: _nullable(await _value(document, context, rule, 'lastChapter')),
    );
  }

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId,
  ) async {
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final tocUrl = await _tocUrl(source, bookId);
    final rule = source.rule('ruleToc');
    final chapters = <BookSourceChapter>[];
    final seenPages = <String>{};
    final seenChapters = <String>{};
    var nextUrl = tocUrl;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(source, nextUrl);
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      final contexts = await _rules.evaluateList(
        document,
        null,
        _requiredRule(rule, 'chapterList'),
      );
      for (final context in contexts) {
        final title = await _value(document, context, rule, 'chapterName');
        final url = await _url(document, context, rule, 'chapterUrl');
        if (title.isEmpty || url.isEmpty || !seenChapters.add(url)) continue;
        if (chapters.length >= _maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        chapters.add(
          BookSourceChapter(id: url, title: title, order: chapters.length),
        );
      }
      nextUrl = await _url(document, null, rule, 'nextTocUrl');
    }
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
  }) async {
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final rule = source.rule('ruleContent');
    final parts = <String>[];
    final seenPages = <String>{};
    var nextUrl = chapterId;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(source, nextUrl);
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      var content = await _value(document, null, rule, 'content', required: true);
      content = _rules.applyReplaceRule(
        content,
        _optionalRule(rule, 'replaceRegex'),
      );
      if (content.trim().isNotEmpty) parts.add(content.trim());
      nextUrl = await _url(document, null, rule, 'nextContentUrl');
    }
    if (parts.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: '',
      content: parts.join('\n\n'),
      contentType: 'text/html',
    );
  }

  Future<String> _tocUrl(LegadoBookSource source, String bookId) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final response = await _request(source, bookId);
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(document, null, init)).firstOrNull;
    return _rules.evaluateString(document, context, tocRule, resolveUrl: true);
  }

  Future<BookSourceBook?> _bookFromRules(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rule,
  ) async {
    final title = await _value(document, context, rule, 'name');
    final url = await _url(document, context, rule, 'bookUrl');
    if (title.isEmpty || url.isEmpty) return null;
    return BookSourceBook(
      id: url,
      title: title,
      author: await _value(document, context, rule, 'author'),
      description: await _value(document, context, rule, 'intro'),
      coverUrl: await _uriValue(document, context, rule, 'coverUrl'),
      categories: _splitCategories(await _value(document, context, rule, 'kind')),
      latestChapter: _nullable(await _value(document, context, rule, 'lastChapter')),
    );
  }

  Future<LegadoResponse> _request(
    LegadoBookSource source,
    String template, {
    Map<String, String> variables = const {},
  }) async {
    await _ensureSandbox();
    // ===== 米读：before-send JS 预处理 =====
    // 当 URL 模板或 header 中包含 @js / <js> 表达式时，先通过 fjs 执行
    // （Legado 书源常用 java.crypto.md5Encode 构造签名、cookie 计算等）
    final processedTemplate = await _preprocessJsInString(template);
    final rawHeaders = _sourceHeaders(source);
    final processedHeaders = <String, String>{};
    for (final entry in rawHeaders.entries) {
      processedHeaders[entry.key] = await _preprocessJsInString(entry.value);
    }
    return _transport.send(
      LegadoRequestTemplate.parse(
        processedTemplate,
        baseUri: source.baseUri,
        variables: variables,
        sourceHeaders: processedHeaders,
      ),
    );
  }

  /// 检测字符串中是否包含 @js: 或 <js>…</js>，如是则交给 fjs 执行并返回结果；
  /// 否则原样返回。
  Future<String> _preprocessJsInString(String value) async {
    if (value.isEmpty) return value;
    final lower = value.toLowerCase();
    if (!lower.contains('@js:') && !lower.contains('<js>')) return value;
    try {
      final r = await _sandbox.evalJs(value);
      return r.isEmpty ? value : r;
    } catch (_) {
      return value;
    }
  }

  // ===== 发现页：exploreUrl + ruleExplore =====
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource registered, {
    String? exploreUrlOverride,
  }) async {
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final urlText = exploreUrlOverride ?? source.exploreUrl;
    if (urlText.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source does not provide an exploreUrl.',
      );
    }
    final response = await _request(source, urlText);
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final rule = source.rule('ruleExplore');

    final sections = <BookSourceDiscoverySection>[];

    // 优先尝试 ruleExplore 结构化字段：bookList / titleList / urlList
    if (rule.isNotEmpty) {
      // 模式 1：列表选择器（一维数组，每个元素是 book/url 块）
      final listRule = _firstNonEmpty([
        _optionalRule(rule, 'bookList'),
        _optionalRule(rule, 'list'),
        '',
      ]);
      if (listRule.isNotEmpty) {
        final contexts = await _rules.evaluateList(document, null, listRule);
        final items = <BookSourceDiscoveryItem>[];
        for (final ctx in contexts) {
          final title = await _value(document, ctx, rule, 'name');
          final url = await _url(document, ctx, rule, 'bookUrl');
          if (title.isEmpty && url.isEmpty) continue;
          final book = (title.isNotEmpty && url.isNotEmpty)
              ? BookSourceBook(
                  id: url,
                  title: title,
                  author: await _value(document, ctx, rule, 'author'),
                  description: await _value(document, ctx, rule, 'intro'),
                  coverUrl: await _uriValue(document, ctx, rule, 'coverUrl'),
                  latestChapter: _nullable(
                    await _value(document, ctx, rule, 'lastChapter'),
                  ),
                )
              : null;
          items.add(BookSourceDiscoveryItem(
            title: title,
            subtitle: await _value(document, ctx, rule, 'author'),
            coverUrl: await _uriValue(document, ctx, rule, 'coverUrl'),
            targetUrl: url.isEmpty ? null : url,
            kind: book != null ? 'book' : 'link',
            book: book,
          ));
        }
        if (items.isNotEmpty) {
          sections.add(BookSourceDiscoverySection(
            title: source.name,
            items: items,
            layout: 'list',
          ));
        }
      }
    }

    // 兜底：从搜索规则 bookList 中抽取（兼容无 exploreRule 的源）
    if (sections.isEmpty) {
      final searchRule = source.rule('ruleSearch');
      final listRule = _optionalRule(searchRule, 'bookList');
      if (listRule.isNotEmpty) {
        try {
          final contexts = await _rules.evaluateList(document, null, listRule);
          final items = <BookSourceDiscoveryItem>[];
          for (final ctx in contexts) {
            final title = await _value(document, ctx, searchRule, 'name');
            final url = await _url(document, ctx, searchRule, 'bookUrl');
            if (title.isEmpty && url.isEmpty) continue;
            final book = (title.isNotEmpty && url.isNotEmpty)
                ? BookSourceBook(
                    id: url,
                    title: title,
                    author: await _value(document, ctx, searchRule, 'author'),
                    coverUrl: await _uriValue(
                      document,
                      ctx,
                      searchRule,
                      'coverUrl',
                    ),
                    latestChapter: _nullable(
                      await _value(document, ctx, searchRule, 'lastChapter'),
                    ),
                  )
                : null;
            items.add(BookSourceDiscoveryItem(
              title: title,
              subtitle: await _value(document, ctx, searchRule, 'author'),
              coverUrl: await _uriValue(document, ctx, searchRule, 'coverUrl'),
              targetUrl: url.isEmpty ? null : url,
              kind: book != null ? 'book' : 'link',
              book: book,
            ));
          }
          if (items.isNotEmpty) {
            sections.add(BookSourceDiscoverySection(
              title: source.name,
              items: items,
              layout: 'list',
            ));
          }
        } catch (_) {
          // 兜底失败继续
        }
      }
    }

    return BookSourceDiscoveryPage(
      title: source.name,
      sections: List.unmodifiable(sections),
    );
  }

  Map<String, String> _sourceHeaders(LegadoBookSource source) {
    final raw = source.raw['header'];
    if (raw == null || '$raw'.trim().isEmpty) return const {};
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw const BookSourceProtocolException(
          'Compatible source headers must be valid JSON.',
        );
      }
    }
    if (decoded is! Map) {
      throw const BookSourceProtocolException(
        'Compatible source headers must be an object.',
      );
    }
    final headers = <String, String>{};
    for (final entry in decoded.entries) {
      final name = '${entry.key}'.trim();
      // 米读：由于巨魔/自签安装，放开 Cookie header 限制
      if (name.isEmpty || entry.value is! String) {
        throw const BookSourceProtocolException(
          'Compatible source headers must contain text values.',
        );
      }
      headers[name] = entry.value as String;
    }
    return headers;
  }

  LegadoBookSource _source(RegisteredBookSource registered) {
    if (registered.sourceProtocol != BookSourceProtocolKind.legado ||
        registered.sourceConfig == null) {
      throw const BookSourceProtocolException(
        'This is not a compatible source configuration.',
      );
    }
    return LegadoBookSource.fromJson(registered.sourceConfig!);
  }

  void _ensureRunnable(LegadoBookSource source) {
    final report = const LegadoCompatibilityScanner().scan(source);
    final blockedIssues = report.issues.where(
      (issue) => issue != LegadoCompatibilityIssue.complexJsonPath,
    );
    if (blockedIssues.isNotEmpty) {
      throw const BookSourceProtocolException(
        'This compatible source uses features that are not supported yet.',
      );
    }
    final headers = _sourceHeaders(source);
    LegadoRequestTemplate.parse(
      source.searchUrl,
      baseUri: source.baseUri,
      variables: const {'key': 'preflight', 'page': '1'},
      sourceHeaders: headers,
    );
    for (final groupName in const [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ]) {
      for (final entry in source.rule(groupName).entries) {
        if (entry.value is String) {
          LegadoRuleEngine.ensureSupported(
            entry.value as String,
            field: '$groupName.${entry.key}',
          );
        }
      }
    }
  }

  Future<String> _value(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    bool required = false,
  }) async {
    final rule = required
        ? _requiredRule(rules, key)
        : _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateString(document, context, rule);
  }

  Future<String> _url(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final rule = _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateString(document, context, rule, resolveUrl: true);
  }

  Future<Uri?> _uriValue(
    LegadoRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final value = await _url(document, context, rules, key);
    return value.isEmpty ? null : Uri.tryParse(value);
  }
}

String _requiredRule(Map<String, dynamic> rules, String key) {
  final rule = _optionalRule(rules, key);
  if (rule.isEmpty) {
    throw BookSourceProtocolException(
      'Compatible source is missing the $key rule.',
    );
  }
  return rule;
}

String _optionalRule(Map<String, dynamic> rules, String key) {
  final value = rules[key];
  return value is String ? value.trim() : '';
}

String? _nullable(String value) => value.trim().isEmpty ? null : value.trim();

List<String> _splitCategories(String value) => value
    .split(RegExp(r'[,/|\s]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

String stableLegadoResourceId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 24);

/// 返回列表中第一个非空字符串；全空则返回空串。
String _firstNonEmpty(List<String> candidates) {
  for (final s in candidates) {
    if (s.isNotEmpty) return s;
  }
  return '';
}
