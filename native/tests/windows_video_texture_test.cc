#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

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

int main(int argc, char**) {
  empty();
  CHECK(!VideoTexture::Open(0));
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
  CHECK(lrdp_video_store_publish(store, bgra, 2, 2, 8));
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
  CHECK(lrdp_video_store_publish(store, next.data(), 3, 3, 12));
  const auto* second = video->Copy();
  CHECK(second && second->width == 3 && second->height == 3);
  CHECK(std::memcmp(first->buffer, rgba, sizeof(rgba)) == 0);
  CHECK(!video->Copy());
  CHECK(VideoTexture::leases == 2);
  CHECK(lrdp_video_store_publish(store, bgra, 2, 2, 8));
  CHECK(!video->Copy());
  release(first);
  const auto* latest = video->Copy();
  CHECK(latest && latest->width == 2);
  CHECK(std::memcmp(latest->buffer, rgba, sizeof(rgba)) == 0);
  for (size_t i = 0; i < next.size(); ++i) CHECK(second->buffer[i] == 0x5a);
  release(second);
  release(latest);

  video->SetVisible(false);
  const auto hidden = video->Status().uploads;
  CHECK(lrdp_video_store_publish(store, next.data(), 3, 3, 12));
  CHECK(!video->Poll());
  const auto* frozen = video->Copy();
  CHECK(frozen && frozen->width == 2 && video->Status().uploads == hidden);
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
      CHECK(
          lrdp_video_store_publish(store, pixels.data(), size, size, size * 4));
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
      "PASS: RGBA/orientation, bounded leases, resize, freeze/resume, "
      "concurrent frames and late release after session teardown");
}
