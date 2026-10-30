#include "video_store.h"
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/sysinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "video store: %s at %d\n", #x, __LINE__); exit(1); } } while (0)
#define CHECK_RECT(rect, left, top, w, h) do { \
    CHECK((rect)); CHECK((rect)->x == (left)); CHECK((rect)->y == (top)); \
    CHECK((rect)->width == (w)); CHECK((rect)->height == (h)); \
  } while (0)

typedef struct {
  int32_t width, height;
  uint8_t byte;
  int accept, calls;
} expected_frame;
static int inspect(const uint8_t* pixels, int32_t width, int32_t height, void* context) {
  expected_frame* expected = context;
  CHECK(width == expected->width && height == expected->height);
  for (size_t i = 0; i < (size_t)width * height * 4; i++) CHECK(pixels[i] == expected->byte);
  expected->calls++;
  return expected->accept;
}
typedef struct {
  const uint8_t* frame;
  int32_t width, height;
  int calls;
} full_expectation;
static int match_full(const uint8_t* pixels, int32_t width, int32_t height, void* context) {
  full_expectation* expected = context;
  CHECK(width == expected->width && height == expected->height);
  CHECK(memcmp(pixels, expected->frame, (size_t)width * height * 4) == 0);
  expected->calls++;
  return 1;
}

typedef struct {
  lrdp_video* video;
  expected_frame expected;
  HANDLE entered, release;
  uint64_t generation;
} blocked_reader;
static int blocked(const uint8_t* pixels, int32_t width, int32_t height, void* context) {
  blocked_reader* reader = context;
  CHECK(inspect(pixels, width, height, &reader->expected));
  CHECK(SetEvent(reader->entered));
  CHECK(WaitForSingleObject(reader->release, 5000) == WAIT_OBJECT_0);
  /* The producer resized/replaced its current frame and destroyed its owner.
   * This consumer's dimensions and bytes must still be the original snapshot. */
  CHECK(inspect(pixels, width, height, &reader->expected));
  return 1;
}
static DWORD WINAPI render(LPVOID parameter) {
  blocked_reader* reader = parameter;
  CHECK(lrdp_video_visit(reader->video, blocked, reader, &reader->generation) == 1);
  return 0;
}

/* A renderer that owns a shadow copy and refreshes only the reported damage.
 * Applying the callback's rectangle to its previous upload must reproduce the
 * full current frame; that is the whole promise of the damage API. */
typedef struct {
  int32_t width, height;
  uint8_t* shadow;
  size_t capacity;
  const uint8_t* expected;
  int32_t expected_width, expected_height;
  lrdp_video_rect reported;
  int reported_whole, calls;
  int accept;
} damage_probe;
static int apply_damage(const uint8_t* pixels, int32_t width, int32_t height,
    const lrdp_video_rect* damage, void* context) {
  damage_probe* probe = context;
  CHECK(width > 0 && height > 0);
  const size_t bytes = (size_t)width * height * 4;
  if (probe->capacity != bytes || probe->width != width || probe->height != height) {
    free(probe->shadow);
    probe->shadow = malloc(bytes); CHECK(probe->shadow);
    memset(probe->shadow, 0, bytes);
    probe->capacity = bytes; probe->width = width; probe->height = height;
  }
  probe->reported_whole = damage == NULL;
  if (!damage) {
    memset(&probe->reported, 0, sizeof(probe->reported));
    memcpy(probe->shadow, pixels, bytes);
  } else {
    probe->reported = *damage;
    CHECK(damage->x >= 0 && damage->y >= 0 && damage->width >= 0 && damage->height >= 0);
    CHECK(damage->x + damage->width <= width && damage->y + damage->height <= height);
    for (int32_t row = 0; row < damage->height; row++) {
      const size_t offset = ((size_t)(damage->y + row) * width + damage->x) * 4;
      memcpy(probe->shadow + offset, pixels + offset, (size_t)damage->width * 4);
    }
  }
  probe->calls++;
  return probe->accept;
}
static void check_shadow(const damage_probe* probe) {
  CHECK(probe->expected);
  CHECK(probe->shadow);
  CHECK(probe->width == probe->expected_width && probe->height == probe->expected_height);
  CHECK(memcmp(probe->shadow, probe->expected,
               (size_t)probe->width * probe->height * 4) == 0);
}
static void fill_frame(uint8_t* frame, int32_t width, int32_t height, uint32_t seed) {
  for (int32_t y = 0; y < height; y++) {
    for (int32_t x = 0; x < width; x++) {
      uint8_t* pixel = frame + ((size_t)y * width + x) * 4;
      pixel[0] = (uint8_t)(seed + (uint32_t)x * 3);
      pixel[1] = (uint8_t)(seed + (uint32_t)y * 5);
      pixel[2] = (uint8_t)(seed ^ ((uint32_t)x << 4 | (uint32_t)y));
      pixel[3] = (uint8_t)(0xff - (uint32_t)x - (uint32_t)y);
    }
  }
}
static void patch_frame(uint8_t* frame, int32_t width, int32_t x, int32_t y, int32_t w,
    int32_t h, uint8_t byte) {
  for (int32_t row = 0; row < h; row++)
    for (int32_t column = 0; column < w; column++)
      memset(frame + ((size_t)(y + row) * width + (x + column)) * 4, byte, 4);
}

