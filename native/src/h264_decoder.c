#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "h264_decoder.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#define HISTORY_BYTES (16u * 1024u * 1024u)
#define HISTORY_PACKETS 512u
#define PARAMETER_BYTES (64u * 1024u)
#define MAX_DIMENSION 8192
#define PARAMETER_COUNT (32u + 256u)

typedef struct { uint8_t* data; size_t size; } parameter;
struct lrdp_h264_decoder {
  const AVCodec* codec;
  AVCodecContext* context;
  AVBufferRef* device;
  AVFrame* received;
  AVFrame* downloaded;
  AVFrame* output;
  struct SwsContext* sws;
  enum AVPixelFormat hw_format;
  enum AVHWDeviceType device_type;
  enum AVPixelFormat vaapi_format, cuda_format;
  struct dirent** render_devices;
  int render_count, render_next, cuda_tried;
  int trial, confirmed, format_failed, need_idr, params_dirty;
  parameter params[PARAMETER_COUNT];
  size_t params_size;
  AVPacket* history[HISTORY_PACKETS];
  size_t history_size, history_count;
  size_t byte_limit, packet_limit;
  lrdp_h264_frame frame;
  char reason[192];
#ifdef LRDP_H264_DECODER_TESTING
  int test_trial, test_fault;
  size_t test_replayed;
#endif
};

