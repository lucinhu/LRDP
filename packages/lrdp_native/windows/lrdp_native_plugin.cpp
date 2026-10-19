#include "include/lrdp_native/lrdp_native_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <algorithm>
#include <condition_variable>
#include <map>
#include <thread>
#include <windows.h>

#include "video_texture.h"

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using lrdp::VideoTexture;

const EncodableValue* Argument(const EncodableMap* args, const char* key) {
  if (!args) return nullptr;
  auto found = args->find(EncodableValue(key));
  return found == args->end() ? nullptr : &found->second;
}

bool Integer(const EncodableValue* value, int64_t* output) {
  if (!value) return false;
  if (const auto* number = std::get_if<int64_t>(value)) {
    *output = *number;
    return true;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    *output = *number;
    return true;
  }
  return false;
}

EncodableMap Status(int64_t id, VideoTexture& video, int frame_rate) {
  auto status = video.Status();
  return {{EncodableValue("id"), EncodableValue(id)},
          {EncodableValue("width"), EncodableValue(status.width)},
          {EncodableValue("height"), EncodableValue(status.height)},
          {EncodableValue("generation"),
           EncodableValue(static_cast<int64_t>(status.generation))},
          {EncodableValue("uploads"),
           EncodableValue(static_cast<int64_t>(status.uploads))},
          {EncodableValue("failed"), EncodableValue(status.failed)},
          {EncodableValue("frameRate"), EncodableValue(frame_rate)}};
}
struct ScheduledVideo {
  std::shared_ptr<VideoTexture> texture;
  int frame_rate = 60;
  std::chrono::steady_clock::time_point next{};
};

void ClipboardImage(HWND window, const flutter::MethodCall<EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const bool read = call.method_name() == "read";
  if (!read && call.method_name() != "write") { result->NotImplemented(); return; }
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  constexpr size_t limit = 16 * 1024 * 1024;
  if (!png_format || !OpenClipboard(window)) {
    result->Error("clipboard-unavailable", "Cannot open clipboard"); return;
  }
  struct Close { ~Close() { CloseClipboard(); } } close;
  if (read) {
    UINT format = IsClipboardFormatAvailable(png_format) ? png_format :
      IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB;
    if (!IsClipboardFormatAvailable(format)) { result->Success(); return; }
    HANDLE handle = GetClipboardData(format);
    const SIZE_T size = handle ? GlobalSize(handle) : 0;
    if (!size || size > limit) { result->Error("clipboard-unavailable", "Invalid image size"); return; }
    const auto* bytes = static_cast<const uint8_t*>(GlobalLock(handle));
    if (!bytes) { result->Error("clipboard-unavailable", "Cannot read image"); return; }
    std::vector<uint8_t> copy(bytes, bytes + size);
    GlobalUnlock(handle);
    result->Success(EncodableValue(EncodableMap{
      {EncodableValue("kind"), EncodableValue(format == png_format ? 1 : 2)},
      {EncodableValue("bytes"), EncodableValue(std::move(copy))}}));
    return;
  }
  const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
  const auto* png_value = Argument(args, "png");
  const auto* dib_value = Argument(args, "dib");
  const auto* png = png_value ? std::get_if<std::vector<uint8_t>>(png_value) : nullptr;
  const auto* dib = dib_value ? std::get_if<std::vector<uint8_t>>(dib_value) : nullptr;
  if (!png || !dib || png->empty() || dib->empty() || png->size() > limit || dib->size() > limit) {
    result->Error("clipboard-unavailable", "Invalid image size"); return;
  }
  auto allocate = [](const std::vector<uint8_t>& bytes) -> HGLOBAL {
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!handle) return nullptr;
    void* data = GlobalLock(handle);
    if (!data) { GlobalFree(handle); return nullptr; }
    memcpy(data, bytes.data(), bytes.size()); GlobalUnlock(handle); return handle;
  };
  HGLOBAL png_handle = allocate(*png), dib_handle = allocate(*dib);
  bool ok = png_handle && dib_handle && EmptyClipboard();
  if (ok) {
    if (SetClipboardData(png_format, png_handle)) png_handle = nullptr;
    else ok = false;
    if (SetClipboardData(CF_DIB, dib_handle)) dib_handle = nullptr;
    else ok = false;
  }
  if (png_handle) GlobalFree(png_handle);
  if (dib_handle) GlobalFree(dib_handle);
  if (ok) result->Success();
  else result->Error("clipboard-unavailable", "Cannot publish clipboard image");
}

