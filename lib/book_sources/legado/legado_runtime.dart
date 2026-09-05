import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../utils/debug_logger.dart';
import '../../services/webview_guard/web_browser_fallback.dart';
import '../../services/webview_guard/webview_gateway_factory.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_source_cookie_store.dart';
import '../services/book_source_debug_recorder.dart';
import '../services/book_source_network_policy.dart';
import '../services/comic_image_url_parser.dart';
import 'legado_book_source.dart';
import 'legado_ajax_rewrite.dart';
import 'legado_fjs_sandbox.dart';
import 'legado_request.dart';
import 'legado_rule_engine.dart';

class LegadoRuntime {
  LegadoRuntime({
    LegadoTransport? transport,
    LegadoJsSandbox? sandbox,
    // 浏览器兜底池：`@webBrowser:/@webView:` 或请求选项 `webView:true` 时执行
    // 路由。测试可注入 mock 池；默认按平台分发（桌面/Web 降级不可用）。
    WebBrowserPool? webBrowserPool,
    // 默认开启 java.ajax / java.connect 接入：走「eval 前改写 + 内联响应」，
    // 同时支持字面量与动态第一参数（如 JSON.parse(result).data.xxx）。只对规则
    // 实际含 java. 调用的源产生改写与一次预取，非 JS 源零开销。
    this.enableAjaxBridge = true,
    // 书源调试记录器：由书源调试页注入（独立 BookSourceClient），正常阅读链路
    // 不传，保持既有行为与零额外开销。
    this.debugRecorder,
    // 登录 Cookie 持久化后端：传给默认 HTTP 传输，使源登录后 Set-Cookie 可
    // 跨 App 重启继续携带（对标 Legado CookieStore）。测试可注入 null 关闭。
    this.cookieStore,
  }) : _transport = transport ?? LegadoHttpTransport(cookieStore: cookieStore),
       _sandbox = sandbox ?? LegadoFjsSandbox(),
       webBrowserPool = webBrowserPool ??
           WebBrowserPool(createGateway: defaultWebBrowserGateway);

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;

  /// 浏览器的默认请求头。部分站点按 UA 中是否含移动端标记来决定是否返回完整
  /// HTML：无浏览器 UA（Dart 默认）时只返回截断的分页预览，导致章节正文不全。
  /// 源的头可在 [_request] 中逐一覆盖，这里仅为兜底。
  static const Map<String, String> _defaultBrowserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  /// 是否给沙箱接入 java.ajax / java.connect 网络执行器。
  /// 开启走「eval 前改写 + 内联响应」，支持字面量与动态第一参数两种 URL
  /// （见 legado_ajax_rewrite.rewriteAjaxCalls），用于强 JS 源（灯读/得间/花生
  /// 等「目录/正文依赖 java.ajax 补全」）的真实请求还原。
  final bool enableAjaxBridge;

  /// 书源调试记录器（可空）：注入后 [_request]/[_rawFetch]/[fetchImageBytes] 会
  /// 把请求/响应/错误写入其中供调试页展示。正常阅读链路不注入，零副作用。
  final BookSourceDebugRecorder? debugRecorder;

  /// 登录 Cookie 持久化后端：传给默认 HTTP 传输，使源登录后 Set-Cookie 可
  /// 跨 App 重启继续携带（对标 Legado CookieStore）。测试可注入 null 关闭。
  final BookSourceCookieStore? cookieStore;

  /// 浏览器兜底池（`@webBrowser:/@webView:` 路由目标）。
  final WebBrowserPool webBrowserPool;

  /// 浏览器兜底出站的 SSRF 策略：与 HTTP 传输层保持同参（允许合成 DNS、
  /// 默认禁私有网段），WebView 发出的每个 URL 都先过 validate 再放行（R3）。
  final BookSourceNetworkPolicy _webViewNetworkPolicy =
      const BookSourceNetworkPolicy(allowSyntheticDns: true);

  final LegadoTransport _transport;
  final LegadoJsSandbox _sandbox;

  /// 与 [_sandbox] 共享同一实例：保证规则引擎 @put/@get 与 JS source.put/get
  /// 的变量在运行时与规则引擎间互通（此前各建一个实例导致变量互相不可见）。
  late final LegadoRuleEngine _rules = LegadoRuleEngine(sandbox: _sandbox);
  bool _sandboxInited = false;

  Future<void> _ensureSandbox() async {
    if (_sandboxInited) return;
    await _sandbox.init();
    // 给沙箱接入 java.ajax / java.connect 网络执行器，复用请求层解码。
    // 生产 fjs 与本地 flutter_js 沙箱都实现 AjaxFetcherSink。
    if (enableAjaxBridge && _sandbox is AjaxFetcherSink) {
      (_sandbox as AjaxFetcherSink).setAjaxFetcher(_rawFetch);
    }
    // 预加载书源 jsLib：jsLib 是 Legado 语义的「公共 JS 脚本」，需先于任何
    // @js / <js> 规则执行注册，保证规则里能直接调用其中声明的函数。
    // 注：当前方法不持有书源对象，jsLib 触发点放在每个源首次求值前
    // （_evalJsPair / _evalJsExpression 入口统一处理，见 _ensureJsLibForSource）。
    _sandboxInited = true;
  }

