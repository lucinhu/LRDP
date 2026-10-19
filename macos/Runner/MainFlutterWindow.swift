import Cocoa
import FlutterMacOS

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
