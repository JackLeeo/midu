import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../utils/debug_logger.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'legado_book_source.dart';
import 'legado_fjs_sandbox.dart';
import 'legado_request.dart';
import 'legado_rule_engine.dart';

class LegadoRuntime {
  LegadoRuntime({LegadoTransport? transport, LegadoJsSandbox? sandbox})
    : _transport = transport ?? LegadoHttpTransport(),
      _sandbox = sandbox ?? LegadoFjsSandbox();

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;

  final LegadoTransport _transport;
  final LegadoJsSandbox _sandbox;

  /// 与 [_sandbox] 共享同一实例：保证规则引擎 @put/@get 与 JS source.put/get
  /// 的变量在运行时与规则引擎间互通（此前各建一个实例导致变量互相不可见）。
  late final LegadoRuleEngine _rules = LegadoRuleEngine(sandbox: _sandbox);
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
    final logger = DebugLogger.instance;
    logger.log('search', '开始搜索', details: {
      'source': registered.name,
      'query': query,
      'page': page,
    });
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    logger.log('search', '搜索URL模板', details: {
      'source': source.name,
      'searchUrl': source.searchUrl,
    });
    final response = await _request(
      source,
      source.searchUrl,
      variables: {'key': query.trim(), 'page': '$page'},
    );
    logger.log('search', '搜索响应', details: {
      'source': source.name,
      'bodyLength': response.body.length,
    });
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final rule = source.rule('ruleSearch');
    logger.log('search', 'ruleSearch 规则', details: {
      'source': source.name,
      'bookList': _requiredRule(rule, 'bookList'),
      'name': _optionalRule(rule, 'name'),
      'bookUrl': _optionalRule(rule, 'bookUrl'),
    });
    final contexts = await _rules.evaluateList(
      document,
      null,
      _requiredRule(rule, 'bookList'),
    );
    logger.log('search', 'bookList 匹配数', details: {
      'source': source.name,
      'count': contexts.length,
    });
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(document, context, rule);
      if (book != null) books.add(book);
    }
    logger.log('search', '搜索结果', details: {
      'source': source.name,
      'books': books.length,
      'titles': books.map((b) => b.title).take(5).toList(),
    });
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
    final logger = DebugLogger.instance;
    logger.log('content', '开始加载章节', details: {
      'source': registered.name,
      'bookId': bookId,
      'chapterId': chapterId,
    });
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final rule = source.rule('ruleContent');
    logger.log('content', 'ruleContent 规则', details: {
      'source': source.name,
      'content': _optionalRule(rule, 'content'),
      'nextContentUrl': _optionalRule(rule, 'nextContentUrl'),
      'replaceRegex': _optionalRule(rule, 'replaceRegex'),
    });
    final parts = <String>[];
    final seenPages = <String>{};
    var nextUrl = chapterId;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      logger.log('content', '请求章节页面 (hop=$hop)', details: {
        'source': source.name,
        'url': nextUrl,
      });
      try {
        final response = await _request(source, nextUrl).timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw const BookSourceProtocolException(
                '章节内容请求超时（15秒）。',
              ),
        );
        logger.log('content', '章节页面响应', details: {
          'source': source.name,
          'bodyLength': response.body.length,
          'finalUri': response.finalUri.toString(),
        });
        final document = LegadoRuleDocument.parse(
          response.body,
          response.finalUri,
        );
        var content = await _value(document, null, rule, 'content', required: true);
        logger.log('content', '提取的内容长度', details: {
          'source': source.name,
          'contentLength': content.length,
          'preview': content.length > 200
              ? content.substring(0, 200)
              : content,
        });
        content = _rules.applyReplaceRule(
          content,
          _optionalRule(rule, 'replaceRegex'),
        );
        if (content.trim().isNotEmpty) parts.add(content.trim());
        nextUrl = await _url(document, null, rule, 'nextContentUrl');
      } catch (e, st) {
        logger.logError('content', '章节加载失败 (hop=$hop)', e, st);
        rethrow;
      }
    }
    if (parts.isEmpty) {
      logger.log('content', '章节内容为空', details: {
        'source': source.name,
        'chapterId': chapterId,
        'hops': _maxPageHops,
      });
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    logger.log('content', '章节加载成功', details: {
      'source': source.name,
      'parts': parts.length,
      'totalLength': parts.join('\n\n').length,
    });
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
    // 当 URL 模板或 header 中包含 @js / <js> 表达式，或 {{...}} 内嵌 JS 表达式
    // （如 {{java.connect(...)}}、{{source.get('k')}}）时，先通过 fjs 执行
    final processedTemplate = await _preprocessJsInString(
      template,
      variables: variables,
    );
    final rawHeaders = _sourceHeaders(source);
    final processedHeaders = <String, String>{};
    for (final entry in rawHeaders.entries) {
      processedHeaders[entry.key] = await _preprocessJsInString(
        entry.value,
        variables: variables,
      );
    }
    return _transport.send(
      LegadoRequestTemplate.parse(
        _expandSourceVars(processedTemplate),
        baseUri: source.baseUri,
        variables: variables,
        sourceHeaders: _expandHeaderVars(processedHeaders),
      ),
    );
  }

  /// 把 URL 模板中的 {{varName}}（@put 规则或 JS source.put 存入的变量）展开。
  /// 纯变量名才展开；JSON 路径（{{$.x}}）与查询变量（{{key}}/{{page}}）保持原样。
  String _expandSourceVars(String input) {
    return input.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (match) {
      final name = match.group(1)!.trim();
      if (name.isEmpty || !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) {
        return match.group(0)!;
      }
      final stored = _sandbox.getSourceVar(name);
      if (stored == null || stored.isEmpty) return match.group(0)!;
      return stored;
    });
  }

  Map<String, String> _expandHeaderVars(Map<String, String> headers) {
    if (headers.isEmpty) return headers;
    return headers.map((key, value) => MapEntry(key, _expandSourceVars(value)));
  }

  /// 检测字符串中是否包含 @js: 或 <js>…</js>，如是则交给 fjs 执行并返回结果；
  /// 同时处理 {{...}} 内嵌的 JS 表达式（{{java.xxx()}}、{{source.get('k')}} 等）。
  /// 否则原样返回。
  Future<String> _preprocessJsInString(
    String value, {
    Map<String, String> variables = const {},
  }) async {
    if (value.isEmpty) return value;
    final lower = value.toLowerCase();
    if (lower.contains('@js:') || lower.contains('<js>')) {
      try {
        final r = await _sandbox.evalJs(value);
        return r.isEmpty ? value : r;
      } catch (_) {
        return value;
      }
    }
    // 处理 {{...}} 内嵌 JS 表达式：仅当表达式中含 JS 调用/运算符时才交给 fjs。
    // 纯变量（{{key}}、{{page}}）保持原样，由 LegadoRequestTemplate 展开。
    if (!RegExp(r'\{\{[^{}]*\{\{').hasMatch(value) &&
        RegExp(r'(\{\{[^{}]*\b(java\.|source\.|Date\.|Math\.|String\.|global)\b[^{}]*\}\})',
                caseSensitive: false)
            .hasMatch(value)) {
      return _evalTemplateJsExpressions(value, variables);
    }
    return value;
  }

  Future<String> _evalTemplateJsExpressions(
    String value,
    Map<String, String> variables,
  ) async {
    final pattern = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');
    final matches = pattern.allMatches(value).toList(growable: false);
    if (matches.isEmpty) return value;
    var result = value;
    for (final match in matches.reversed) {
      final expression = match.group(1)!;
      final trimmed = expression.trim();
      if (trimmed.isEmpty) continue;
      // 纯变量/字面量不处理
      if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(trimmed) ||
          ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
              (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
        continue;
      }
      final evaluated = await _evalJsExpression(trimmed, variables);
      result = result.replaceRange(match.start, match.end, evaluated);
    }
    return result;
  }

  Future<String> _evalJsExpression(
    String expression,
    Map<String, String> variables,
  ) async {
    final globals = variables.map((key, value) => MapEntry(key, value));
    try {
      final code = '@js:finalResult = $expression;';
      final r = await _sandbox.evalJs(code, extraGlobals: globals);
      return r.trim();
    } catch (_) {
      return '';
    }
  }

  // ===== 发现页：exploreUrl + ruleExplore =====
  /// 米读：发现页完整重写，支持 Legado 书源的 exploreUrl 分类列表格式。
  ///
  /// 调用模式：
  /// - 不传 [exploreUrlOverride]：解析 source.exploreUrl 为分类列表，
  ///   每个分类作为 BookSourceDiscoveryItem（kind='category'），供用户选择。
  /// - 传入 [exploreUrlOverride]：请求对应分类 URL，用 ruleExplore 解析书籍列表。
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource registered, {
    String? exploreUrlOverride,
  }) async {
    final logger = DebugLogger.instance;
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    final urlText = exploreUrlOverride ?? source.exploreUrl;
    logger.log('discover', 'getDiscovery 调用', details: {
      'source': source.name,
      'exploreUrl': source.exploreUrl,
      'override': exploreUrlOverride,
      'hasRuleExplore': source.rule('ruleExplore').isNotEmpty,
    });
    if (urlText.trim().isEmpty) {
      logger.log('discover', 'exploreUrl 为空', details: {'source': source.name});
      throw const BookSourceProtocolException(
        'Compatible source does not provide an exploreUrl.',
      );
    }

    // 分支 A：带 override，请求分类页面并用 ruleExplore 解析书籍
    if (exploreUrlOverride != null) {
      return _fetchDiscoveryPage(source, exploreUrlOverride);
    }

    // 分支 B：解析 exploreUrl 为分类列表
    final categories = _parseExploreCategories(urlText);
    logger.log('discover', '解析分类列表', details: {
      'source': source.name,
      'categories': categories.length,
      'titles': categories.map((c) => c.title).take(10).toList(),
    });
    if (categories.isEmpty) {
      // 无分类列表时，直接当作单一 URL 请求
      return _fetchDiscoveryPage(source, urlText);
    }

    // 只有一个分类且 URL 为空时，也直接请求
    if (categories.length == 1 && categories.first.url.isEmpty) {
      return _fetchDiscoveryPage(source, urlText);
    }

    // 返回分类列表供 UI 展示
    final items = categories
        .where((cat) => cat.title.isNotEmpty || cat.url.isNotEmpty)
        .map((cat) => BookSourceDiscoveryItem(
              title: cat.title,
              subtitle: '',
              coverUrl: null,
              targetUrl: cat.url.isEmpty ? null : cat.url,
              kind: 'category',
              book: null,
            ))
        .toList(growable: false);
    return BookSourceDiscoveryPage(
      title: source.name,
      sections: [
        BookSourceDiscoverySection(
          title: source.name,
          items: items,
          layout: 'categories',
        ),
      ],
    );
  }

  /// 请求发现页分类 URL 并用 ruleExplore 解析书籍列表。
  Future<BookSourceDiscoveryPage> _fetchDiscoveryPage(
    LegadoBookSource source,
    String urlTemplate,
  ) async {
    final resolvedUrl = _resolveExploreUrlTemplate(urlTemplate, page: 1);
    final response = await _request(
      source,
      resolvedUrl,
      variables: const {'key': '', 'page': '1'},
    );
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final rule = source.rule('ruleExplore');

    final sections = <BookSourceDiscoverySection>[];

    // 优先用 ruleExplore 解析
    if (rule.isNotEmpty) {
      final listRule = _firstNonEmpty([
        _optionalRule(rule, 'bookList'),
        _optionalRule(rule, 'list'),
        '',
      ]);
      if (listRule.isNotEmpty) {
        final items = await _parseDiscoveryItems(document, rule, listRule);
        if (items.isNotEmpty) {
          sections.add(BookSourceDiscoverySection(
            title: source.name,
            items: items,
            layout: 'list',
          ));
        }
      }
    }

    // 兜底：用 ruleSearch.bookList 解析（兼容无 ruleExplore 的源）
    if (sections.isEmpty) {
      final searchRule = source.rule('ruleSearch');
      final listRule = _optionalRule(searchRule, 'bookList');
      if (listRule.isNotEmpty) {
        try {
          final items = await _parseDiscoveryItems(document, searchRule, listRule);
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
      nextPageUrl: null,
    );
  }

  Future<List<BookSourceDiscoveryItem>> _parseDiscoveryItems(
    LegadoRuleDocument document,
    Map<String, dynamic> rule,
    String listRule,
  ) async {
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
    return items;
  }

  /// 解析 exploreUrl 为分类列表。支持三种 Legado 格式：
  /// 1. JSON 数组：`[{"title":"...","url":"...","style":{...}},...]`
  /// 2. 多行文本：`标题::URL\n标题::URL\n...`（URL 可含 `<,...>` 分页语法）
  /// 3. JS 生成：`@js:...` 或 `<js>...</js>`（通过 fjs 执行返回 JSON 数组）
  List<_ExploreCategory> _parseExploreCategories(String exploreUrl) {
    final text = exploreUrl.trim();
    if (text.isEmpty) return const [];

    // 格式 1：JSON 数组
    if (text.startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) {
          return decoded
              .map((item) {
                if (item is! Map) return null;
                final title = '${item['title'] ?? ''}'.trim();
                final url = '${item['url'] ?? ''}'.trim();
                if (title.isEmpty && url.isEmpty) return null;
                return _ExploreCategory(title: title, url: url);
              })
              .whereType<_ExploreCategory>()
              .toList(growable: false);
        }
      } on FormatException {
        // 非 JSON，继续尝试其他格式
      }
    }

    // 格式 3：JS 生成（@js: 或 <js>）
    final lower = text.toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) {
      // JS 规则需要在 fjs 沙箱中执行，这里同步返回空，
      // 由调用方异步处理。为简化首版，JS 格式当作单一 URL 请求。
      return [_ExploreCategory(title: '', url: text)];
    }

    // 格式 2：多行文本（标题::URL）
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.length > 1 || text.contains('::')) {
      final categories = <_ExploreCategory>[];
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final sepIdx = trimmed.indexOf('::');
        if (sepIdx < 0) {
          // 无 :: 分隔符的行，如果像 URL 则当作单一 URL 分类
          if (trimmed.startsWith('http') || trimmed.startsWith('/')) {
            categories.add(_ExploreCategory(title: '', url: trimmed));
          }
          continue;
        }
        final title = trimmed.substring(0, sepIdx).trim();
        final url = trimmed.substring(sepIdx + 2).trim();
        if (title.isEmpty && url.isEmpty) continue;
        categories.add(_ExploreCategory(title: title, url: url));
      }
      if (categories.isNotEmpty) return categories;
    }

    // 兜底：当作单一 URL
    return [_ExploreCategory(title: '', url: text)];
  }

  /// 解析发现页 URL 模板，处理 Legado 特有的分页语法：
  /// - `{{page}}` 替换为页码
  /// - `<,index_{{page}}.html>` 表示在基础 URL 后追加 `index_{{page}}.html`
  ///   （`<,` 内部是追加部分，逗号后是分页模板）
  String _resolveExploreUrlTemplate(String template, {int page = 1}) {
    var result = template;
    // 处理 <,...> 分页语法：<,index_{{page}}.html> → index_{{page}}.html
    final pageTag = RegExp(r'<,([^>]*)>').firstMatch(result);
    if (pageTag != null) {
      final pagePart = pageTag.group(1)!.replaceAll('{{page}}', '$page');
      result = result.replaceFirst(pageTag.group(0)!, pagePart);
    }
    // 替换 {{page}}
    result = result.replaceAll('{{page}}', '$page');
    return result;
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
    // 米读：只有 unsupported 级别（音频/视频/登录/自定义DNS代理/缺搜索缺规则）
    // 才阻塞运行；partial 级别（含 JS/XPath/Cookies 等）通过 fjs 沙箱可正常运行。
    if (report.level == LegadoCompatibilityLevel.unsupported) {
      throw const BookSourceProtocolException(
        'This source uses unsupported features (audio/video/login/custom DNS/proxy/missing rules).',
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

/// 发现页分类条目（标题 + URL 模板）。
class _ExploreCategory {
  const _ExploreCategory({required this.title, required this.url});

  final String title;
  final String url;
}
