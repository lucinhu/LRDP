#include "video_store.h"
#include <winpr/synch.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define VIDEO_SLOTS 3
#define VIDEO_READERS 2
#define VIDEO_MAX_DIM 4096
typedef struct {
  uint8_t* pixels;
  size_t bytes;
  int32_t width, height;
  uint64_t generation;
  unsigned leases;
} video_frame;

struct lrdp_video {
  CRITICAL_SECTION lock;
  video_frame frames[VIDEO_SLOTS];
  int current;
  unsigned leases;
  uint64_t generation, ticket;
  size_t references;
  struct lrdp_video* next;
};

/* Tickets cross isolates/platform channels, never session addresses. Retiring
 * a session removes its ticket before dropping its reference. An already open
 * renderer retains plain frame memory and never touches FreeRDP or a session. */
static INIT_ONCE registry_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION registry_lock;
static lrdp_video* registry;
static uint64_t next_ticket;
static BOOL CALLBACK registry_init(PINIT_ONCE once, PVOID parameter, PVOID* context) {
  (void)once; (void)parameter; (void)context;
  InitializeCriticalSection(&registry_lock);
  return TRUE;
}

lrdp_video* lrdp_video_store_new(void) {
  if (!InitOnceExecuteOnce(&registry_once, registry_init, NULL, NULL)) return NULL;
  lrdp_video* video = calloc(1, sizeof(*video));
  if (!video) return NULL;
  InitializeCriticalSection(&video->lock);
  video->current = -1;
  video->references = 1;
  EnterCriticalSection(&registry_lock);
  if (next_ticket == INT64_MAX) {
    LeaveCriticalSection(&registry_lock);
    DeleteCriticalSection(&video->lock); free(video); return NULL;
  }
  video->ticket = ++next_ticket;
  video->next = registry;
  registry = video;
  LeaveCriticalSection(&registry_lock);
  return video;
}

uint64_t lrdp_video_store_ticket(lrdp_video* video) {
  return video ? video->ticket : 0;
}

lrdp_video* lrdp_video_open(uint64_t ticket) {
  if (!ticket || !InitOnceExecuteOnce(&registry_once, registry_init, NULL, NULL)) return NULL;
  EnterCriticalSection(&registry_lock);
  lrdp_video* found = registry;
  while (found && found->ticket != ticket) found = found->next;
  if (found) found->references++;
  LeaveCriticalSection(&registry_lock);
  return found;
}

void lrdp_video_close(lrdp_video* video) {
  if (!video) return;
  EnterCriticalSection(&registry_lock);
  BOOL last = --video->references == 0;
  LeaveCriticalSection(&registry_lock);
  if (!last) return;
  for (unsigned i = 0; i < VIDEO_SLOTS; i++) free(video->frames[i].pixels);
  DeleteCriticalSection(&video->lock); free(video);
}

void lrdp_video_store_retire(lrdp_video* video) {
  if (!video) return;
  EnterCriticalSection(&registry_lock);
  lrdp_video** link = &registry;
  while (*link && *link != video) link = &(*link)->next;
  if (*link) *link = video->next;
  LeaveCriticalSection(&registry_lock);
  lrdp_video_close(video);
}

int lrdp_video_store_publish(lrdp_video* video, const uint8_t* pixels,
    int32_t width, int32_t height, size_t stride) {
  if (!video || !pixels || width < 1 || height < 1 ||
      width > VIDEO_MAX_DIM || height > VIDEO_MAX_DIM || stride < (size_t)width * 4) return 0;
  const size_t bytes = (size_t)width * height * 4;
  EnterCriticalSection(&video->lock);
  int index = video->current;
  if (index < 0 || video->frames[index].leases) {
    for (index = 0; index < VIDEO_SLOTS && video->frames[index].leases; index++) {}
  }
  /* At most two callbacks hold leases; the producer always has a third slot.
   * In particular, a blocked GPU upload cannot block disconnect or allocate
   * unbounded frames. Reuse the current slot when no renderer is borrowing it. */
  if (index == VIDEO_SLOTS) { LeaveCriticalSection(&video->lock); return 0; }
  video_frame* frame = &video->frames[index];
  if (frame->bytes != bytes) {
    uint8_t* next = realloc(frame->pixels, bytes);
    if (!next) { LeaveCriticalSection(&video->lock); return 0; }
    frame->pixels = next; frame->bytes = bytes;
  }
  for (int32_t y = 0; y < height; y++)
    memcpy(frame->pixels + (size_t)y * width * 4, pixels + (size_t)y * stride, (size_t)width * 4);
  frame->width = width; frame->height = height;
  if (++video->generation == 0) video->generation++;
  frame->generation = video->generation;
  video->current = index;
  LeaveCriticalSection(&video->lock);
  return 1;
}

int lrdp_video_info(lrdp_video* video, int32_t* width, int32_t* height, uint64_t* generation) {
  if (!video || !width || !height || !generation) return 0;
  EnterCriticalSection(&video->lock);
  int ok = video->current >= 0;
  if (ok) {
    const video_frame* frame = &video->frames[video->current];
    *width = frame->width; *height = frame->height; *generation = frame->generation;
  }
  LeaveCriticalSection(&video->lock);
  return ok;
}

int lrdp_video_store_copy(lrdp_video* video, uint8_t* out, size_t capacity,
    int32_t* width, int32_t* height, uint64_t* generation) {
  if (!video || !width || !height || !generation) return 0;
  EnterCriticalSection(&video->lock);
  if (video->current < 0) { LeaveCriticalSection(&video->lock); return 0; }
  const video_frame* frame = &video->frames[video->current];
  if (*generation == frame->generation) { LeaveCriticalSection(&video->lock); return 0; }
  if (!out || capacity < frame->bytes) {
    int required = -(int)frame->bytes; LeaveCriticalSection(&video->lock); return required;
  }
  memcpy(out, frame->pixels, frame->bytes);
  *width = frame->width; *height = frame->height; *generation = frame->generation;
  int size = (int)frame->bytes;
  LeaveCriticalSection(&video->lock);
  return size;
}

int lrdp_video_visit(lrdp_video* video, lrdp_video_callback callback, void* context,
    uint64_t* generation) {
  if (!video || !callback || !generation) return 0;
  EnterCriticalSection(&video->lock);
  if (video->current < 0 || video->frames[video->current].generation == *generation) {
    LeaveCriticalSection(&video->lock); return 0;
  }
  if (video->leases == VIDEO_READERS) { LeaveCriticalSection(&video->lock); return -2; }
  video_frame* frame = &video->frames[video->current];
  frame->leases++; video->leases++;
  LeaveCriticalSection(&video->lock);
  int ok = callback(frame->pixels, frame->width, frame->height, context);
  EnterCriticalSection(&video->lock);
  if (ok) *generation = frame->generation;
  frame->leases--; video->leases--;
  LeaveCriticalSection(&video->lock);
  return ok ? 1 : -1;
}
