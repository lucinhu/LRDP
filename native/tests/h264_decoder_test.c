#include "h264_decoder.h"
#ifndef LRDP_H264_DECODER_TESTING
#error "Build this test and h264_decoder.c with LRDP_H264_DECODER_TESTING"
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "h264: %s at %d\n", #x, __LINE__); exit(1); } } while (0)

#ifdef LRDP_H264_ANDROID_FAKE
#ifndef __ANDROID__
#error "Android fake requires __ANDROID__ for the engine platform branch"
#endif
#include "h264_android.h"
/* Host-only transport double: the frames below are decoded by FFmpeg CPU.
 * It validates engine transitions, never proves real Android/GPU capability. */
struct lrdp_android_h264 { AVCodecContext* codec; int candidate, calls; };
static int fake_candidates, fake_bad_candidates, fake_fault, fake_fail_after;
static int fake_next_calls, fake_decode_calls, fake_live, fake_freed;
static void fake_reset(int candidates) {
  CHECK(fake_live == 0);
  fake_candidates = candidates; fake_bad_candidates = 0;
  fake_fault = fake_fail_after = fake_next_calls = fake_decode_calls = fake_freed = 0;
}
static enum AVPixelFormat fake_format(AVCodecContext* context, const enum AVPixelFormat* formats) {
  (void)context;
  for (; *formats != AV_PIX_FMT_NONE; ++formats)
    if (*formats == AV_PIX_FMT_YUV420P) return *formats;
  return AV_PIX_FMT_NONE;
}
lrdp_android_h264* lrdp_android_h264_new(void) {
  if (!fake_candidates) return NULL;
  lrdp_android_h264* d = calloc(1, sizeof(*d)); CHECK(d);
  ++fake_live;
  return d;
}
void lrdp_android_h264_free(lrdp_android_h264* d) {
  if (!d) return;
  avcodec_free_context(&d->codec);
  free(d); --fake_live; ++fake_freed;
}
int lrdp_android_h264_next(lrdp_android_h264* d) {
  ++fake_next_calls;
  avcodec_free_context(&d->codec);
  d->calls = 0;
  return ++d->candidate < fake_candidates;
}
int lrdp_android_h264_decode(lrdp_android_h264* d, const uint8_t* data, size_t size, AVFrame* output) {
  ++fake_decode_calls; ++d->calls;
  if ((fake_bad_candidates & (1 << d->candidate)) ||
      (fake_fail_after && d->calls >= fake_fail_after)) return AVERROR_EXTERNAL;
  if (fake_fault == 1) { fake_fault = 0; return 0; } /* Illegal delayed output. */
  if (!d->codec) {
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264); CHECK(codec);
    d->codec = avcodec_alloc_context3(codec); CHECK(d->codec);
    d->codec->get_format = fake_format;
    d->codec->thread_count = 1;
    CHECK(avcodec_open2(d->codec, codec, NULL) == 0);
  }
  AVPacket* p = av_packet_alloc(); CHECK(p);
  CHECK(size < INT_MAX);
  CHECK(av_new_packet(p, (int)size) == 0);
  memcpy(p->data, data, size);
  int rc = avcodec_send_packet(d->codec, p);
  av_packet_free(&p);
  if (rc < 0) return rc;
  rc = avcodec_receive_frame(d->codec, output);
  if (rc < 0) return rc;
  if (fake_fault == 2) { fake_fault = 0; output->format = AV_PIX_FMT_YUV444P; }
  return 1;
}
#endif

typedef struct {
  AVPacket** packets;
  size_t count;
  int width, height;
} fixture;

static uint8_t pixel(int index, int plane, int x, int y) {
  return (uint8_t)(16 + (index * 11 + plane * 37 + x * 3 + y * 7) % 200);
}
/* Generate real H264 access units, including reference-dependent P pictures.
 * libx264 qp=0 makes byte-for-byte I420 comparison possible without a second
 * decoder that might share exactly the bug being tested. */
