#ifndef LRDP_AUDIO_BUFFER_H
#define LRDP_AUDIO_BUFFER_H
#include <stdint.h>
#include <stddef.h>
typedef struct lrdp_audio_buffer lrdp_audio_buffer;
int lrdp_audio_rate_supported(uint32_t rate);
lrdp_audio_buffer* lrdp_audio_buffer_new(unsigned bits, unsigned channels, uint32_t rate, unsigned latency);
void lrdp_audio_buffer_free(lrdp_audio_buffer* buffer);
void lrdp_audio_buffer_reset(lrdp_audio_buffer* buffer);
int lrdp_audio_buffer_push(lrdp_audio_buffer* buffer, const uint8_t* data, size_t size, uint64_t now);
/* Emits aligned signed PCM16 blocks. now is a monotonic millisecond clock. */
size_t lrdp_audio_buffer_take(lrdp_audio_buffer* buffer, uint8_t* output, size_t capacity, uint64_t now);
unsigned lrdp_audio_buffer_latency(const lrdp_audio_buffer* buffer, uint64_t now);
#endif
