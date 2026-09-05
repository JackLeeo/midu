import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';

enum LegadoCompatibilityLevel { supported, partial, unsupported }

enum LegadoCompatibilityIssue {
  audio,
  video,
  image,
  file,
  javascript,
  webView,
  login,
  cookies,
  customDns,
  customProxy,
  missingSearch,
  missingReadingRules,
  xpath,
  complexJsonPath,
}

class LegadoBookSource {
  const LegadoBookSource._(this.raw);

  factory LegadoBookSource.fromJson(Map<String, dynamic> json) {
    final raw = Map<String, dynamic>.unmodifiable(json);
    if (_string(raw['bookSourceUrl']).isEmpty ||
        _string(raw['bookSourceName']).isEmpty) {
      throw const FormatException(
        'Legado source requires bookSourceUrl and bookSourceName.',
      );
    }
    final uri = Uri.tryParse(_string(raw['bookSourceUrl']).split('#').first);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException(
        'Legado bookSourceUrl must be an absolute HTTP(S) URL.',
      );
    }
    return LegadoBookSource._(raw);
  }

  final Map<String, dynamic> raw;

  String get url => _string(raw['bookSourceUrl']);
  String get name => _string(raw['bookSourceName']);
  String get group => _string(raw['bookSourceGroup']);
  String get comment => _string(raw['bookSourceComment']);
  int get type => _integer(raw['bookSourceType']);
  String get searchUrl => _string(raw['searchUrl']);
  String get exploreUrl => _string(raw['exploreUrl']);
  bool get enabledCookieJar => raw['enabledCookieJar'] == true;
  int get lastUpdateTime => _integer(raw['lastUpdateTime']);
  int get respondTime => _integer(raw['respondTime']);

  // 米读：对标 Legado BaseSource/BookSource 的扩展字段。
  // 这些字段参与书源加权排序、登录态、JS 预加载与规则配套，均以「存在即有
  // 语义」方式读取，缺省时返回安全默认值，不影响老书源运行。

  /// 书源权重：聚合搜索/书源排序时高权重优先展示。
  int get weight => raw['weight'] == null ? 0 : _integer(raw['weight']);

  /// 并发请求数（占位字段，对齐 Legado；当前实现暂不据此限制并发）。
  int get concurrentRate => raw['concurrentRate'] == null ? 1 : _integer(raw['concurrentRate']);

  /// 登录驱动脚本：同一源所有 JS 规则执行前预编译注册的公共脚本。
  String get jsLib => _string(raw['jsLib']);

  /// 自定义请求头（JSON 对象，如 {"User-Agent": "..."}）。空返回 Map。
  Map<String, String> get header {
    final value = raw['header'];
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', '$value'));
    }
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry('$key', '$value'));
        }
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  /// 登录页 URL（含登录 UI 探测规则时可联合使用）。
  String get loginUrl => _string(raw['loginUrl']);
  String get loginUi => _string(raw['loginUi']);

  /// 登录校验 JS：登录后判断是否成功的脚本。
  String get loginCheckJs => _string(raw['loginCheckJs']);

  /// 正文段评规则（Legado ruleContent.think），用于段落间插入评论。
  String get think => _string(raw['think'] ?? _string(raw['ruleThink']));

  /// 书源式 RSS 规则（ruleRss / rssUrl）。
  String get ruleRss {
    final value = raw['ruleRss'];
    if (value is Map && value.isNotEmpty) {
      return value.entries.map((e) => '${e.key}=${e.value}').join('&&');
    }
    if (value is String) return value.trim();
    return _string(raw['rssUrl']);
  }

  /// 图片规则（ruleImage，漫画/图集源，当前兼容性扫描已标记 image 类型）。
  String get ruleImage => _string(raw['ruleImage']);

  /// 序列化回写：编辑保存后需要保留全部原始字段（含扩展字段）。
  Map<String, dynamic> toJson() => Map<String, dynamic>.unmodifiable(raw);

  /// 以新原始数据生成新实例（保持强校验）。
  LegadoBookSource copyWithRaw(Map<String, dynamic> nextRaw) {
    return LegadoBookSource.fromJson(
      Map<String, dynamic>.from(nextRaw),
    );
  }

  Uri get baseUri => Uri.parse(url.split('#').first);

  String get stableId =>
      'legado.${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}';

  Map<String, dynamic> rule(String name) {
    final value = raw[name];
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    if (value is String && value.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry('$key', value));
        }
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  bool get hasMalformedRuleJson {
    for (final name in const [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ]) {
      final value = raw[name];
      if (value is! String || !value.trim().startsWith('{')) continue;
      try {
        if (jsonDecode(value) is! Map) return true;
      } on FormatException {
        return true;
      }
    }
    return false;
  }

  RegisteredBookSource toRegisteredSource({
    bool enabled = false,
    bool readingChainVerified = false,
  }) {
    final report = const LegadoCompatibilityScanner().scan(this);
    // 米读：Legado 源只要通过兼容性扫描（report.canRun）就视为具备完整能力，
    // 不再额外强制 readingChainVerified（健康检查模块会单独探测并标记）。
    // 米读：Legado 书源的 exploreUrl/ruleExplore 对应 ORSP 的 discover 能力，
    // 只要源不是 audio/video 且有搜索和阅读规则，就同时声明 discover 能力。
    final hasFullCapabilities = report.canRun;
    final hasExplore = exploreUrl.trim().isNotEmpty ||
        rule('ruleExplore').isNotEmpty;
    return RegisteredBookSource(
      id: stableId,
      name: name,
      description: comment,
      manifestUrl: baseUri,
      apiBaseUrl: baseUri,
      websiteUrl: baseUri,
      protocolVersion: 'legado-3',
      languages: const [],
      capabilities: hasFullCapabilities
          ? (hasExplore
                ? const {'search', 'detail', 'catalog', 'content', 'discover'}
                : const {'search', 'detail', 'catalog', 'content'})
          : const {},
      enabled: enabled && hasFullCapabilities,
      addedAt: DateTime.now(),
      sourceProtocol: BookSourceProtocolKind.legado,
      sourceConfig: {
        ...raw,
        if (readingChainVerified)
          '_openReadingReadingChainVerifiedAt': DateTime.now()
              .toUtc()
              .toIso8601String(),
      },
    );
  }
}

