import Flutter
import UIKit

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
    let channel = FlutterMethodChannel(name: "dev.lrdp/clipboard_image",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      let pasteboard = UIPasteboard.general
      let limit = 16 * 1024 * 1024
      if call.method == "read" {
        // Prefer encoded data so dimensions are checked by Dart before decoding.
        guard let bytes = pasteboard.data(forPasteboardType: "public.png") ??
                pasteboard.data(forPasteboardType: "public.jpeg") else { result(nil); return }
        guard bytes.count <= limit else {
          result(FlutterError(code: "clipboard-unavailable", message: "Image exceeds 16 MiB", details: nil)); return
        }
        result(["kind": 1, "bytes": FlutterStandardTypedData(bytes: bytes)])
      } else if call.method == "write" {
        guard let args = call.arguments as? [String: Any],
              let bytes = args["png"] as? FlutterStandardTypedData,
              !bytes.data.isEmpty, bytes.data.count <= limit else {
          result(FlutterError(code: "clipboard-unavailable", message: "Invalid image", details: nil)); return
        }
        pasteboard.setData(bytes.data, forPasteboardType: "public.png")
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
  }
}
