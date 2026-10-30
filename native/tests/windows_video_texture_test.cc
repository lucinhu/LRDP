#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#include "video_texture.h"

extern "C" {
#include "video_store.h"
}

#define CHECK(value)                                                         \
  do {                                                                       \
    if (!(value)) {                                                          \
      std::fprintf(stderr, "Windows texture: %s at %d\n", #value, __LINE__); \
      std::exit(1);                                                          \
    }                                                                        \
  } while (0)

using lrdp::VideoTexture;
static void release(const FlutterDesktopPixelBuffer* frame) {
  CHECK(frame && frame->release_callback);
  frame->release_callback(frame->release_context);
}
static void empty() {
  CHECK(VideoTexture::objects == 0);
  CHECK(VideoTexture::leases == 0);
  CHECK(VideoTexture::buffer_bytes == 0);
}

// Records what the damage callback is told so the store-level contract is
// checked without going through the texture: whole frame versus a rectangle,
// the clipped rectangle, and whether the caller accepted the upload.
struct damage_capture {
  int calls = 0;
  int accept = 1;
  bool whole = false;
  lrdp_video_rect rect{};
  int32_t width = 0, height = 0;
};
static int capture_damage(const uint8_t*, int32_t width, int32_t height,
                          const lrdp_video_rect* damage, void* context) {
  auto* capture = static_cast<damage_capture*>(context);
  ++capture->calls;
  capture->whole = damage == nullptr;
  capture->width = width;
  capture->height = height;
  if (damage) capture->rect = *damage;
  return capture->accept;
}

int main(int argc, char**) {
  empty();
  CHECK(!VideoTexture::Open(0));

  // Damage callback contract: the first upload asks for the whole frame, a
  // patch reports just its rectangle, a rejected callback leaves the
  // generation stale, an empty rectangle is a successful no-op, and a frame
  // size change goes back to whole-frame semantics.
  lrdp_video* probe = lrdp_video_store_new();
  CHECK(probe);
  std::vector<uint8_t> probe_frame(4 * 3 * 4, 0x42);
  CHECK(lrdp_video_store_publish(probe, probe_frame.data(), 4, 3, 16, nullptr));
  damage_capture capture;
  uint64_t probe_generation = 0;
  CHECK(lrdp_video_visit_damage(probe, capture_damage, &capture,
                                &probe_generation) == 1);
  CHECK(capture.calls == 1 && capture.whole && capture.width == 4 &&
        capture.height == 3);
  CHECK(probe_generation != 0);
  const uint64_t uploaded = probe_generation;

  const lrdp_video_rect probe_patch = {1, 1, 2, 1};
  CHECK(lrdp_video_store_publish(probe, probe_frame.data(), 4, 3, 16,
                                 &probe_patch));
  uint64_t stale = probe_generation;
  capture.accept = 0;
  CHECK(lrdp_video_visit_damage(probe, capture_damage, &capture, &stale) == -1);
  CHECK(capture.calls == 2 && !capture.whole);
  CHECK(capture.rect.x == 1 && capture.rect.y == 1 && capture.rect.width == 2 &&
        capture.rect.height == 1);
  CHECK(stale == uploaded);  // no generation until the upload succeeds
  capture.accept = 1;
  CHECK(lrdp_video_visit_damage(probe, capture_damage, &capture,
                                &probe_generation) == 1);
  CHECK(capture.calls == 3 && probe_generation != uploaded);

  const lrdp_video_rect empty_rect = {0, 0, 0, 0};
  CHECK(lrdp_video_store_publish(probe, probe_frame.data(), 4, 3, 16,
                                 &empty_rect));
  CHECK(lrdp_video_visit_damage(probe, capture_damage, &capture,
                                &probe_generation) == 1);
  CHECK(capture.calls == 4 && !capture.whole && capture.rect.width == 0 &&
        capture.rect.height == 0);

  std::vector<uint8_t> probe_resized(5 * 4 * 4, 0x42);
  CHECK(lrdp_video_store_publish(probe, probe_resized.data(), 5, 4, 20,
                                 &probe_patch));
  CHECK(lrdp_video_visit_damage(probe, capture_damage, &capture,
                                &probe_generation) == 1);
  CHECK(capture.calls == 5 && capture.whole && capture.width == 5 &&
        capture.height == 4);
  lrdp_video_store_retire(probe);

  auto* store = lrdp_video_store_new();
  CHECK(store);
  const auto ticket = lrdp_video_store_ticket(store);
  auto video = VideoTexture::Open(ticket);
  CHECK(video && VideoTexture::objects == 1);
  const auto* placeholder = video->Copy();
  CHECK(placeholder && placeholder->width == 1 && placeholder->height == 1);
  CHECK(placeholder->buffer[3] == 0);
  release(placeholder);

  const uint8_t bgra[] = {0x20, 0x41, 0xd3, 0xff, 0xc6, 0x50, 0x25, 0xff,
                          0x10, 0x80, 0x30, 0x80, 0xff, 0xff, 0xff, 0xff};
  CHECK(lrdp_video_store_publish(store, bgra, 2, 2, 8, nullptr));
  if (argc > 1) {
#ifdef _WIN32
    _putenv_s("LRDP_VIDEO_TEST_FAIL_UPLOAD", "1");
#else
    setenv("LRDP_VIDEO_TEST_FAIL_UPLOAD", "1", 1);
#endif
    const auto* failed = video->Copy();
    CHECK(failed && failed->width == 1);
    CHECK(video->Status().failed && video->Status().uploads == 0);
    CHECK(!video->Poll() && !video->Active() && VideoTexture::failures == 1);
    release(failed);
    lrdp_video_store_retire(store);
    video.reset();
    empty();
    std::puts(
        "PASS: failed upload preserves placeholder and retires every retained "
        "buffer");
    return 0;
  }
  const uint8_t rgba[] = {0xd3, 0x41, 0x20, 0xff, 0x25, 0x50, 0xc6, 0xff,
                          0x30, 0x80, 0x10, 0x80, 0xff, 0xff, 0xff, 0xff};
  CHECK(video->Poll());
  const auto* first = video->Copy();
  CHECK(first && first->width == 2 && first->height == 2);
  CHECK(std::memcmp(first->buffer, rgba, sizeof(rgba)) == 0);
  CHECK(!video->Poll());
  std::vector<uint8_t> next(3 * 3 * 4, 0x5a);
  CHECK(lrdp_video_store_publish(store, next.data(), 3, 3, 12, nullptr));
  const auto* second = video->Copy();
  CHECK(second && second->width == 3 && second->height == 3);
  CHECK(std::memcmp(first->buffer, rgba, sizeof(rgba)) == 0);
  CHECK(!video->Copy());
  CHECK(VideoTexture::leases == 2);
  CHECK(lrdp_video_store_publish(store, bgra, 2, 2, 8, nullptr));
  CHECK(!video->Copy());
  release(first);
  const auto* latest = video->Copy();
  CHECK(latest && latest->width == 2);
  CHECK(std::memcmp(latest->buffer, rgba, sizeof(rgba)) == 0);
  for (size_t i = 0; i < next.size(); ++i) CHECK(second->buffer[i] == 0x5a);
  uint8_t previous[sizeof(rgba)];
  std::memcpy(previous, latest->buffer, sizeof(previous));
  release(second);
  release(latest);

  // A small rectangle refreshes only its own pixels: the bytes outside it must
  // be identical to the previous upload, not freshly converted or cleared.
  const uint8_t patch[] = {0xaa, 0xbb, 0xcc, 0xdd, 0x03, 0x02, 0x01, 0x04,
                           0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66};
  const lrdp_video_rect patch_rect = {1, 0, 1, 1};
  uint8_t patched[sizeof(rgba)];
  std::memcpy(patched, previous, sizeof(patched));
  patched[4] = 0x01;
  patched[5] = 0x02;
  patched[6] = 0x03;
  patched[7] = 0x04;
  CHECK(lrdp_video_store_publish(store, patch, 2, 2, 8, &patch_rect));
  CHECK(video->Poll());
  const uint64_t before_patch = video->Status().uploads;
  const auto* partial = video->Copy();
  CHECK(partial && partial->width == 2 && partial->height == 2);
  CHECK(video->Status().uploads == before_patch + 1);
  CHECK(std::memcmp(partial->buffer, patched, sizeof(patched)) == 0);
  CHECK(previous[4] != partial->buffer[4] &&
        previous[5] != partial->buffer[5]);  // the rectangle really changed
  release(partial);

  // A frame size change rebuilds the buffer and converts the whole frame; the
  // following corner patch must then land in the new geometry.
  std::vector<uint8_t> wide(3 * 2 * 4, 0x33);
  CHECK(lrdp_video_store_publish(store, wide.data(), 3, 2, 12, nullptr));
  CHECK(video->Poll());
  const auto* resized = video->Copy();
  CHECK(resized && resized->width == 3 && resized->height == 2);
  uint8_t wide_rgba[3 * 2 * 4];
  std::memcpy(wide_rgba, resized->buffer, sizeof(wide_rgba));
  for (size_t i = 0; i < sizeof(wide_rgba); ++i) CHECK(wide_rgba[i] == 0x33);
  release(resized);

  std::vector<uint8_t> wide_patch = wide;
  const size_t corner = (1 * 3 + 2) * 4;  // pixel (2, 1)
  wide_patch[corner] = 0x01;
  wide_patch[corner + 1] = 0x02;
  wide_patch[corner + 2] = 0x03;
  wide_patch[corner + 3] = 0x04;
  const lrdp_video_rect wide_rect = {2, 1, 1, 1};
  CHECK(lrdp_video_store_publish(store, wide_patch.data(), 3, 2, 12,
                                 &wide_rect));
  CHECK(video->Poll());
  const auto* patched_wide = video->Copy();
  CHECK(patched_wide && patched_wide->width == 3 && patched_wide->height == 2);
  uint8_t wide_expected[sizeof(wide_rgba)];
  std::memcpy(wide_expected, wide_rgba, sizeof(wide_expected));
  wide_expected[corner] = 0x03;
  wide_expected[corner + 1] = 0x02;
  wide_expected[corner + 2] = 0x01;
  wide_expected[corner + 3] = 0x04;
  CHECK(std::memcmp(patched_wide->buffer, wide_expected,
                    sizeof(wide_expected)) == 0);
  release(patched_wide);

  // A patch that arrives while the previous upload is still leased must copy
  // that upload into the free slot and refresh it in place, never write into
  // the leased buffer and never drop pixels outside the rectangle.
  const auto* held = video->Copy();
  CHECK(held && held->width == 3 && held->height == 2);
  CHECK(std::memcmp(held->buffer, wide_expected, sizeof(wide_expected)) == 0);
  std::vector<uint8_t> held_patch = wide_patch;
  held_patch[0] = 0x0a;
  held_patch[1] = 0x0b;
  held_patch[2] = 0x0c;
  held_patch[3] = 0x0d;
  const lrdp_video_rect held_rect = {0, 0, 1, 1};
  CHECK(lrdp_video_store_publish(store, held_patch.data(), 3, 2, 12,
                                 &held_rect));
  CHECK(video->Poll());
  const uint64_t before_held_patch = video->Status().uploads;
  const auto* patched_held = video->Copy();
  CHECK(patched_held && patched_held->width == 3 &&
        patched_held->height == 2);
  CHECK(video->Status().uploads == before_held_patch + 1);
  uint8_t held_expected[sizeof(wide_expected)];
  std::memcpy(held_expected, wide_expected, sizeof(held_expected));
  held_expected[0] = 0x0c;
  held_expected[1] = 0x0b;
  held_expected[2] = 0x0a;
  held_expected[3] = 0x0d;
  CHECK(std::memcmp(patched_held->buffer, held_expected,
                    sizeof(held_expected)) == 0);
  release(held);
  release(patched_held);

  video->SetVisible(false);
  const auto hidden = video->Status().uploads;
  CHECK(lrdp_video_store_publish(store, next.data(), 3, 3, 12, nullptr));
  CHECK(!video->Poll());
  const auto* frozen = video->Copy();
  CHECK(frozen && frozen->width == 3 && frozen->height == 2 &&
        video->Status().uploads == hidden);
  release(frozen);
  video->SetVisible(true);
  CHECK(video->Poll());
  const auto* resumed = video->Copy();
  CHECK(resumed && resumed->width == 3 && video->Status().uploads > hidden);
  release(resumed);

  // Producer and raster callbacks use real retained native frame storage.
  std::atomic<bool> done{false};
  std::thread producer([&] {
    for (int n = 1; n <= 500; ++n) {
      const int size = n % 17 + 1;
      std::vector<uint8_t> pixels(size * size * 4, static_cast<uint8_t>(n));
      CHECK(lrdp_video_store_publish(store, pixels.data(), size, size, size * 4,
                                     nullptr));
    }
    done = true;
  });
  while (!done) {
    const auto* frame = video->Copy();
    CHECK(frame && frame->width >= 1 && frame->width <= 17);
    for (size_t i = 0; i < frame->width * frame->height * 4; ++i)
      CHECK(frame->buffer[i] == frame->buffer[0]);
    release(frame);
  }
  producer.join();
  const auto* retained = video->Copy();
  CHECK(retained && retained->width == 8);
  lrdp_video_store_retire(store);
  CHECK(!VideoTexture::Open(ticket));
  std::weak_ptr<VideoTexture> weak = video;
  video.reset();
  CHECK(!weak.expired() && VideoTexture::leases == 1);
  for (size_t i = 0; i < retained->width * retained->height * 4; ++i)
    CHECK(retained->buffer[i] == static_cast<uint8_t>(500));
  release(retained);
  CHECK(weak.expired());
  empty();
  CHECK(VideoTexture::failures == 0);
  std::puts(
      "PASS: damage rectangles, RGBA/orientation, bounded leases, resize, "
      "freeze/resume, concurrent frames and late release after session "
      "teardown");
}