bool isReadingChainVerifiedLegadoSource(RegisteredBookSource source) {
  return source.sourceProtocol == BookSourceProtocolKind.legado &&
      source.sourceConfig?['_openReadingReadingChainVerifiedAt'] is String;
}

class LegadoCompatibilityReport {
  const LegadoCompatibilityReport({required this.level, required this.issues});

  final LegadoCompatibilityLevel level;
  final Set<LegadoCompatibilityIssue> issues;

  /// 米读：partial 级别（含 JS/XPath/Cookies 等）通过 fjs 沙箱也可运行，
  /// 只有 unsupported（音频/视频/登录/自定义DNS代理/缺搜索缺规则）才不可运行。
  bool get canRun => level != LegadoCompatibilityLevel.unsupported;
}

class LegadoCompatibilityScanner {
  const LegadoCompatibilityScanner();

  LegadoCompatibilityReport scan(LegadoBookSource source) {
    final issues = <LegadoCompatibilityIssue>{};
    final typeIssue = switch (source.type) {
      1 => LegadoCompatibilityIssue.audio,
      2 => LegadoCompatibilityIssue.image,
      3 => LegadoCompatibilityIssue.file,
      4 => LegadoCompatibilityIssue.video,
      _ => null,
    };
    if (typeIssue != null) issues.add(typeIssue);
    if (source.searchUrl.isEmpty) {
      issues.add(LegadoCompatibilityIssue.missingSearch);
    }
    if (source.hasMalformedRuleJson) {
      issues.add(LegadoCompatibilityIssue.missingReadingRules);
    }
    if (source.rule('ruleToc').isEmpty || source.rule('ruleContent').isEmpty) {
      issues.add(LegadoCompatibilityIssue.missingReadingRules);
    }
    if (source.enabledCookieJar) issues.add(LegadoCompatibilityIssue.cookies);

    _walk(source.raw, (key, value) {
      if (value is! String || value.trim().isEmpty) return;
      final field = key.toLowerCase();
      final text = value.toLowerCase();
      if (field == 'loginurl' ||
          field == 'loginui' ||
          field == 'logincheckjs') {
        issues.add(LegadoCompatibilityIssue.login);
      }
      if (field == 'jslib' ||
          field == 'mainjs' ||
          field.endsWith('js') ||
          text.contains('<js>') ||
          text.contains('@js:') ||
          text.contains('java.') ||
          text.contains('source.')) {
        issues.add(LegadoCompatibilityIssue.javascript);
      }
      if (field == 'header' && !_isStaticJsonObject(value)) {
        issues.add(LegadoCompatibilityIssue.javascript);
      }
      if (field.contains('webview') ||
          field == 'webjs' ||
          text.contains('webview') ||
          text.contains('webjs')) {
        issues.add(LegadoCompatibilityIssue.webView);
      }
      if (text.contains('"dnsip"')) {
        issues.add(LegadoCompatibilityIssue.customDns);
      }
      if (text.contains('"proxy"')) {
        issues.add(LegadoCompatibilityIssue.customProxy);
      }
      if (_isRuleField(field) &&
          (text.startsWith('@xpath:') || text.trimLeft().startsWith('//'))) {
        issues.add(LegadoCompatibilityIssue.xpath);
      }
      if (_isRuleField(field) &&
          (text.startsWith('@json:') || text.startsWith(r'$.')) &&
          (text.contains('?(') || text.contains('..'))) {
        issues.add(LegadoCompatibilityIssue.complexJsonPath);
      }
    });

    // 米读：只有 audio/video/missingSearch/missingReadingRules 才阻塞运行；
    // login/customDns/customProxy/cookies/javascript/xpath/webView 均通过
    // fjs 沙箱、忽略或兼容方式实现，不再视为 blocked。
    // - loginUrl 字段只是声明登录入口，不代表搜索/阅读必须登录
    // - customDns/customProxy 字段可忽略，用默认网络栈请求
    // - cookies/javascript/xpath 通过 fjs 沙箱支持
    const blocked = {
      LegadoCompatibilityIssue.audio,
      LegadoCompatibilityIssue.video,
      LegadoCompatibilityIssue.missingSearch,
      LegadoCompatibilityIssue.missingReadingRules,
    };
    final hasBlockedIssue = issues.any(blocked.contains);
    final level = hasBlockedIssue
        ? LegadoCompatibilityLevel.unsupported
        : issues.isEmpty
        ? LegadoCompatibilityLevel.supported
        : LegadoCompatibilityLevel.partial;
    return LegadoCompatibilityReport(
      level: level,
      issues: Set.unmodifiable(issues),
    );
  }
}

