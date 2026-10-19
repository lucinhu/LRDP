import Cocoa
import FlutterMacOS
import ImageIO

class MainFlutterWindow: NSWindow {
  private var fullscreenRequested = false
  private var fullscreenChanging = false
  private var fullscreenObservers: [NSObjectProtocol] = []

  private func applyFullscreen() {
    if !fullscreenChanging && styleMask.contains(.fullScreen) != fullscreenRequested {
      fullscreenChanging = true
      toggleFullScreen(nil)
    }
  }

  deinit {
    for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let images = FlutterMethodChannel(name: "dev.lrdp/clipboard_image",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    images.setMethodCallHandler { call, result in
      let pasteboard = NSPasteboard.general
      let limit = 16 * 1024 * 1024
      if call.method == "read" {
        var data = pasteboard.data(forType: .png)
        if data == nil, let tiff = pasteboard.data(forType: .tiff), tiff.count <= limit,
           let source = CGImageSourceCreateWithData(tiff as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 4194304,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
          data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        guard let bytes = data else { result(nil); return }
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
        pasteboard.clearContents()
        if pasteboard.setData(bytes.data, forType: .png) { result(nil) }
        else { result(FlutterError(code: "clipboard-unavailable", message: "Cannot publish image", details: nil)) }
      } else { result(FlutterMethodNotImplemented) }
    }
    for notification in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      fullscreenObservers.append(NotificationCenter.default.addObserver(
        forName: notification, object: self, queue: .main) { [weak self] _ in
          guard let window = self else { return }
          let requestedTransition = window.fullscreenChanging
          window.fullscreenChanging = false
          if requestedTransition {
            window.applyFullscreen()
          } else {
            window.fullscreenRequested = window.styleMask.contains(.fullScreen)
          }
        })
    }

    let channel = FlutterMethodChannel(name: "dev.lrdp/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "fullscreen" else { result(FlutterMethodNotImplemented); return }
      guard let window = self, let enabled = call.arguments as? Bool else {
        result(FlutterError(code: "window-unavailable", message: "Invalid window", details: nil))
        return
      }
      window.fullscreenRequested = enabled
      window.applyFullscreen()
      result(nil)
    }

    super.awakeFromNib()
  }
}
