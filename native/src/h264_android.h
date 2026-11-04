#ifndef LRDP_H264_ANDROID_H
#define LRDP_H264_ANDROID_H

#include <stddef.h>
#include <stdint.h>

/* Private platform interface. Every operation on a decoder runs on the native
 * connection thread. It never calls FreeRDP or waits for the Android main loop.
 * A missing Java bridge / hardware capability is an ordinary CPU fallback. */
typedef struct lrdp_android_h264 lrdp_android_h264;
struct AVFrame;
/* Select the first candidate; NULL when the bridge has none. */
lrdp_android_h264* lrdp_android_h264_new(void);
void lrdp_android_h264_free(lrdp_android_h264* decoder);
/* Select the next hardware candidate, releasing the previous codec. */
int lrdp_android_h264_next(lrdp_android_h264* decoder);
/* One complete AnnexB AU, including cached SPS/PPS at each IDR.
 * Returns 1 only after the output for this exact AU has been copied to owned
 * I420 AVFrame storage. Errors, unexpected tokens and bounded waiting timeouts
 * return negative; a VCL AU must never return a pending / delayed frame.
 * This synchrony is required by FreeRDP's AVC444 luma/chroma composition. */
int lrdp_android_h264_decode(lrdp_android_h264* decoder,
                            const uint8_t* data, size_t size,
                            struct AVFrame* output);

/* Java/JNI contract (H264Decoder in dev.lrdp.lrdp_native):
 * static native void nativeInitialize(); caches VM + global class on plugin attach
 * static H264Decoder create(); null if no supported hardware candidates
 * boolean next(); select next candidate, deferred configuration on first decode
 * Frame decode(java.nio.ByteBuffer packet, long token, int width, int height);
 * void releaseFrame(); close Image then release codec output, safe after failure
 * void close(); release all codec/image resources
 * Frame fields: java.nio.ByteBuffer y, u, v (direct slices at plane position);
 * int yRowStride, uRowStride, vRowStride, yPixelStride, uPixelStride, vPixelStride;
 * int width, height (cropped output dimensions), cropLeft, cropTop.
 * Frame buffers remain readable until releaseFrame. A Java exception or null
 * result is an ordinary decode failure, never a successful hardware frame.
 */
#endif
