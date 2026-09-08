import 'dart:math' as math;

/// 一种植物。所有字段来自 plants.json，不在 Dart 里硬编码。
class PlantSpecies {
  const PlantSpecies({
    required this.id,
    required this.name,
    required this.totalDays,
    required this.videoUrl,
    this.videoDurationMs,
    this.sampleCount,
    this.frameWidth = 720,
    this.coverUrl,
  });

  /// 唯一 id，同时用作缓存 key
  final String id;
  final String name;

  /// 完整生长周期天数（7 ~ 300）
  final int totalDays;

  /// mp4 下载地址
  final String videoUrl;

  /// 视频时长(ms)。**可为空** —— 留空则由 App 运行时探测一次并持久化。
  /// 建议：填了能省掉首次进入时的探测耗时，不填也能正常工作。
  final int? videoDurationMs;

  /// 实际抽帧数量。300 天的植物没必要抽 300 帧，
  /// 抽 120 帧 + 相邻天共用，肉眼无差别但缓存命中率更高。
  final int? sampleCount;

  /// 抽帧宽度（显示宽度的 1~1.5 倍即可，别用原始分辨率）
  final int frameWidth;

  /// 可选的成熟封面图。给了就直接用网络图，省掉一次抽帧；
  /// 不给则自动抽视频最后一帧作为封面。
  final String? coverUrl;

  int get effectiveSampleCount => sampleCount ?? totalDays;

  /// 第 day 天 -> 第几号采样帧（0-based）
  int frameIndexForDay(int day) {
    final n = effectiveSampleCount;
    if (n <= 1 || totalDays <= 1) return 0;
    final t = (day - 1) / (totalDays - 1);
    return (t * (n - 1)).round().clamp(0, n - 1);
  }

  /// 第 day 天 -> 视频中的时间戳(ms)
  /// durationMs 由运行时探测或 JSON 字段提供
  int timeMsForDay(int day, int durationMs) {
    final idx = frameIndexForDay(day);
    final n = effectiveSampleCount;
    if (n <= 1) return 0;
    // 收 1ms，避免 seek 到视频绝对末尾时原生侧返回 null
    return (idx / (n - 1) * durationMs).round().clamp(0, durationMs - 1);
  }

  factory PlantSpecies.fromJson(Map<String, dynamic> j) {
    final totalDays = j['totalDays'] as int? ?? 0;
    if (totalDays < 1) {
      throw FormatException('plant "$j" 的 totalDays 非法');
    }
    final sample = j['sampleCount'] as int?;
    return PlantSpecies(
      id: j['id'] as String,
      name: j['name'] as String,
      totalDays: totalDays,
      videoUrl: j['videoUrl'] as String,
      videoDurationMs: j['videoDurationMs'] as int?,
      sampleCount: sample == null ? null : math.max(2, sample),
      frameWidth: j['frameWidth'] as int? ?? 720,
      coverUrl: j['coverUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'totalDays': totalDays,
        'videoUrl': videoUrl,
        if (videoDurationMs != null) 'videoDurationMs': videoDurationMs,
        if (sampleCount != null) 'sampleCount': sampleCount,
        'frameWidth': frameWidth,
        if (coverUrl != null) 'coverUrl': coverUrl,
      };

  @override
  String toString() => 'PlantSpecies($id, $name, $totalDays天)';
}
