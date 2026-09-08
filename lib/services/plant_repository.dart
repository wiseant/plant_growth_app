import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../models/plant_species.dart';

/// 植物配置仓库。
///
/// 加载策略：**本地 assets 打底 + 远程 JSON 覆盖**
///   1. 先读 assets/plants/plants.json —— 保证首次启动、离线状态一定可用
///   2. 若提供了 remoteUrl，再尝试拉取远程配置，成功则覆盖
///      （超时 4s 自动放弃，不拖慢启动）
///
/// 这样「新增植物」只需改服务器上的 JSON，用户无感更新，不用发版。
class PlantRepository {
  PlantRepository({
    this.remoteConfigUrl,
    this.localAssetPath = 'assets/plants/plants.json',
    this.timeout = const Duration(seconds: 4),
  });

  /// 远程配置地址。为 null 时纯本地模式。
  final String? remoteConfigUrl;
  final String localAssetPath;

  /// 远程配置拉取超时
  final Duration timeout;

  /// 加载配置（本地优先，远程覆盖）
  Future<PlantConfig> load() async {
    PlantConfig local;
    try {
      local = await loadLocal();
    } catch (e, st) {
      debugPrint('[PlantRepository] 本地配置加载失败: $e\n$st');
      rethrow;
    }

    if (remoteConfigUrl == null) return local;

    try {
      final remote = await _fetchRemote(remoteConfigUrl!);
      debugPrint('[PlantRepository] 远程配置生效，${remote.plants.length} 种植物');
      return remote;
    } catch (e) {
      // 远程失败静默回退本地，不让用户感知
      debugPrint('[PlantRepository] 远程配置不可用，回退本地: $e');
      return local;
    }
  }

  /// 只加载本地 assets 配置
  Future<PlantConfig> loadLocal() async {
    final text = await rootBundle.loadString(localAssetPath);
    return PlantConfig.fromJsonString(text);
  }

  Future<PlantConfig> _fetchRemote(String url) async {
    final resp = await http
        .get(Uri.parse(url))
        .timeout(timeout, onTimeout: () => throw TimeoutException('远程配置超时', timeout));
    if (resp.statusCode != 200) {
      throw HttpExceptionLite('远程配置 HTTP ${resp.statusCode}');
    }
    return PlantConfig.fromJsonString(utf8.decode(resp.bodyBytes));
  }
}

/// 一份完整的植物配置
class PlantConfig {
  const PlantConfig({required this.plants, this.version = 0});

  final List<PlantSpecies> plants;

  /// 配置版本号。视频替换后可 +1，用于强制刷新抽帧缓存。
  final int version;

  factory PlantConfig.fromJsonString(String text) {
    final decoded = json.decode(text);
    if (decoded is List) {
      // 兼容「顶层直接是数组」的写法
      return PlantConfig(
        plants: decoded
            .map((e) => PlantSpecies.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }
    final map = decoded as Map<String, dynamic>;
    final list = (map['plants'] as List? ?? []);
    return PlantConfig(
      version: map['version'] as int? ?? 0,
      plants: list
          .map((e) => PlantSpecies.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  PlantSpecies? byId(String id) {
    for (final p in plants) {
      if (p.id == id) return p;
    }
    return null;
  }
}

class HttpExceptionLite implements Exception {
  HttpExceptionLite(this.message);
  final String message;
  @override
  String toString() => message;
}
