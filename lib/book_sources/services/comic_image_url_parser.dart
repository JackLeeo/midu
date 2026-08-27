import 'dart:convert';

/// 从章节正文提取漫画图片 URL 列表的公共解析器。
///
/// 引擎（LegadoRuntime）与章节磁盘缓存（BookSourceChapterCache）共用同一份
/// 识别逻辑，避免两边各自维护一套规则导致同一正文在请求路径识别成漫画、
/// 缓存恢复路径却识别成文本的漂移。返回的每个元素都是可被图片加载器直接
/// 请求的绝对 http(s) 地址。
///
/// 依次尝试：JSON 图片数组 → HTML `<img>`（src 带双引号/单引号/无引号三种
/// 形态，相对路径用 [baseUrl] 拼成绝对地址）→ Markdown 图片语法 → 纯 URL
/// 列表。全部无法识别返回空，正文按普通文本处理。
///
/// [baseUrl] 通常传章节请求的最终 URL：漫画源的正文常为相对路径 `<img>`，
/// 需要用章节页/章节目录地址补全为可下载的绝对图片地址。
List<String> extractContentImageUrls(
  String content, {
  String? baseUrl,
}) {
  if (content.trim().isEmpty) return const [];
  final trimmed = content.trim();
  // 1) JSON 形态：{images:[…]} / {imgs:[…]} / 嵌套 data/images，或纯字符串数组。
  final jsonUrls = _imageUrlsFromJson(trimmed);
  if (jsonUrls.isNotEmpty) return jsonUrls;
  // 2) HTML <img> 形态：src 允许双引号、单引号、完全无引号（部分漫画源的
  //    规则直接拼 '<img src='+url+'>'，无引号）。相对路径由 baseUrl 补全。
  final imgUrls = <String>[];
  final imgRe = RegExp(
    r"""<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""",
    caseSensitive: false,
  );
  for (final match in imgRe.allMatches(trimmed)) {
    final raw = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
    final resolved = resolveChapterImage(raw, baseUrl);
    if (resolved != null) imgUrls.add(resolved);
  }
  // 至少 2 张图，或正文几乎全部由图片标签组成，才判定为漫画正文，
  // 避免小说里一张装饰图（如站点 logo/表情）误入漫画翻页渲染。
  if (imgUrls.length >= 2) return imgUrls;
  if (imgUrls.length == 1) {
    final stripped = trimmed.replaceAll(imgRe, '').trim();
    if (stripped.length * 5 <= trimmed.length) return imgUrls;
  }
  // 3) Markdown 图片语法：![](url)
  final markdownUrls = <String>[];
  final mdRe = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');
  for (final match in mdRe.allMatches(trimmed)) {
    final resolved = resolveChapterImage(match.group(1) ?? '', baseUrl);
    if (resolved != null) markdownUrls.add(resolved);
  }
  if (markdownUrls.isNotEmpty) return markdownUrls;
  // 4) 非 JSON/非 img：整段按空白拆分成若干 URL。仅凭"每段都是合法绝对
  //    http(s)"不足以判定漫画——小说源可能把正文文本以 URL 形式返回。要求每段
  //    地址还必须"看起来像图片"（路径以常见图片扩展名结尾），避免正文 URL
  //    文本误入漫画翻页渲染。
  final tokens =
      trimmed.split(RegExp(r'[\s,，]+')).where((s) => s.isNotEmpty).toList();
  if (tokens.isEmpty) return const [];
  final urls = <String>[];
  for (final token in tokens) {
    final resolved = resolveChapterImage(token, baseUrl);
    if (resolved == null || !isImageLikeUrl(resolved)) return const [];
    urls.add(resolved);
  }
  return urls;
}

/// 把单个图片地址归一为可下载的绝对 http(s) URL，无法识别返回 null。
/// 支持：绝对 http(s)、相对路径（用 [baseUrl] 拼接）、常见尾部杂质清理。
String? resolveChapterImage(String rawSrc, String? baseUrl) {
  var src = rawSrc.trim();
  if (src.isEmpty || src.startsWith('data:')) return null;
  // 清理 HTML 杂质与转义实体：无引号 src 常带 > 或行尾逗号残留。
  src = src
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[>;)\]},]+$'), '')
      .trim();
  final uri = Uri.tryParse(src);
  if (uri != null &&
      uri.isAbsolute &&
      (uri.scheme == 'http' || uri.scheme == 'https')) {
    return uri.toString();
  }
  if (baseUrl != null) {
    final base = Uri.tryParse(baseUrl);
    if (base != null && base.isAbsolute) {
      final resolved = base.resolve(src);
      if (resolved.scheme == 'http' || resolved.scheme == 'https') {
        return resolved.toString();
      }
    }
  }
  return null;
}

/// 判断 URL 是否「看起来像图片」：去掉 query/fragment 后路径以常见图片扩展名
/// 结尾（jpg/jpeg/png/webp/gif/bmp/avif）。纯 URL 列表形态用它防误判——
/// 有些小说源会把正文以 URL 文本形式返回，仅「全是合法 http(s)」不足以判定漫画。
bool isImageLikeUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final path = uri.path.toLowerCase();
  const imageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'avif',
  ];
  for (final ext in imageExtensions) {
    if (path.endsWith('.$ext')) return true;
  }
  return false;
}

/// 从 JSON 中递归提取图片地址列表。识别 {images:[…]}、{imgs:[…]}、
/// {pictures:[…]} 等键，以及嵌套的 {"data": {"images": …}} 和对象数组内
/// 的 url/src 字段。找不到图片数组返回空。
List<String> _imageUrlsFromJson(String trimmed) {
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return const [];
  }
  return _imageUrlListFromJson(decoded);
}

List<String> _imageUrlListFromJson(Object? value) {
  if (value is String) return const [];
  if (value is List) {
    final direct = _listOfStrings(value);
    if (direct.isNotEmpty) return direct;
    for (final item in value) {
      final sub = _imageUrlListFromJson(item);
      if (sub.isNotEmpty) return sub;
    }
    return const [];
  }
  if (value is Map) {
    for (final entry in value.entries) {
      final key = '${entry.key}'.toLowerCase();
      if (key.contains('image') ||
          key.contains('img') ||
          key.contains('pic') ||
          key.contains('url')) {
        if (entry.value is String) {
          final part = _listOfStrings(
            entry.value.split(RegExp(r'[\s,，]+')).toList(),
          );
          if (part.isNotEmpty) return part;
        }
        final sub = _imageUrlListFromJson(entry.value);
        if (sub.isNotEmpty) return sub;
      }
    }
    for (final entry in value.entries) {
      final sub = _imageUrlListFromJson(entry.value);
      if (sub.isNotEmpty) return sub;
    }
  }
  return const [];
}

/// 把 JSON 列表安全归一成非空字符串列表。
List<String> _listOfStrings(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .map((s) => s.trim())
      .toList(growable: false);
}