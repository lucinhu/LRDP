#ifndef LRDP_WINDOWS_VIDEO_TEXTURE_H_
#define LRDP_WINDOWS_VIDEO_TEXTURE_H_

#include <flutter_texture_registrar.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "lrdp.h"

namespace lrdp {

struct VideoStatus {
  int32_t width = 0, height = 0;
  uint64_t generation = 0, uploads = 0;
  bool failed = false;
};

// Plain retained frame memory only: no session pointer or FreeRDP operation.
// Flutter uploads RGBA on its raster thread and releases each borrowed buffer.
class VideoTexture : public std::enable_shared_from_this<VideoTexture> {
 public:
  static std::shared_ptr<VideoTexture> Open(uint64_t ticket);
  ~VideoTexture();
  VideoTexture(const VideoTexture&) = delete;
  VideoTexture& operator=(const VideoTexture&) = delete;

  const FlutterDesktopPixelBuffer* Copy();
  bool Poll();
  bool Active();
  void SetVisible(bool visible);
  VideoStatus Status();

  static std::atomic<int64_t> objects, leases, buffer_bytes, failures;

 private:
  explicit VideoTexture(lrdp_video* video);
  struct Slot {
    std::vector<uint8_t> pixels;
    size_t references = 0;
    int32_t width = 0, height = 0;
  };
  struct Lease;
  static int Convert(const uint8_t*, int32_t, int32_t, void*);
  static void Release(void*);

  std::mutex mutex_;
  lrdp_video* video_;
  std::array<Slot, 3> slots_;
  int current_ = -1;
  int writing_ = -1;
  size_t outstanding_ = 0;
  uint64_t generation_ = 0, announced_ = 0, uploads_ = 0;
  bool visible_ = true, failed_ = false;
};

}  // namespace lrdp
#endif