  /// java.ajax / java.connect 的原始抓取：构造请求并复用请求层（含内容自适应
  /// 解码）。失败返回空串（与旧行为一致，不抛错炸掉规则）。
  Future<String> _rawFetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
  }) async {
    final recorder = debugRecorder;
    final order = recorder?.recordRequest(
      stage: BookSourceDebugStage.js,
      sourceName: 'JS',
      url: url,
      method: method.toUpperCase(),
      body: body,
      headers: headers,
    );
    final stopwatch = Stopwatch()..start();
    try {
      final isPost = method.trim().toUpperCase() == 'POST';
      final response = await _transport.send(
        LegadoRequestTemplate(
          url: Uri.parse(url),
          method: isPost
              ? LegadoRequestMethod.post
              : LegadoRequestMethod.get,
          headers: headers ?? const {},
          charset: 'utf-8',
          body: isPost ? body : null,
        ),
      );
      stopwatch.stop();
      recorder?.recordResponse(
        stage: BookSourceDebugStage.js,
        sourceName: 'JS',
        order: order ?? 0,
        statusCode: response.statusCode ?? 0,
        headers: response.headers,
        url: response.finalUri.toString(),
        elapsedMs: stopwatch.elapsedMilliseconds,
        preview: debugPreview(response.body),
      );
      return response.body;
    } catch (e) {
      stopwatch.stop();
      recorder?.recordError(
        stage: BookSourceDebugStage.js,
        sourceName: 'JS',
        order: order,
        message:
            'java.ajax/java.connect 执行失败：$e（改强势 JS 源受沙箱限制时为空串）',
        url: url,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return '';
    }
  }

  void close({bool force = true}) {
    final transport = _transport;
    if (transport is LegadoHttpTransport) transport.close(force: force);
    unawaited(webBrowserPool.closeAll());
    _sandbox.dispose();
    _sandboxInited = false;
  }

  // ===== 书源调试辅助（BookSourceDebugPage 使用） =====

  /// 在沙箱中执行一段 JS（可带 `@js:` / `<js>` 标记），返回寄存器/完成值字符串，
  /// 并把结果写入调试记录器（若有）。用于调试页「JS 单测」分区。
  Future<String> debugEvalJs({
    required String code,
    required String sourceName,
    String? docHtml,
    Uri? baseUri,
    Map<String, dynamic> extraGlobals = const {},
  }) async {
    await _ensureSandbox();
    final recorder = debugRecorder;
    final result = await _sandbox.evalJs(
      code,
      docHtml: docHtml,
      baseUri: baseUri,
      extraGlobals: extraGlobals,
    );
    recorder?.recordRuleResult(
      stage: BookSourceDebugStage.js,
      sourceName: sourceName,
      message: result.isEmpty ? '（空结果）' : result,
    );
    return result;
  }

  /// 调试页「规则单测」：给一段（HTML/JSON）正文与基准 URI，按单条规则求值，
  /// 返回匹配到的值列表（无匹配返回空列表，求值异常也返回空列表，不抛错）。
  Future<List<Object?>> debugEvaluateRule(
    String body,
    Uri baseUri,
    String rule,
  ) async {
    if (rule.trim().isEmpty) return const [];
    await _ensureSandbox();
    try {
      final document = LegadoRuleDocument.parse(body, baseUri);
      return await _rules.evaluateList(document, null, rule);
    } catch (_) {
      return const [];
    }
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
    await _ensureJsLib(source);
    logger.log('search', '搜索URL模板', details: {
      'source': source.name,
      'searchUrl': source.searchUrl,
    });
    final response = await _request(
      source,
      source.searchUrl,
      variables: {'key': query.trim(), 'page': '$page'},
      debugStage: BookSourceDebugStage.search,
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
    debugRecorder?.recordInfo(
      stage: BookSourceDebugStage.search,
      sourceName: source.name,
      message: 'ruleSearch.bookList 匹配到 ${contexts.length} 条',
    );
    logger.log('search', 'bookList 匹配数', details: {
      'source': source.name,
      'count': contexts.length,
    });
    final books = <BookSourceBook>[];
    final bookListRule = _requiredRule(rule, 'bookList');
    if (contexts.isEmpty && !_isJsListRule(bookListRule)) {
      // 单本兜底：部分站点的关键字搜索会直接 302 到书籍详情页（四五中文、
      // 得间/花生等无搜索结果列表），此时 bookList 匹配为 0。改用详情规则把
      // 当前响应解析为唯一一本书，避免「搜索空 → 进不了详情」的死路。
      // 注意：bookList 为 <js> 生成（JSON 接口源，如菠萝漫画）时，空数组即「确
      // 无结果」，不应走详情兜底，否则会把整页 JSON 当单本详情解析而报错。
      final book = await _singleBookFromSearch(document, source);
      if (book != null) books.add(book);
    } else if (contexts.isNotEmpty) {
      for (final context in contexts.take(_maxSearchItems)) {
        final book = await _bookFromRules(document, context, rule);
        if (book != null) books.add(book);
      }
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
    String bookId, {
    BookSourceBook? seedBook,
  }) async {
    await _ensureSandbox();
    _seedVarsFromBookId(bookId);
    final source = _source(registered);
    _ensureRunnable(source);
    await _ensureJsLib(source);
    final response = await _request(
      source,
      bookId,
      debugStage: BookSourceDebugStage.bookInfo,
    );
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final rule = source.rule('ruleBookInfo');
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(document, null, init)).firstOrNull;
    var title = await _value(document, context, rule, 'name');
    // 米读：Legado 语义——ruleBookInfo.name 为空时回退到搜索结果的信息。
    // 部分源详情规则未写 name/author（如天地/圣墟/宜搜仅含 tocUrl 或以 @js 取书名），
    // 若不继承搜索点位则详情永远取不到书名。
    var author = await _value(document, context, rule, 'author');
    var intro = await _value(document, context, rule, 'intro');
    var coverUrl = await _uriValue(document, context, rule, 'coverUrl');
    // 以 search 结果字段兜底细节页缺失的元信息。
    if (title.isEmpty && seedBook != null && seedBook.title.isNotEmpty) {
      title = seedBook.title;
    }
    if (title.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return a book title.',
      );
    }
    if (seedBook != null) {
      if (author.isEmpty) author = seedBook.author;
      if (intro.isEmpty) intro = seedBook.description ?? '';
      coverUrl ??= seedBook.coverUrl;
    }
    return BookSourceBook(
      id: response.finalUri.toString(),
      title: title,
      author: author,
      description: intro,
      coverUrl: coverUrl,
      categories: _splitCategories(await _value(document, context, rule, 'kind')),
      status: _nullable(await _value(document, context, rule, 'status')),
      latestChapter: _nullable(await _value(document, context, rule, 'lastChapter')),
    );
  }

  /// [normalizeChapterOrder] 开关仅供诊断/取证：生产始终开启归一化，诊断脚本
  /// 传 false 取原始目录顺序以核对源端真实结构（不影响生产行为，默认 true）。
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    bool normalizeChapterOrder = true,
  }) async {
    await _ensureSandbox();
    _seedVarsFromBookId(bookId);
    final source = _source(registered);
    _ensureRunnable(source);
    await _ensureJsLib(source);
    final tocUrl = await _tocUrl(source, bookId);
    final rule = source.rule('ruleToc');
    final chapters = <BookSourceChapter>[];
    final seenPages = <String>{};
    final seenChapters = <String>{};
    var nextUrl = tocUrl;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(
        source,
        nextUrl,
        debugStage: BookSourceDebugStage.toc,
      );
      DebugLogger.instance.log('toc', 'toc请求', details: {
        'url': nextUrl,
        'len': response.body.length,
        'gid': _sandbox.getSourceVar('gid'),
        'nid': _sandbox.getSourceVar('nid'),
      });
      final document = LegadoRuleDocument.parse(
        response.body,
        response.finalUri,
      );
      final contexts = await _rules.evaluateList(
        document,
        null,
        _requiredRule(rule, 'chapterList'),
      );
      debugRecorder?.recordInfo(
        stage: BookSourceDebugStage.toc,
        sourceName: source.name,
        message: 'ruleToc.chapterList 匹配到 ${contexts.length} 条 (hop=$hop)',
      );
      DebugLogger.instance.log('toc', 'chapterList 匹配数', details: {
        'count': contexts.length,
        'bodyHead': response.body.length > 120
            ? response.body.substring(0, 120)
            : response.body,
      });
      var addedThisHop = 0;
      for (final context in contexts) {
        final title = await _value(document, context, rule, 'chapterName');
        // 单章 URL 解析异常（末页占位链接 href="javascript:void(0)" 等多页目录
        // 源常见）只跳过该章，不让整份目录失败。
        String url;
        try {
          url = await _url(document, context, rule, 'chapterUrl');
        } on BookSourceProtocolException {
          continue;
        }
        if (title.isEmpty || url.isEmpty || !seenChapters.add(url)) continue;
        addedThisHop++;
        if (chapters.length >= _maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        chapters.add(
          BookSourceChapter(id: url, title: title, order: chapters.length),
        );
      }
      // 空翻页保护：本页未解析出任何新章节（末页占位/分页规则失效）且目录已有
      // 内容时提前终止，避免无进展地翻满 _maxPageHops 制造无谓请求与卡顿。
      if (addedThisHop == 0 && chapters.isNotEmpty) break;
      try {
        nextUrl = await _url(document, null, rule, 'nextTocUrl');
        final nextUri = Uri.tryParse(nextUrl);
        if (nextUrl.isNotEmpty &&
            (nextUri == null ||
                (nextUri.scheme != 'http' && nextUri.scheme != 'https'))) {
          nextUrl = ''; // 末页占位链接（javascript:... 等），视为没有下一页
        }
      } on BookSourceProtocolException {
        nextUrl = '';
      }
    }
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    // 部分源目录会整表倒序，或在顶部插入最近更新章节（随后的才是第 1 章起）；
    // 依据章节名中提取到的序号做归一化，保证按故事顺序返回。
    return normalizeChapterOrder
        ? _normalizeChapterOrder(chapters)
        : _renumber(chapters);
  }

  /// 从章节名中提取首个数字序号，兼容阿拉伯数字与中文数字：
  /// 「第123章」= 123、「第2章」= 2、「第一百二十三章」= 123、「第四千五百六十二章」= 4562。
  /// 无法识别时返回 null。
  static int? _extractChapterOrdinal(String title) {
    // 1) 阿拉伯数字：优先「第N章/节」，退而取「像序号」的数字串。
    final arabic = _arabicChapter.firstMatch(title);
    if (arabic != null && arabic.group(1) != null) {
      final v = int.tryParse(arabic.group(1)!);
      if (v != null) return v;
    } else {
      final any = _arabicAny.firstMatch(title);
      if (any != null && _looksLikeOrdinal(title, any.start)) {
        final v = int.tryParse(any.group(0)!);
        if (v != null) return v;
      }
    }
    // 2) 中文数字：优先「第X章/节/回/话」，退而取「像序号」的中文数字串。
    final ch = _chineseChapter.firstMatch(title);
    if (ch != null && ch.group(1) != null) {
      final token = ch.group(1)!;
      if (token.isNotEmpty) return _chineseToArabic(token);
    }
    final anyCn = _chineseAny.firstMatch(title);
    if (anyCn != null && _looksLikeOrdinal(title, anyCn.start)) {
      final token = anyCn.group(0)!;
      if (token.isNotEmpty) return _chineseToArabic(token);
    }
    return null;
  }

  /// 宽松回退（无「第X章」前缀的裸数字串）是否为「像章节序号」的位置：
  /// 必须位于标题开头，或紧跟在「第」/空白/括号/点号/分隔符之后。
  /// 避免把正文词语中夹带的数字误判为章号（如「关于一点细节」里的「一」、
  /// 「第104章里的1」等），这正是 zzs5 公告标题导致目录错乱的根因。
  static bool _looksLikeOrdinal(String title, int start) {
    if (start <= 0) return true;
    final prev = title[start - 1];
    return prev == '第' ||
        prev == ' ' ||
        prev == '\u3000' ||
        prev == '(' ||
        prev == '（' ||
        prev == '[' ||
        prev == '【' ||
        prev == '.' ||
        prev == '。' ||
        prev == '、' ||
        prev == '·' ||
        prev == ':';
  }

  static final RegExp _arabicChapter = RegExp(r'第(\d+)(?:章|节|回|话)?');
  static final RegExp _arabicAny = RegExp(r'\d+');
  static final RegExp _chineseChapter =
      RegExp(r'第([零一二三四五六七八九十百千万]+)(?:章|节|回|话)?');
  static final RegExp _chineseAny = RegExp(r'[零一二三四五六七八九十百千万]+');

  static const Map<String, int> _cnDigits = {
    '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    '十': 10, '百': 100, '千': 1000, '万': 10000,
  };

  /// 中文数字串 → 阿拉伯数字。支持「四千五百六十二」= 4562、「二十三」= 23、
  /// 「十」= 10、「一百一十」= 110。解析失败返回 null。
  static int? _chineseToArabic(String s) {
    var result = 0;
    var section = 0; // 万以内的累加段
    var num = 0;     // 当前数字位
    for (final ch in s.split('')) {
      final v = _cnDigits[ch];
      if (v == null) return null;
      if (v <= 9) {
        num = v;
      } else if (v == 10000) {
        section = (section + num) * 10000;
        result += section;
        section = 0;
        num = 0;
      } else {
        // 十/百/千：若之前无数位（如『十』），按 1 计。
        section += (num == 0 ? 1 : num) * v;
        num = 0;
      }
    }
    return result + section + num;
  }

  /// 依据序号把目录归一化为「第 1 章在前」的顺序，并重排 order 字段。
  ///
  /// 处理两类异常：
  ///  1. 整表倒序（如 [.., 第3章, 第2章, 第1章]）→ 整体反转。
  ///  2. 顶部堆了一段「后续/最新章节或公告」之后才从第 1 章起（如
  ///     [第100章..第96章, 公告, 第1章..第95章]）→ 找到重启边界，把顶部非
  ///     正文的堆块移到末尾，使第 1 章回到最前。
  /// 其余正常情况原样返回。
  List<BookSourceChapter> _normalizeChapterOrder(
    List<BookSourceChapter> raw,
  ) {
    if (raw.length <= 6) return raw;
    final ord = raw
        .map((c) => _extractChapterOrdinal(c.title))
        .toList(growable: false);
    final n = raw.length;

    var decreasingPairs = 0;
    var comparablePairs = 0;
    for (var i = 0; i + 1 < n; i++) {
      final a = ord[i];
      final b = ord[i + 1];
      if (a == null || b == null) continue;
      comparablePairs++;
      if (a > b) decreasingPairs++;
    }
    // 1) 整表倒序：绝大多数相邻对是递减。
    if (comparablePairs >= 3 && decreasingPairs * 10 >= comparablePairs * 6) {
      return _renumber(raw.reversed.toList());
    }

    // 2) 顶部堆块：寻找「从低序号（第 1、2 章）重新开始、其后单调递增」的
    //    边界 k（取最早的一处），把 [0..k) 堆块移到末尾。要求堆块里确实存在
    //    更大的章号（>2），避免把正常源的开头误判成堆块。
    final maxPrefix = math.min(40, n ~/ 2);
    for (var k = 1; k <= maxPrefix; k++) {
      final restart = ord[k];
      if (restart == null || restart > 2) continue;
      // 堆块 [0..k) 里必须至少有一个章号 > 2（说明顶部确实堆了后续章节）。
      if (headHasOnlyPrefaceOrdinals(ord, k)) continue;
      // 确认 k..n 从低序号起"基本单调递增"：允许极少量倒序（长目录常因
      // 分卷/番外等出现零星序号回跳）。超过 5% 的相邻对递减则视为不成立。
      var suffixComparable = 0;
      var suffixDecreasing = 0;
      int? prev;
      for (var i = k; i < n; i++) {
        final o = ord[i];
        if (o == null) continue;
        if (prev != null) {
          suffixComparable++;
          if (o < prev) suffixDecreasing++;
        }
        prev = o;
      }
      if (suffixComparable >= 2 &&
          suffixDecreasing * 20 > suffixComparable) {
        continue;
      }
      final prefix = raw.sublist(0, k);
      final rp = ord.sublist(0, k);
      final prefixAdjusted = _reorderPrefixByOrdinal(prefix, rp);
      return _renumber([...raw.sublist(k), ...prefixAdjusted]);
    }

    // 3) 「公告/最新章节预览块」与正文全表混合（猪猪书网 zzs5 章节页内嵌目录
    //    常见：[公告, 第34章, 第35章, …, 最新章, …, 第33章]）。此时相邻可比较
    //    对既非整表正序也非整表倒序，且顶部存在无序号项（公告）。按章节序号
    //    稳定升序重排（无序号项视为最小排最前，保持站点「公告置顶」的呈现），
    //    使目录恢复为 [公告, 第33章, 第34章, …, 第N章] 的单调顺序。
    // 复用第 1 条已统计的 comparablePairs/decreasingPairs（整表相邻可比较对与
    // 递减对），不重复遍历。
    var topHasNoOrdinal = false;
    final topLimit = math.min(10, n);
    for (var i = 0; i < topLimit; i++) {
      if (ord[i] == null) {
        topHasNoOrdinal = true;
        break;
      }
    }
    // 触发条件：非纯倒序（纯倒序已被第 1 条整体反转处理）且顶部存在公告类
    // 无序号项；此时无论「仅尾部回跳」（如上例最后一章第33章）还是「公告+最新
    // 预览+全表混排」，都按序号稳定升序恢复。纯升序源排序后顺序不变（_isSameOrder
    // 命中即返回原表），因此不会误伤普通目录。
    if (comparablePairs >= 6 &&
        topHasNoOrdinal &&
        !(decreasingPairs * 10 >= comparablePairs * 6) && // 非整表倒序
        decreasingPairs > 0) {
      final indexed = <(int?, BookSourceChapter, int)>[];
      for (var i = 0; i < n; i++) {
        indexed.add((ord[i], raw[i], i));
      }
      indexed.sort((x, y) {
        final ax = x.$1;
        final ay = y.$1;
        if (ax == null && ay == null) return x.$3.compareTo(y.$3);
        if (ax == null) return -1;
        if (ay == null) return 1;
        final c = ax.compareTo(ay);
        if (c != 0) return c;
        return x.$3.compareTo(y.$3);
      });
      final sorted = indexed.map((e) => e.$2).toList();
      if (!_isSameOrder(raw, sorted)) return _renumber(sorted);
    }
    return raw;
  }

  static bool _isSameOrder(List<BookSourceChapter> a, List<BookSourceChapter> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// 顶部块 [0..k) 是否只含「前置位」的低序号/无序号内容而没有任何后置章号（>2）。
  /// 若成立，说明顶部并非「最近更新」的倒序堆块，而是正常源的开头内容
  /// （如序章、公告、番外），此时不应被整体搬到目录末尾。
  static bool headHasOnlyPrefaceOrdinals(List<int?> ord, int k) {
    for (var i = 0; i < k; i++) {
      final v = ord[i];
      if (v != null && v > 2) return false;
    }
    return true;
  }

  /// 顶部块内若呈倒序（最近更新通常按新到旧显示），则反转使其从小到大。
  List<BookSourceChapter> _reorderPrefixByOrdinal(
    List<BookSourceChapter> prefix,
    List<int?> ord,
  ) {
    var decreasing = 0;
    var total = 0;
    for (var i = 0; i + 1 < ord.length; i++) {
      final a = ord[i];
      final b = ord[i + 1];
      if (a == null || b == null) continue;
      total++;
      if (a > b) decreasing++;
    }
    if (total >= 1 && decreasing > total / 2) return prefix.reversed.toList();
    return prefix;
  }

  /// 重排后按新的索引重新写入 order 字段，保证下游按 order 排序即得正确顺序。
  List<BookSourceChapter> _renumber(List<BookSourceChapter> chapters) {
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      if (c.order == i) continue;
      chapters[i] = BookSourceChapter(
        id: c.id,
        title: c.title,
        order: i,
        updatedAt: c.updatedAt,
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
    await _ensureJsLib(source);
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
    // 章节目录/正文页的最终请求 URL：漫画源正文为相对路径 `<img>` 时，
    // 用它做图片地址拼接基准。
    String? chapterBaseUrl;
    LegadoRuleDocument? lastDocument;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      logger.log('content', '请求章节页面 (hop=$hop)', details: {
        'source': source.name,
        'url': nextUrl,
      });
      try {
        final response = await _request(
          source,
          nextUrl,
          debugStage: BookSourceDebugStage.content,
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw const BookSourceProtocolException(
                '章节内容请求超时（15秒）。',
              ),
        );
        chapterBaseUrl = response.finalUri.toString();
        logger.log('content', '章节页面响应', details: {
          'source': source.name,
          'bodyLength': response.body.length,
          'finalUri': response.finalUri.toString(),
        });
        final document = LegadoRuleDocument.parse(
          response.body,
          response.finalUri,
        );
        lastDocument = document;
        var content = await _value(document, null, rule, 'content', required: true);
        debugRecorder?.recordInfo(
          stage: BookSourceDebugStage.content,
          sourceName: source.name,
          message: 'ruleContent.content 提取 ${content.length} 字符 (hop=$hop)',
        );
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
        logger.log('content', '替换规则后的内容长度', details: {
          'source': source.name,
          'replaceLength': content.length,
        });
        if (content.trim().isNotEmpty) parts.add(content.trim());
        // nextContentUrl 分页是尽力而为：规则产出非法/不可解析的下一页 URL 时
        // （如 JS 匹配失败退化成页面标题）、或解析抛 FormatException，应视为
        // 「无下一页」停止分页，而不是把坏 URL 抛给用户（果文/群搜等源即属此类，
        // 首页正文已成功提取）。
        try {
          nextUrl = await _url(document, null, rule, 'nextContentUrl');
        } catch (_) {
          nextUrl = '';
        }
        if (nextUrl.isNotEmpty) {
          final parsed = Uri.tryParse(nextUrl);
          if (parsed == null ||
              !(parsed.isAbsolute && (parsed.scheme == 'http' || parsed.scheme == 'https'))) {
            nextUrl = '';
          }
        }
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
    final joined = parts.join('\n\n');
    final imageUrls = _extractContentImageUrls(joined, baseUrl: chapterBaseUrl);
    // 段评（ruleContent.think）：仅文本章节物化插入段落间；漫画正文不入文本。
    final thinks = await _extractChapterThink(source, rule, lastDocument);
    final display = imageUrls.isNotEmpty || thinks.isEmpty
        ? joined
        : attachChapterThink(joined, thinks);
    // 漫画正文：图片列表即为章节内容，不入库为文本；标记 type/image 供阅读器渲染。
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: '',
      content: imageUrls.isEmpty ? display : imageUrls.join('\n'),
      contentType: imageUrls.isEmpty ? 'text/html' : 'application/x-imagelist',
      imageUrls: imageUrls,
      thinkList: imageUrls.isEmpty ? thinks : const [],
    );
  }

  /// 评估段评规则（`think` / `ruleContent.think`，对标 Legado ruleContent.think）。
  ///
  /// 规则返回 JSON 数组或单个对象（字段：title/content/user/date/likes）。
  /// 任何解析失败都静默降级为空列表——段评是增强能力，绝不影响正文加载。
  Future<List<BookSourceChapterThink>> _extractChapterThink(
    LegadoBookSource source,
    Map<String, dynamic> contentRule,
    LegadoRuleDocument? document,
  ) async {
    if (document == null) return const [];
    var rule = source.think;
    if (rule.isEmpty) rule = _optionalRule(contentRule, 'think');
    if (rule.isEmpty) return const [];
    try {
      final raw = (await _rules.evaluateString(document, null, rule)).trim();
      if (raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      final items = decoded is List ? decoded : [decoded];
      final thinks = <BookSourceChapterThink>[
        for (final item in items)
          if (item != null && item is Map)
            BookSourceChapterThink.fromJson(item),
      ]..removeWhere((think) => think.content.isEmpty);
      debugRecorder?.recordInfo(
        stage: BookSourceDebugStage.content,
        sourceName: source.name,
        message: 'ruleContent.think 提取 ${thinks.length} 条段评',
      );
      return List.unmodifiable(thinks);
    } catch (error) {
      debugRecorder?.recordInfo(
        stage: BookSourceDebugStage.content,
        sourceName: source.name,
        message: 'ruleContent.think 解析失败，忽略段评：$error',
      );
      return const [];
    }
  }

  /// 拉取漫画单页图片的原始字节。图片 URL 已是解析后的绝对地址，这里走请求层
  /// （浏览器头 + 源自定义头 + 自适应解码无关的原始字节）返回二进制，供阅读器
  /// 图片翻页渲染。失败抛出可读异常。
  Future<Uint8List> fetchImageBytes(
    RegisteredBookSource registered,
    String url,
  ) async {
    final source = _source(registered);
    _ensureRunnable(source);
    // 图片加载只备一套通用来源头：浏览器级默认头覆盖 + 源自定义头，
    // 多数图站按 Referer/UA 决定是否 403，这两者已足够。
    final headers = <String, String>{..._defaultBrowserHeaders};
    headers.addAll(_sourceHeaders(source));
    final template = LegadoRequestTemplate(
      url: Uri.parse(url),
      method: LegadoRequestMethod.get,
      headers: headers,
      charset: 'utf-8',
    );
    final recorder = debugRecorder;
    final order = recorder?.recordRequest(
      stage: BookSourceDebugStage.image,
      sourceName: source.name,
      url: url,
      method: 'GET',
      headers: headers,
    );
    final stopwatch = Stopwatch()..start();
    try {
      final bytes = await _transport.sendBytes(template);
      stopwatch.stop();
      recorder?.recordResponse(
        stage: BookSourceDebugStage.image,
        sourceName: source.name,
        order: order ?? 0,
        statusCode: 200,
        url: url,
        elapsedMs: stopwatch.elapsedMilliseconds,
        preview: '图片加载成功，${bytes.length} 字节',
      );
      return bytes;
    } catch (e) {
      stopwatch.stop();
      recorder?.recordError(
        stage: BookSourceDebugStage.image,
        sourceName: source.name,
        order: order,
        message: '图片加载失败：$e',
        url: url,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      throw BookSourceProtocolException('漫画图片加载失败：$e');
    }
  }

  /// 从章节内容里推测正文是否为漫画图片列表。
  ///
  /// 依次尝试：JSON 图片数组 → HTML `<img>`（src 带双引号/单引号/无引号三种
  /// 形态，相对路径用 [baseUrl] 拼成绝对地址）→ Markdown 图片语法 →
  /// 纯 URL 列表。全部无法识别返回空，正文按普通文本处理。
  ///
  /// [baseUrl] 通常传章节请求的最终 URL：漫画源的正文常为相对路径 `<img>`，
  /// 需要用章节目录/章节页地址补全为可下载的绝对图片地址。
  static List<String> _extractContentImageUrls(
    String content, {
    String? baseUrl,
  }) =>
      extractContentImageUrls(content, baseUrl: baseUrl);

  Future<String> _tocUrl(LegadoBookSource source, String bookId) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _optionalRule(rule, 'tocUrl');
    // tocUrl 未配置：目录页即详情页（bookId），与搜索/详情共用一条 URL。
    if (tocRule.isEmpty) return bookId;
    final response = await _request(
      source,
      bookId,
      debugStage: BookSourceDebugStage.bookInfo,
    );
    final document = LegadoRuleDocument.parse(response.body, response.finalUri);
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(document, null, init)).firstOrNull;
    final resolved = await _rules.evaluateString(
      document,
      context,
      tocRule,
      resolveUrl: true,
    );
    // 宽容：tocUrl 选择器在当前详情页匹配不到任何元素（如猪猪书网写
    // `id.downlink@a.0@href` 但其目录直接内嵌在详情页 `div.list>dl>dd`）
    // 时，回退到详情页自身（bookId）作为目录页，避免 nextUrl 为空导致
    // getChapters 直接跳目录为空。
    if (resolved.trim().isEmpty) return bookId;
    return resolved;
  }

  /// 单本兜底：搜索响应未匹配到搜索列表（bookList==0）时，用详情规则把当前
  /// 响应（可能已被 302 到书籍详情页）解析为唯一一本书。书名/书址取不到则弃。
  Future<BookSourceBook?> _singleBookFromSearch(
    LegadoRuleDocument document,
    LegadoBookSource source,
  ) async {
    final infoRule = source.rule('ruleBookInfo');
    final init = _optionalRule(infoRule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateList(document, null, init)).firstOrNull;
    final title = await _value(document, context, infoRule, 'name');
    if (title.isEmpty) return null;
    // 详情页兜底：单本结果的书址就是当前响应最终地址（已完成 302 重定向）。
    final url = document.baseUri.toString();
    return BookSourceBook(
      id: url,
      title: title,
      author: await _value(document, context, infoRule, 'author'),
      description: await _value(document, context, infoRule, 'intro'),
      coverUrl: await _uriValue(document, context, infoRule, 'coverUrl'),
      categories: _splitCategories(await _value(document, context, infoRule, 'kind')),
      latestChapter: _nullable(await _value(document, context, infoRule, 'lastChapter')),
    );
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

  /// 书源登录请求（对标 Legado `source.login()`）：按已登录表单回填的变量
  /// 展开 `loginUrl` 模板请求，返回响应（响应头含 Set-Cookie，已由传输层
  /// 持久化进 [BookSourceCookieStore]）。用于登录页“提交登录”。
  Future<LegadoResponse> requestForLogin(
    RegisteredBookSource registered, {
    Map<String, String> variables = const {},
  }) async {
    await _ensureSandbox();
    final source = _source(registered);
    _ensureRunnable(source);
    await _ensureJsLib(source);
    final template = source.loginUrl.trim();
    if (template.isEmpty) {
      throw const BookSourceProtocolException(
        'This source does not provide a loginUrl.',
      );
    }
    final response = await _request(
      source,
      template,
      variables: variables,
      debugStage: BookSourceDebugStage.raw,
    );
    return response;
  }

  /// 在沙箱中执行一段书源脚本（登录校验/动作），返回寄存器或完成值字符串。
  /// 复用 `debugEvalJs`，但把响应 HTML 作为 document 上下文注入。
  Future<String> evalSourceScript(
    RegisteredBookSource registered, {
    required String code,
    String? docHtml,
    Map<String, dynamic> extraGlobals = const {},
  }) async {
    await _ensureSandbox();
    await _ensureJsLib(_source(registered));
    return debugEvalJs(
      code: code,
      sourceName: _source(registered).name,
      docHtml: docHtml,
      extraGlobals: extraGlobals,
    );
  }

  Future<LegadoResponse> _request(
    LegadoBookSource source,
    String template, {
    Map<String, String> variables = const {},
    BookSourceDebugStage debugStage = BookSourceDebugStage.raw,
  }) async {
    await _ensureSandbox();
    // ===== 米读：before-send JS 预处理 =====
    // 当 URL 模板或 header 中包含 @js / <js> 表达式，或 {{...}} 内嵌 JS 表达式
    // （如 {{java.connect(...)}}、{{source.get('k')}}）时，先通过 fjs 执行
    final processedTemplate = await _preprocessJsInString(
      template,
      variables: variables,
      baseUri: source.baseUri,
    );
    final rawHeaders = _sourceHeaders(source);
    final processedHeaders = <String, String>{};
    // 先写入浏览器级默认头，再让源自定义头覆盖。没有浏览器 UA 时部分站点
    // （如 m.shuhaige.net）只返回截断的分页预览，导致章节正文显示不全。
    processedHeaders.addAll(_defaultBrowserHeaders);
    for (final entry in rawHeaders.entries) {
      processedHeaders[entry.key] = await _preprocessJsInString(
        entry.value,
        variables: variables,
        baseUri: source.baseUri,
      );
    }
    // ===== 米读：@webBrowser:/@webView: 浏览器兜底路由 =====
    // 浏览器兜底指向真实 WebView 加载（还原强 JS / 反爬站点环境），而非普通
    // HTTP 传输。识别两处：URL 模板前缀（forceWebView）与请求选项 webView:true
    // （后者由 LegadoRequestTemplate.parse 回填 useWebView）。
    final browserStripped = WebBrowserRoute.stripBrowserPrefix(processedTemplate);
    final parseInput = browserStripped ?? processedTemplate;
    final parsedTemplate = LegadoRequestTemplate.parse(
      _expandSourceVars(parseInput),
      baseUri: source.baseUri,
      variables: variables,
      sourceHeaders: _expandHeaderVars(processedHeaders),
      forceWebView: browserStripped != null,
    );
    if (parsedTemplate.useWebView) {
      return _openInWebBrowser(source, parsedTemplate, debugStage: debugStage);
    }
    // ===== 米读：浏览器安全验证挑战自动重试 =====
    // 部分书源（爱下网书等）在详情/目录/章节页先返回一个「正在验证浏览器」页面，
    // 内含 `token`，脚本里 `location.pathname + "?challenge=" + token` 跳转放行。
    // 合法的 token 可直接回传 `?challenge=` 通过；该挑战不含需要真实 JS 执行的
    // 认证逻辑，故在此自动求解，不再把裸挑战页当正文抛给用户。
    var challengeTemplate = parsedTemplate;
    var attempt = 0;
    while (true) {
      final template = challengeTemplate;
      // ===== 调试记录：每次真实发出的请求对应一条 request + 一条 response =====
      final recorder = debugRecorder;
      final order = recorder?.recordRequest(
        stage: debugStage,
        sourceName: source.name,
        url: template.url.toString(),
        method: template.method == LegadoRequestMethod.post ? 'POST' : 'GET',
        body: template.body,
        headers: template.headers,
      );
      final stopwatch = Stopwatch()..start();
      final LegadoResponse response;
      try {
        response = await _transport.send(template);
      } catch (error) {
        stopwatch.stop();
        recorder?.recordError(
          stage: debugStage,
          sourceName: source.name,
          order: order,
          message: '$error',
          url: template.url.toString(),
          elapsedMs: stopwatch.elapsedMilliseconds,
        );
        rethrow;
      }
      stopwatch.stop();
      recorder?.recordResponse(
        stage: debugStage,
        sourceName: source.name,
        order: order ?? 0,
        statusCode: response.statusCode ?? 0,
        headers: response.headers,
        url: response.finalUri.toString(),
        elapsedMs: stopwatch.elapsedMilliseconds,
        preview: debugPreview(response.body, max: 1500),
      );
      final token = _extractChallengeToken(response.body);
      // 无挑战、或已重试次数用尽（避免循环），直接返回。
      if (token == null || attempt >= 2) return response;
      final finalUri = response.finalUri;
      if (!finalUri.hasAuthority) return response;
      // 重新构造模板：把 challenge token 拼到最终 URL 的查询参数上重发。
      final solvedUrl = finalUri.replace(
        queryParameters: {
          ...finalUri.queryParameters,
          'challenge': token,
        },
      );
      challengeTemplate = LegadoRequestTemplate(
        url: solvedUrl,
        method: template.method,
        headers: template.headers,
        charset: template.charset,
        body: template.body,
      );
      attempt++;
    }
  }

  /// 执行一次浏览器兜底：SSRF 前置校验 → WebView 池加载 → 包装为 LegadoResponse。
  /// 调试记录器与普通请求一致记录 request/response/error。
  Future<LegadoResponse> _openInWebBrowser(
    LegadoBookSource source,
    LegadoRequestTemplate template, {
    BookSourceDebugStage debugStage = BookSourceDebugStage.raw,
  }) async {
    final recorder = debugRecorder;
    final order = recorder?.recordRequest(
      stage: debugStage,
      sourceName: source.name,
      url: template.url.toString(),
      method: template.method == LegadoRequestMethod.post ? 'POST' : 'GET',
      body: template.body,
      headers: template.headers,
    );
    final stopwatch = Stopwatch()..start();
    try {
      // R3：WebView 出站 URL 一律先过 SSRF 策略，失败即抛错且不触网。
      await _webViewNetworkPolicy.validate(template.url);
      final document = await webBrowserPool.open(
        WebBrowserRequest(
          url: template.url,
          method: template.method == LegadoRequestMethod.post ? 'POST' : 'GET',
          headers: template.headers,
          body: template.body,
        ),
      );
      stopwatch.stop();
      recorder?.recordResponse(
        stage: debugStage,
        sourceName: source.name,
        order: order ?? 0,
        statusCode: document.statusCode ?? 0,
        headers: null,
        url: document.finalUri.toString(),
        elapsedMs: stopwatch.elapsedMilliseconds,
        preview: debugPreview(document.body, max: 1500),
      );
      return LegadoResponse(
        body: document.body,
        finalUri: document.finalUri,
        statusCode: document.statusCode,
      );
    } catch (error) {
      stopwatch.stop();
      recorder?.recordError(
        stage: debugStage,
        sourceName: source.name,
        order: order,
        message: '$error',
        url: template.url.toString(),
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  /// 从「正在验证浏览器」挑战页中提取 token（`let token = "..."`）。非挑战页
  /// 返回 null。兼容带 `?challenge=` 已放行页（不重复求解）。
  static String? _extractChallengeToken(String body) {
    if (body.isEmpty) return null;
    // 快速否定：不含验证标记直接返回。
    if (!body.contains('正在验证浏览器') &&
        !body.contains('安全验证') &&
        !body.contains('location')) {
      return null;
    }
    final m = RegExp(
      r'''let\s+token\s*=\s*["']([A-Za-z0-9+/=_\-\.:~%]+)["']''',
    ).firstMatch(body);
    return m?.group(1);
  }

  /// 把 bookId（通常为搜索/详情拼出的完整 URL）的查询参数灌入来源变量，
  /// 供后续规则里的 @get:{name} / {{name}} 使用（宜搜等源的 tocUrl 依赖
  /// gid/nid 这类来自详情 URL 的参数）。仅补缺，不覆盖已有的显式 @put 值。
  void _seedVarsFromBookId(String bookId) {
    final uri = Uri.tryParse(bookId);
    if (uri == null || !uri.hasQuery) {
      DebugLogger.instance.log('seed', 'seedVars noQuery', details: {'bookId': bookId});
      return;
    }
    uri.queryParameters.forEach((k, v) {
      if (!_isSimpleVarName(k)) return;
      if (_sandbox.getSourceVar(k) == null) _sandbox.putSourceVar(k, v);
    });
    DebugLogger.instance.log('seed', 'seedVars from bookId',
        details: {'bookId': bookId, 'keys': uri.queryParameters.keys.toList()});
  }

  static bool _isSimpleVarName(String s) =>
      RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(s);

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
    Uri? baseUri,
  }) async {
    if (value.isEmpty) return value;
    final lower = value.toLowerCase();
    if (lower.contains('@js:') || lower.contains('<js>')) {
      final trimmed = value.trim();
      final isPureJs =
          trimmed.toLowerCase().startsWith('@js:') ||
          trimmed.toLowerCase().startsWith('<js>');
      // 纯 JS 表达式（整段 @js:/<js>）：执行结果必须非空才可作为请求模板。
      // 结果为空的场景（强 JS 依赖源里 java.ajax/java.connect + org.jsoup 无法
      // 执行，evalJs 返回空）应判为「搜索无结果」，而非把带 @js: 的原文漏进 URL
      // 解析抛误导性的 FormatException。内嵌片段（@js: 只是其中一段）保留原文。
      // 注入 baseUri（供 source.getKey()/baseUrl）与 key/page 变量（供 ${key}
      // 等模板字符串），否则果文/群搜等纯 JS searchUrl 会因取不到 token/key 而
      // 生成空请求 URL。
      if (isPureJs) {
        try {
          final r = await _sandbox.evalJs(
            value,
            baseUri: baseUri,
            extraGlobals: Map<String, dynamic>.from(variables),
          );
          return r.isEmpty ? '' : r;
        } catch (_) {
          return '';
        }
      }
      try {
        final r = await _sandbox.evalJs(
          value,
          baseUri: baseUri,
          extraGlobals: Map<String, dynamic>.from(variables),
        );
        return r.isEmpty ? value : r;
      } catch (_) {
        return value;
      }
    }
    // 处理 {{...}} 内嵌 JS 表达式：仅当表达式中含 JS 调用/运算符时才交给 fjs。
    // 纯变量（{{key}}、{{page}}）、JSON 路径（{{$.x}}）、引号字面量保持原样，
    // 由 LegadoRequestTemplate / 规则引擎展开。识别范围覆盖豆书籍源常见的
    // 算术表达式（企鹅阅读 searchUrl 的 {{page-1}}）与方法调用
    // （{{baseUrl.replace(...)}}、{{source.get('k')}} 等）。
    if (!RegExp(r'\{\{[^{}]*\{\{').hasMatch(value) &&
        RegExp(r'\{\{\s*[^{}]+\s*\}\}')
            .allMatches(value)
            .any((m) => _isPlainJsTemplate(m.group(0)!))) {
      return _evalTemplateJsExpressions(value, variables);
    }
    return value;
  }

  /// `{{...}}` 是否为需要 JS 求值的表达式（而非纯变量 / JSON 路径 / 字面量）。
  static bool _isPlainJsTemplate(String raw) {
    final inner = raw.replaceAll(RegExp(r'^\s*\{\{|\}\}\s*$'), '').trim();
    if (inner.isEmpty) return false;
    // 纯变量：{{key}} / {{page}} / {{baseUrl}}
    if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(inner)) return false;
    // 引号字面量
    if ((inner.startsWith('"') && inner.endsWith('"')) ||
        (inner.startsWith("'") && inner.endsWith("'"))) {
      return false;
    }
    // JSON 路径：{{$.x}} / ${...}
    if (inner.startsWith(r'$')) return false;
    // 纯数字字面量
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(inner)) return false;
    // 需要 JS 求值：含运算符或方法调用
    return RegExp(r'[+\-*/%<>=!?:&|^~]|\w\.\w').hasMatch(inner);
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
      // 纯变量 / JSON 路径 / 引号字面量 / 纯数字不处理
      if (RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(trimmed) ||
          trimmed.startsWith(r'$') ||
          RegExp(r'^\d+(\.\d+)?$').hasMatch(trimmed) ||
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
    await _ensureJsLib(source);
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
        // 宽容降级：部分源（多为手改的漫画源）header 格式不规范——键未加引号、
        // 用 \r/\n 而非逗号分隔、末尾残留换行等，严格 jsonDecode 会失败。
        // 尝试按「裸键: "值"」模式逐行提取，能解析多少算多少；仍失败则视为空头。
        decoded = _looseDecodeHeaders(raw);
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

  /// 宽松解析格式不规范的 header 字符串（严格 JSON 失败后的降级路径）。
  ///
  /// 常见问题形态：
  ///  - 键未加引号：`user-agent: "..."`（而非 `"user-agent": "..."`）
  ///  - 用 `\r`/`\n` 分隔而非逗号：`{\ruser-agent: "..."\r}`
  ///  - 值含冒号、末尾残留换行/`}` 等。
  /// 这里按「分段 → 键: 值」逐条提取，能解析多少算多少；完全解析不出返回空 Map。
  /// 注意：仅提取简单 `键: "字符串值"` 对，不做表达式/嵌套求值，避免引入安全风险。
  Map<String, dynamic> _looseDecodeHeaders(String raw) {
    final out = <String, dynamic>{};
    var body = raw.trim();
    if (body.startsWith('{')) body = body.substring(1);
    if (body.endsWith('}')) body = body.substring(0, body.length - 1);
    // 以逗号、\r、\n 为分隔点切开各条目（容忍多余分隔符与空段）。
    final parts = body
        .split(RegExp(r'[,;\r\n]+|\r\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    for (final part in parts) {
      final colon = part.indexOf(':');
      if (colon <= 0) continue;
      final key = part
          .substring(0, colon)
          .trim()
          .replaceAll(RegExp('^["\']+|["\']+\$'), '');
      var value = part.substring(colon + 1).trim();
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      } else if (value.startsWith("'") && value.endsWith("'")) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty && value.isNotEmpty) {
        out[key] = value;
      }
    }
    return out;
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

  /// 预加载书源公共 jsLib（幂等）。每个业务入口在拿到 [source] 后调用一次，
  /// jsLib 在沙箱内注册的全局函数即可被后续所有 @js / <js> 规则使用。
  Future<void> _ensureJsLib(LegadoBookSource source) async {
    final jsLib = source.jsLib;
    if (jsLib.trim().isEmpty) return;
    await _sandbox.preloadJsLib(jsLib);
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
    // 预检仅对静态模板有意义：含 @js:/<js> 的 searchUrl 需运行时 JS 求值才能
    // 得到真实 URL，这里无法静态解析（强行 parse 会抛误导性的 FormatException）。
    // 跳过此类，交由 _request 里真正的 JS 预处理执行。
    final searchUrl = source.searchUrl;
    final lcSearch = searchUrl.toLowerCase();
    final isJsSearchUrl =
        lcSearch.startsWith('@js:') || lcSearch.startsWith('<js>');
    // 内联 {{...}} JS 模板（如 {{java.connect(source.getKey()).raw().request()
    // .url()}}modules/...，读趣/爱看/书趣阁等源）同样需运行时 JS 求值才能得到
    // 真实 URL：_preprocessJsInString 会把该块求值/剥离后交给 parse。静态预检
    // 无法解析，直接跳过，与 @js:/<js> 同一逻辑，避免误抛「unsupported template
    // expression」——否则 search 在 _request 之前就被 _ensureRunnable 拦下。
    final hasInlineJsTemplate = RegExp(r'\{\{\s*[^{}]+\s*\}\}')
        .allMatches(searchUrl)
        .any((m) => _isPlainJsTemplate(m.group(0)!));
    // @webBrowser:/@webView: 浏览器兜底路由由 _request 运行时执行（含 SSRF 校验），
    // 静态预检无法模拟真实 WebView 环境，跳过 parse 预检。
    if (!isJsSearchUrl &&
        !hasInlineJsTemplate &&
        !WebBrowserRoute.isBrowserUrl(searchUrl)) {
      LegadoRequestTemplate.parse(
        searchUrl,
        baseUri: source.baseUri,
        variables: const {'key': 'preflight', 'page': '1'},
        sourceHeaders: headers,
      );
    }
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
    // 目录翻页的 nextTocUrl 若解析出非 HTTP 链接（如最后一页的
    // `javascript:void(0)` 占位按钮，抖音小说/多页目录源常见），应视为「没有
    // 下一页」而停止翻页，而不是抛「non-HTTP URL」把整个目录判失败。
    if (key == 'nextTocUrl') {
      try {
        return _rules.evaluateString(
          document,
          context,
          rule,
          resolveUrl: true,
        );
      } on BookSourceProtocolException {
        return '';
      }
    }
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

/// 列表规则是否为 <js> / @js: 生成（JSON 接口源返回结果数组）。这类源的空列表
/// 表意是「确无结果」，不应触发「单本 302 兜底」。
bool _isJsListRule(String rule) {
  final lower = rule.toLowerCase();
  return lower.startsWith('<js>') ||
      lower.startsWith('@js:') ||
      lower.contains('</js>');
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
