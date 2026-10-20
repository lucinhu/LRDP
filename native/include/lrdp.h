#ifndef LRDP_H
#define LRDP_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
#if defined(LRDP_BUILDING_LIBRARY)
#define LRDP_API __declspec(dllexport)
#else
#define LRDP_API __declspec(dllimport)
#endif
#else
#define LRDP_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct lrdp_session lrdp_session;
typedef struct lrdp_video lrdp_video;
/* Base ABI v5; native video calls are additive. Session calls belong to one
 * Dart worker isolate. Only the internal network thread may call FreeRDP.
 * Frame pixels are caller-owned copies, except the explicitly scoped native
 * renderer callback below; no borrowed session pointer crosses isolates. */
enum { LRDP_IDLE, LRDP_CONNECTING, LRDP_CONNECTED, LRDP_CLOSED,
       LRDP_FAILED, LRDP_CERTIFICATE_REQUIRED };
enum { LRDP_END_NONE, LRDP_END_LOCAL, LRDP_END_TRANSPORT,
       LRDP_END_AUTHENTICATION, LRDP_END_CERTIFICATE, LRDP_END_REMOTE,
       LRDP_END_PROTOCOL, LRDP_END_CONFIGURATION };
LRDP_API int lrdp_abi_version(void);
LRDP_API const char* lrdp_version(void);
/* Initialize the application's private storage before creating sessions.
 * On Android this supplies a missing process home, as required by upstream.
 * Existing desktop/mobile home directories are never overridden. */
LRDP_API int lrdp_initialize(const char* private_directory);
LRDP_API lrdp_session* lrdp_create(void);
/* Configuration is immutable after start. Unknown keys fail closed. */
LRDP_API int lrdp_set(lrdp_session*, const char* key, const char* value);
LRDP_API int lrdp_start(lrdp_session*);
LRDP_API int lrdp_state(lrdp_session*);
/* Stable terminal snapshot. Only TRANSPORT is eligible for a fresh connection.
 * Unknown errors and explicit server ErrorInfo never request automatic retry. */
LRDP_API int lrdp_end_reason(lrdp_session*);
LRDP_API uint32_t lrdp_error_code(lrdp_session*);
/* Bits: 0 text clipboard ready, 1 dynamic display control ready,
 * 2 an AVC420/AVC444 surface command was successfully decoded,
 * 3 server negotiated Unicode keyboard input,
 * 4 this adapter provides bounded PNG/DIB clipboard operations (not a promise
 * that the server or destination application supports images),
 * 5 server negotiated file clipboard streams and this adapter supports them. */
LRDP_API int lrdp_features(lrdp_session*);
/* Fields: 0 error, 1 SHA256 fingerprint, 2 received clipboard (consumed),
 * 3 paste status: idle/pending/sent/rejected/timeout/cancelled.
 * 4 audio status: off/paused/pausing/waiting/playing/unavailable.
 * "sent" confirms Unicode data delivery and Ctrl+V transmission, not that an
 * arbitrary remote application accepted the paste. Unknown fields return -1. */
LRDP_API int lrdp_read(lrdp_session*, int field, char* out, size_t capacity);
/* BGRA snapshot, max 4096x4096. Returns bytes copied, 0 if unchanged,
 * or negative required capacity. Dimensions are written only on success. */
LRDP_API int lrdp_frame(lrdp_session*, uint8_t* out, size_t capacity,
                       int32_t* width, int32_t* height, uint64_t* generation);
/* Native rendering API. Tickets, not session addresses, cross platform channels.
 * ticket() belongs to the session owner. All other video calls use only plain
 * frame memory and may run on renderer threads without calling FreeRDP.
 * open() retains a frame store while its ticket is live; stale tickets fail.
 * A retained video outlives session teardown and may display its last frame.
 * One close() per successful open(); callers synchronize closing their handle
 * with their own reads/callbacks. A callback borrows immutable BGRA pixels only
 * until it returns; never retain that pointer. Return nonzero after upload.
 * visit(): 1 uploaded, 0 unchanged/empty, -1 callback failure, -2 busy (retry).
 * Generation advances only on callback success. GPU work does not hold the
 * producer mutex. Three bounded slots permit at most two concurrent callbacks.
 * info() returns 1 when a frame is available, writing dimensions/generation. */
