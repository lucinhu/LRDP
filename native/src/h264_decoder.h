#ifndef LRDP_H264_DECODER_H
#define LRDP_H264_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lrdp_h264_decoder lrdp_h264_decoder;
typedef struct {
  const uint8_t* planes[3];
  uint32_t strides[3];
  uint32_t width;
  uint32_t height;
} lrdp_h264_frame;

/* One decoder per surface/AVC420 stream; calls on it must be serialized.
 * Input is one complete AnnexB access unit (SPS/PPS-only units are allowed).
 * Returns -1 on invalid data/failure, 0 when waiting for a frame, 1 on frame.
 * A stream must begin at an IDR; non-IDR slices before it return -1.
 * The returned I420 planes remain valid until the next decode/free call.
 * No flush packet is sent implicitly: this is a low-delay surface decoder. */
lrdp_h264_decoder* lrdp_h264_decoder_new(void);
void lrdp_h264_decoder_free(lrdp_h264_decoder* decoder);
int lrdp_h264_decoder_decode(lrdp_h264_decoder* decoder,
                             const uint8_t* data, size_t size);
const lrdp_h264_frame* lrdp_h264_decoder_frame(const lrdp_h264_decoder* decoder);
/* "pending", "software", "vaapi", or "cuda". Hardware names are returned
 * only after an actual hardware frame was decoded and downloaded. */
const char* lrdp_h264_decoder_backend(const lrdp_h264_decoder* decoder);
/* Empty if there was no fallback. Owned by the decoder; never NULL. */
const char* lrdp_h264_decoder_fallback_reason(const lrdp_h264_decoder* decoder);

#ifdef LRDP_H264_DECODER_TESTING
/* Deterministic tests exercise the hardware state machine using a software
 * codec without claiming that a hardware frame was produced. No env hooks. */
enum lrdp_h264_test_fault {
  LRDP_H264_TEST_SEND = 1,
  LRDP_H264_TEST_RECEIVE,
  LRDP_H264_TEST_TRANSFER,
  LRDP_H264_TEST_FORMAT
};
lrdp_h264_decoder* lrdp_h264_decoder_test_new(int trial);
struct AVFrame;
int lrdp_h264_decoder_test_frame(lrdp_h264_decoder* decoder, struct AVFrame* frame);
int lrdp_h264_decoder_test_software(lrdp_h264_decoder* decoder);
int lrdp_h264_decoder_test_trial(lrdp_h264_decoder* decoder);
void lrdp_h264_decoder_test_fail(lrdp_h264_decoder* decoder, int fault);
void lrdp_h264_decoder_test_limits(lrdp_h264_decoder* decoder,
                                   size_t bytes, size_t packets);
size_t lrdp_h264_decoder_test_history(const lrdp_h264_decoder* decoder);
size_t lrdp_h264_decoder_test_replayed(const lrdp_h264_decoder* decoder);
#endif

#ifdef __cplusplus
}
#endif
#endif
