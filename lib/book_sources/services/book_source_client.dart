import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../utils/source_protocol_meta.dart';
import '../legado/legado_fjs_sandbox.dart';
import '../legado/legado_runtime.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_download_cancellation.dart';
import 'book_source_chapter_cache.dart';
import 'book_source_network_policy.dart';

class DiscoveredBookSource {
  final Uri manifestUrl;
  final BookSourceManifest manifest;

  const DiscoveredBookSource({
    required this.manifestUrl,
    required this.manifest,
  });
}

class BookSourceClient {
  final Dio _dio;
  final BookSourceChapterCache _chapterCache;
  final BookSourceNetworkPolicy _networkPolicy;
  // 米读：按源隔离 Legado runtime。健康检测/聚合搜索会并发请求多个源，
  // 若共享单个 runtime（单 JS 引擎 + 单变量空间），不同源的 @put/@get 变量
  // 与 document 状态会互相污染，导致大量源解析失败。
  final Map<String, LegadoRuntime> _legadoRuntimes = {};

  // 测试/诊断注入：为每个源构造 JS 沙箱。生产为 null 时用默认 fjs；
  // 本机无 fjs.dll 时用 FlutterLegadoJsSandbox（flutter_js QuickJS）跑真实链路。
  final LegadoJsSandbox Function(String sourceId)? _sandboxFactory;
  final bool _enableAjaxBridge;

  /// 单次响应体上限。书源返回的都是 JSON 元数据/章节文本，
  /// 超过该值基本可以判定为异常或恶意响应，中途截断防止 OOM。
  static const int maxResponseBytes = 8 * 1024 * 1024;
  static const int maxDownloadResponseBytes = 24 * 1024 * 1024;
  static const Duration downloadReceiveTimeout = Duration(seconds: 90);

  /// ORSP §11 章节目录默认页大小；书源未声明 maxCatalogPageSize 时使用。
  static const int _defaultChapterPageSize = 100;

  /// 章节总数的硬上限（约 3 万章，远超真实连载小说的记录）。翻页次数上限
  /// 由它除以实际页大小动态推出，与页大小无关地防止死循环或内存膨胀——
  /// 哪怕某一页返回的条目数远超请求的 pageSize，这里也会强制截断。
  static const int _maxChapters = 30000;

  static const int _maxRetryAttempts = 3;
  static const Duration _maxRetryAfter = Duration(seconds: 60);

  BookSourceClient({
    Dio? dio,
    BookSourceChapterCache? chapterCache,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(),
    LegadoJsSandbox Function(String sourceId)? sandboxFactory,
    bool enableAjaxBridge = false,
  }) : _sandboxFactory = sandboxFactory,
       _enableAjaxBridge = enableAjaxBridge,
       _chapterCache = chapterCache ?? const BookSourceChapterCache(),
       _networkPolicy = networkPolicy,
       _dio =
           dio ??
           (Dio(
               BaseOptions(
                 connectTimeout: const Duration(seconds: 8),
                 receiveTimeout: const Duration(seconds: 12),
                 sendTimeout: const Duration(seconds: 8),
                 headers: const {
                   'Accept': 'application/json',
                   'X-MiDu-Protocol': openReadingSourceProtocolVersion,
                 },
               ),
             )
             ..httpClientAdapter = IOHttpClientAdapter(
               createHttpClient: networkPolicy.createPinnedHttpClient,
             ));

  void close({bool force = true}) {
    for (final runtime in _legadoRuntimes.values) {
      runtime.close(force: force);
    }
    _legadoRuntimes.clear();
    _dio.close(force: force);
  }

  static void ensureSafeTarget(Uri uri) {
    final address = InternetAddress.tryParse(uri.host);
    if (address != null && BookSourceNetworkPolicy.isBlockedAddress(address)) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
  }