static void clear_output(lrdp_h264_decoder* d) {
  memset(&d->frame, 0, sizeof(d->frame));
  av_frame_unref(d->output);
}
static void clear_history(lrdp_h264_decoder* d) {
  for (size_t i = 0; i < d->history_count; ++i) av_packet_free(&d->history[i]);
  d->history_count = d->history_size = 0;
}
static void close_codec(lrdp_h264_decoder* d) {
  avcodec_free_context(&d->context);
  av_buffer_unref(&d->device);
  if (d->received) av_frame_unref(d->received);
  if (d->downloaded) av_frame_unref(d->downloaded);
  d->confirmed = 0;
}
static void reason(lrdp_h264_decoder* d, const char* action, int error) {
  if (error < 0) {
    char text[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(error, text, sizeof(text));
    snprintf(d->reason, sizeof(d->reason), "%s: %s", action, text);
  } else snprintf(d->reason, sizeof(d->reason), "%s", action);
}

static enum AVPixelFormat choose_format(AVCodecContext* context,
                                        const enum AVPixelFormat* formats) {
  lrdp_h264_decoder* d = context->opaque;
  if (d->trial) {
    for (const enum AVPixelFormat* p = formats; *p != AV_PIX_FMT_NONE; ++p)
      if (*p == d->hw_format) return *p;
    /* Never silently select software on a hardware context: rebuild and replay. */
    d->format_failed = 1;
    return AV_PIX_FMT_NONE;
  }
  for (const enum AVPixelFormat* p = formats; *p != AV_PIX_FMT_NONE; ++p)
    if (*p == AV_PIX_FMT_YUV420P || *p == AV_PIX_FMT_YUVJ420P) return *p;
  d->format_failed = 1;
  return AV_PIX_FMT_NONE;
}
static int open_codec(lrdp_h264_decoder* d, int hardware) {
  d->context = avcodec_alloc_context3(d->codec);
  if (!d->context) return AVERROR(ENOMEM);
  d->context->opaque = d;
  d->context->get_format = choose_format;
  d->context->thread_count = 1;
  d->context->thread_type = FF_THREAD_SLICE;
  d->context->flags |= AV_CODEC_FLAG_LOW_DELAY;
  d->context->err_recognition = AV_EF_CAREFUL | AV_EF_EXPLODE;
  d->context->max_pixels = (int64_t)MAX_DIMENSION * MAX_DIMENSION;
  d->format_failed = 0;
  if (hardware) {
    d->context->hw_device_ctx = av_buffer_ref(d->device);
    if (!d->context->hw_device_ctx) return AVERROR(ENOMEM);
  }
  return avcodec_open2(d->context, d->codec, NULL);
}
static int open_cpu(lrdp_h264_decoder* d) {
  close_codec(d);
  d->trial = 0;
#ifdef LRDP_H264_DECODER_TESTING
  d->test_trial = 0;
#endif
  return open_codec(d, 0);
}
static int try_device(lrdp_h264_decoder* d, enum AVHWDeviceType type,
                      enum AVPixelFormat format, const char* name) {
  close_codec(d);
  if (av_hwdevice_ctx_create(&d->device, type, name, NULL, 0) < 0) return 0;
  d->device_type = type;
  d->hw_format = format;
  d->trial = 1;
  if (open_codec(d, 1) >= 0) return 1;
  close_codec(d);
  d->trial = 0;
  return 0;
}
static int render_device(const struct dirent* entry) {
  const char* p = entry->d_name;
  if (strncmp(p, "renderD", 7) != 0 || !p[7]) return 0;
  for (p += 7; *p; ++p) if (*p < '0' || *p > '9') return 0;
  return 1;
}
static int next_device(lrdp_h264_decoder* d) {
  while (d->render_next < d->render_count) {
    const struct dirent* entry = d->render_devices[d->render_next++];
    char path[sizeof("/dev/dri/") + NAME_MAX];
    int n = snprintf(path, sizeof(path), "/dev/dri/%s", entry->d_name);
    if (n > 0 && (size_t)n < sizeof(path) &&
        try_device(d, AV_HWDEVICE_TYPE_VAAPI, d->vaapi_format, path)) return 1;
  }
  if (!d->cuda_tried && d->cuda_format != AV_PIX_FMT_NONE) {
    d->cuda_tried = 1;
    if (try_device(d, AV_HWDEVICE_TYPE_CUDA, d->cuda_format, NULL)) return 1;
  }
  return 0;
}
static int select_device(lrdp_h264_decoder* d) {
  for (int i = 0;; ++i) {
    const AVCodecHWConfig* config = avcodec_get_hw_config(d->codec, i);
    if (!config) break;
    if (!(config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) continue;
    if (config->device_type == AV_HWDEVICE_TYPE_VAAPI) d->vaapi_format = config->pix_fmt;
    if (config->device_type == AV_HWDEVICE_TYPE_CUDA) d->cuda_format = config->pix_fmt;
  }
  if (d->vaapi_format != AV_PIX_FMT_NONE) {
    d->render_count = scandir("/dev/dri", &d->render_devices, render_device, alphasort);
    if (d->render_count < 0) d->render_count = 0;
  }
  return next_device(d);
}

/* Read only the small Exp-Golomb prefix that identifies SPS/PPS. Removing
 * emulation-prevention bytes here avoids trusting arbitrary RBSP lengths. */
static int parameter_id(const uint8_t* nal, size_t size, unsigned type) {
  uint8_t rbsp[32];
  size_t count = 0;
  int zeros = 0;
  for (size_t i = 1; i < size && count < sizeof(rbsp); ++i) {
    uint8_t value = nal[i];
    if (zeros == 2 && value == 3) { zeros = 0; continue; }
    rbsp[count++] = value;
    zeros = value == 0 ? zeros + 1 : 0;
    if (zeros > 2) zeros = 2;
  }
  size_t bit = type == 7 ? 24 : 0;
  unsigned zeros_bits = 0;
  while (bit < count * 8 && !(rbsp[bit / 8] & (1u << (7 - bit % 8)))) {
    ++bit;
    if (++zeros_bits > 8) return -1;
  }
  if (bit >= count * 8) return -1;
  ++bit;
  unsigned value = 1;
  for (unsigned i = 0; i < zeros_bits; ++i, ++bit) {
    if (bit >= count * 8) return -1;
    value = (value << 1) | ((rbsp[bit / 8] >> (7 - bit % 8)) & 1);
  }
  --value;
  if (value >= (type == 7 ? 32u : 256u)) return -1;
  return (int)(type == 7 ? value : 32 + value);
}
static size_t start_code(const uint8_t* data, size_t size, size_t from,
                          size_t* length) {
  for (size_t i = from; i + 2 < size; ++i) {
    if (data[i] || data[i + 1]) continue;
    if (data[i + 2] == 1) { *length = 3; return i; }
    if (i + 3 < size && data[i + 2] == 0 && data[i + 3] == 1) {
      *length = 4; return i;
    }
  }
  return size;
}
static int inspect_packet(lrdp_h264_decoder* d, const uint8_t* data, size_t size,
                           int* idr, int* slices) {
  size_t length = 0, start = start_code(data, size, 0, &length);
  if (start == size) return -1;
  for (size_t i = 0; i < start; ++i) if (data[i]) return -1;
  *idr = *slices = 0;
  while (start < size) {
    size_t nal_start = start + length, next_length = 0;
    size_t next = start_code(data, size, nal_start, &next_length);
    size_t end = next;
    while (end > nal_start && data[end - 1] == 0) --end;
    if (end <= nal_start || (data[nal_start] & 0x80)) return -1;
    unsigned type = data[nal_start] & 31;
    if (!type || type >= 24) return -1;
    if (type >= 1 && type <= 5) {
      if (type != 1 && type != 5) return -1; /* No data-partitioned streams. */
      *slices = 1;
      if (type == 5) *idr = 1;
    }
    if (type == 7 || type == 8) {
      size_t bytes = end - nal_start;
      int id = parameter_id(data + nal_start, bytes, type);
      if (id < 0 || bytes > PARAMETER_BYTES - 4) return -1;
      parameter* p = &d->params[id];
      size_t stored = bytes + 4;
      if (d->params_size - p->size > PARAMETER_BYTES - stored) return -1;
      if (p->size != stored || memcmp(p->data + 4, data + nal_start, bytes)) {
        uint8_t* replacement = av_malloc(stored);
        if (!replacement) return -1;
        memcpy(replacement, "\0\0\0\1", 4);
        memcpy(replacement + 4, data + nal_start, bytes);
        d->params_size = d->params_size - p->size + stored;
        av_free(p->data);
        p->data = replacement;
        p->size = stored;
        d->params_dirty = 1;
      }
    }
    start = next;
    length = next_length;
  }
  return 0;
}
/* Every IDR packet carries a snapshot of the currently cached SPS/PPS.
 * Keeping that immutable prefix in history[0] also handles servers which send
 * their parameter sets separately and do not repeat them at the next IDR. */
static int active_trial(const lrdp_h264_decoder* d) {
#ifdef LRDP_H264_DECODER_TESTING
  return d->trial || d->test_trial;
#else
  return d->trial;
#endif
}
static AVPacket* packet(lrdp_h264_decoder* d, const uint8_t* data,
                         size_t size, int prefix) {
  size_t extra = prefix ? d->params_size : 0;
  if (size > HISTORY_BYTES || extra > HISTORY_BYTES - size) return NULL;
  AVPacket* p = av_packet_alloc();
  if (!p) return NULL;
  /* av_new_packet allocates and zeroes AV_INPUT_BUFFER_PADDING_SIZE bytes. */
  if (av_new_packet(p, (int)(extra + size)) < 0) { av_packet_free(&p); return NULL; }
  size_t offset = 0;
  if (prefix) {
    for (size_t i = 0; i < PARAMETER_COUNT; ++i) {
      if (!d->params[i].size) continue;
      memcpy(p->data + offset, d->params[i].data, d->params[i].size);
      offset += d->params[i].size;
    }
  }
  memcpy(p->data + offset, data, size);
  return p;
}

static int publish_frame(lrdp_h264_decoder* d, AVFrame* frame) {
  if (frame->width <= 0 || frame->height <= 0 ||
      frame->width > MAX_DIMENSION || frame->height > MAX_DIMENSION ||
      (frame->flags & AV_FRAME_FLAG_CORRUPT)) return AVERROR_INVALIDDATA;
  av_frame_unref(d->output);
  if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P) {
    int rc = av_frame_ref(d->output, frame);
    if (rc < 0) return rc;
  } else if (frame->format == AV_PIX_FMT_NV12) {
    d->output->format = AV_PIX_FMT_YUV420P;
    d->output->width = frame->width;
    d->output->height = frame->height;
    int rc = av_frame_get_buffer(d->output, 32);
    if (rc < 0) return rc;
    d->sws = sws_getCachedContext(d->sws, frame->width, frame->height, AV_PIX_FMT_NV12,
        frame->width, frame->height, AV_PIX_FMT_YUV420P, SWS_POINT, NULL, NULL, NULL);
    if (!d->sws) return AVERROR(ENOMEM);
    rc = sws_scale(d->sws, (const uint8_t* const*)frame->data, frame->linesize,
                   0, frame->height, d->output->data, d->output->linesize);
    if (rc != frame->height) return AVERROR_INVALIDDATA;
  } else return AVERROR(ENOSYS);
  for (int i = 0; i < 3; ++i) {
    int width = i == 0 ? frame->width : (frame->width + 1) / 2;
    if (!d->output->data[i] || d->output->linesize[i] < width)
      return AVERROR_INVALIDDATA;
    d->frame.planes[i] = d->output->data[i];
    d->frame.strides[i] = (uint32_t)d->output->linesize[i];
  }
  d->frame.width = (uint32_t)frame->width;
  d->frame.height = (uint32_t)frame->height;
  return 1;
}
#ifdef LRDP_H264_DECODER_TESTING
static int inject(lrdp_h264_decoder* d, int fault) {
  if (!d->test_trial || d->test_fault != fault) return 0;
  d->test_fault = 0;
  return 1;
}
#else
#define inject(d, fault) 0
#endif
static int consume(lrdp_h264_decoder* d, const AVPacket* p) {
  int got = 0, rc;
  if (inject(d, LRDP_H264_TEST_SEND)) return AVERROR_EXTERNAL;
  rc = avcodec_send_packet(d->context, p);
  if (rc < 0) return rc;
  while (1) {
    if (inject(d, LRDP_H264_TEST_RECEIVE)) return AVERROR_EXTERNAL;
    rc = avcodec_receive_frame(d->context, d->received);
    if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) return got;
    if (rc < 0) return rc;
    AVFrame* frame = d->received;
    int real_hardware = d->trial && frame->format == d->hw_format &&
                        frame->hw_frames_ctx != NULL;
    if (inject(d, LRDP_H264_TEST_TRANSFER)) return AVERROR_EXTERNAL;
    if (real_hardware) {
      av_frame_unref(d->downloaded);
      rc = av_hwframe_transfer_data(d->downloaded, frame, 0);
      if (rc < 0) return rc;
      frame = d->downloaded;
    } else if (d->trial) return AVERROR(ENOSYS);
    if (inject(d, LRDP_H264_TEST_FORMAT)) return AVERROR(ENOSYS);
    rc = publish_frame(d, frame);
    av_frame_unref(d->received);
    av_frame_unref(d->downloaded);
    if (rc < 0) return rc;
    if (real_hardware) d->confirmed = 1;
    got = 1;
  }
}

