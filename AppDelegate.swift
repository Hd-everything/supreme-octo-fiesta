import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let mediaChannelName = "com.ptip.statushd/media"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: mediaChannelName, binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "trimVideo" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard
          let args = call.arguments as? [String: Any],
          let inputPath = args["inputPath"] as? String,
          let outputPath = args["outputPath"] as? String,
          let startMs = args["startMs"] as? Double ?? (args["startMs"] as? Int).map(Double.init),
          let endMs = args["endMs"] as? Double ?? (args["endMs"] as? Int).map(Double.init),
          endMs > startMs
        else {
          result(FlutterError(code: "invalid_arguments", message: "Invalid video trim range.", details: nil))
          return
        }
        self?.trimVideo(inputPath: inputPath, outputPath: outputPath, startMs: startMs, endMs: endMs, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func trimVideo(inputPath: String, outputPath: String, startMs: Double, endMs: Double, result: @escaping FlutterResult) {
    let inputURL = URL(fileURLWithPath: inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outputURL)
    let asset = AVURLAsset(url: inputURL)
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      result(FlutterError(code: "export_unavailable", message: "This video format cannot be exported on this device.", details: nil))
      return
    }
    exporter.outputURL = outputURL
    exporter.outputFileType = .mp4
    exporter.timeRange = CMTimeRange(
      start: CMTime(seconds: startMs / 1000, preferredTimescale: 600),
      duration: CMTime(seconds: (endMs - startMs) / 1000, preferredTimescale: 600)
    )
    exporter.shouldOptimizeForNetworkUse = true
    exporter.exportAsynchronously {
      DispatchQueue.main.async {
        if exporter.status == .completed {
          result(outputURL.path)
        } else {
          try? FileManager.default.removeItem(at: outputURL)
          result(FlutterError(code: "trim_failed", message: exporter.error?.localizedDescription ?? "Video trimming failed.", details: nil))
        }
      }
    }
  }
}
