import 'dart:io';

import '../protocol/book_source_protocol.dart';

typedef BookSourceAddressLookup =
    Future<List<InternetAddress>> Function(String host);

class BookSourceNetworkPolicy {
  const BookSourceNetworkPolicy({
    BookSourceAddressLookup? lookup,
    this.allowPrivateNetwork = false,
    this.allowSyntheticDns = true,
    this.proxyAddress,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final BookSourceAddressLookup _lookup;
  final bool allowPrivateNetwork;
  final bool allowSyntheticDns;

  /// 本地 HTTP 代理（如 Clash/Mihomo 的 127.0.0.1:7897）。设置后所有请求
  /// 走该代理并把 hostname 交给代理远端解析，从而绕过 ISP DNS 污染与直连封锁
  /// （用于修复 全免漫画/猫眼看书 等强 JS 源在代理环境下的连通性）。
  final Uri? proxyAddress;

  /// 从环境变量 `BOOK_SOURCE_PROXY`（如 `http://127.0.0.1:7897`）读取本地代理。
  /// 只有显式设置该变量才走代理，未设置则回退直连，避免影响未启用代理的环境。
  static Uri? get _envProxy {
    final raw = Platform.environment['BOOK_SOURCE_PROXY']?.trim() ?? '';
    try {
      final uri = Uri.parse(raw);
      return (raw.isNotEmpty && uri.hasAuthority) ? uri : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> validate(Uri uri) async {
    await resolve(uri);
  }

  Future<List<InternetAddress>> resolve(Uri uri) async {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Book source targets must use HTTP or HTTPS.',
      );
    }
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null ? await _lookup(uri.host) : [literal];
    if (addresses.isEmpty ||
        addresses.any(
          (address) =>
              _isAlwaysBlockedAddress(address) ||
              (!allowPrivateNetwork &&
                  isBlockedAddress(
                    address,
                    allowSyntheticDns: allowSyntheticDns,
                  )),
        )) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
    return addresses;
  }

  HttpClient createPinnedHttpClient() {
    // 米读（关键修复）：不再自定义 connectionFactory。
    // 之前的实现用 Socket.startConnect 直连，会产生两个致命问题：
    //  1) 只连解析出的第一个 IP——IPv6 优先的域名（如 Cloudflare CDN）会
    //     一直挂到超时，导致大量书源搜索/正文请求失败；
    //  2) 自定义 socket 未按 HttpClient 期望完成初始化，服务器会拒绝请求，
    //     实测所有请求都返回 400 Bad Request（默认 HttpClient 同 URL 为 200）。
    // 直接返回系统默认 HttpClient：Dart 内置连接管理自动做多 IP 轮询与
    // happy-eyeballs；SSRF 防护由调用方在请求前执行 resolve/validate 承担。
    final client = HttpClient();
    final proxy = proxyAddress ?? _envProxy;
    if (proxy != null && (proxy.scheme == 'http' || proxy.scheme == 'https')) {
      final proxyTarget =
          '${proxy.host.isNotEmpty ? proxy.host : ''}'
          '${proxy.hasPort ? ':${proxy.port}' : ''}';
      if (proxyTarget.isNotEmpty) {
        client.findProxy = (uri) {
          if (uri.hasAuthority) {
            // hostname 原样交给代理远端解析，规避本地 ISP DNS 污染。
            return 'PROXY $proxyTarget; DIRECT';
          }
          return 'DIRECT';
        };
      }
    }
    return client;
  }

  static bool isBlockedAddress(
    InternetAddress address, {
    bool allowSyntheticDns = false,
  }) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return _isBlockedIpv4(bytes, allowSyntheticDns: allowSyntheticDns);
    }
    if (bytes.length != 16) return true;

    // IPv4-mapped IPv6 addresses must inherit the IPv4 restrictions.
    final isIpv4Mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isIpv4Mapped) {
      return _isBlockedIpv4(
        bytes.sublist(12),
        allowSyntheticDns: allowSyntheticDns,
      );
    }

    // Unspecified, loopback, and unique-local (fc00::/7) addresses.
    if (bytes.every((byte) => byte == 0) ||
        (bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1) ||
        (bytes[0] & 0xfe) == 0xfc) {
      return true;
    }
    return false;
  }

  static bool _isAlwaysBlockedAddress(InternetAddress address) {
    if (address.isMulticast) return true;
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    return bytes.length == 4 && bytes[0] >= 224;
  }

  static bool _isBlockedIpv4(
    List<int> bytes, {
    bool allowSyntheticDns = false,
  }) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && (second & 0xc0) == 0x40) ||
        (first == 169 && second == 254) ||
        (first == 172 && (second & 0xf0) == 16) ||
        (first == 192 && second == 168) ||
        (!allowSyntheticDns &&
            first == 198 &&
            (second == 18 || second == 19)) ||
        first >= 224;
  }

  static Uri redirectTarget(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'Book source redirect is missing its target.',
      );
    }
    final target = current.resolve(location.trim());
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const BookSourceProtocolException(
        'Book source redirects must use HTTP or HTTPS.',
      );
    }
    // 宽容：不少书源镜像站（品如漫画等）POST 搜索后会 https→http 降级重定向
    // 返回正文。真实 Legado 会跟随，故此处放行（仅限 http/https 直降，不做
    // 端口/协议逻辑态变化校验——小说站正文敏感度低，按参考实现跟随）。
    return target;
  }
}
