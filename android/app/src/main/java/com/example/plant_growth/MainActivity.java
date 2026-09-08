package com.example.plant_growth;

import android.graphics.Bitmap;
import android.media.MediaMetadataRetriever;

import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
  /** 与 lib/services/native_frame_extractor.dart 保持一致。 */
  private static final String CHANNEL = "plant_growth/frame_extractor";
  /** 视频解码属重操作，放到独立后台线程执行，避免阻塞主线程。 */
  private static final ExecutorService FRAME_WORKER = Executors.newSingleThreadExecutor();

  @Override
  public void configureFlutterEngine(FlutterEngine flutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
        .setMethodCallHandler(this::onMethodCall);
  }

  private void onMethodCall(MethodCall call, MethodChannel.Result result) {
    if (!"extractFrame".equals(call.method)) {
      result.notImplemented();
      return;
    }
    final String videoPath = call.argument("videoPath");
    final String outPath = call.argument("outPath");
    final Number timeMs = call.argument("timeMs");
    final Number maxWidth = call.argument("maxWidth");
    if (videoPath == null || outPath == null) {
      result.error("FRAME_EXTRACT_FAILED", "videoPath/outPath 缺失", null);
      return;
    }
    FRAME_WORKER.execute(() -> {
      try {
        File out = extractFrame(videoPath, outPath,
            timeMs == null ? 0L : timeMs.longValue(),
            maxWidth == null ? 0 : maxWidth.intValue());
        result.success(out.getAbsolutePath());
      } catch (Throwable t) {
        result.error("FRAME_EXTRACT_FAILED", String.valueOf(t.getMessage()), null);
      }
    });
  }

  /** 官方 MediaMetadataRetriever API：抽 timeMs 毫秒时刻一帧，等比缩放到 maxWidth 后存为 JPEG。 */
  private static File extractFrame(String videoPath, String outPath, long timeMs, int maxWidth)
      throws Exception {
    MediaMetadataRetriever retriever = new MediaMetadataRetriever();
    try {
      retriever.setDataSource(videoPath);
      Bitmap frame = retriever.getFrameAtTime(timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST);
      if (frame == null) {
        throw new IllegalStateException("getFrameAtTime 未返回帧: " + timeMs + "ms");
      }
      Bitmap out = frame;
      if (maxWidth > 0 && frame.getWidth() > maxWidth) {
        int height = Math.max(1, Math.round(frame.getHeight() * (maxWidth / (float) frame.getWidth())));
        out = Bitmap.createScaledBitmap(frame, maxWidth, height, true);
        if (out != frame) {
          frame.recycle();
        }
      }
      try {
        File parent = new File(outPath).getParentFile();
        if (parent != null && !parent.exists()) {
          parent.mkdirs();
        }
        try (FileOutputStream fos = new FileOutputStream(outPath)) {
          if (!out.compress(Bitmap.CompressFormat.JPEG, 88, fos)) {
            throw new IllegalStateException("JPEG 编码失败");
          }
        }
      } finally {
        out.recycle();
      }
      return new File(outPath);
    } finally {
      retriever.release();
    }
  }
}
