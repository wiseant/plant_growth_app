import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 自研抽帧 Channel：iOS 使用官方 AVAssetImageGenerator，零第三方依赖。
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PlantFrameExtractor") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "plant_growth/frame_extractor",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "extractFrame" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let videoPath = args["videoPath"] as? String,
        let outPath = args["outPath"] as? String
      else {
        result(
          FlutterError(code: "FRAME_EXTRACT_FAILED", message: "videoPath/outPath 缺失", details: nil))
        return
      }
      let timeMs = (args["timeMs"] as? NSNumber)?.int64Value ?? 0
      let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue ?? 0

      // 解码耗时，丢后台线程执行，完成后再回主线程回调。
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let saved = try Self.extractFrame(
            videoPath: videoPath, outPath: outPath, timeMs: timeMs, maxWidth: maxWidth)
          DispatchQueue.main.async { result(saved) }
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(code: "FRAME_EXTRACT_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  /// 官方 AVAssetImageGenerator API：抽 timeMs 毫秒时刻一帧，等比缩放到 maxWidth 后存为 JPEG。
  private static func extractFrame(
    videoPath: String, outPath: String, timeMs: Int64, maxWidth: Int
  ) throws -> String {
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    if maxWidth > 0 {
      // maximumSize 会保持原始纵横比做等比缩放（只缩不放）。
      generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: CGFloat(maxWidth))
    }
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    let at = CMTime(value: timeMs * 1000, timescale: 1000)
    let cgImage = try generator.copyCGImage(at: at, actualTime: nil)

    let fileURL = URL(fileURLWithPath: outPath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.88) else {
      throw NSError(
        domain: "PlantFrameExtractor", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "JPEG 编码失败"])
    }
    try data.write(to: fileURL, options: .atomic)
    return outPath
  }
}
