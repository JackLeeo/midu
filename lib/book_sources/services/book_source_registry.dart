import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../legado/legado_book_source.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_client.dart';
import 'book_source_health_service.dart';

class BookSourceRegistry {
  static const String _storageKey = 'open_reading_book_sources_v1';
  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  /// 串行化注册表变更的尾操作（Completer 队列）。
  ///
  /// 使用 Completer 而非 Future 链的原因：flutter_test 的 testWidgets 中
  /// setUp 与 test body 运行在不同 zone，若尾链保存的是已完成的外部 Future，
  /// 新用例对它 `.then` 会把回调调度到 Future 创建时的（可能已销毁的）
  /// FakeAsync zone，导致永久挂起。Completer 可同步判断 `isCompleted`：
  /// 上一操作已完成时直接在当前 zone 调度，未完成时（同 zone 并发写）
  /// 才链式等待其 future。
  static Completer<void>? _mutationTail;

  Stream<void> get changes => _changesController.stream;

  Future<List<RegisteredBookSource>> load() async {
    return _load(filterUnverified: true);
  }

  Future<List<RegisteredBookSource>> _load({
    required bool filterUnverified,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) return const [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final sources = <RegisteredBookSource>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          sources.add(
            RegisteredBookSource.fromJson(
              item.map((key, value) => MapEntry('$key', value)),
            ),
          );
        } catch (_) {
          // Skip a damaged entry instead of making the whole registry unusable.
        }
      }
      // 保留存储顺序（对标 Legado 书源顺序）：M4 起用户可拖拽/按名称/按权重
      // 重排，加载时不得再按名字强制排序，否则手动顺序被破坏。
      if (!filterUnverified) return sources;
      // 米读：Legado 源只需兼容性扫描通过（capabilities 非空）即可参与运行；
      // ORSP 源保留原有放行逻辑。
      return sources
          .where(
            (source) =>
                source.sourceProtocol == BookSourceProtocolKind.orsp ||
                (source.sourceProtocol == BookSourceProtocolKind.legado &&
                    source.capabilities.isNotEmpty) ||
                source.sourceConfig?['_openReadingReadingChainVerifiedAt']
                    is String,
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Returns sources that may participate in runtime requests right now.
  /// 米读：额外过滤临时屏蔽列表（7天健康检查屏蔽机制）。
  Future<List<RegisteredBookSource>> loadRunnable() async {
    final list = await load();
    return BookSourceBlocklistStore.instance.filterBlocked(list);
  }

  Future<List<RegisteredBookSource>> upsert(RegisteredBookSource source) async {
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false)).toList();
      final index = sources.indexWhere((item) => item.id == source.id);
      if (index >= 0) {
        final previous = sources[index];
        // 防止书源 id 劫持：清单 id 由服务端自报，若同 id 的源来自
        // 不同域名，则拒绝静默覆盖已注册源的 API 地址。用户如确要
        // 更换域名，需先删除旧源再添加。
        final sameOrigin =
            previous.manifestUrl.host == source.manifestUrl.host &&
            previous.apiBaseUrl.host == source.apiBaseUrl.host;
        if (!sameOrigin) {
          throw BookSourceProtocolException(
            'A source with id "${source.id}" is already registered from '
            '${previous.manifestUrl.host}. Remove it first before adding a '
            'source with the same id from a different host.',
          );
        }
        sources[index] = RegisteredBookSource(
          id: source.id,
          name: source.name,
          description: source.description,
          manifestUrl: source.manifestUrl,
          apiBaseUrl: source.apiBaseUrl,
          iconUrl: source.iconUrl,
          websiteUrl: source.websiteUrl,
          operatorName: source.operatorName,
          contactUrl: source.contactUrl,
          contentLicense: source.contentLicense,
          rightsStatement: source.rightsStatement,
          protocolVersion: source.protocolVersion,
          languages: source.languages,
          capabilities: source.capabilities,
          maxCatalogPageSize: source.maxCatalogPageSize,
          enabled: previous.enabled,
          addedAt: previous.addedAt,
          sourceProtocol: source.sourceProtocol,
          sourceConfig: source.sourceConfig,
        );
      } else {
        sources.add(source);
      }
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  /// Adds or refreshes a bounded import batch in one serialized write.
  /// Existing entries keep their local enabled state and original add time.
  Future<List<RegisteredBookSource>> upsertAll(
    Iterable<RegisteredBookSource> imported,
  ) async {
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false)).toList();
      final indexes = <String, int>{
        for (var index = 0; index < sources.length; index++)
          sources[index].id: index,
      };
      for (final source in imported) {
        final index = indexes[source.id];
        if (index == null) {
          indexes[source.id] = sources.length;
          sources.add(source);
          continue;
        }
        final previous = sources[index];
        final sameOrigin =
            previous.manifestUrl.host == source.manifestUrl.host &&
            previous.apiBaseUrl.host == source.apiBaseUrl.host &&
            previous.sourceProtocol == source.sourceProtocol;
        if (!sameOrigin) {
          throw BookSourceProtocolException(
            'A source with id "${source.id}" is already registered from a '
            'different origin or protocol.',
          );
        }
        sources[index] = RegisteredBookSource(
          id: source.id,
          name: source.name,
          description: source.description,
          manifestUrl: source.manifestUrl,
          apiBaseUrl: source.apiBaseUrl,
          iconUrl: source.iconUrl,
          websiteUrl: source.websiteUrl,
          operatorName: source.operatorName,
          contactUrl: source.contactUrl,
          contentLicense: source.contentLicense,
          rightsStatement: source.rightsStatement,
          protocolVersion: source.protocolVersion,
          languages: source.languages,
          capabilities: source.capabilities,
          maxCatalogPageSize: source.maxCatalogPageSize,
          enabled: source.enabled && source.capabilities.isNotEmpty,
          addedAt: previous.addedAt,
          sourceProtocol: source.sourceProtocol,
          sourceConfig: source.sourceConfig,
        );
      }
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  Future<List<RegisteredBookSource>> setEnabled(String id, bool enabled) async {
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false))
          .map((source) {
            if (source.id != id) return source;
            if (enabled && source.capabilities.isEmpty) {
              throw const BookSourceProtocolException(
                'This source cannot be enabled because its rules are unsupported.',
              );
            }
            return source.copyWith(enabled: enabled);
          })
          .toList(growable: false);
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  /// Re-fetches a saved source's manifest while retaining local user choices.
  /// A manifest is not allowed to change the registered source identity.
  Future<List<RegisteredBookSource>> refresh(
    RegisteredBookSource source,
    BookSourceClient client,
  ) async {
    final discovered = await client.discover(source.manifestUrl.toString());
    final refreshed = RegisteredBookSource.fromManifest(
      manifest: discovered.manifest,
      manifestUrl: discovered.manifestUrl,
    );
    if (refreshed.id != source.id) {
      throw const BookSourceProtocolException(
        'The refreshed manifest changed the source ID. Remove the old source before adding it again.',
      );
    }
    return upsert(refreshed);
  }

  Future<List<RegisteredBookSource>> remove(String id) async {
    return _mutate(() async {
      final sources = (await _load(
        filterUnverified: false,
      )).where((source) => source.id != id).toList();
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  Future<List<RegisteredBookSource>> removeAll(Iterable<String> ids) async {
    final removed = ids.toSet();
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false))
          .where((source) => !removed.contains(source.id))
          .toList(growable: false);
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  Future<List<RegisteredBookSource>> setEnabledAll(
    Iterable<String> ids,
    bool enabled,
  ) async {
    final selected = ids.toSet();
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false))
          .map((source) {
            if (!selected.contains(source.id)) return source;
            final canEnable = source.capabilities.isNotEmpty;
            return source.copyWith(enabled: enabled && canEnable);
          })
          .toList(growable: false);
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  /// 按给定 id 顺序重排书源列表（对标 Legado 拖拽排序）。
  /// 仅位于 [orderedIds] 中的源参与重排，其余源保持相对顺序垫后。
  Future<List<RegisteredBookSource>> sortSources(
    Iterable<String> orderedIds,
  ) async {
    final rank = <String, int>{};
    var index = 0;
    for (final id in orderedIds) {
      if (rank.containsKey(id)) continue;
      rank[id] = index++;
    }
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false)).toList();
      final startsAt = rank.length;
      sources.sort((a, b) {
        final ra = rank[a.id] ?? startsAt;
        final rb = rank[b.id] ?? startsAt;
        if (ra != rb) return ra.compareTo(rb);
        return a.name.compareTo(b.name);
      });
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  /// 设置书源分组（对标 `bookSourceGroup`，仅 Legado 源生效）。
  /// [group] 为空时移除分组字段（回退默认分组）。
  Future<List<RegisteredBookSource>> setGroup(String id, String group) async {
    final nextGroup = group.trim();
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false))
          .map((source) {
            if (source.id != id) return source;
            final config = Map<String, dynamic>.of(source.sourceConfig ?? {});
            if (nextGroup.isEmpty) {
              config.remove('bookSourceGroup');
            } else {
              config['bookSourceGroup'] = nextGroup;
            }
            return _withConfig(source, config);
          })
          .toList(growable: false);
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  /// 设置书源权重（对标 `weight`，仅 Legado 源生效；[weight] <= 0 时清除）。
  Future<List<RegisteredBookSource>> setWeight(String id, int weight) async {
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false))
          .map((source) {
            if (source.id != id) return source;
            final config = Map<String, dynamic>.of(source.sourceConfig ?? {});
            if (weight <= 0) {
              config.remove('weight');
            } else {
              config['weight'] = weight;
            }
            return _withConfig(source, config);
          })
          .toList(growable: false);
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  static RegisteredBookSource _withConfig(
    RegisteredBookSource source,
    Map<String, dynamic> config,
  ) {
    return RegisteredBookSource(
      id: source.id,
      name: source.name,
      description: source.description,
      manifestUrl: source.manifestUrl,
      apiBaseUrl: source.apiBaseUrl,
      iconUrl: source.iconUrl,
      websiteUrl: source.websiteUrl,
      operatorName: source.operatorName,
      contactUrl: source.contactUrl,
      contentLicense: source.contentLicense,
      rightsStatement: source.rightsStatement,
      protocolVersion: source.protocolVersion,
      languages: source.languages,
      capabilities: source.capabilities,
      maxCatalogPageSize: source.maxCatalogPageSize,
      enabled: source.enabled,
      addedAt: source.addedAt,
      sourceProtocol: source.sourceProtocol,
      sourceConfig: config.isEmpty ? null : config,
    );
  }

  /// Applies an exact record-level winner received from the user's sync space.
  ///
  /// Unlike manifest refresh, sync must preserve the remote device's enabled
  /// state and added time because those fields are part of the synced record.
  Future<List<RegisteredBookSource>> applySynced(
    RegisteredBookSource source,
  ) async {
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false)).toList();
      final index = sources.indexWhere((item) => item.id == source.id);
      if (index < 0) {
        sources.add(source);
      } else {
        sources[index] = source;
      }
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  /// 米读：书源编辑保存入口。用编辑后的 Legado 原始数据替换本地配置，
  /// 保留用户本地的 enabled / addedAt 状态；若字段变化导致源不再可运行
  /// （capabilities 收缩），则自动停用，避免崩溃路径。
  ///
  /// [source] 为当前注册源；[nextRaw] 为编辑后的完整书源 JSON（含 rules）。
  Future<List<RegisteredBookSource>> updateSourceConfig(
    RegisteredBookSource source,
    Map<String, dynamic> nextRaw,
  ) async {
    final lib = LegadoBookSource.fromJson(nextRaw);
    final registered = lib.toRegisteredSource(enabled: source.enabled);
    return _mutate(() async {
      final sources = (await _load(filterUnverified: false)).toList();
      final index = sources.indexWhere((item) => item.id == source.id);
      if (index < 0) throw const BookSourceProtocolException('Source no longer exists.');
      final previous = sources[index];
      sources[index] = RegisteredBookSource(
        id: previous.id,
        name: registered.name,
        description: registered.description,
        manifestUrl: previous.manifestUrl,
        apiBaseUrl: previous.apiBaseUrl,
        iconUrl: previous.iconUrl,
        websiteUrl: previous.websiteUrl,
        operatorName: previous.operatorName,
        contactUrl: previous.contactUrl,
        contentLicense: previous.contentLicense,
        rightsStatement: previous.rightsStatement,
        protocolVersion: previous.protocolVersion,
        languages: registered.languages,
        capabilities: registered.capabilities,
        maxCatalogPageSize: previous.maxCatalogPageSize,
        enabled: previous.enabled && registered.capabilities.isNotEmpty,
        addedAt: previous.addedAt,
        sourceProtocol: previous.sourceProtocol,
        sourceConfig: registered.sourceConfig,
      );
      await _save(sources);
      _changesController.add(null);
      return load();
    });
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    Future<void> run(_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }

    final previous = _mutationTail;
    final gate = Completer<void>();
    _mutationTail = gate;
    // 上一操作已完成（或没有）时，直接在【当前】zone 调度，避免旧 zone
    // 的 Future 让 .then 永久挂起；仅在上一操作确实未完成（同 zone 内
    // 并发写，例如 load/upsert 竞态）时才链式等待其 future。
    if (previous == null || previous.isCompleted) {
      Zone.current.scheduleMicrotask(() async {
        try {
          await run(null);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      });
    } else {
      previous.future.then<void>((_) async {
        try {
          await run(null);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      }, onError: (_) async {
        try {
          await run(null);
        } finally {
          if (!gate.isCompleted) gate.complete();
        }
      });
    }
    return completer.future;
  }

  /// 测试专用：重置静态串行尾链。
  ///
  /// flutter_test 的 testWidgets 各用例运行在独立的 FakeAsync zone 中，
  /// 静态 `_mutationTail` 里的 Future 完成微任务绑定在旧 zone 上，旧 zone
  /// 销毁后新用例在此 Future 上 `.then` 永远不会触发（永久挂起）。每个用例
  /// 的 setUp 里调用本方法，让尾链在当前用例的 zone 中重新创建。
  @visibleForTesting
  static void resetMutationTailForTest() {
    _mutationTail = null;
  }

  Future<void> _save(List<RegisteredBookSource> sources) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _storageKey,
      jsonEncode(sources.map((source) => source.toJson()).toList()),
    );
  }
}