class VideoPlugin : public flutter::Plugin {
 public:
  explicit VideoPlugin(flutter::PluginRegistrarWindows* registrar,
                       FlutterDesktopTextureRegistrarRef textures,
                       FlutterDesktopMessengerRef messenger)
      : textures_(textures),
        window_(GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT)),
        messenger_(FlutterDesktopMessengerAddRef(messenger)),
        channel_(registrar->messenger(), "dev.lrdp/video",
                 &flutter::StandardMethodCodec::GetInstance()),
        window_channel_(registrar->messenger(), "dev.lrdp/window",
                 &flutter::StandardMethodCodec::GetInstance()),
        clipboard_channel_(registrar->messenger(), "dev.lrdp/clipboard_image",
                 &flutter::StandardMethodCodec::GetInstance()) {
    clipboard_channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      ClipboardImage(window_, call, std::move(result));
    });
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      Handle(call, std::move(result));
    });
    window_channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (call.method_name() != "fullscreen") { result->NotImplemented(); return; }
      if (!enabled || !IsWindow(window_)) { result->Error("window-unavailable", "Invalid window"); return; }
      if (*enabled != fullscreen_) {
        if (*enabled) {
          placement_.length = sizeof(placement_);
          MONITORINFO monitor{};
          monitor.cbSize = sizeof(monitor);
          if (!GetWindowPlacement(window_, &placement_) ||
              !GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor)) {
            result->Error("window-unavailable", "Cannot read window placement"); return;
          }
          style_ = GetWindowLongPtr(window_, GWL_STYLE);
          SetWindowLongPtr(window_, GWL_STYLE, style_ & ~WS_OVERLAPPEDWINDOW);
          SetWindowPos(window_, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
            monitor.rcMonitor.right - monitor.rcMonitor.left,
            monitor.rcMonitor.bottom - monitor.rcMonitor.top, SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
        } else {
          SetWindowLongPtr(window_, GWL_STYLE, style_);
          SetWindowPlacement(window_, &placement_);
          SetWindowPos(window_, nullptr, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER);
        }
        fullscreen_ = *enabled;
      }
      result->Success();
    });
    ticker_ = std::thread([this] { Tick(); });
  }

  ~VideoPlugin() override {
    // The engine clears the messenger's engine pointer before destroying its
    // plugin registrars. SetCallback dereferences that pointer even when the
    // requested callback is null. The registrar destroys its handler table
    // immediately after the plugins, so no channel call is needed at shutdown.
    if (FlutterDesktopMessengerIsAvailable(messenger_)) {
      channel_.SetMethodCallHandler(nullptr);
      window_channel_.SetMethodCallHandler(nullptr);
      clipboard_channel_.SetMethodCallHandler(nullptr);
    }
    {
      std::lock_guard<std::mutex> guard(mutex_);
      stopping_ = true;
    }
    wake_.notify_one();
    ticker_.join();
    for (auto& entry : videos_)
      Unregister(entry.first, std::move(entry.second.texture));
    FlutterDesktopMessengerRelease(messenger_);
  }

 private:
  void Unregister(int64_t id, std::shared_ptr<VideoTexture> video) {
    video->SetVisible(false);
    // The engine can still call Copy until asynchronous unregister completes.
    auto* retained = new std::shared_ptr<VideoTexture>(std::move(video));
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        textures_, id,
        [](void* context) {
          delete static_cast<std::shared_ptr<VideoTexture>*>(context);
        },
        retained);
  }

  void Tick() {
    std::unique_lock<std::mutex> lock(mutex_);
    while (!stopping_) {
      bool active = false;
      const auto now = std::chrono::steady_clock::now();
      auto next = now + std::chrono::seconds(1);
      for (auto& entry : videos_) {
        auto& video = entry.second;
        if (!video.texture->Active()) continue;
        active = true;
        if (now >= video.next) {
          if (video.texture->Poll())
            FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
                textures_, entry.first);
          const auto interval = std::chrono::microseconds(1000000 / video.frame_rate);
          video.next += interval;
          if (video.next <= now) video.next = now + interval;
        }
        next = std::min(next, video.next);
      }
      if (active)
        wake_.wait_until(lock, next);
      else
        wake_.wait(lock);
    }
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    std::lock_guard<std::mutex> guard(mutex_);
    const auto& method = call.method_name();
    if (method == "diagnostics") {
      result->Success(EncodableValue(
          EncodableMap{{EncodableValue("registered"),
                        EncodableValue(static_cast<int64_t>(videos_.size()))},
                       {EncodableValue("objects"),
                        EncodableValue(VideoTexture::objects.load())},
                       {EncodableValue("leases"),
                        EncodableValue(VideoTexture::leases.load())},
                       {EncodableValue("bufferBytes"),
                        EncodableValue(VideoTexture::buffer_bytes.load())},
                       {EncodableValue("uploadFailures"),
                        EncodableValue(VideoTexture::failures.load())}}));
      return;
    }
    const auto* args = call.arguments()
                           ? std::get_if<EncodableMap>(call.arguments())
                           : nullptr;
    int64_t id = -1;
    if (!Integer(Argument(args, method == "create" ? "ticket" : "id"), &id) ||
        id < 0 || (method == "create" && id == 0)) {
      result->Error("video-unavailable", "Invalid video handle");
      return;
    }
    if (method == "create") {
      auto video = VideoTexture::Open(static_cast<uint64_t>(id));
      if (!video) {
        result->Error("video-unavailable", "Session has already ended");
        return;
      }
      FlutterDesktopTextureInfo info{};
      info.type = kFlutterDesktopPixelBufferTexture;
      info.pixel_buffer_config.user_data = video.get();
      info.pixel_buffer_config.callback = [](size_t, size_t, void* data) {
        return static_cast<VideoTexture*>(data)->Copy();
      };
      id = FlutterDesktopTextureRegistrarRegisterExternalTexture(textures_,
                                                                 &info);
      if (id < 0) {
        result->Error("video-unavailable", "Texture registration failed");
        return;
      }
      int64_t rate = 60;
      Integer(Argument(args, "frameRate"), &rate);
      const int fps = static_cast<int>(std::clamp<int64_t>(rate, 1, 240));
      videos_.emplace(id, ScheduledVideo{video, fps});
      result->Success(EncodableValue(Status(id, *video, fps)));
      wake_.notify_one();
      return;
    }
    auto found = videos_.find(id);
    if (found == videos_.end()) {
      result->Error("video-unavailable", "Texture is already closed");
      return;
    }
    if (method == "status") {
      result->Success(EncodableValue(Status(id, *found->second.texture, found->second.frame_rate)));
    } else if (method == "visible") {
      const auto* value = Argument(args, "visible");
      const auto* visible = value ? std::get_if<bool>(value) : nullptr;
      if (!visible) {
        result->Error("video-unavailable", "Invalid visibility");
        return;
      }
      found->second.texture->SetVisible(*visible);
      found->second.next = {};
      wake_.notify_one();
      result->Success();
    } else if (method == "frameRate") {
      int64_t rate;
      if (!Integer(Argument(args, "frameRate"), &rate) || rate < 1 || rate > 240) {
        result->Error("video-unavailable", "Invalid frame rate");
        return;
      }
      found->second.frame_rate = static_cast<int>(rate);
      found->second.next = {};
      wake_.notify_one();
      result->Success();
    } else if (method == "dispose") {
      Unregister(id, std::move(found->second.texture));
      videos_.erase(found);
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  FlutterDesktopTextureRegistrarRef textures_;
  HWND window_;
  WINDOWPLACEMENT placement_{};
  LONG_PTR style_ = 0;
  bool fullscreen_ = false;
  FlutterDesktopMessengerRef messenger_;
  flutter::MethodChannel<EncodableValue> channel_;
  flutter::MethodChannel<EncodableValue> window_channel_;
  flutter::MethodChannel<EncodableValue> clipboard_channel_;
  std::map<int64_t, ScheduledVideo> videos_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::thread ticker_;
  bool stopping_ = false;
};
}  // namespace

void LrdpNativePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* wrapper =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  wrapper->AddPlugin(std::make_unique<VideoPlugin>(
      wrapper, FlutterDesktopRegistrarGetTextureRegistrar(registrar),
      FlutterDesktopPluginRegistrarGetMessenger(registrar)));
}
