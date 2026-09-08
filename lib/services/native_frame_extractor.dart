import 'dart:io';

import 'package:flutter/services.dart';

/// MethodChannel 名：与 Android/iOS 原生侧注册保持一致。
const String kFrameExtractorChannel = 'plant_growth/frame_extractor';

/// 抽帧能力抽象：从本地 mp4 抽取指定毫秒时刻的一帧，输出为 JPEG 文件。
///
/// 当前实现 [NativeFrameExtractor] 直接调用平台官方 API：
/// - Android：MediaMetadataRetriever.getFrameAtTime
/// - iOS：AVAssetImageGenerator.copyCGImage
///
/// 不依赖任何第三方 pub 包，因此不会受到 AGP/Gradle 版本升级、
/// 上游仓库停止维护（jcenter 移除等）带来的影响。
abstract class FrameExtractor {
  /// [videoFile] 本地视频绝对路径（mp4）。
  /// [outputFile] 输出 JPEG 绝对路径（父目录不存在会自动创建）。
  /// [timeMs] 抽取的视频时刻（毫秒），越界时平台自动夹取到最近可用帧。
  /// [maxWidth] 缩放上限宽度（像素），<=0 表示保持原始分辨率；只缩不放。
  ///
  /// 成功返回实际产出文件的绝对路径；失败抛出异常（含 [PlatformException]）。
  Future<String?> extract({
    required String videoFile,
    required String outputFile,
    required int timeMs,
    int maxWidth = 1280,
  });
}

/// 自研原生 Channel 抽帧实现（平台自带 API，零第三方依赖）。
class NativeFrameExtractor implements FrameExtractor {
  NativeFrameExtractor({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(kFrameExtractorChannel);

  final MethodChannel _channel;

  @override
  Future<String?> extract({
    required String videoFile,
    required String outputFile,
    required int timeMs,
    int maxWidth = 1280,
  }) async {
    if (!File(videoFile).existsSync()) {
      throw ArgumentError.value(videoFile, 'videoFile', '本地视频不存在');
    }
    final out = await _channel.invokeMethod<String>('extractFrame', <String, Object>{
      'videoPath': videoFile,
      'outPath': outputFile,
      'timeMs': timeMs,
      'maxWidth': maxWidth,
    });
    if (out == null || !File(out).existsSync()) {
      throw StateError('原生抽帧未产出文件: $videoFile @ $timeMs ms');
    }
    return out;
  }
}

/// 便捷入口：页面层抽帧使用同一单例，便于集中替换实现。
final FrameExtractor frameExtractor = NativeFrameExtractor();