static int replay_cpu(lrdp_h264_decoder* d, const char* why, int error) {
  reason(d, why, error);
  clear_output(d);
  int rc = open_cpu(d), result = 0;
  if (rc < 0) {
    clear_history(d);
    d->need_idr = 1;
    close_codec(d);
    return -1;
  }
  for (size_t i = 0; i < d->history_count; ++i) {
    rc = consume(d, d->history[i]);
#ifdef LRDP_H264_DECODER_TESTING
    ++d->test_replayed;
#endif
    if (rc < 0) { result = -1; break; }
    result = rc;
  }
  clear_history(d);
  if (result < 0) {
    clear_output(d);
    d->need_idr = 1;
    close_codec(d);
  }
  return result;
}

static int recover_hardware(lrdp_h264_decoder* d, const char* why, int error) {
  /* Device creation alone does not establish codec/profile support. Try every
   * remaining candidate once before committing to CPU. A device that already
   * produced a frame fails straight to CPU, preventing retry loops midstream. */
  if (!d->confirmed) {
    while (next_device(d)) {
      clear_output(d);
      int result = 0;
      for (size_t i = 0; i < d->history_count; ++i) {
        result = consume(d, d->history[i]);
        if (result < 0) break;
      }
      if (result >= 0) return result;
      if (d->confirmed) break;
    }
  }
  return replay_cpu(d, why, error);
}

