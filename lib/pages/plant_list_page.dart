import 'dart:io';

import 'package:flutter/material.dart';

import '../models/plant_species.dart';
import '../services/plant_frame_service.dart';
import 'growth_page.dart';

/// 正式植物列表页（阶段二）。
///
/// - 封面来源：优先 coverUrl 下载图；没有封面图的植物，后台抽视频最后一帧作封面。
/// - 点卡片进入 [PlantGrowthPage] 做生长交互。
class PlantListPage extends StatefulWidget {
  const PlantListPage({
    super.key,
    required this.plants,
    required this.coverPaths,
    required this.frames,
  });

  final List<PlantSpecies> plants;
  final Map<String, String> coverPaths;
  final PlantFrameService frames;

  @override
  State<PlantListPage> createState() => _PlantListPageState();
}

class _PlantListPageState extends State<PlantListPage> {
  /// id -> 封面本地路径（网络封面 + 抽帧封面统一入口）
  final Map<String, String> _covers = {};

  @override
  void initState() {
    super.initState();
    _covers.addAll(widget.coverPaths);
    // 没配封面图的植物：用视频最后一帧当封面（后台生成，好了再刷）
    _warmUpMatureFrames();
  }

  Future<void> _warmUpMatureFrames() async {
    for (final p in widget.plants) {
      if (_covers.containsKey(p.id)) continue;
      final fp = await widget.frames.frameFor(p, p.totalDays);
      if (fp != null && mounted) {
        setState(() => _covers[p.id] = fp);
      }
    }
  }

  void _open(PlantSpecies p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlantGrowthPage(
          plant: p,
          frames: widget.frames,
          videoPath: widget.frames.videoPathFor(p),
          coverPath: _covers[p.id],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plants = widget.plants;
    return Scaffold(
      appBar: AppBar(title: const Text('我的植物')),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.8,
        ),
        itemCount: plants.length,
        itemBuilder: (context, i) => _buildCard(plants[i]),
      ),
    );
  }

  Widget _buildCard(PlantSpecies p) {
    final scheme = Theme.of(context).colorScheme;
    final cover = _covers[p.id];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(p),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: cover != null
                  ? Image.file(
                      File(cover),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => _fallback(scheme),
                    )
                  : _fallback(scheme),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${p.totalDays} 天',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.eco, size: 48, color: scheme.outline),
      ),
    );
  }
}
