#include "video_store.h"
#include <winpr/synch.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define VIDEO_SLOTS 3
#define VIDEO_READERS 2
#define VIDEO_MAX_DIM 4096
/* Per-frame changed rectangles, indexed by generation. A reused slot refreshes
 * the generations it missed and a renderer that skipped frames refreshes its
 * whole gap, so both read back into this ring. A gap that is no longer covered
 * falls back to a whole-frame transfer instead of guessing. */
#define VIDEO_DAMAGE_GENERATIONS 32

typedef struct {
  uint8_t* pixels;
  size_t bytes;
  int32_t width, height;
  uint64_t generation;
  uint64_t filled; /* generation of the complete frame this slot holds, 0 unknown */
  unsigned leases;
} video_frame;

typedef struct {
  uint64_t generation;
  int32_t width, height;
  int32_t x, y, w, h;
  BOOL full;    /* every pixel of the frame changed */
  BOOL resized; /* the frame dimensions changed at this generation */
} video_damage_entry;

struct lrdp_video {
  CRITICAL_SECTION lock;
  video_frame frames[VIDEO_SLOTS];
  video_damage_entry damage[VIDEO_DAMAGE_GENERATIONS];
  int current;
  unsigned leases;
  uint64_t generation, ticket;
  int32_t width, height; /* dimensions of the last published frame */
  size_t references;
  struct lrdp_video* next;
};

static int32_t min_i32(int32_t a, int32_t b) { return a < b ? a : b; }
static int32_t max_i32(int32_t a, int32_t b) { return a > b ? a : b; }

static BOOL rect_empty(const lrdp_video_rect* rect) {
  return rect->width <= 0 || rect->height <= 0;
}

/* Intersect a changed rectangle with the frame. FALSE means the rectangle is
 * empty or entirely outside it, which also means no visible pixel changed. */
static BOOL clip_rect(int32_t x, int32_t y, int32_t w, int32_t h,
    int32_t width, int32_t height, lrdp_video_rect* out) {
  int64_t left = x, top = y, right = (int64_t)x + w, bottom = (int64_t)y + h;
  if (w <= 0 || h <= 0 || right <= 0 || bottom <= 0 ||
      left >= width || top >= height) return FALSE;
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right > width) right = width;
  if (bottom > height) bottom = height;
  out->x = (int32_t)left; out->y = (int32_t)top;
  out->width = (int32_t)(right - left); out->height = (int32_t)(bottom - top);
  return TRUE;
}

/* Grow one rectangle into the bounding box of both; empty rectangles add nothing. */
static void merge_rect(lrdp_video_rect* into, const lrdp_video_rect* rect) {
  if (rect_empty(rect)) return;
  if (rect_empty(into)) { *into = *rect; return; }
  const int32_t x = min_i32(into->x, rect->x);
  const int32_t y = min_i32(into->y, rect->y);
  const int32_t right = max_i32(into->x + into->width, rect->x + rect->width);
  const int32_t bottom = max_i32(into->y + into->height, rect->y + rect->height);
  into->x = x; into->y = y; into->width = right - x; into->height = bottom - y;
}

/* Bounding box of every changed pixel of the generations after from up to to.
 * FALSE means the gap is not fully described any more (an evicted generation,
 * more than VIDEO_DAMAGE_GENERATIONS of them, or a frame size change), so the
 * caller must transfer the whole frame. */
static BOOL damage_since(const lrdp_video* video, uint64_t from, uint64_t to,
    int32_t width, int32_t height, lrdp_video_rect* out) {
  memset(out, 0, sizeof(*out));
  if (to <= from) return TRUE;
  if (to - from > VIDEO_DAMAGE_GENERATIONS) return FALSE;
  for (uint64_t generation = from + 1; generation <= to; generation++) {
    const video_damage_entry* entry = &video->damage[generation % VIDEO_DAMAGE_GENERATIONS];
    if (entry->generation != generation || entry->resized) return FALSE;
    if (entry->full) {
      out->x = 0; out->y = 0; out->width = width; out->height = height;
      return TRUE;
    }
    const lrdp_video_rect rect = {entry->x, entry->y, entry->w, entry->h};
    merge_rect(out, &rect);
  }
  return TRUE;
}