static fixture make_fixture(int width, int height, int count, int keyint) {
  fixture f = {0};
  const AVCodec* codec = avcodec_find_encoder_by_name("libx264");
  CHECK(codec);
  AVCodecContext* c = avcodec_alloc_context3(codec);
  CHECK(c);
  c->width = width; c->height = height;
  c->pix_fmt = AV_PIX_FMT_YUV420P;
  c->time_base = (AVRational){1, 30};
  c->framerate = (AVRational){30, 1};
  c->gop_size = keyint; c->max_b_frames = 0; c->thread_count = 1;
  CHECK(av_opt_set(c->priv_data, "preset", "ultrafast", 0) == 0);
  CHECK(av_opt_set(c->priv_data, "tune", "zerolatency", 0) == 0);
  CHECK(av_opt_set(c->priv_data, "qp", "0", 0) == 0);
  char params[128];
  snprintf(params, sizeof(params), "keyint=%d:min-keyint=%d:scenecut=0:repeat-headers=1:threads=1", keyint, keyint);
  CHECK(av_opt_set(c->priv_data, "x264-params", params, 0) == 0);
  CHECK(avcodec_open2(c, codec, NULL) == 0);
  AVFrame* frame = av_frame_alloc();
  CHECK(frame);
  frame->width = width; frame->height = height; frame->format = AV_PIX_FMT_YUV420P;
  CHECK(av_frame_get_buffer(frame, 32) == 0);
  f.packets = calloc((size_t)count, sizeof(*f.packets));
  CHECK(f.packets);
  f.width = width; f.height = height;
  for (int i = 0; i < count; ++i) {
    CHECK(av_frame_make_writable(frame) == 0);
    for (int p = 0; p < 3; ++p) {
      int w = p ? width / 2 : width, h = p ? height / 2 : height;
      for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
          frame->data[p][y * frame->linesize[p] + x] = pixel(i, p, x, y);
    }
    frame->pts = i;
    CHECK(avcodec_send_frame(c, frame) == 0);
    AVPacket* packet = av_packet_alloc();
    CHECK(packet);
    CHECK(avcodec_receive_packet(c, packet) == 0);
    CHECK((!!(packet->flags & AV_PKT_FLAG_KEY)) == (i % keyint == 0));
    f.packets[f.count++] = packet;
  }
  av_frame_free(&frame);
  avcodec_free_context(&c);
  return f;
}
static void free_fixture(fixture* f) {
  for (size_t i = 0; i < f->count; ++i) av_packet_free(&f->packets[i]);
  free(f->packets);
}
static void check_pixels(lrdp_h264_decoder* d, const fixture* f, int index) {
  const lrdp_h264_frame* frame = lrdp_h264_decoder_frame(d);
  CHECK(frame);
  CHECK(frame->width == (uint32_t)f->width && frame->height == (uint32_t)f->height);
  for (int p = 0; p < 3; ++p) {
    int w = p ? f->width / 2 : f->width, h = p ? f->height / 2 : f->height;
    CHECK(frame->planes[p]); CHECK(frame->strides[p] >= (uint32_t)w);
    for (int y = 0; y < h; ++y)
      for (int x = 0; x < w; ++x)
        CHECK(frame->planes[p][(size_t)y * frame->strides[p] + x] == pixel(index, p, x, y));
  }
}
static void decode_index(lrdp_h264_decoder* d, const fixture* f, size_t index) {
  CHECK(lrdp_h264_decoder_decode(d, f->packets[index]->data, (size_t)f->packets[index]->size) == 1);
  check_pixels(d, f, (int)index);
}
static lrdp_h264_decoder* decoder(int trial) {
  lrdp_h264_decoder* d = lrdp_h264_decoder_test_new(trial);
  CHECK(d);
  CHECK(trial ? lrdp_h264_decoder_test_trial(d) == 0 : lrdp_h264_decoder_test_software(d) == 0);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
  return d;
}
/* Strip parameter-set NALs from an IDR, reproducing the common server pattern
 * where SPS/PPS are sent once and later IDRs contain only picture data. */