class LegadoSourceImportResult {
  const LegadoSourceImportResult({
    required this.sources,
    required this.sourceUrls,
    required this.errors,
  });

  final List<LegadoBookSource> sources;
  final List<Uri> sourceUrls;
  final List<String> errors;
}

LegadoSourceImportResult parseLegadoSources(
  String input, {
  int maxSources = 10000,
  int maxNestedUrls = 50,
}) {
  final text = input.replaceFirst('\ufeff', '').trim();
  if (text.isEmpty) throw const FormatException('Source JSON is empty.');
  final decoded = jsonDecode(text);
  final sourceUrls = <Uri>[];
  final candidates = <Object?>[];
  if (decoded is List) {
    candidates.addAll(decoded);
  } else if (decoded is Map) {
    final nested = decoded['sourceUrls'];
    if (nested is List) {
      if (nested.length > maxNestedUrls) {
        throw FormatException(
          'Too many nested source URLs (max $maxNestedUrls).',
        );
      }
      for (final value in nested) {
        final uri = Uri.tryParse('$value');
        if (uri == null ||
            !uri.hasAuthority ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw const FormatException('Nested source URL must use HTTP(S).');
        }
        sourceUrls.add(uri);
      }
    } else if (decoded.containsKey('bookSourceUrl')) {
      candidates.add(decoded);
    } else {
      for (final key in const ['bookSourceList', 'sources', 'data']) {
        final value = decoded[key];
        if (value is List) {
          candidates.addAll(value);
          break;
        }
      }
    }
  } else {
    throw const FormatException('Expected a source object or array.');
  }
  if (candidates.length > maxSources) {
    throw FormatException('Too many sources (max $maxSources).');
  }
  final byUrl = <String, LegadoBookSource>{};
  final errors = <String>[];
  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    if (candidate is! Map) {
      errors.add('Item ${index + 1} is not an object.');
      continue;
    }
    try {
      final source = LegadoBookSource.fromJson(
        candidate.map((key, value) => MapEntry('$key', value)),
      );
      byUrl[source.url] = source;
    } on FormatException catch (error) {
      errors.add('Item ${index + 1}: ${error.message}');
    }
  }
  return LegadoSourceImportResult(
    sources: List.unmodifiable(byUrl.values),
    sourceUrls: List.unmodifiable(sourceUrls),
    errors: List.unmodifiable(errors),
  );
}

void _walk(Object? value, void Function(String key, Object? value) visitor) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = '${entry.key}';
      visitor(key, entry.value);
      _walk(entry.value, visitor);
    }
  } else if (value is List) {
    for (final item in value) {
      _walk(item, visitor);
    }
  }
}

String _string(Object? value) => value is String ? value.trim() : '';

int _integer(Object? value) => switch (value) {
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

bool _isStaticJsonObject(String value) {
  try {
    return jsonDecode(value) is Map;
  } on FormatException {
    return false;
  }
}

bool _isRuleField(String field) => const {
  'booklist',
  'name',
  'author',
  'intro',
  'kind',
  'bookurl',
  'coverurl',
  'lastchapter',
  'wordcount',
  'init',
  'tocurl',
  'chapterlist',
  'chaptername',
  'chapterurl',
  'nexttocurl',
  'content',
  'nextcontenturl',
  'replaceregex',
}.contains(field);
