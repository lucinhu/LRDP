/* Bounded PCM prebuffer and packet coalescing for the OpenSL ES backend. */
#include "audio_buffer.h"
#include <stdlib.h>
#include <string.h>
struct lrdp_audio_buffer {
  uint8_t* data;
  size_t used, limit, packet, target;
  unsigned bits, channels, rate, latency, primed;
  uint64_t last_input, queued_until;
};
int lrdp_audio_rate_supported(uint32_t rate) {
  switch (rate) {
    case 8000: case 11025: case 16000: case 22050: case 24000:
    case 32000: case 44100: case 48000: return 1;
    default: return 0;
  }
}
lrdp_audio_buffer* lrdp_audio_buffer_new(unsigned bits, unsigned channels, uint32_t rate, unsigned latency) {
  if ((bits != 8 && bits != 16) || (channels != 1 && channels != 2) || !lrdp_audio_rate_supported(rate)) return NULL;
  lrdp_audio_buffer* b = calloc(1, sizeof(*b));
  if (!b) return NULL;
  b->bits = bits; b->channels = channels; b->rate = rate;
  b->latency = latency < 20 ? 20 : latency > 400 ? 400 : latency;
  size_t frame = channels * bits / 8;
  b->packet = ((rate + 19) / 20) * frame; /* approximately 50 ms */
  b->target = ((size_t)rate * b->latency + 999) / 1000 * frame;
  b->limit = ((size_t)rate + 1) / 2 * frame; /* at most 500 ms awaiting submission */
  b->data = malloc(b->limit);
  if (!b->data) { free(b); return NULL; }
  return b;
}
void lrdp_audio_buffer_free(lrdp_audio_buffer* b) { if (b) { free(b->data); free(b); } }
void lrdp_audio_buffer_reset(lrdp_audio_buffer* b) {
  if (b) { b->used = 0; b->primed = 0; b->queued_until = 0; b->last_input = 0; }
}
int lrdp_audio_buffer_push(lrdp_audio_buffer* b, const uint8_t* data, size_t size, uint64_t now) {
  if (!b || !data || size % (b->channels * b->bits / 8)) return 0;
  if (size >= b->limit) {
    data += size - b->limit; size = b->limit; b->used = 0;
  } else if (size > b->limit - b->used) {
    size_t drop = size - (b->limit - b->used);
    memmove(b->data, b->data + drop, b->used - drop); b->used -= drop;
  }
  memcpy(b->data + b->used, data, size); b->used += size; b->last_input = now;
  return 1;
}
size_t lrdp_audio_buffer_take(lrdp_audio_buffer* b, uint8_t* output, size_t capacity, uint64_t now) {
  if (!b || !output || !b->used) return 0;
  const int flush = now >= b->last_input && now - b->last_input >= 100;
  if (!b->primed && b->used < b->target && !flush) return 0;
  const uint64_t clock_us = now * 1000;
  if (b->queued_until > clock_us && b->queued_until - clock_us >= (b->latency + 50) * 1000U) return 0;
  size_t bytes = b->used < b->packet ? b->used : b->packet;
  if (bytes < b->packet && !flush) return 0;
  size_t out_size = b->bits == 8 ? bytes * 2 : bytes;
  if (out_size > capacity) return 0;
  if (b->bits == 8) {
    for (size_t i = 0; i < bytes; i++) {
      int16_t value = (int16_t)(((int)b->data[i] - 128) * 256);
      output[i * 2] = (uint8_t)value; output[i * 2 + 1] = (uint8_t)((uint16_t)value >> 8);
    }
  } else memcpy(output, b->data, bytes);
  b->used -= bytes; memmove(b->data, b->data + bytes, b->used);
  const uint64_t frames = bytes / (b->channels * b->bits / 8);
  if (b->queued_until < clock_us) b->queued_until = clock_us;
  b->queued_until += (frames * 1000000 + b->rate - 1) / b->rate;
  b->primed = 1;
  return out_size;
}
unsigned lrdp_audio_buffer_latency(const lrdp_audio_buffer* b, uint64_t now) {
  uint64_t queued = b->queued_until > now * 1000 ? (b->queued_until - now * 1000 + 999) / 1000 : 0;
  queued += b->used * 1000 / (b->channels * b->bits / 8) / b->rate;
  return (unsigned)(queued > 1000 ? 1000 : queued);
}