static AVPacket* filter_parameters(const AVPacket* packet, int keep_parameters) {
  AVPacket* result = av_packet_alloc(); CHECK(result);
  CHECK(av_new_packet(result, packet->size) == 0);
  size_t size = (size_t)packet->size, written = 0;
  for (size_t i = 0; i + 3 < size;) {
    size_t code = packet->data[i + 2] == 1 ? 3 : 4;
    CHECK(packet->data[i] == 0 && packet->data[i + 1] == 0);
    CHECK(packet->data[i + code - 1] == 1);
    size_t end = i + code;
    while (end + 3 < size && !(packet->data[end] == 0 && packet->data[end + 1] == 0 &&
           (packet->data[end + 2] == 1 || (packet->data[end + 2] == 0 && packet->data[end + 3] == 1)))) ++end;
    if (end + 3 >= size) end = size;
    unsigned type = packet->data[i + code] & 31;
    if ((type == 7 || type == 8) == keep_parameters) {
      memcpy(result->data + written, packet->data + i, end - i);
      written += end - i;
    }
    i = end;
  }
  av_shrink_packet(result, (int)written);
  return result;
}
static void test_cpu_and_auto(const fixture* f, int probe) {
  lrdp_h264_decoder* cpu = decoder(0);
  lrdp_h264_decoder* automatic = probe ? lrdp_h264_decoder_new() : decoder(0);
  CHECK(automatic);
  CHECK(strcmp(lrdp_h264_decoder_backend(automatic), "vaapi") != 0);
  CHECK(strcmp(lrdp_h264_decoder_backend(automatic), "cuda") != 0);
  for (size_t i = 0; i < f->count; ++i) {
    decode_index(cpu, f, i);
    decode_index(automatic, f, i);
  }
  if (strcmp(lrdp_h264_decoder_backend(automatic), "software") == 0)
    CHECK(*lrdp_h264_decoder_fallback_reason(automatic));
  printf("auto backend: %s; %s\n", lrdp_h264_decoder_backend(automatic),
         lrdp_h264_decoder_fallback_reason(automatic));
  lrdp_h264_decoder_free(cpu); lrdp_h264_decoder_free(automatic);
}
static void test_recovery(const fixture* f) {
  for (int fault = LRDP_H264_TEST_SEND; fault <= LRDP_H264_TEST_FORMAT; ++fault) {
    lrdp_h264_decoder* d = decoder(1);
    decode_index(d, f, 0); decode_index(d, f, 1);
    CHECK(lrdp_h264_decoder_test_history(d) == 2);
    lrdp_h264_decoder_test_fail(d, fault);
    decode_index(d, f, 2);
    CHECK(lrdp_h264_decoder_test_replayed(d) == 3);
    CHECK(lrdp_h264_decoder_test_history(d) == 0);
    CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
    CHECK(*lrdp_h264_decoder_fallback_reason(d));
    for (size_t i = 3; i < f->count; ++i) decode_index(d, f, i);
    CHECK(lrdp_h264_decoder_test_replayed(d) == 3);
    lrdp_h264_decoder_free(d);
  }
}
static void test_idr_without_parameters(const fixture* f) {
  lrdp_h264_decoder* d = decoder(1);
  for (size_t i = 0; i < 4; ++i) decode_index(d, f, i);
  AVPacket* idr = filter_parameters(f->packets[4], 0);
  CHECK(lrdp_h264_decoder_decode(d, idr->data, (size_t)idr->size) == 1);
  check_pixels(d, f, 4);
  CHECK(lrdp_h264_decoder_test_history(d) == 1);
  lrdp_h264_decoder_test_fail(d, LRDP_H264_TEST_TRANSFER);
  decode_index(d, f, 5);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 2);
  av_packet_free(&idr); lrdp_h264_decoder_free(d);
}
static void test_separate_parameters(const fixture* f) {
  lrdp_h264_decoder* d = decoder(1);
  AVPacket* parameters = filter_parameters(f->packets[0], 1);
  AVPacket* idr = filter_parameters(f->packets[0], 0);
  CHECK(lrdp_h264_decoder_decode(d, parameters->data, (size_t)parameters->size) == 0);
  CHECK(!lrdp_h264_decoder_frame(d));
  CHECK(lrdp_h264_decoder_decode(d, idr->data, (size_t)idr->size) == 1);
  check_pixels(d, f, 0);
  lrdp_h264_decoder_test_fail(d, LRDP_H264_TEST_SEND);
  decode_index(d, f, 1);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 2);
  av_packet_free(&parameters); av_packet_free(&idr); lrdp_h264_decoder_free(d);
}
static void test_limits(const fixture* f) {
  for (int bytes = 0; bytes < 2; ++bytes) {
    lrdp_h264_decoder* d = decoder(1);
    decode_index(d, f, 0);
    lrdp_h264_decoder_test_limits(d, bytes ? 1 : 0, bytes ? 0 : 2);
    decode_index(d, f, 1); decode_index(d, f, 2);
    CHECK(lrdp_h264_decoder_test_replayed(d) == (bytes ? 1u : 2u));
    CHECK(lrdp_h264_decoder_test_history(d) == 0);
    CHECK(strstr(lrdp_h264_decoder_fallback_reason(d), "history limit"));
    lrdp_h264_decoder_free(d);
  }
}
static void test_resolution(const fixture* small, const fixture* large) {
  lrdp_h264_decoder* d = decoder(1);
  decode_index(d, small, 0); decode_index(d, small, 1);
  decode_index(d, large, 0); decode_index(d, large, 1);
  lrdp_h264_decoder_test_fail(d, LRDP_H264_TEST_RECEIVE);
  decode_index(d, large, 2);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 3);
  lrdp_h264_decoder_free(d);
}
static void test_bad_input(const fixture* f) {
  lrdp_h264_decoder* d = decoder(0);
  CHECK(lrdp_h264_decoder_decode(NULL, NULL, 0) == -1);
  CHECK(lrdp_h264_decoder_decode(d, NULL, 0) == -1);
  CHECK(lrdp_h264_decoder_decode(d, f->packets[0]->data, SIZE_MAX) == -1);
  CHECK(lrdp_h264_decoder_decode(d, f->packets[0]->data, (size_t)INT_MAX) == -1);
  CHECK(lrdp_h264_decoder_decode(d, f->packets[1]->data, (size_t)f->packets[1]->size) == -1);
  CHECK(!lrdp_h264_decoder_frame(d));
  const uint8_t bad[][8] = {
    {0xff, 0xff}, {0, 0, 1, 0x80}, {0, 0, 1, 0x67}, {0, 0, 1, 0x68}, {0, 0, 1, 0x65}
  };
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
    CHECK(lrdp_h264_decoder_decode(d, bad[i], sizeof(bad[i])) == -1);
    CHECK(!lrdp_h264_decoder_frame(d));
  }
  decode_index(d, f, 0); decode_index(d, f, 1);
  lrdp_h264_decoder_free(d);
}
static void test_full_packet_limit(void) {
  fixture f = make_fixture(16, 16, 514, 1024);
  lrdp_h264_decoder* d = decoder(1);
  for (size_t i = 0; i < f.count; ++i) decode_index(d, &f, i);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 512);
  CHECK(lrdp_h264_decoder_test_history(d) == 0);
  CHECK(strstr(lrdp_h264_decoder_fallback_reason(d), "history limit"));
  lrdp_h264_decoder_free(d); free_fixture(&f);
}
static void test_nv12(void) {
  lrdp_h264_decoder* d = decoder(0);
  for (int iteration = 0; iteration < 2; ++iteration) {
    fixture expected = { .width = iteration ? 64 : 32, .height = iteration ? 48 : 32 };
    AVFrame* frame = av_frame_alloc(); CHECK(frame);
    frame->format = AV_PIX_FMT_NV12;
    frame->width = expected.width; frame->height = expected.height;
    CHECK(av_frame_get_buffer(frame, 64) == 0);
    for (int y = 0; y < frame->height; ++y)
      for (int x = 0; x < frame->width; ++x)
        frame->data[0][y * frame->linesize[0] + x] = pixel(3, 0, x, y);
    for (int y = 0; y < frame->height / 2; ++y)
      for (int x = 0; x < frame->width / 2; ++x) {
        frame->data[1][y * frame->linesize[1] + x * 2] = pixel(3, 1, x, y);
        frame->data[1][y * frame->linesize[1] + x * 2 + 1] = pixel(3, 2, x, y);
      }
    CHECK(lrdp_h264_decoder_test_frame(d, frame) == 1);
    check_pixels(d, &expected, 3);
    av_frame_free(&frame);
    check_pixels(d, &expected, 3);
  }
  AVFrame* invalid = av_frame_alloc(); CHECK(invalid);
  invalid->width = 8193; invalid->height = 32; invalid->format = AV_PIX_FMT_YUV420P;
  CHECK(lrdp_h264_decoder_test_frame(d, invalid) < 0);
  CHECK(!lrdp_h264_decoder_frame(d));
  invalid->width = 32; invalid->format = AV_PIX_FMT_YUV444P;
  CHECK(lrdp_h264_decoder_test_frame(d, invalid) < 0);
  CHECK(!lrdp_h264_decoder_frame(d));
  av_frame_free(&invalid); lrdp_h264_decoder_free(d);
}
#ifdef LRDP_H264_ANDROID_FAKE
static void test_android_engine(const fixture* f) {
  /* No JNI bridge/capability: construct and decode directly on CPU. */
  fake_reset(0);
  lrdp_h264_decoder* d = lrdp_h264_decoder_new(); CHECK(d);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
  decode_index(d, f, 0);
  CHECK(fake_decode_calls == 0);
  lrdp_h264_decoder_free(d);

  /* First candidate selected at new(), only next() after its actual failure. */
  fake_reset(2); fake_bad_candidates = 1;
  d = lrdp_h264_decoder_new(); CHECK(d);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "pending") == 0);
  CHECK(!lrdp_h264_decoder_frame(d)); CHECK(fake_next_calls == 0);
  decode_index(d, f, 0);
  CHECK(fake_next_calls == 1 && fake_decode_calls == 2);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "mediacodec") == 0);
  decode_index(d, f, 1);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 0);
  lrdp_h264_decoder_free(d); CHECK(fake_freed == 1);

  /* A confirmed decoder fails mid-GOP: replay CPU including the failing P AU,
   * release platform state once and never try a new candidate on this stream. */
  fake_reset(2); fake_fail_after = 3;
  d = lrdp_h264_decoder_new(); CHECK(d);
  decode_index(d, f, 0); decode_index(d, f, 1); decode_index(d, f, 2);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
  CHECK(fake_freed == 1 && fake_next_calls == 0);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 3);
  for (size_t i = 3; i < f->count; ++i) decode_index(d, f, i);
  CHECK(fake_decode_calls == 3);
  lrdp_h264_decoder_free(d); CHECK(fake_freed == 1);

  /* Pending output and wrong pixel format are failures, not frame successes. */
  for (int fault = 1; fault <= 2; ++fault) {
    fake_reset(1); fake_fault = fault;
    d = lrdp_h264_decoder_new(); CHECK(d);
    decode_index(d, f, 0);
    CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
    CHECK(lrdp_h264_decoder_test_replayed(d) == 1);
    CHECK(fake_freed == 1 && fake_next_calls == 1);
    decode_index(d, f, 1);
    lrdp_h264_decoder_free(d);
  }

  fake_reset(2); fake_bad_candidates = 3;
  d = lrdp_h264_decoder_new(); CHECK(d);
  decode_index(d, f, 0);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
  CHECK(fake_decode_calls == 2 && fake_next_calls == 2 && fake_freed == 1);
  lrdp_h264_decoder_free(d);

  /* History limit also closes a working platform codec before CPU replay. */
  fake_reset(1);
  d = lrdp_h264_decoder_new(); CHECK(d);
  lrdp_h264_decoder_test_limits(d, 0, 2);
  decode_index(d, f, 0); decode_index(d, f, 1); decode_index(d, f, 2);
  CHECK(lrdp_h264_decoder_test_replayed(d) == 2);
  CHECK(fake_decode_calls == 2 && fake_freed == 1);
  CHECK(strcmp(lrdp_h264_decoder_backend(d), "software") == 0);
  lrdp_h264_decoder_free(d);
  fake_reset(0);
  puts("Android engine host transport double passed; no real MediaCodec/hardware tested");
}
#endif
int main(int argc, char** argv) {
  CHECK(argc == 1 || (argc == 2 && strcmp(argv[1], "--software-only") == 0));
  av_log_set_level(AV_LOG_FATAL);
  fixture small = make_fixture(32, 32, 12, 4);
  fixture large = make_fixture(64, 48, 4, 4);
  test_cpu_and_auto(&small, argc == 1);
  test_recovery(&small);
  test_idr_without_parameters(&small);
  test_separate_parameters(&small);
  test_limits(&small);
  test_resolution(&small, &large);
  test_bad_input(&small);
  test_full_packet_limit();
  test_nv12();
#ifdef LRDP_H264_ANDROID_FAKE
  test_android_engine(&small);
#endif
  free_fixture(&small); free_fixture(&large);
  lrdp_h264_decoder_free(NULL);
  puts("h264 decoder: CPU pixels, multi-GOP, recovery, limits, resize, isolation and malformed input passed");
  return 0;
}
