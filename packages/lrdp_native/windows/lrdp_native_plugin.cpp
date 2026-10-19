#include "include/lrdp_native/lrdp_native_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <condition_variable>
#include <map>
#include <thread>

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

EncodableMap Status(int64_t id, VideoTexture& video) {
  auto status = video.Status();
  return {{EncodableValue("id"), EncodableValue(id)},
          {EncodableValue("width"), EncodableValue(status.width)},
          {EncodableValue("height"), EncodableValue(status.height)},
          {EncodableValue("generation"),
           EncodableValue(static_cast<int64_t>(status.generation))},
          {EncodableValue("uploads"),
           EncodableValue(static_cast<int64_t>(status.uploads))},
          {EncodableValue("failed"), EncodableValue(status.failed)}};
}

class VideoPlugin : public flutter::Plugin {
 public:
  explicit VideoPlugin(flutter::PluginRegistrarWindows* registrar,
                       FlutterDesktopTextureRegistrarRef textures,
                       FlutterDesktopMessengerRef messenger)
      : textures_(textures),
        messenger_(FlutterDesktopMessengerAddRef(messenger)),
        channel_(registrar->messenger(), "dev.lrdp/video",
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      Handle(call, std::move(result));
    });
    ticker_ = std::thread([this] { Tick(); });
  }

  ~VideoPlugin() override {
    // The engine clears the messenger's engine pointer before destroying its
    // plugin registrars. SetCallback dereferences that pointer even when the
    // requested callback is null. The registrar destroys its handler table
    // immediately after the plugins, so no channel call is needed at shutdown.
    if (FlutterDesktopMessengerIsAvailable(messenger_))
      channel_.SetMethodCallHandler(nullptr);
    {
      std::lock_guard<std::mutex> guard(mutex_);
      stopping_ = true;
    }
    wake_.notify_one();
    ticker_.join();
    for (auto& entry : videos_)
      Unregister(entry.first, std::move(entry.second));
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
      for (auto& entry : videos_) {
        active = active || entry.second->Active();
        if (entry.second->Poll())
          FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
              textures_, entry.first);
      }
      if (active)
        wake_.wait_for(lock, std::chrono::milliseconds(16));
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
      videos_.emplace(id, video);
      result->Success(EncodableValue(Status(id, *video)));
      wake_.notify_one();
      return;
    }
    auto found = videos_.find(id);
    if (found == videos_.end()) {
      result->Error("video-unavailable", "Texture is already closed");
      return;
    }
    if (method == "status") {
      result->Success(EncodableValue(Status(id, *found->second)));
    } else if (method == "visible") {
      const auto* value = Argument(args, "visible");
      const auto* visible = value ? std::get_if<bool>(value) : nullptr;
      if (!visible) {
        result->Error("video-unavailable", "Invalid visibility");
        return;
      }
      found->second->SetVisible(*visible);
      wake_.notify_one();
      result->Success();
    } else if (method == "dispose") {
      Unregister(id, std::move(found->second));
      videos_.erase(found);
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  FlutterDesktopTextureRegistrarRef textures_;
  FlutterDesktopMessengerRef messenger_;
  flutter::MethodChannel<EncodableValue> channel_;
  std::map<int64_t, std::shared_ptr<VideoTexture>> videos_;
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