static lrdp_h264_decoder* decoder_new(int probe_devices) {
  lrdp_h264_decoder* d = av_mallocz(sizeof(*d));
  if (!d) return NULL;
  d->vaapi_format = d->cuda_format = AV_PIX_FMT_NONE;
  d->codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  d->received = av_frame_alloc();
  d->downloaded = av_frame_alloc();
  d->output = av_frame_alloc();
  d->need_idr = 1;
  d->byte_limit = HISTORY_BYTES;
  d->packet_limit = HISTORY_PACKETS;
  if (!d->codec || !d->received || !d->downloaded || !d->output) {
    lrdp_h264_decoder_free(d); return NULL;
  }
  if (!probe_devices || !select_device(d)) {
    reason(d, "No usable FFmpeg VAAPI render device or CUDA device; using software", 0);
    if (open_cpu(d) < 0) { lrdp_h264_decoder_free(d); return NULL; }
  }
  return d;
}
lrdp_h264_decoder* lrdp_h264_decoder_new(void) { return decoder_new(1); }
void lrdp_h264_decoder_free(lrdp_h264_decoder* d) {
  if (!d) return;
  close_codec(d);
  clear_history(d);
  for (size_t i = 0; i < PARAMETER_COUNT; ++i) av_free(d->params[i].data);
  for (int i = 0; i < d->render_count; ++i) free(d->render_devices[i]);
  free(d->render_devices);
  av_frame_free(&d->received);
  av_frame_free(&d->downloaded);
  av_frame_free(&d->output);
  sws_freeContext(d->sws);
  av_free(d);
}
int lrdp_h264_decoder_decode(lrdp_h264_decoder* d, const uint8_t* data, size_t size) {
  if (!d) return -1;
  clear_output(d);
  if (!data || !size || size > HISTORY_BYTES || size > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE)
    return -1;
  int idr, slices;
  if (inspect_packet(d, data, size, &idr, &slices) < 0) return -1;
  if (!slices) return 0;
  if (d->need_idr && !idr) return -1;
  if (!d->context && open_cpu(d) < 0) return -1;
  AVPacket* p = packet(d, data, size, d->params_dirty || idr);
  if (!p) return -1;
  d->params_dirty = 0;
  if (active_trial(d) && idr) clear_history(d);
  d->need_idr = 0;
  int result;
  if (active_trial(d) && (d->history_count >= d->packet_limit ||
      d->history_size >= d->byte_limit ||
      (size_t)p->size > d->byte_limit - d->history_size)) {
    /* Switch before dropping any reference packet; decode current after replay. */
    result = replay_cpu(d, "GOP history limit reached; using software", 0);
    if (result < 0) { av_packet_free(&p); return -1; }
    clear_output(d);
  }
  if (active_trial(d)) {
    d->history[d->history_count++] = p;
    d->history_size += (size_t)p->size;
    result = consume(d, p);
    if (result < 0) {
      const char* why = d->format_failed ? "Hardware pixel format unavailable; replaying on software" :
        "Hardware decode or frame transfer failed; replaying on software";
      return recover_hardware(d, why, result);
    }
    return result;
  }
  result = consume(d, p);
  av_packet_free(&p);
  if (result < 0) {
    clear_output(d);
    reason(d, "Software H264 decode failed; waiting for IDR", result);
    d->need_idr = 1;
    close_codec(d);
    return -1;
  }
  return result;
}
const lrdp_h264_frame* lrdp_h264_decoder_frame(const lrdp_h264_decoder* d) {
  return d && d->frame.width ? &d->frame : NULL;
}
const char* lrdp_h264_decoder_backend(const lrdp_h264_decoder* d) {
  if (!d) return "software";
  if (d->confirmed) return d->device_type == AV_HWDEVICE_TYPE_VAAPI ? "vaapi" : "cuda";
  return d->trial ? "pending" : "software";
}
const char* lrdp_h264_decoder_fallback_reason(const lrdp_h264_decoder* d) {
  return d ? d->reason : "";
}