  /// 统一的受限 GET：目标地址校验 + 响应体大小上限。
  Future<Object?> _getBounded(
    Uri uri, {
    int maxBytes = maxResponseBytes,
    Duration? receiveTimeout,
    BookDownloadCancellation? cancellation,
  }) async {
    final cancelToken = CancelToken();
    void cancelRequest() => cancelToken.cancel('Book download cancelled.');
    cancellation?.throwIfCancelled();
    cancellation?.addListener(cancelRequest);
    try {
      var current = uri;
      for (var redirects = 0; redirects <= 5; redirects++) {
        await _networkPolicy.validate(current);
        final response = await _dio.getUri<Object?>(
          current,
          options: Options(
            receiveTimeout: receiveTimeout,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (received > maxBytes || total > maxBytes) {
              cancelToken.cancel('Response exceeds $maxBytes bytes.');
            }
          },
        );
        final status = response.statusCode ?? 0;
        if (status < 300) {
          cancellation?.throwIfCancelled();
          return response.data;
        }
        if (redirects == 5) {
          throw const BookSourceProtocolException(
            'Book source redirected too many times.',
          );
        }
        current = BookSourceNetworkPolicy.redirectTarget(
          current,
          response.headers.value(HttpHeaders.locationHeader),
        );
      }
      cancellation?.throwIfCancelled();
      throw const BookSourceProtocolException('Book source request failed.');
    } on DioException {
      cancellation?.throwIfCancelled();
      rethrow;
    } finally {
      cancellation?.removeListener(cancelRequest);
    }
  }