typedef int (*lrdp_video_callback)(const uint8_t*, int32_t, int32_t, void*);
LRDP_API uint64_t lrdp_video_ticket(lrdp_session*);
LRDP_API lrdp_video* lrdp_video_open(uint64_t ticket);
LRDP_API int lrdp_video_info(lrdp_video*, int32_t*, int32_t*, uint64_t*);
LRDP_API int lrdp_video_visit(lrdp_video*, lrdp_video_callback, void*, uint64_t*);
LRDP_API void lrdp_video_close(lrdp_video*);
enum { LRDP_CURSOR_DEFAULT, LRDP_CURSOR_HIDDEN, LRDP_CURSOR_BITMAP };
/* Cursor snapshot, max 384x384. info[9]: kind,width,height,hotX,hotY,
 * remoteX,remoteY,positionSerial,shapeSerial. Caller owns both arrays/buffer.
 * Buffer: premultiplied BGRA normal plane, then BGRA white inversion mask.
 * Returns copied bytes (1 for default/hidden), 0 unchanged, or negative required
 * capacity. Metadata/generation advance only on success. Position -1 is unknown. */
LRDP_API int lrdp_cursor(lrdp_session*, uint8_t* out, size_t capacity,
                         int32_t* info, uint64_t* generation);
/* type: 0 mouse(flags,x,y), 1 scancode(flags,code), 2 UTF16(flags,unit),
 * 3 resize(width,height), 4 synchronize(toggle flags). Returns 0 if full. */
LRDP_API int lrdp_input(lrdp_session*, int type, int a, int b, int c);
/* Playback permission mailbox. Defaults paused. Safe before/during connect;
 * does not disconnect RDP or change the user's negotiated audio preference.
 * Pausing drops queued device audio; resume plays only newly received data. */
LRDP_API int lrdp_audio_active(lrdp_session*, int active);
LRDP_API int lrdp_clipboard(lrdp_session*, const char* text);
/* One bounded text-paste operation. Writes the remote text clipboard, waits
 * for its format acknowledgement, then sends Ctrl+V on the network owner.
 * Returns 1 if accepted; poll field 3 for completion. No automatic retries.
 * Regular clipboard writes return 0 while a paste is pending. */
LRDP_API int lrdp_paste(lrdp_session*, const char* text);
/* Additive ABI v5 extension. Caller owns bytes; accepted data is copied.
 * PNG and packed 24/32-bit DIB must describe the same dimensions. Each is
 * bounded to 16 MiB, 4096 per axis and 4 Mi pixels. Uses the same single paste
 * slot/status as text and performs no automatic retry. */
LRDP_API int lrdp_paste_image(lrdp_session*, const uint8_t* png, size_t png_size,
                             const uint8_t* dib, size_t dib_size);
/* Latest incoming image; kind 1=PNG, 2=packed DIB. Returns 0 if absent,
 * negative required capacity without consuming, or positive copied bytes.
 * Peek with NULL/0; successful reads consume. No borrowed pointer escapes. */
LRDP_API int lrdp_read_image(lrdp_session*, uint8_t*, size_t, int32_t* kind);
/* Additive ABI v5 extension, feature bit 5 gates lookup. Pins read-only handles
 * to private staged regular files; caller may remove staged paths after return.
 * Names only, never local paths, are exposed. Up to 32 files, 256 MiB each,
 * 512 MiB total; no folders. Uses the single paste slot. "sent" confirms only
 * descriptor delivery and Ctrl+V; the peer reads file contents asynchronously.
 * Keep the session/clipboard unchanged until the remote copy finishes. */
LRDP_API int lrdp_paste_files(lrdp_session*, const char* const* paths, size_t count);
LRDP_API void lrdp_stop(lrdp_session*);
/* Joins the network thread. Must only be called by the owning isolate. */
LRDP_API void lrdp_destroy(lrdp_session*);
#ifdef __cplusplus
}
#endif
#endif