/* Copy one rectangle of tightly packed BGRA rows out of a strided source. */
static void copy_rect(uint8_t* dst, int32_t width, const uint8_t* src, size_t stride,
    const lrdp_video_rect* rect) {
  const size_t row_bytes = (size_t)rect->width * 4;
  for (int32_t y = 0; y < rect->height; y++) {
    const int32_t row = rect->y + y;
    memcpy(dst + (size_t)row * (size_t)width * 4 + (size_t)rect->x * 4,
           src + (size_t)row * stride + (size_t)rect->x * 4, row_bytes);
  }
}

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
    int32_t width, int32_t height, size_t stride, const lrdp_video_rect* damage) {
  if (!video || !pixels || width < 1 || height < 1 ||
      width > VIDEO_MAX_DIM || height > VIDEO_MAX_DIM || stride < (size_t)width * 4) return 0;
  const size_t bytes = (size_t)width * height * 4;
  lrdp_video_rect changed;
  const BOOL clipped = damage && clip_rect(damage->x, damage->y, damage->width,
                                           damage->height, width, height, &changed);
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
    uint8_t* grown = realloc(frame->pixels, bytes);
    if (!grown) { LeaveCriticalSection(&video->lock); return 0; }
    frame->pixels = grown; frame->bytes = bytes; frame->filled = 0;
  }
  uint64_t generation = video->generation + 1;
  if (generation == 0) generation = 1;
  const BOOL resized = video->width != width || video->height != height;
  const BOOL whole = !damage || resized || frame->filled == 0 ||
                     frame->width != width || frame->height != height;
  lrdp_video_rect refresh = {0, 0, width, height};
  BOOL full_copy = whole;
  if (!full_copy) {
    lrdp_video_rect history;
    if (!damage_since(video, frame->filled, video->generation, width, height, &history)) {
      full_copy = TRUE;
    } else {
      refresh = history;
      if (clipped) merge_rect(&refresh, &changed);
    }
  }
  if (full_copy) {
    const lrdp_video_rect all = {0, 0, width, height};
    copy_rect(frame->pixels, width, pixels, stride, &all);
  } else if (!rect_empty(&refresh)) {
    copy_rect(frame->pixels, width, pixels, stride, &refresh);
  }
  frame->width = width; frame->height = height; frame->filled = generation;
  video->generation = generation; frame->generation = generation;
  video->current = index; video->width = width; video->height = height;
  /* The entry describes this frame's own damage, not why the slot was refreshed:
   * a slot can need a full copy while the rendered change stays small. */
  video_damage_entry* entry = &video->damage[generation % VIDEO_DAMAGE_GENERATIONS];
  entry->generation = generation;
  entry->width = width; entry->height = height;
  entry->resized = resized;
  entry->full = !damage;
  if (!damage) {
    entry->x = 0; entry->y = 0; entry->w = width; entry->h = height;
  } else if (clipped) {
    entry->x = changed.x; entry->y = changed.y;
    entry->w = changed.width; entry->h = changed.height;
  } else {
    entry->x = 0; entry->y = 0; entry->w = 0; entry->h = 0;
  }
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

int lrdp_video_visit_damage(lrdp_video* video, lrdp_video_damage_callback callback,
    void* context, uint64_t* generation) {
  if (!video || !callback || !generation) return 0;
  lrdp_video_rect damage;
  memset(&damage, 0, sizeof(damage));
  BOOL whole = TRUE;
  EnterCriticalSection(&video->lock);
  if (video->current < 0 || video->frames[video->current].generation == *generation) {
    LeaveCriticalSection(&video->lock); return 0;
  }
  if (video->leases == VIDEO_READERS) { LeaveCriticalSection(&video->lock); return -2; }
  video_frame* frame = &video->frames[video->current];
  /* A renderer uploads again only after it consumed the previous frame, so the
   * span from its last generation describes exactly what it is missing. */
  if (*generation != 0 && damage_since(video, *generation, frame->generation,
                                       frame->width, frame->height, &damage)) {
    whole = damage.x == 0 && damage.y == 0 &&
            damage.width == frame->width && damage.height == frame->height;
  }
  frame->leases++; video->leases++;
  LeaveCriticalSection(&video->lock);
  int ok = callback(frame->pixels, frame->width, frame->height,
                    whole ? NULL : &damage, context);
  EnterCriticalSection(&video->lock);
  if (ok) *generation = frame->generation;
  frame->leases--; video->leases--;
  LeaveCriticalSection(&video->lock);
  return ok ? 1 : -1;
}
