// 文件说明：发现页内容缓存服务。首次进入先渲染上次缓存避免空白页，
// 网络数据拉取成功后再静默写回替换，下次启动继续读缓存。
// 技术要点：本地文件 JSON 缓存、过期失效。

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 发现页缓存：仅持久化一个 JSON 文件，由页面负责编解码。
class DiscoveryCacheService {
  DiscoveryCacheService._();

  static final DiscoveryCacheService instance = DiscoveryCacheService._();

  static const String _fileName = 'discovery_cache_v1.json';
  static const Duration _maxAge = Duration(hours: 6);

  Future<File?> _file() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } catch (_) {
      return null;
    }
  }

  /// 读取缓存，过期或不可用时返回 null（调用方应展示空白/加载态）。
  Future<String?> read() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return null;
      final stat = await file.stat();
      final age = DateTime.now().difference(stat.modified);
      if (age > _maxAge) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 静默把最新内容写入缓存；失败不影响主流程。
  Future<void> write(String json) async {
    try {
      final file = await _file();
      if (file == null) return;
      await file.create(recursive: true);
      await file.writeAsString(json, flush: true);
    } catch (_) {}
  }
}