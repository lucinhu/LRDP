#include "video_texture.h"

#include <cstdlib>
#include <new>

namespace lrdp {
std::atomic<int64_t> VideoTexture::objects{0}, VideoTexture::leases{0},
    VideoTexture::buffer_bytes{0}, VideoTexture::failures{0};

struct VideoTexture::Lease {
  FlutterDesktopPixelBuffer buffer{};
  std::shared_ptr<VideoTexture> owner;
  int slot;
};

std::shared_ptr<VideoTexture> VideoTexture::Open(uint64_t ticket) {
  lrdp_video* video = lrdp_video_open(ticket);
  if (!video) return nullptr;
  VideoTexture* texture;
  try {
    texture = new VideoTexture(video);
  } catch (const std::bad_alloc&) {
    lrdp_video_close(video);
    return nullptr;
  }
  // shared_ptr construction owns deletion even if its control block fails.
  try {
    return std::shared_ptr<VideoTexture>(texture);
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
}

VideoTexture::VideoTexture(lrdp_video* video) : video_(video) { ++objects; }

VideoTexture::~VideoTexture() {
  lrdp_video_close(video_);
  for (const auto& slot : slots_) buffer_bytes -= slot.pixels.capacity();
  --objects;
}

int VideoTexture::Convert(const uint8_t* pixels, int32_t width, int32_t height,
                          void* context) {
  auto* self = static_cast<VideoTexture*>(context);
#ifndef NDEBUG
  if (std::getenv("LRDP_VIDEO_TEST_FAIL_UPLOAD")) return 0;
#endif
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return 0;
  auto& slot = self->slots_[self->writing_];
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  const size_t previous_capacity = slot.pixels.capacity();
  try {
    slot.pixels.resize(bytes);
  } catch (const std::bad_alloc&) {
    return 0;
  }
  buffer_bytes += slot.pixels.capacity() - previous_capacity;
  for (size_t i = 0; i < bytes; i += 4) {
    slot.pixels[i] = pixels[i + 2];
    slot.pixels[i + 1] = pixels[i + 1];
    slot.pixels[i + 2] = pixels[i];
    slot.pixels[i + 3] = pixels[i + 3];
  }
  slot.width = width;
  slot.height = height;
  self->current_ = self->writing_;
  ++self->uploads_;
  return 1;
}

const FlutterDesktopPixelBuffer* VideoTexture::Copy() {
  std::lock_guard<std::mutex> guard(mutex_);
  // Bound leases as well as storage, even if an embedder delays releases.
  if (outstanding_ >= 2) return nullptr;
  if (visible_ && !failed_) {
    for (size_t i = 0; i < slots_.size(); ++i) {
      if (slots_[i].references != 0) continue;
      writing_ = static_cast<int>(i);
      if (lrdp_video_visit(video_, Convert, this, &generation_) == -1) {
        failed_ = true;
        ++failures;
      }
      break;
    }
  }
  auto* lease = new (std::nothrow) Lease;
  if (!lease) {
    if (!failed_) ++failures;
    failed_ = true;
    return nullptr;
  }
  lease->owner = shared_from_this();
  lease->slot = current_;
  if (current_ >= 0) {
    auto& slot = slots_[current_];
    ++slot.references;
    lease->buffer.buffer = slot.pixels.data();
    lease->buffer.width = slot.width;
    lease->buffer.height = slot.height;
  } else {
    static const uint8_t transparent[] = {0, 0, 0, 0};
    lease->buffer.buffer = transparent;
    lease->buffer.width = lease->buffer.height = 1;
  }
  lease->buffer.release_callback = Release;
  lease->buffer.release_context = lease;
  ++outstanding_;
  ++leases;
  return &lease->buffer;
}

void VideoTexture::Release(void* context) {
  auto* lease = static_cast<Lease*>(context);
  {
    std::lock_guard<std::mutex> guard(lease->owner->mutex_);
    if (lease->slot >= 0) --lease->owner->slots_[lease->slot].references;
    --lease->owner->outstanding_;
    --leases;
  }
  // May destroy the owner: release outside its mutex.
  delete lease;
}

bool VideoTexture::Poll() {
  std::lock_guard<std::mutex> guard(mutex_);
  int32_t width, height;
  uint64_t generation;
  if (!visible_ || failed_ ||
      !lrdp_video_info(video_, &width, &height, &generation) ||
      (generation == announced_ && generation == generation_))
    return false;
  announced_ = generation;
  return true;
}

bool VideoTexture::Active() {
  std::lock_guard<std::mutex> guard(mutex_);
  return visible_ && !failed_;
}

void VideoTexture::SetVisible(bool visible) {
  std::lock_guard<std::mutex> guard(mutex_);
  visible_ = visible;
  if (visible) announced_ = 0;
}

VideoStatus VideoTexture::Status() {
  std::lock_guard<std::mutex> guard(mutex_);
  VideoStatus status;
  lrdp_video_info(video_, &status.width, &status.height, &status.generation);
  status.uploads = uploads_;
  status.failed = failed_;
  return status;
}
}  // namespace lrdp
