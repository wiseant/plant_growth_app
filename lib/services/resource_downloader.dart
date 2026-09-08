import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models/plant_species.dart';

/// 启动时资源下载进度
class DownloadState {
  const DownloadState({
    required this.completed,
    required this.total,
    this.currentName,
    this.currentProgress = 0,
    this.downloadedBytes = 0,
    this.error,
    this.done = false,
  });

  final int completed;
  final int total;

  /// 当前正在下载的资源名
  final String? currentName;

  /// 当前文件进度 0~1
  final double currentProgress;

  final int downloadedBytes;
  final String? error;
  final bool done;

  /// 整体进度 0~1。按每个文件的进度求平均，比单纯数文件数更平滑。
  double get overall {
    if (total == 0) return 1;
    return ((completed + currentProgress) / total).clamp(0.0, 1.0);
  }

  bool get hasError => error != null;
}

enum _TaskKind { video, cover }

/// 单个下载任务
class _Task {
  _Task(this.url, this.label, this.kind);
  final String url;
  final String label;

  /// video 是进入主页面的必需资源；cover 失败可以容忍
  final _TaskKind kind;

  double progress = 0;
  int downloaded = 0;

  bool get required => kind == _TaskKind.video;
}

/// 启动资源下载器：把 JSON 里声明的 mp4（及可选封面图）拉到本地缓存。
///
/// 特性：
///  - 已缓存的资源秒过，不重复下载
///  - 并发度 3，避免低端机网络拥塞
///  - 实时进度回调（文件级 + 字节级）
///  - 视频校验 mp4 文件头，坏缓存自动重下
class ResourceDownloader {
  ResourceDownloader({this.concurrency = 3});

  /// 并发下载任务数
  final int concurrency;
  final CacheManager _cache = CacheManager(
    Config(
      'plantMediaCache',
      stalePeriod: const Duration(days: 365),
      maxNrOfCacheObjects: 200,
    ),
  );

  final _controller = StreamController<DownloadState>.broadcast();

  /// 进度流
  Stream<DownloadState> get progress => _controller.stream;

  final Map<String, String> _videoPaths = {};
  final Map<String, String> _coverPaths = {};

  Map<String, String> get videoPaths => Map.unmodifiable(_videoPaths);
  Map<String, String> get coverPaths => Map.unmodifiable(_coverPaths);

  /// 开始下载。返回的 Future 在所有任务结束后完成。
  Future<DownloadResult> start(List<PlantSpecies> plants) async {
    final tasks = <_Task>[];
    final videoOwner = <_Task, PlantSpecies>{};
    final coverOwner = <_Task, PlantSpecies>{};

    for (final p in plants) {
      final t = _Task(p.videoUrl, p.name, _TaskKind.video);
      tasks.add(t);
      videoOwner[t] = p;

      final cover = p.coverUrl;
      if (cover != null) {
        final c = _Task(cover, '${p.name} 封面', _TaskKind.cover);
        tasks.add(c);
        coverOwner[c] = p;
      }
    }

    var completed = 0;
    String? fatalError;

    void emit(String? currentName, double currentProgress) {
      if (_controller.isClosed) return;
      var bytes = 0;
      for (final t in tasks) {
        bytes += t.downloaded;
      }
      _controller.add(DownloadState(
        completed: completed,
        total: tasks.length,
        currentName: currentName,
        currentProgress: currentProgress,
        downloadedBytes: bytes,
        error: fatalError,
      ));
    }

    emit(null, 0);

    // 先过一遍本地缓存，命中的直接登记，不走网络
    final pending = <_Task>[];
    for (final t in tasks) {
      final hit = await _cache.getFileFromCache(t.url);
      if (hit != null && await _isHealthy(hit.file, t.kind)) {
        _register(t, hit.file.path, videoOwner, coverOwner);
        t.progress = 1;
        completed++;
        emit(null, 0);
      } else {
        if (hit != null) {
          await _cache.removeFile(t.url); // 坏缓存清掉重下
        }
        pending.add(t);
      }
    }

    if (pending.isEmpty) {
      if (!_controller.isClosed) {
        _controller.add(DownloadState(
            completed: completed, total: tasks.length, done: true));
      }
      return DownloadResult(_videoPaths, _coverPaths);
    }

    // 并发下载
    final queue = List<_Task>.from(pending);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        if (cursor >= queue.length) return;
        final t = queue[cursor++];
        try {
          await for (final resp
              in _cache.getFileStream(t.url, withProgress: true)) {
            if (resp is DownloadProgress) {
              t.progress = resp.progress ?? 0;
              t.downloaded = resp.downloaded;
              emit(t.label, t.progress);
            } else if (resp is FileInfo) {
              t.progress = 1;
              t.downloaded = resp.file.lengthSync();
              _register(t, resp.file.path, videoOwner, coverOwner);
            }
          }
        } catch (e) {
          debugPrint('[ResourceDownloader] 下载失败 ${t.url}: $e');
          if (t.required) fatalError = '${t.label} 下载失败，请检查网络';
        } finally {
          completed++;
          emit(null, 0);
        }
      }
    }

    final n = concurrency.clamp(1, queue.length);
    await Future.wait([for (var i = 0; i < n; i++) worker()]);

    if (!_controller.isClosed) {
      _controller.add(DownloadState(
        completed: completed,
        total: tasks.length,
        done: true,
        error: fatalError,
      ));
    }
    return DownloadResult(_videoPaths, _coverPaths, error: fatalError);
  }

  void _register(
    _Task t,
    String path,
    Map<_Task, PlantSpecies> videoMap,
    Map<_Task, PlantSpecies> coverMap,
  ) {
    if (t.kind == _TaskKind.video) {
      final p = videoMap[t];
      if (p != null) _videoPaths[p.id] = path;
    } else {
      final p = coverMap[t];
      if (p != null) _coverPaths[p.id] = path;
    }
  }

  /// 缓存健康检查。
  /// 视频：校验 mp4 的 'ftyp' 魔数，防止截断文件被当成已下载。
  /// 图片：只校验非空（封面格式可能是 jpg/png/webp，不做魔数限制）。
  Future<bool> _isHealthy(File f, _TaskKind kind) async {
    try {
      if (!await f.exists()) return false;
      final len = await f.length();
      if (len < 512) return false;

      if (kind == _TaskKind.cover) return true;

      final head = await f.openRead(0, 16).first;
      if (head.length < 8) return false;
      // mp4 结构: [size][ftyp]...
      return String.fromCharCodes(head.sublist(4, 8)) == 'ftyp';
    } catch (_) {
      return false;
    }
  }

  void dispose() => _controller.close();
}

class DownloadResult {
  DownloadResult(this.videos, this.covers, {this.error});
  final Map<String, String> videos;
  final Map<String, String> covers;
  final String? error;
  bool get ok => error == null;
}
