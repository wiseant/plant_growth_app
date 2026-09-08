import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/plant_species.dart';
import '../services/plant_frame_service.dart';

/// 生长交互页。
///
/// - 底部主按钮：单击长 1 天；长按连续生长（帧只追最新，不做无用排队）。
/// - 帧展示优先走 [PlantFrameService.peek] 同步命中缓存；未命中则保留上一帧、
///   等后台抽帧完成后淡入新帧，任何情况都不闪黑。
/// - 达到总天数后出现「播放完整动画」，播放视频原件。
class PlantGrowthPage extends StatefulWidget {
  const PlantGrowthPage({
    super.key,
    required this.plant,
    required this.frames,
    this.videoPath,
    this.coverPath,
  });

  final PlantSpecies plant;
  final PlantFrameService frames;
  final String? videoPath;

  /// 封面（有则作为初始画面，避免首帧生成前空白）
  final String? coverPath;

  @override
  State<PlantGrowthPage> createState() => _PlantGrowthPageState();
}

class _PlantGrowthPageState extends State<PlantGrowthPage> {
  int _day = 1;
  String? _framePath;
  Timer? _autoTimer;

  // —— 帧追踪：同时只保留一个在途抽帧，期间再被请求则只追最新 ——
  bool _busy = false;
  int? _pendingDay;

  // —— 视频播放 ——
  VideoPlayerController? _controller;
  bool _playing = false;
  bool _playLoading = false;

  PlantSpecies get _plant => widget.plant;
  String? get _videoPath => widget.videoPath;
  bool get _mature => _day >= _plant.totalDays;

  @override
  void initState() {
    super.initState();
    _framePath = widget.coverPath;
    // 后台预取接下来 4 天，长按初期尽量命中缓存
    widget.frames.prefetch(_plant, _day + 1, 4, videoPath: _videoPath);
    _syncFrameTo(_day);
  }

  // ---------- 帧调度 ----------

  void _syncFrameTo(int day) {
    final hit = widget.frames.peek(_plant, day);
    if (hit != null) {
      if (day == _day && mounted) setState(() => _framePath = hit);
      return;
    }
    _pendingDay = day; // 覆盖为最新目标
    _drain();
  }

  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_pendingDay != null) {
        final target = _pendingDay!;
        _pendingDay = null;
        final fp =
            await widget.frames.frameFor(_plant, target, videoPath: _videoPath);
        if (fp != null && target == _day && mounted) {
          setState(() => _framePath = fp);
        }
      }
    } finally {
      _busy = false;
    }
  }

  // ---------- 生长操作 ----------

  void _growOneDay() {
    if (_mature) return;
    setState(() {
      _day++;
      _autoTimer?.cancel();
    });
    _syncFrameTo(_day);
  }

  void _autoStart() {
    _autoTimer?.cancel();
    _growOneDay();
    _autoTimer = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (_mature) {
        _autoStop();
        return;
      }
      _growOneDay();
    });
  }

  void _autoStop() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  void _seekTo(int day) {
    final d = day.clamp(1, _plant.totalDays);
    if (d == _day) return;
    setState(() => _day = d);
    _syncFrameTo(d);
  }

  // ---------- 视频播放 ----------

  Future<void> _playVideo() async {
    final vp = _videoPath;
    if (vp == null) return;
    setState(() => _playLoading = true);
    final controller = VideoPlayerController.file(File(vp));
    try {
      await controller.initialize();
    } catch (e) {
      if (mounted) {
        setState(() => _playLoading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('视频无法播放：$e')));
      }
      await controller.dispose();
      return;
    }
    controller.setLooping(true);
    await controller.play();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _playing = true;
      _playLoading = false;
    });
  }

  void _closeVideo() {
    final c = _controller;
    setState(() {
      _controller = null;
      _playing = false;
    });
    c?.dispose();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_plant.name)),
      body: _playing ? _buildPlayer(context) : _buildGrowth(context),
    );
  }

  /// 全屏循环播放视频层
  Widget _buildPlayer(BuildContext context) {
    final controller = _controller!;
    final ratio = controller.value.isInitialized ? controller.value.aspectRatio : 16 / 9;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Center(
          child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(controller)),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: IconButton.filled(
            tooltip: '返回画面',
            icon: const Icon(Icons.close),
            onPressed: _closeVideo,
          ),
        ),
      ],
    );
  }

  /// 生长/回看主界面
  Widget _buildGrowth(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        children: [
          Expanded(child: _buildStage(scheme)),
          _buildDayBar(),
          const SizedBox(height: 12),
          _buildControls(scheme),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// 大图舞台：淡入切换当前帧
  Widget _buildStage(ColorScheme scheme) {
    final frame = _framePath;
    final width = _plant.frameWidth;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          color: scheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: frame != null
                    ? Image.file(
                        File(frame),
                        key: ValueKey(frame),
                        fit: BoxFit.cover,
                        cacheWidth: width,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => _placeholder(scheme),
                      )
                    : _placeholder(scheme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.eco, size: 56, color: scheme.outline),
            const SizedBox(height: 8),
            Text('画面生成中…', style: TextStyle(color: scheme.outline)),
          ],
        ),
      ),
    );
  }

  /// 天数展示 + 可拖动回看的进度条
  Widget _buildDayBar() {
    final total = _plant.totalDays;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _mature ? '已成熟' : '第 $_day 天',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              Text(
                '共 $total 天',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
          Slider(
            value: _day.toDouble(),
            max: total.toDouble(),
            min: 1,
            label: '$_day / $total 天',
            onChanged: (v) => _seekTo(v.round()),
          ),
        ],
      ),
    );
  }

  /// 主操作区：生长/长按连续生长 + 成熟后播放视频
  Widget _buildControls(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          _mature
              ? _matureActions(scheme)
              : _growButton(scheme),
          const SizedBox(height: 8),
          Text(
            _mature ? '' : '轻点长一天 · 按住连续生长',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  Widget _growButton(ColorScheme scheme) {
    return SizedBox(
      height: 56,
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        // InkWell 不支持长按 start/end/cancel 生命周期，
        // 换 GestureDetector 以获得完整的「按住连续生长」手势控制。
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _growOneDay,
          onLongPressStart: (_) => _autoStart(),
          onLongPressEnd: (_) => _autoStop(),
          onLongPressCancel: _autoStop,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.grass, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                '生长一天',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _matureActions(ColorScheme scheme) {
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: _playLoading ? null : _playVideo,
            icon: _playLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle_fill, size: 26),
            label: const Text('播放完整动画', style: TextStyle(fontSize: 16)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '已走完 ${_plant.totalDays} 天的生长历程',
          style: TextStyle(color: scheme.outline, fontSize: 12),
        ),
      ],
    );
  }
}
