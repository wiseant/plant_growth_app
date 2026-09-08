import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../models/plant_species.dart';
import 'native_frame_extractor.dart';

/// 抽帧缓存服务：管理「本地 mp4 -> 按天 JPEG 帧」的全链路。
///
/// - 缓存根目录 `<appSupport>/plant_frames/<id>_<url摘要>/`。
///   目录名携带视频 URL 指纹：视频换源后旧帧目录自动作废、按新源重抽。
/// - 常用帧命中后经 [peek] 同步读盘，界面零等待；未命中走 [frameFor] 后台抽帧。
/// - 并发闸门：同时最多 [maxConcurrent] 个抽帧任务，避免低端机解码器过载。
/// - 同一天被多处同时请求时合并为一次抽帧（[PlantFrameService._inflight]）。
/// - `videoDurationMs` 缺失时用 video_player 探测一次并持久化到 `durations.json`。
class PlantFrameService {
  PlantFrameService({FrameExtractor? extractor, int? maxConcurrent})
      : _extractor = extractor ?? frameExtractor,
        _maxConcurrent = maxConcurrent ?? 2;

  final FrameExtractor _extractor;
  final int _maxConcurrent;

  /// id -> 本地视频路径（启动下载完成后登记）
  final Map<String, String> _videoPaths = {};
  Directory? _root;

  /// 并发闸门状态
  final List<Future<void> Function()> _queue = [];
  int _running = 0;

  /// 同 key（plant#idx）合并：避免同一帧被并发抽多次
  final Map<String, Future<String?>> _inflight = {};

  /// 时长缓存：内存优先，磁盘兜底
  final Map<String, int> _durationMem = {};
  Map<String, int>? _durationDisk;

  /// 尚未完成的抽帧任务数（含排队与执行中），调试用
  int get pendingWork => _queue.length + _running;

  /// 初始化缓存根目录。进入主页面之前 await 一次即可；未调用时会懒加载。
  Future<Directory> init() async {
    final existing = _root;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final root =
        Directory('${base.path}${Platform.pathSeparator}plant_frames');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _root = root;
    return root;
  }

  /// 登记本地视频路径（启动下载完成后调用）。
  void registerVideos(Map<String, String> paths) {
    _videoPaths.addAll(paths);
  }

  /// 某植物本地视频路径；未登记/未下载成功返回 null。
  String? videoPathFor(PlantSpecies plant) => _videoPaths[plant.id];

  /// URL 指纹（djb2）：帧目录带视频源指纹，换源即自动作废旧帧缓存。
  static String urlDigest(String url) {
    var h = 5381;
    for (final c in url.codeUnits) {
      h = ((h << 5) + h + c) & 0x7fffffff;
    }
    return h.toRadixString(36);
  }

  Directory _plantDir(PlantSpecies p) => Directory(
      '${_root!.path}${Platform.pathSeparator}${p.id}_${urlDigest(p.videoUrl)}');

  File _frameFile(PlantSpecies p, int idx) => File(
      '${_plantDir(p).path}${Platform.pathSeparator}frame_${idx.toString().padLeft(4, '0')}.jpg');

  /// 同步探测第 [day] 天帧是否已缓存。命中返回绝对路径，否则返回 null（未缓存或未初始化）。
  ///
  /// 页面「单击生长」优先走这里：命中则立即换帧，零等待。
  String? peek(PlantSpecies p, int day) {
    final root = _root;
    if (root == null) return null;
    final f = _frameFile(p, p.frameIndexForDay(day));
    return f.existsSync() ? f.path : null;
  }

