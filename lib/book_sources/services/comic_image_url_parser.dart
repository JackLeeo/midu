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
  //    规则直接拼 '<img src='+url+'>'，无引号）。无引号分支允许含空格——
  //    部分漫画源图片 URL 直接带未编码空格（如 kaimanhua 章节图
  //    '/comic/Y/ 妖者为王/…'），严格按空白截断会取到半个 URL。
  //    相对路径由 baseUrl 补全。
  final imgUrls = <String>[];
  final imgRe = RegExp(
    r"""<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^"'>]+))""",
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
  // 4) 通用 URL 扫描：正文常被包裹成「数组形态文本」——真实漫画源把图片列表
  //    toString 成 '[url1, url2, …]'（如 kaimanhua 的 ruleContent 对
  //    chapter_img_list 数组取 result 后未按预期拼 img 标签）。这里直接收集
  //    正文里所有 http(s) URL 子串（允许 URL 内含未编码空格，直到逗号/右
  //    括号/右花括号/右尖括号才截断），规范化后仅保留「看起来像图片」的地址。
  //    图片 URL 数量 ≥2 才判定漫画：防止小说正文里的零星链接误判。
  final scanned = <String>[];
  // 停止集：逗号/右括号/右花括号/右尖括号/换行回车——换行分隔的 URL 列表
  // 若被连成单串会导致 Uri.parse 失败；空格（未编码）则允许并稍后编码为 %20。
  final urlRe = RegExp(r"https?://[^,\]}>\n\r]*", caseSensitive: false);
  for (final match in urlRe.allMatches(trimmed)) {
    final resolved = resolveChapterImage(match.group(0) ?? '', baseUrl);
    if (resolved != null && isImageLikeUrl(resolved)) scanned.add(resolved);
  }
  final unique = <String>[];
  for (final url in scanned) {
    if (!unique.contains(url)) unique.add(url);
  }
  return unique;
}

/// 把单个图片地址归一为可下载的绝对 http(s) URL，无法识别返回 null。
/// 支持：绝对 http(s)、相对路径（用 [baseUrl] 拼接）、常见尾部杂质清理，
/// 以及把未编码空格规范为 %20（部分漫画源的图片 URL 直接含空格，如
/// kaimanhua 章节图 '/comic/Y/ 妖者为王/…'；不编码时下游 Uri.parse
/// 抛 FormatException）。
String? resolveChapterImage(String rawSrc, String? baseUrl) {
  var src = rawSrc.trim();
  if (src.isEmpty || src.startsWith('data:')) return null;
  // 清理 HTML 杂质与转义实体：无引号 src 常带 > 或行尾逗号残留。
  src = src
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[>;)\]},]+$'), '')
      .trim();
  // 空格是 URI 非法字符，需编码为 %20 才能被 Uri.parse / 图片加载器接受。
  src = src.replaceAll(' ', '%20');
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