  static Uri normalizeManifestUri(String input) {
    final trimmed = input.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.hasAuthority ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Please enter a valid http or https URL.',
      );
    }
    if (parsed.path.endsWith('.json')) return parsed;

    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return parsed
        .replace(path: path, query: null, fragment: null)
        .resolve(openReadingSourceDiscoveryPath);
  }

  Future<DiscoveredBookSource> discover(String input) async {
    final manifestUrl = normalizeManifestUri(input);
    try {
      final manifest = BookSourceManifest.fromJson(
        asBookSourceJsonObject(decodeBookSourceJson(await _getBounded(manifestUrl))),
      );
      return DiscoveredBookSource(manifestUrl: manifestUrl, manifest: manifest);
    } on DioException catch (error) {
      throw BookSourceProtocolException(
        _dioErrorMessage(error),
        code: _sourceErrorCode(error),
      );
    }
  }

  // ===== 米读：发现页接入 =====
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source, {
    String? exploreUrlOverride,
  }) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      await _ensureAdditionalProtocolsEnabled();
      return _legadoFor(source).getDiscovery(
        source,
        exploreUrlOverride: exploreUrlOverride,
      );
    }
    // ORSP 源：回退到 browse 的第一页转换
    if (!source.capabilities.contains('browse')) {
      throw const BookSourceProtocolException(
        'This source does not provide browse/discovery.',
      );
    }
    final page = await browse(source, page: 1, pageSize: 30);
    final items = page.items
        .map((b) => BookSourceDiscoveryItem(
              title: b.title,
              subtitle: b.author,
              coverUrl: b.coverUrl,
              targetUrl: b.id, // 用 bookId 作为 targetUrl，后续跳转解析用
              book: b,
            ))
        .toList(growable: false);
    return BookSourceDiscoveryPage(
      title: source.name,
      sections: [
        BookSourceDiscoverySection(title: '推荐', items: items, layout: 'grid'),
      ],
      // ORSP browse 是页码式分页，发现页统一由下一次 browse(page++) 驱动翻页。
      nextPageUrl: page.hasMore ? '__browse_page_${page.page + 1}__' : null,
    );
  }

  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      await _ensureAdditionalProtocolsEnabled();
      return _legadoFor(source).search(
        source,
        query,
        page: page,
        pageSize: pageSize,
      );
    }
    if (!source.capabilities.contains('search')) {
      throw const BookSourceProtocolException(
        'This source does not support search.',
      );
    }
    final uri = _apiUri(source.apiBaseUrl, 'v1/search').replace(
      queryParameters: {
        'q': query.trim(),
        'page': '$page',
        'pageSize': '$pageSize',
      },
    );
    try {
      return BookSourceSearchPage.fromJson(
        asBookSourceJsonObject(decodeBookSourceJson(await _getBounded(uri))),
      );
    } on DioException catch (error) {
      throw BookSourceProtocolException(
        _dioErrorMessage(error),
        code: _sourceErrorCode(error),
      );
    }
  }

  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
  ) async {
    if (!source.capabilities.contains('categories')) {
      throw const BookSourceProtocolException(
        'This source does not support categories.',
      );
    }
    final uri = _apiUri(source.apiBaseUrl, 'v1/categories');
    try {
      final json = decodeBookSourceJson(await _getBounded(uri));
      if (json is! Map) {
        throw const BookSourceProtocolException(
          'Category response must be a JSON object.',
        );
      }
      final items = json['items'];
      if (items is! List) {
        throw const BookSourceProtocolException(
          'Category response must contain an items array.',
        );
      }
      return items
          .map(
            (item) => BookSourceCategory.fromJson(asBookSourceJsonObject(item)),
          )
          .toList(growable: false);
    } on DioException catch (error) {
      throw BookSourceProtocolException(
        _dioErrorMessage(error),
        code: _sourceErrorCode(error),
      );
    }
  }

  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!source.capabilities.contains('browse')) {
      throw const BookSourceProtocolException(
        'This source does not support browsing.',
      );
    }
    final uri = _apiUri(source.apiBaseUrl, 'v1/browse').replace(
      queryParameters: {
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        'sort': sort,
        'page': '$page',
        'pageSize': '$pageSize',
      },
    );
    try {
      return BookSourceSearchPage.fromJson(
        asBookSourceJsonObject(decodeBookSourceJson(await _getBounded(uri))),
      );
    } on DioException catch (error) {
      throw BookSourceProtocolException(
        _dioErrorMessage(error),
        code: _sourceErrorCode(error),
      );
    }
  }

  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId,
  ) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      await _ensureAdditionalProtocolsEnabled();
      return _legadoFor(source).getBook(source, bookId);
    }
    final uri = _apiUri(
      source.apiBaseUrl,
      'v1/books/${Uri.encodeComponent(bookId)}',
    );
    try {
      final book = BookSourceBook.fromJson(
        asBookSourceJsonObject(decodeBookSourceJson(await _getBounded(uri))),
      );
      if (book.id != bookId) {
        throw const BookSourceProtocolException(
          'Book detail response does not match the requested book.',
        );
      }
      return book;
    } on DioException catch (error) {
      throw BookSourceProtocolException(
        _dioErrorMessage(error),
        code: _sourceErrorCode(error),
      );
    }
  }

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId,
  ) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      await _ensureAdditionalProtocolsEnabled();
      return _legadoFor(source).getChapters(source, bookId);
    }
    return _chapterCache.getChapterCatalogOrLoad(
      sourceId: source.id,
      sourceRevision: source.apiBaseUrl.toString(),
      bookId: bookId,
      loader: () => _fetchAllChapters(
        _apiUri(
          source.apiBaseUrl,
          'v1/books/${Uri.encodeComponent(bookId)}/chapters',
        ),
        pageSize: _chapterPageSizeFor(source),
        maxBytes: maxResponseBytes,
        receiveTimeout: null,
      ),
    );
  }

  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    BookDownloadCancellation? cancellation,
  }) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      cancellation?.throwIfCancelled();
      await _ensureAdditionalProtocolsEnabled();
      final chapters = await _legadoFor(source).getChapters(source, bookId);
      cancellation?.throwIfCancelled();
      return chapters;
    }
    return _fetchAllChapters(
      _apiUri(
        source.apiBaseUrl,
        'v1/books/${Uri.encodeComponent(bookId)}/chapters',
      ),
      pageSize: _chapterPageSizeFor(source),
      maxBytes: maxDownloadResponseBytes,
      receiveTimeout: downloadReceiveTimeout,
      cancellation: cancellation,
    );
  }

  /// The page size to request for `source`'s chapter catalog: its own
  /// declared `maxCatalogPageSize` when present (ORSP §3), otherwise the
  /// protocol default of 100. Clamped to the spec's own 1000 ceiling purely
  /// to stop a source from talking the client into absurdly large single
  /// requests — a source is free to declare a smaller bound than 100 and
  /// have it honored exactly, since the 100-1000 range is a requirement on
  /// what sources are supposed to declare, not on what the client must send.
  int _chapterPageSizeFor(RegisteredBookSource source) {
    return (source.maxCatalogPageSize ?? _defaultChapterPageSize).clamp(
      1,
      1000,
    );
  }

  /// Fetches the full chapter catalog, following pagination when the source
  /// implements it (protocol 1.5). `pageSize` is capped to the source's own
  /// declared `maxCatalogPageSize` (ORSP §3) — sending a larger value than a
  /// source advertises is a protocol violation the source may legitimately
  /// reject with 400, so it must never be hardcoded higher than what the
  /// source actually said it accepts. Sources that still return every chapter
  /// in a single `{items}` response (legacy unpaged behavior) parse as one
  /// complete page, so the loop exits after the first request with identical
  /// results to before pagination existed.
  Future<List<BookSourceChapter>> _fetchAllChapters(
    Uri uri, {
    required int pageSize,
    required int maxBytes,
    required Duration? receiveTimeout,
    BookDownloadCancellation? cancellation,
  }) async {
    const maxPageRequests = 1000;
    final maxPages = ((_maxChapters / pageSize).ceil()).clamp(
      1,
      maxPageRequests,
    );
    final chapters = <BookSourceChapter>[];
    final chapterIds = <String>{};
    for (var page = 1; page <= maxPages; page++) {
      cancellation?.throwIfCancelled();
      final pageUri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'page': '$page',
          'pageSize': '$pageSize',
        },
      );
      final result = await _withRetries(() async {
        final json = decodeBookSourceJson(
          await _getBounded(
            pageUri,
            maxBytes: maxBytes,
            receiveTimeout: receiveTimeout,
            cancellation: cancellation,
          ),
        );
        return BookSourceChapterPage.fromJson(asBookSourceJsonObject(json));
      }, cancellation: cancellation);
      if (result.items.length > _maxChapters - chapters.length) {
        throw const BookSourceProtocolException(
          'Book source chapter catalog exceeds the supported limit.',
        );
      }
      for (final chapter in result.items) {
        if (!chapterIds.add(chapter.id)) {
          throw const BookSourceProtocolException(
            'Book source chapter catalog contains duplicate chapter IDs.',
          );
        }
        chapters.add(chapter);
      }
      if (chapters.length >= _maxChapters && result.hasMore) {
        throw const BookSourceProtocolException(
          'Book source chapter catalog exceeds the supported limit.',
        );
      }
      if (!result.hasMore || result.items.isEmpty) break;
      if (page == maxPages) {
        throw const BookSourceProtocolException(
          'Book source chapter catalog contains too many pages.',
        );
      }
    }
    chapters.sort(compareBookSourceChapters);
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
  }) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      await _ensureAdditionalProtocolsEnabled();
      return _legadoFor(source).getChapterContent(
        source,
        bookId: bookId,
        chapterId: chapterId,
      );
    }
    return _chapterCache.getOrLoad(
      sourceId: source.id,
      sourceRevision: source.apiBaseUrl.toString(),
      bookId: bookId,
      chapterId: chapterId,
      loader: () async {
        final uri = _apiUri(
          source.apiBaseUrl,
          'v1/books/${Uri.encodeComponent(bookId)}/chapters/'
          '${Uri.encodeComponent(chapterId)}',
        );
        try {
          final content = BookSourceChapterContent.fromJson(
            asBookSourceJsonObject(decodeBookSourceJson(await _getBounded(uri))),
          );
          _validateChapterContentIdentity(content, bookId, chapterId);
          return content;
        } on DioException catch (error) {
          throw BookSourceProtocolException(
            _dioErrorMessage(error),
            code: _sourceErrorCode(error),
          );
        }
      },
    );
  }

  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    BookDownloadCancellation? cancellation,
  }) async {
    if (source.sourceProtocol == BookSourceProtocolKind.legado) {
      cancellation?.throwIfCancelled();
      await _ensureAdditionalProtocolsEnabled();
      final content = await _legadoFor(source).getChapterContent(
        source,
        bookId: bookId,
        chapterId: chapterId,
      );
      cancellation?.throwIfCancelled();
      return content;
    }
    cancellation?.throwIfCancelled();
    final content = await _chapterCache.getOrLoad(
      sourceId: source.id,
      sourceRevision: source.apiBaseUrl.toString(),
      bookId: bookId,
      chapterId: chapterId,
      staleWhileRevalidate: false,
      loader: () {
        final uri = _apiUri(
          source.apiBaseUrl,
          'v1/books/${Uri.encodeComponent(bookId)}/chapters/'
          '${Uri.encodeComponent(chapterId)}',
        );
        return _withRetries(() async {
          final content = BookSourceChapterContent.fromJson(
            asBookSourceJsonObject(decodeBookSourceJson(
              await _getBounded(
                uri,
                maxBytes: maxDownloadResponseBytes,
                receiveTimeout: downloadReceiveTimeout,
                cancellation: cancellation,
              ),
            )),
          );
          _validateChapterContentIdentity(content, bookId, chapterId);
          return content;
        }, cancellation: cancellation);
      },
    );
    cancellation?.throwIfCancelled();
    return content;
  }

  void _validateChapterContentIdentity(
    BookSourceChapterContent content,
    String bookId,
    String chapterId,
  ) {
    if (content.bookId != bookId || content.chapterId != chapterId) {
      throw const BookSourceProtocolException(
        'Chapter response does not match the requested resource.',
      );
    }
  }

  Future<void> prefetchChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
  }) async {
    try {
      await getChapterContent(source, bookId: bookId, chapterId: chapterId);
    } catch (_) {
      // Prefetching is opportunistic and must not surface reader errors.
    }
  }

  /// 按源获取独立 runtime（跨源隔离变量与 JS 引擎状态）。
  LegadoRuntime _legadoFor(RegisteredBookSource source) {
    return _legadoRuntimes.putIfAbsent(
      source.id,
      () {
        final sandbox = _sandboxFactory?.call(source.id);
        return sandbox == null
            ? LegadoRuntime(enableAjaxBridge: _enableAjaxBridge)
            : LegadoRuntime(
                sandbox: sandbox,
                enableAjaxBridge: _enableAjaxBridge,
              );
      },
    );
  }

  /// 测试专用：暴露按源 runtime 解析，用于验证跨源隔离。
  @visibleForTesting
  LegadoRuntime legadoRuntimeForSource(RegisteredBookSource source) =>
      _legadoFor(source);

  Future<void> _ensureAdditionalProtocolsEnabled() async {
    // 米读：Legado 为原生支持，无需额外协议开关
  }

  /// Retries only on failures that a second attempt could plausibly fix:
  /// network/timeout errors, 429 and 5xx. A 404 or 400 will never succeed on
  /// retry, so those fail immediately instead of wasting three attempts.
  /// A 429 with a `Retry-After` header is honored; otherwise attempts back
  /// off with increasing delay.
  Future<T> _withRetries<T>(
    Future<T> Function() request, {
    BookDownloadCancellation? cancellation,
  }) async {
    for (var attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      cancellation?.throwIfCancelled();
      try {
        return await request();
      } on DioException catch (error) {
        if (attempt == _maxRetryAttempts || !_isRetryable(error)) {
          throw BookSourceProtocolException(
            _dioErrorMessage(error),
            code: _sourceErrorCode(error),
          );
        }
        final delay = _retryDelay(error, attempt);
        if (cancellation == null) {
          await Future<void>.delayed(delay);
        } else {
          await cancellation.delay(delay);
        }
      }
    }
    throw const BookSourceProtocolException('Source request failed.');
  }

  bool _isRetryable(DioException error) {
    final status = error.response?.statusCode;
    if (status == null) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.connectionError => true,
        _ => false,
      };
    }
    return status == HttpStatus.tooManyRequests || status >= 500;
  }

  Duration _retryDelay(DioException error, int attempt) {
    return _retryAfterHeader(error) ??
        Duration(milliseconds: 500 * attempt * attempt);
  }

  Duration? _retryAfterHeader(DioException error) {
    final value = error.response?.headers.value(HttpHeaders.retryAfterHeader);
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(0, _maxRetryAfter.inSeconds));
    }
    try {
      final delta = HttpDate.parse(value.trim()).difference(DateTime.now());
      if (delta.isNegative) return Duration.zero;
      return delta > _maxRetryAfter ? _maxRetryAfter : delta;
    } on FormatException {
      return null;
    }
  }

  static Uri _apiUri(Uri baseUrl, String relativePath) {
    final normalizedPath = baseUrl.path.endsWith('/')
        ? baseUrl.path
        : '${baseUrl.path}/';
    return baseUrl.replace(path: normalizedPath).resolve(relativePath);
  }

  /// Protocol §5 asks sources to return `{"error":{"code","message"}}`.
  /// Surface that message when present instead of discarding it in favor of
  /// a generic "HTTP $status" string.
  String _dioErrorMessage(DioException error) {
    final status = error.response?.statusCode;
    final serverMessage = _errorBody(error)?['message'];
    if (serverMessage is String && serverMessage.trim().isNotEmpty) {
      return status == null
          ? serverMessage.trim()
          : '${serverMessage.trim()} (HTTP $status)';
    }
    if (status != null) return 'Source request failed with HTTP $status.';
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'Source request timed out.',
      DioExceptionType.connectionError => 'Could not connect to the source.',
      _ => error.message ?? 'Source request failed.',
    };
  }

  String? _sourceErrorCode(DioException error) {
    final code = _errorBody(error)?['code'];
    return code is String && code.trim().isNotEmpty ? code.trim() : null;
  }

  /// Parses the `error` object out of a failed response body. Malformed or
  /// absent bodies must fall back silently rather than raise a new error.
  Map<String, dynamic>? _errorBody(DioException error) {
    try {
      final data = error.response?.data;
      if (data == null) return null;
      final decoded = decodeBookSourceJson(data);
      if (decoded is! Map) return null;
      final body = decoded['error'];
      if (body is! Map) return null;
      return body.map((key, value) => MapEntry('$key', value));
    } catch (_) {
      return null;
    }
  }
}

int compareBookSourceChapters(BookSourceChapter left, BookSourceChapter right) {
  final order = left.order.compareTo(right.order);
  return order != 0 ? order : left.id.compareTo(right.id);
}
