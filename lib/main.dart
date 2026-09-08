import 'dart:async';

import 'package:flutter/material.dart';

import 'models/plant_species.dart';
import 'pages/plant_list_page.dart';
import 'services/plant_frame_service.dart';
import 'services/plant_repository.dart';
import 'services/resource_downloader.dart';

/// 远程配置地址。改成你自己的 CDN 地址后，**新增植物只需改服务器 JSON，不用发版**。
/// 设为 null 则纯本地 assets 模式。
const String? kRemoteConfigUrl = null;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PlantApp());
}

class PlantApp extends StatelessWidget {
  const PlantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '植物生长',
      theme: ThemeData(
        colorSchemeSeed: Colors.green,
        useMaterial3: true,
      ),
      home: const SplashPage(),
    );
  }
}

/// 启动页：加载配置 -> 下载缺失资源（带进度条）-> 进入主页面
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  StreamSubscription<DownloadState>? _sub;
  DownloadState? _state;
  String? _fatal;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      // 1) 加载配置（本地打底，远程覆盖）
      final repo = PlantRepository(remoteConfigUrl: kRemoteConfigUrl);
      final config = await repo.load();

      if (config.plants.isEmpty) {
        if (mounted) setState(() => _fatal = '配置为空：没有找到任何植物');
        return;
      }

      // 2) 下载缺失资源
      final downloader = ResourceDownloader(concurrency: 3);
      _sub = downloader.progress.listen((s) {
        if (!mounted) return;
        setState(() => _state = s);
        if (s.done) _onDone(downloader, config.plants, s);
      });

      await downloader.start(config.plants);
    } catch (e) {
      if (mounted) setState(() => _fatal = '启动失败：$e');
    }
  }

  Future<void> _onDone(
    ResourceDownloader downloader,
    List<PlantSpecies> plants,
    DownloadState state,
  ) async {
    if (_entered) return;

    // 必需资源（视频）失败 -> 停在错误页让用户重试
    if (state.hasError) {
      if (mounted) setState(() => _fatal = state.error);
      return;
    }

    _entered = true;

    if (!mounted) return;

    // 3) 抽帧服务登记视频路径并初始化缓存根目录
    final frames = PlantFrameService();
    frames.registerVideos(downloader.videoPaths);
    await frames.init();

    if (!mounted) return;

    // 4) 进入正式列表页（阶段二）
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlantListPage(
          plants: plants,
          coverPaths: downloader.coverPaths,
          frames: frames,
        ),
      ),
    );
  }

  void _retry() {
    setState(() {
      _fatal = null;
      _state = null;
      _entered = false;
    });
    _sub?.cancel();
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final err = _fatal;
    final s = _state;
    final pct = s == null ? 0 : (s.overall * 100).round();

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: err != null ? _buildError(err) : _buildProgress(s, pct),
        ),
      ),
    );
  }

  Widget _buildProgress(DownloadState? s, int pct) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.eco, size: 64, color: Colors.green),
        const SizedBox(height: 24),
        const Text('正在准备植物资源',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        SizedBox(
          width: 260,
          child: LinearProgressIndicator(
            value: s?.overall,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          s == null
              ? '读取配置…'
              : s.done
                  ? '完成，正在进入…'
                  : '$pct%　${s.completed}/${s.total}'
                      '${s.currentName != null ? '　·　${s.currentName}' : ''}',
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildError(String msg) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off, size: 64, color: Colors.orange),
        const SizedBox(height: 24),
        Text(msg, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
          onPressed: _retry,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
