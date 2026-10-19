#include "audio_buffer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #x); return 1; } } while (0)
int main(void) {
  CHECK(!lrdp_audio_buffer_new(24, 2, 48000, 250));
  CHECK(!lrdp_audio_buffer_new(16, 3, 48000, 250));
  CHECK(!lrdp_audio_buffer_new(16, 2, 12345, 250));
  lrdp_audio_buffer* b = lrdp_audio_buffer_new(16, 2, 48000, 250); CHECK(b);
  unsigned char input[57600], result[57600], packet[9600];
  for (size_t i = 0; i < sizeof(input); i++) input[i] = (unsigned char)(i * 37 + i / 17);
  CHECK(lrdp_audio_buffer_push(b, input, 19200, 0));
  CHECK(lrdp_audio_buffer_take(b, packet, sizeof(packet), 0) == 0);
  CHECK(lrdp_audio_buffer_push(b, input + 19200, 19200, 100));
  CHECK(lrdp_audio_buffer_take(b, packet, sizeof(packet), 100) == 0);
  CHECK(lrdp_audio_buffer_push(b, input + 38400, 19200, 200));
  size_t total = 0, n;
  while ((n = lrdp_audio_buffer_take(b, packet, sizeof(packet), 200)) != 0) {
    CHECK(total + n <= sizeof(result)); memcpy(result + total, packet, n); total += n;
  }
  CHECK(total == sizeof(input) && memcmp(input, result, total) == 0);
  CHECK(lrdp_audio_buffer_latency(b, 200) == 300);
  CHECK(lrdp_audio_buffer_push(b, input, 4800, 300));
  CHECK(!lrdp_audio_buffer_push(b, input, 3, 300));
  lrdp_audio_buffer_reset(b);
  CHECK(lrdp_audio_buffer_take(b, packet, sizeof(packet), 1000) == 0);
  CHECK(lrdp_audio_buffer_push(b, input + 4800, 4800, 1000));
  CHECK(lrdp_audio_buffer_take(b, packet, sizeof(packet), 1050) == 0);
  CHECK(lrdp_audio_buffer_take(b, packet, 4, 1100) == 0);
  CHECK(lrdp_audio_buffer_take(b, packet, sizeof(packet), 1100) == 4800);
  CHECK(memcmp(packet, input + 4800, 4800) == 0);
  lrdp_audio_buffer_free(b);
  b = lrdp_audio_buffer_new(8, 1, 8000, 20); CHECK(b);
  unsigned char pcm8[256]; for (unsigned i = 0; i < 256; i++) pcm8[i] = (unsigned char)i;
  CHECK(lrdp_audio_buffer_push(b, pcm8, sizeof(pcm8), 0));
  CHECK(lrdp_audio_buffer_take(b, packet, sizeof(packet), 200) == 512);
  /* Reference checksum of the complete standard PCM8 -> signed PCM16 table. */
  uint32_t hash = 2166136261U;
  for (unsigned i = 0; i < 512; i++) hash = (hash ^ packet[i]) * 16777619U;
  CHECK(hash == 0x222559c5U);
  lrdp_audio_buffer_free(b);
  b = lrdp_audio_buffer_new(16, 2, 11025, 250); CHECK(b);
  /* Fractional packet rates must not accumulate millisecond rounding drift. */
  unsigned char samples[2208] = {0};
  for (unsigned i = 0; i < 1200; i++) {
    uint64_t now = (uint64_t)i * 552 * 1000 / 11025;
    CHECK(lrdp_audio_buffer_push(b, samples, sizeof(samples), now));
    while (lrdp_audio_buffer_take(b, packet, sizeof(packet), now)) { }
    if (i > 10) CHECK(lrdp_audio_buffer_latency(b, now) < 400);
  }
  lrdp_audio_buffer_free(b);
  b = lrdp_audio_buffer_new(16, 1, 8000, 20); CHECK(b);
  unsigned char backlog[12000], retained[8000];
  for (size_t i = 0; i < sizeof(backlog); i++) backlog[i] = (unsigned char)(i * 11 + i / 113);
  /* Overflow discards the oldest complete frames, including oversized pushes. */
  CHECK(lrdp_audio_buffer_push(b, backlog, 6000, 0));
  CHECK(lrdp_audio_buffer_push(b, backlog + 6000, 6000, 0));
  total = 0;
  for (unsigned tick = 0; tick < 25; tick++) {
    while ((n = lrdp_audio_buffer_take(b, packet, sizeof(packet), tick * 50)) != 0) {
      CHECK(total + n <= sizeof(retained)); memcpy(retained + total, packet, n); total += n;
    }
  }
  CHECK(total == sizeof(retained) && memcmp(retained, backlog + 4000, total) == 0);
  lrdp_audio_buffer_reset(b);
  CHECK(lrdp_audio_buffer_push(b, backlog, sizeof(backlog), 0));
  total = 0;
  for (unsigned tick = 0; tick < 25; tick++) {
    while ((n = lrdp_audio_buffer_take(b, packet, sizeof(packet), tick * 50)) != 0) {
      CHECK(total + n <= sizeof(retained)); memcpy(retained + total, packet, n); total += n;
    }
  }
  CHECK(total == sizeof(retained) && memcmp(retained, backlog + 4000, total) == 0);
  lrdp_audio_buffer_free(b);
  puts("PASS: bounded PCM prebuffer, exact packet reassembly, reset, PCM8 conversion and fractional-rate clock");
  return 0;
}