  /// 确保第 [day] 天帧存在并返回路径；未缓存则在后台抽帧。
  ///
  /// 返回 null 表示暂时取不到（本地视频缺失 / 抽帧失败），调用方应保留上一帧。
  Future<String?> frameFor(
    PlantSpecies p,
    int day, {
    String? videoPath,
  }) async {
    if (_root == null) {
      await init();
    }
    final idx = p.frameIndexForDay(day);
    final file = _frameFile(p, idx);

    if (await file.exists()) return file.path;

    final key = '${p.id}#$idx';
    final inflight = _inflight[key];
    if (inflight != null) return inflight;

    final vp = videoPath ?? videoPathFor(p);
    if (vp == null) {
      debugPrint('[PlantFrameService] ${p.id} 无本地视频，跳过 day=$day');
      return null;
    }

    final future = _schedule(() async {
      try {
        final dir = _plantDir(p);
        if (!await dir.exists()) await dir.create(recursive: true);
        final durationMs = await _durationMsFor(p, videoPath: vp);
        final timeMs = p.timeMsForDay(day, durationMs);
        await _extractor.extract(
          videoFile: vp,
          outputFile: file.path,
          timeMs: timeMs,
          maxWidth: p.frameWidth,
        );
        return file.existsSync() ? file.path : null;
      } catch (e) {
        debugPrint('[PlantFrameService] ${p.id} day=$day 抽帧失败: $e');
        return null;
      }
    });
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  /// 预取 [count] 帧（自 [fromDay] 起，均落在 1..totalDays 内）。
  /// 常用于进入生长页后预热，让长按初段尽量命中缓存。
  Future<void> prefetch(
    PlantSpecies p,
    int fromDay,
    int count, {
    String? videoPath,
  }) async {
    final vp = videoPath ?? videoPathFor(p);
    if (vp == null) return;
    final days = [
      for (var d = fromDay; d < fromDay + count; d++)
        if (d >= 1 && d <= p.totalDays) d,
    ];
    await Future.wait([for (final d in days) frameFor(p, d, videoPath: vp)]);
  }

  /// 时长解析优先级：JSON 显式字段 > 内存 > 磁盘缓存 > video_player 探测。
  Future<int> _durationMsFor(PlantSpecies p, {required String videoPath}) async {
    final given = p.videoDurationMs;
    if (given != null && given > 0) return given;

    final mem = _durationMem[p.id];
    if (mem != null) return mem;

    final disk = await _loadDurationDisk();
    final cached = disk[p.id];
    if (cached != null) {
      _durationMem[p.id] = cached;
      return cached;
    }

    final probed = await _probeDuration(videoPath);
    if (probed > 0) {
      _durationMem[p.id] = probed;
      await _saveDurationDisk(p.id, probed);
      return probed;
    }

    // 极端兜底：探测也失败时用符号性时长，保证抽帧不中断。
    debugPrint('[PlantFrameService] ${p.id} 时长探测失败，使用兜底值');
    return 10_000;
  }

  /// video_player 探测本地视频时长（一次，结果持久化）。
  Future<int> _probeDuration(String videoPath) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(File(videoPath));
      await controller.initialize();
      final ms = controller.value.duration.inMilliseconds;
      debugPrint('[PlantFrameService] 时长探测 $videoPath -> $ms ms');
      return ms;
    } catch (e) {
      debugPrint('[PlantFrameService] 时长探测失败: $e');
      return 0;
    } finally {
      await controller?.dispose();
    }
  }

  File get _durationFile =>
      File('${_root!.path}${Platform.pathSeparator}durations.json');

  Future<Map<String, int>> _loadDurationDisk() async {
    final cachedMap = _durationDisk;
    if (cachedMap != null) return cachedMap;
    final f = _durationFile;
    if (await f.exists()) {
      try {
        final data =
            jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return _durationDisk = {
          for (final e in data.entries) e.key: e.value as int,
        };
      } catch (_) {
        // 文件损坏则忽略，重新走探测
      }
    }
    return _durationDisk = {};
  }

  Future<void> _saveDurationDisk(String plantId, int ms) async {
    final map = await _loadDurationDisk();
    map[plantId] = ms;
    final f = _durationFile;
    try {
      if (!await f.parent.exists()) {
        await f.parent.create(recursive: true);
      }
      await f.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('[PlantFrameService] 时长写盘失败: $e');
    }
  }

  /// 简单信号量：最多 [_maxConcurrent] 个抽帧同时在跑。
  Future<T> _schedule<T>(Future<T> Function() job) {
    final completer = Completer<T>();
    _queue.add(() async {
      try {
        completer.complete(await job());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _pump();
    return completer.future;
  }

  void _pump() {
    while (_running < _maxConcurrent && _queue.isNotEmpty) {
      _running++;
      final job = _queue.removeAt(0);
      job().whenComplete(() {
        _running--;
        _pump();
      });
    }
  }
}
