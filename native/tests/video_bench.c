/* Frame-path micro-benchmark for the damage-aware video store. Not a CTest:
 * timings are hardware dependent and must not gate a build. Run it to compare
 * whole-frame publishes, per-rectangle publishes and renderer-side copies. */
#include "video_store.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static uint64_t now_ns(void) {
  LARGE_INTEGER frequency, counter;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&counter);
  return (uint64_t)((double)counter.QuadPart * 1e9 / (double)frequency.QuadPart);
}
#else
#include <time.h>
static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
#endif

#define WIDTH 1920
#define HEIGHT 1080
#define ITERATIONS 400
#define BYTES ((size_t)WIDTH * HEIGHT * 4)
#define STRIDE ((size_t)WIDTH * 4)

static uint8_t* source;
static uint8_t* destination;
static lrdp_video* owner;
static uint64_t generation;
static lrdp_video_rect damage;

static int copy_whole(const uint8_t* pixels, int32_t width, int32_t height, void* context) {
  (void)context;
  memcpy(destination, pixels, (size_t)width * height * 4);
  return 1;
}
static int copy_damage(const uint8_t* pixels, int32_t width, int32_t height,
    const lrdp_video_rect* changed, void* context) {
  (void)height; (void)context;
  if (!changed) { memcpy(destination, pixels, BYTES); return 1; }
  for (int32_t row = 0; row < changed->height; row++) {
    const size_t offset = ((size_t)(changed->y + row) * (size_t)width + changed->x) * 4;
    memcpy(destination + offset, pixels + offset, (size_t)changed->width * 4);
  }
  return 1;
}

static void report(const char* label, uint64_t elapsed, int iterations, size_t bytes_per_op) {
  const double per_op_ns = (double)elapsed / iterations;
  const double megabyte_rate = per_op_ns > 0 ? (double)bytes_per_op / per_op_ns * 1000.0 : 0.0;
  printf("  %-26s %8.1f us/frame  %8zu B/frame  %6.0f MB/s  %5.2f%% of one core at 30 fps\n",
         label, per_op_ns / 1000.0, bytes_per_op, megabyte_rate,
         per_op_ns * 30.0 / 1e6 * 100.0);
}

int main(void) {
  source = malloc(BYTES); destination = malloc(BYTES);
  if (!source || !destination) return 1;
  for (size_t i = 0; i < BYTES; i++) source[i] = (uint8_t)i;
  owner = lrdp_video_store_new();
  lrdp_video* reader = owner ? lrdp_video_open(lrdp_video_store_ticket(owner)) : NULL;
  if (!reader) { fprintf(stderr, "video bench: store unavailable\n"); return 1; }

  for (int i = 0; i < 10; i++) lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, NULL);
  uint64_t began = now_ns();
  for (int i = 0; i < ITERATIONS; i++)
    lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, NULL);
  report("store publish whole", now_ns() - began, ITERATIONS, BYTES);

  damage = (lrdp_video_rect){640, 360, 320, 240};
  lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, &damage);
  began = now_ns();
  for (int i = 0; i < ITERATIONS; i++) {
    source[(size_t)(360 + i % 240) * STRIDE + ((640 + i % 320) * 4)] ^= 1;
    lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, &damage);
  }
  report("store publish 320x240", now_ns() - began, ITERATIONS, (size_t)320 * 240 * 4);

  damage = (lrdp_video_rect){960, 540, 2, 18};
  lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, &damage);
  began = now_ns();
  for (int i = 0; i < ITERATIONS; i++) {
    source[(size_t)(540 + i % 18) * STRIDE + (960 * 4)] ^= 1;
    lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, &damage);
  }
  report("store publish 2x18 caret", now_ns() - began, ITERATIONS, (size_t)2 * 18 * 4);

  began = now_ns();
  for (int i = 0; i < ITERATIONS; i++) {
    lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, NULL);
    lrdp_video_visit(reader, copy_whole, NULL, &generation);
  }
  report("publish + whole visit", now_ns() - began, ITERATIONS, BYTES);

  damage = (lrdp_video_rect){640, 360, 320, 240};
  began = now_ns();
  for (int i = 0; i < ITERATIONS; i++) {
    lrdp_video_store_publish(owner, source, WIDTH, HEIGHT, STRIDE, &damage);
    lrdp_video_visit_damage(reader, copy_damage, NULL, &generation);
  }
  report("publish + damage visit", now_ns() - began, ITERATIONS, (size_t)320 * 240 * 4);

  printf("  whole frame %zu bytes; 30 fps whole-frame traffic would be %.1f MB/s\n",
         BYTES, (double)BYTES * 30.0 / 1e6);
  lrdp_video_close(reader);
  lrdp_video_store_retire(owner);
  free(source); free(destination);
  return 0;
}
