#include "video_store.h"
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/sysinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "video store: %s at %d\n", #x, __LINE__); exit(1); } } while (0)
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
  CHECK(lrdp_video_store_publish(owner, padded, 4, 2, 20));
  CHECK(!lrdp_video_store_publish(owner, padded, 4097, 1, 20000));
  CHECK(!lrdp_video_store_publish(owner, padded, 4, 2, 15));
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
    CHECK(lrdp_video_store_publish(owner, data, w, h, (size_t)w * 4));
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
    CHECK(lrdp_video_store_publish(owner, data, w, 5, (size_t)w * 4));
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
  puts("PASS: frame leases, padded stride, retry, resize, bounded readers and owner teardown during blocked rendering");
  return 0;
}
