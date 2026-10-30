#include "video_texture.h"

#include <cstdlib>
#include <cstring>
#include <new>

// x86 has a cheap 16-byte lane shuffle for the BGRA->RGBA byte swap. Everything
// else (including 32-bit MSVC builds without SSE2 and ARM64) uses the portable
// 64-bit word path; big-endian targets fall back to the scalar tail only.
#if defined(__SSE2__) || defined(_M_X64) || \
    (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define LRDP_VIDEO_SSE2 1
#elif defined(_WIN32) || \
    (defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
#define LRDP_VIDEO_WORD64 1
#endif

namespace lrdp {
namespace {

// Flutter's desktop pixel buffer wants RGBA while an RDP surface is BGRA, so
// only the red and blue bytes of every pixel move. That is memory bound: the
// variants below shuffle whole pixels instead of loading and storing each byte
// separately like the original loop. `pixels` is tightly packed (4 bytes each).
void ConvertSpan(uint8_t* dst, const uint8_t* src, size_t pixels) {
  size_t i = 0;
#if defined(LRDP_VIDEO_SSE2)
  // Each 32-bit lane is A<<24|R<<16|G<<8|B; move B up 16 bits and R down 16,
  // keep the G/A bytes in place. Four pixels per iteration, unaligned safe.
  const __m128i red = _mm_set1_epi32(0x00FF0000);
  const __m128i blue = _mm_set1_epi32(0x000000FF);
  const __m128i green_alpha = _mm_set1_epi32(0xFF00FF00);
  for (; i + 4 <= pixels; i += 4) {
    const __m128i pixel =
        _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + i * 4));
    const __m128i swapped = _mm_or_si128(
        _mm_or_si128(_mm_srli_epi32(_mm_and_si128(pixel, red), 16),
                     _mm_slli_epi32(_mm_and_si128(pixel, blue), 16)),
        _mm_and_si128(pixel, green_alpha));
    _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + i * 4), swapped);
  }
#elif defined(LRDP_VIDEO_WORD64)
  // Two pixels per 64-bit word on little-endian targets: byte offsets 0 and 4
  // hold B, offsets 2 and 6 hold R. Shifts stay inside the word.
  const uint64_t blue = 0x000000FF000000FFULL;
  const uint64_t red = 0x00FF000000FF0000ULL;
  for (; i + 2 <= pixels; i += 2) {
    uint64_t pixel;
    std::memcpy(&pixel, src + i * 4, sizeof(pixel));
    const uint64_t swapped = (pixel & ~(blue | red)) | ((pixel & blue) << 16) |
                             ((pixel & red) >> 16);
    std::memcpy(dst + i * 4, &swapped, sizeof(swapped));
  }
#endif
  for (; i < pixels; ++i) {
    const uint8_t* in = src + i * 4;
    uint8_t* out = dst + i * 4;
    out[0] = in[2];
    out[1] = in[1];
    out[2] = in[0];
    out[3] = in[3];
  }
}

// Convert one complete tightly packed frame.
void ConvertWhole(uint8_t* dst, const uint8_t* src, int32_t width,
                  int32_t height) {
  ConvertSpan(dst, src, static_cast<size_t>(width) * static_cast<size_t>(height));
}

// Convert only rows [y, y + height) and columns [x, x + width) of a frame.
void ConvertRect(uint8_t* dst, const uint8_t* src, int32_t frame_width, int32_t x,
                 int32_t y, int32_t width, int32_t height) {
  const size_t stride = static_cast<size_t>(frame_width) * 4;
  for (int32_t row = y; row < y + height; ++row) {
    const size_t offset = static_cast<size_t>(row) * stride +
                          static_cast<size_t>(x) * 4;
    ConvertSpan(dst + offset, src + offset, static_cast<size_t>(width));
  }
}

}  // namespace

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

bool VideoTexture::Reallocate(Slot& slot, size_t bytes) {
  const size_t previous_capacity = slot.pixels.capacity();
  try {
    slot.pixels.resize(bytes);
  } catch (const std::bad_alloc&) {
    return false;
  }
  buffer_bytes += static_cast<int64_t>(slot.pixels.capacity()) -
                  static_cast<int64_t>(previous_capacity);
  return true;
}

int VideoTexture::Convert(const uint8_t* pixels, int32_t width, int32_t height,
                          const lrdp_video_rect* damage, void* context) {
  auto* self = static_cast<VideoTexture*>(context);
#ifndef NDEBUG
  if (std::getenv("LRDP_VIDEO_TEST_FAIL_UPLOAD")) return 0;
#endif
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return 0;
  Slot& slot = self->slots_[self->writing_];
  const size_t bytes =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (damage) {
    // The store reports a zero-size rectangle when the generation advanced but
    // no visible pixel changed: the previous upload is still current.
    int64_t left = damage->x;
    int64_t top = damage->y;
    int64_t right = static_cast<int64_t>(damage->x) + damage->width;
    int64_t bottom = static_cast<int64_t>(damage->y) + damage->height;
    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > width) right = width;
    if (bottom > height) bottom = height;
    if (left >= right || top >= bottom) return self->current_ >= 0 ? 1 : 0;
    bool editable = false;
    if (self->writing_ == self->current_) {
      editable = slot.valid && slot.width == width && slot.height == height &&
                 slot.pixels.size() == bytes;
    } else if (self->current_ >= 0) {
      // The previous upload may still be leased, so start the free slot from a
      // copy of it. Reading a leased buffer is safe; writing it is not.
      const Slot& previous = self->slots_[self->current_];
      if (previous.valid && previous.width == width &&
          previous.height == height && previous.pixels.size() == bytes) {
        editable = Reallocate(slot, bytes);
        if (!editable) return 0;
        std::memcpy(slot.pixels.data(), previous.pixels.data(), bytes);
      }
    }
    if (editable) {
      ConvertRect(slot.pixels.data(), pixels, width, static_cast<int32_t>(left),
                  static_cast<int32_t>(top), static_cast<int32_t>(right - left),
                  static_cast<int32_t>(bottom - top));
      slot.width = width;
      slot.height = height;
      slot.valid = true;
      self->current_ = self->writing_;
      ++self->uploads_;
      return 1;
    }
  }
  // Whole frame: first upload, a frame size change, a slot without the previous
  // upload, or a damage history that no longer covers the gap.
  if (!Reallocate(slot, bytes)) return 0;
  ConvertWhole(slot.pixels.data(), pixels, width, height);
  slot.width = width;
  slot.height = height;
  slot.valid = true;
  self->current_ = self->writing_;
  ++self->uploads_;
  return 1;
}

const FlutterDesktopPixelBuffer* VideoTexture::Copy() {
  std::lock_guard<std::mutex> guard(mutex_);
  // Bound leases as well as storage, even if an embedder delays releases.
  if (outstanding_ >= 2) return nullptr;
  if (visible_ && !failed_) {
    // Refreshing the slot that holds the previous upload lets a damage-only
    // frame update it in place; any other free slot needs a full conversion.
    writing_ = current_ >= 0 && slots_[current_].references == 0 ? current_ : -1;
    if (writing_ < 0) {
      for (size_t i = 0; i < slots_.size(); ++i) {
        if (slots_[i].references != 0) continue;
        writing_ = static_cast<int>(i);
        break;
      }
    }
    if (writing_ >= 0 &&
        lrdp_video_visit_damage(video_, Convert, this, &generation_) == -1) {
      failed_ = true;
      ++failures;
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