#ifdef LRDP_H264_DECODER_TESTING
lrdp_h264_decoder* lrdp_h264_decoder_test_new(int trial) {
  lrdp_h264_decoder* d = decoder_new(0);
  if (d && trial) d->test_trial = 1;
  return d;
}
int lrdp_h264_decoder_test_frame(lrdp_h264_decoder* d, AVFrame* frame) {
  clear_output(d);
  return publish_frame(d, frame);
}
int lrdp_h264_decoder_test_software(lrdp_h264_decoder* d) {
  if (!d || !d->need_idr) return -1;
  return open_cpu(d);
}
int lrdp_h264_decoder_test_trial(lrdp_h264_decoder* d) {
  if (lrdp_h264_decoder_test_software(d) < 0) return -1;
  /* Keep choose_format in CPU mode, but enable the history/recovery path. */
  d->test_trial = 1;
  return 0;
}
void lrdp_h264_decoder_test_fail(lrdp_h264_decoder* d, int fault) { d->test_fault = fault; }
void lrdp_h264_decoder_test_limits(lrdp_h264_decoder* d, size_t bytes, size_t packets) {
  if (bytes && bytes <= HISTORY_BYTES) d->byte_limit = bytes;
  if (packets && packets <= HISTORY_PACKETS) d->packet_limit = packets;
}
size_t lrdp_h264_decoder_test_history(const lrdp_h264_decoder* d) { return d->history_count; }
size_t lrdp_h264_decoder_test_replayed(const lrdp_h264_decoder* d) { return d->test_replayed; }
#endif