int main(void) {
  CHECK(!lrdp_video_open(0)); CHECK(!lrdp_video_open(UINT64_MAX));
  CHECK(!lrdp_video_info(NULL, NULL, NULL, NULL)); lrdp_video_close(NULL);
  lrdp_video* owner = lrdp_video_store_new(); CHECK(owner);
  uint64_t ticket = lrdp_video_store_ticket(owner); CHECK(ticket);
  lrdp_video* reader = lrdp_video_open(ticket); CHECK(reader);
  int32_t width = -1, height = -1; uint64_t generation = 0;
  expected_frame expected = {4, 2, 0x2a, 0, 0};
  CHECK(!lrdp_video_info(reader, &width, &height, &generation));
  CHECK(!lrdp_video_visit(reader, inspect, &expected, &generation));
  uint8_t padded[40]; memset(padded, 0x2a, sizeof(padded));
  memset(padded + 16, 0xee, 4); memset(padded + 36, 0xee, 4);
  CHECK(lrdp_video_store_publish(owner, padded, 4, 2, 20, NULL));
  CHECK(!lrdp_video_store_publish(owner, padded, 4097, 1, 20000, NULL));
  CHECK(!lrdp_video_store_publish(owner, padded, 4, 2, 15, NULL));
  CHECK(lrdp_video_visit(reader, inspect, &expected, &generation) == -1);
  CHECK(generation == 0 && expected.calls == 1);
  expected.accept = 1;
  CHECK(lrdp_video_visit(reader, inspect, &expected, &generation) == 1);
  CHECK(generation == 1 && expected.calls == 2);
  CHECK(lrdp_video_visit(reader, inspect, &expected, &generation) == 0);
  CHECK(expected.calls == 2);
  uint8_t copy[32]; uint64_t copied = 0;
  CHECK(lrdp_video_store_copy(owner, copy, 31, &width, &height, &copied) == -32);
  CHECK(width == -1 && height == -1 && copied == 0);
  CHECK(lrdp_video_store_copy(owner, copy, sizeof(copy), &width, &height, &copied) == 32);
  CHECK(width == 4 && height == 2 && copied == 1);
  for (unsigned i = 0; i < sizeof(copy); i++) CHECK(copy[i] == 0x2a);
  lrdp_video_store_retire(owner);
  CHECK(!lrdp_video_open(ticket));
  CHECK(lrdp_video_info(reader, &width, &height, &copied) && copied == 1);
  lrdp_video_close(reader);

  owner = lrdp_video_store_new(); CHECK(owner);
  CHECK(lrdp_video_store_ticket(owner) != ticket);
  ticket = lrdp_video_store_ticket(owner);
  blocked_reader readers[2] = {0}; HANDLE threads[2];
  uint8_t data[140];
  for (unsigned i = 0; i < 2; i++) {
    int32_t w = (int32_t)i + 2, h = (int32_t)i + 1;
    memset(data, (int)i + 0x11, sizeof(data));
    CHECK(lrdp_video_store_publish(owner, data, w, h, (size_t)w * 4, NULL));
    readers[i].video = lrdp_video_open(ticket); CHECK(readers[i].video);
    readers[i].expected = (expected_frame){w, h, (uint8_t)(i + 0x11), 1, 0};
    readers[i].entered = CreateEvent(NULL, TRUE, FALSE, NULL);
    readers[i].release = CreateEvent(NULL, TRUE, FALSE, NULL);
    CHECK(readers[i].entered && readers[i].release);
    threads[i] = CreateThread(NULL, 0, render, &readers[i], 0, NULL); CHECK(threads[i]);
    CHECK(WaitForSingleObject(readers[i].entered, 5000) == WAIT_OBJECT_0);
  }
  uint64_t began = GetTickCount64();
  for (int i = 0; i < 1000; i++) {
    int w = i % 7 + 1;
    memset(data, i & 0xff, sizeof(data));
    CHECK(lrdp_video_store_publish(owner, data, w, 5, (size_t)w * 4, NULL));
  }
  CHECK(GetTickCount64() - began < 1500);
  lrdp_video* last = lrdp_video_open(ticket); CHECK(last);
  generation = 0;
  CHECK(lrdp_video_visit(last, inspect, &expected, &generation) == -2);
  CHECK(generation == 0);
  began = GetTickCount64();
  lrdp_video_store_retire(owner);
  CHECK(GetTickCount64() - began < 500);
  CHECK(!lrdp_video_open(ticket));
  for (unsigned i = 0; i < 2; i++) {
    CHECK(SetEvent(readers[i].release));
    CHECK(WaitForSingleObject(threads[i], 5000) == WAIT_OBJECT_0);
    CHECK(readers[i].generation == i + 1 && readers[i].expected.calls == 2);
    lrdp_video_close(readers[i].video);
    CloseHandle(threads[i]); CloseHandle(readers[i].entered); CloseHandle(readers[i].release);
  }
  expected = (expected_frame){999 % 7 + 1, 5, 999 & 0xff, 1, 0};
  CHECK(lrdp_video_visit(last, inspect, &expected, &generation) == 1);
  CHECK(generation == 1002);
  lrdp_video_close(last);

  /* Damage-aware uploads: only the reported rectangle may be copied; applying it
   * to the renderer's previous upload has to reproduce the current frame. */
  owner = lrdp_video_store_new(); CHECK(owner);
  ticket = lrdp_video_store_ticket(owner);
  lrdp_video* damage_reader = lrdp_video_open(ticket); CHECK(damage_reader);
  damage_probe probe = {0}, skipped = {0};
  probe.accept = skipped.accept = 1;
  uint64_t damage_generation = 0, skipped_generation = 0;
  uint8_t frame[8 * 4 * 4], next[8 * 4 * 4];
  fill_frame(frame, 8, 4, 0x40);
  CHECK(lrdp_video_store_publish(owner, frame, 8, 4, 32, NULL));
  probe.expected = frame; probe.expected_width = 8; probe.expected_height = 4;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &probe, &damage_generation) == 1);
  CHECK(damage_generation == 1 && probe.reported_whole && probe.calls == 1);
  check_shadow(&probe);

  memcpy(next, frame, sizeof(next));
  patch_frame(next, 8, 1, 1, 2, 2, 0x99);
  const lrdp_video_rect first_change = {1, 1, 2, 2};
  CHECK(lrdp_video_store_publish(owner, next, 8, 4, 32, &first_change));
  probe.expected = next;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &probe, &damage_generation) == 1);
  CHECK(damage_generation == 2 && !probe.reported_whole);
  CHECK_RECT(&probe.reported, 1, 1, 2, 2);
  check_shadow(&probe);

  /* Failing callbacks must not advance the generation and must stay retryable. */
  memcpy(next + ((size_t)2 * 8 + 5) * 4, "\x11\x22\x33\x44", 4);
  const lrdp_video_rect second_change = {5, 2, 1, 1};
  probe.accept = 0;
  CHECK(lrdp_video_store_publish(owner, next, 8, 4, 32, &second_change));
  probe.expected = next;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &probe, &damage_generation) == -1);
  CHECK(damage_generation == 2);
  probe.accept = 1;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &probe, &damage_generation) == 1);
  CHECK(damage_generation == 3);
  CHECK_RECT(&probe.reported, 5, 2, 1, 1);
  check_shadow(&probe);

  /* Leaving pixels untouched outside the rectangle must be enough for a reader
   * whose whole-frame visit still works: slots always keep complete frames. */
  lrdp_video* full_reader = lrdp_video_open(ticket); CHECK(full_reader);
  full_expectation full = {next, 8, 4, 0};
  uint64_t full_generation = 0;
  CHECK(lrdp_video_visit(full_reader, match_full, &full, &full_generation) == 1);
  CHECK(full_generation == 3 && full.calls == 1);
  lrdp_video_close(full_reader);

  /* A renderer that skipped frames gets the bounding box of everything it missed. */
  uint8_t third[8 * 4 * 4];
  memcpy(third, next, sizeof(third));
  patch_frame(third, 8, 1, 1, 2, 2, 0x5a);
  CHECK(lrdp_video_store_publish(owner, third, 8, 4, 32, &first_change));
  memcpy(third + ((size_t)2 * 8 + 5) * 4, "\x77\x66\x55\x44", 4);
  CHECK(lrdp_video_store_publish(owner, third, 8, 4, 32, &second_change));
  skipped.expected = third; skipped.expected_width = 8; skipped.expected_height = 4;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &skipped, &skipped_generation) == 1);
  CHECK(skipped_generation == 5 && skipped.reported_whole);
  check_shadow(&skipped);
  /* Now skip two generations and upload only their union. */
  uint8_t fourth[8 * 4 * 4];
  memcpy(fourth, third, sizeof(fourth));
  patch_frame(fourth, 8, 1, 1, 2, 2, 0x21);
  CHECK(lrdp_video_store_publish(owner, fourth, 8, 4, 32, &first_change));
  memcpy(fourth + ((size_t)2 * 8 + 5) * 4, "\x31\x32\x33\x34", 4);
  CHECK(lrdp_video_store_publish(owner, fourth, 8, 4, 32, &second_change));
  skipped.expected = fourth;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &skipped, &skipped_generation) == 1);
  CHECK(skipped_generation == 7);
  CHECK_RECT(&skipped.reported, 1, 1, 5, 2);
  check_shadow(&skipped);

  /* Beyond the retained history a whole-frame upload is the only safe answer. */
  uint8_t rolling[8 * 4 * 4];
  memcpy(rolling, fourth, sizeof(rolling));
  for (int i = 0; i < 40; i++) {
    patch_frame(rolling, 8, 0, 0, 1, 1, (uint8_t)i);
    const lrdp_video_rect corner = {0, 0, 1, 1};
    CHECK(lrdp_video_store_publish(owner, rolling, 8, 4, 32, &corner));
  }
  skipped.expected = rolling;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &skipped, &skipped_generation) == 1);
  CHECK(skipped.reported_whole);
  check_shadow(&skipped);

  /* Frame size changes force a whole-frame upload and a new renderer size. */
  uint8_t resized[6 * 6 * 4];
  fill_frame(resized, 6, 6, 0x70);
  CHECK(lrdp_video_store_publish(owner, resized, 6, 6, 24, NULL));
  skipped.expected = resized; skipped.expected_width = 6; skipped.expected_height = 6;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &skipped, &skipped_generation) == 1);
  CHECK(skipped.reported_whole);
  check_shadow(&skipped);
  uint8_t resized_patch[6 * 6 * 4];
  memcpy(resized_patch, resized, sizeof(resized_patch));
  patch_frame(resized_patch, 6, 0, 0, 2, 2, 0x44);
  const lrdp_video_rect small_change = {0, 0, 2, 2};
  CHECK(lrdp_video_store_publish(owner, resized_patch, 6, 6, 24, &small_change));
  skipped.expected = resized_patch;
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &skipped, &skipped_generation) == 1);
  CHECK(!skipped.reported_whole);
  CHECK_RECT(&skipped.reported, 0, 0, 2, 2);
  check_shadow(&skipped);

  /* A rectangle outside the frame changes no pixels: an empty damage report is
   * still a successful generation, it just transfers nothing. */
  uint64_t empty_generation = skipped_generation;
  const lrdp_video_rect outside = {100, 100, 2, 2};
  CHECK(lrdp_video_store_publish(owner, resized_patch, 6, 6, 24, &outside));
  CHECK(lrdp_video_visit_damage(damage_reader, apply_damage, &skipped, &empty_generation) == 1);
  CHECK(!skipped.reported_whole);
  CHECK(skipped.reported.width <= 0 || skipped.reported.height <= 0);
  check_shadow(&skipped);

  free(probe.shadow); free(skipped.shadow);
  lrdp_video_close(damage_reader); lrdp_video_store_retire(owner);
  puts("PASS: frame leases, padded stride, retry, resize, bounded readers, owner teardown during "
       "blocked rendering, damage rectangles, skipped frames, history fallback and small updates");
  return 0;
}
