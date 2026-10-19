#include "lrdp.h"
#include "audio_gate.h"
#include "video_store.h"
#include <freerdp/freerdp.h>
#include <freerdp/version.h>
#include <freerdp/config.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/error.h>
#include <freerdp/transport_io.h>
#include <freerdp/utils/helpers.h>
#include <freerdp/graphics.h>
#include <freerdp/codec/color.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/client/disp.h>
#include <freerdp/crypto/certificate.h>
#include <winpr/crt.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/thread.h>
#include <winpr/string.h>
#include <winpr/wlog.h>
#include <winpr/environment.h>
#include <winpr/file.h>
#include <winpr/path.h>
#include <winpr/winsock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define MAX_CURSOR 384
#define MAX_DIM 4096
#define MAX_CLIP (1024 * 1024)
#define QUEUE_SIZE 1024
#define STOP_GRACE_MS 500
enum { PASTE_IDLE, PASTE_PENDING, PASTE_SENT, PASTE_REJECTED, PASTE_TIMEOUT, PASTE_CANCELLED };
typedef struct { int type, a, b, c; } input_event;
typedef struct { rdpContext base; lrdp_session* owner; } lrdp_context;
struct lrdp_session {
  freerdp* instance;
  HANDLE thread, stop, wake;
  CRITICAL_SECTION lock;
  int state, features, end_reason;
  BOOL audio_requested;
  lrdp_audio_gate* audio;
  UINT32 error_code;
  lrdp_video* video;
  BYTE* cursor_pixels;
  size_t cursor_bytes;
  int32_t cursor_info[9];
  uint64_t cursor_generation;
  char error[512], fingerprint[256], accepted_fingerprint[256];
  char* clipboard_in;
  char* clipboard_out;
  char* clipboard_pending;
  BOOL clipboard_waiting, clipboard_pending_paste, clipboard_out_paste;
  BOOL paste_ready, paste_keys_sent, paste_data_served;
  int paste_status;
  UINT64 clipboard_announced_at, paste_deadline;
  UINT64 paste_serial, clipboard_out_paste_serial;
  UINT64 stop_deadline;
  pTransportConnectLayer connect_layer;
  pcRdpgfxSurfaceCommand gfx_surface_command;
  input_event queue[QUEUE_SIZE];
  unsigned head, tail;
  /* Only the network owner reads/writes delivered input state. */
  BYTE held_scans[1024 / 8], held_unicode[65536 / 8];
  unsigned held_keys;
  UINT16 held_buttons, mouse_x, mouse_y;
  CliprdrClientContext* clip;
  DispClientContext* disp;
  BOOL display_ready;
  BOOL drive_configured;
};
static lrdp_session* owner(rdpContext* c) { return ((lrdp_context*)c)->owner; }
lrdp_audio_gate* lrdp_audio_for_context(rdpContext* c) { return owner(c)->audio; }
typedef struct { lrdp_session* session; rdpTransportLayer* inner; } cancel_layer;
static BOOL transport_cancelled(cancel_layer* layer) {
  lrdp_session* s = layer->session;
  if (WaitForSingleObject(s->stop, 0) != WAIT_OBJECT_0) return FALSE;
  EnterCriticalSection(&s->lock);
  BOOL expired = GetTickCount64() >= s->stop_deadline;
  LeaveCriticalSection(&s->lock);
  if (expired) errno = ECANCELED;
  return expired;
}
static int cancel_read(void* context, void* data, int bytes) {
  cancel_layer* layer = context;
  return transport_cancelled(layer) ? -1 : layer->inner->Read(layer->inner->userContext, data, bytes);
}
static int cancel_write(void* context, const void* data, int bytes) {
  cancel_layer* layer = context;
  return transport_cancelled(layer) ? -1 : layer->inner->Write(layer->inner->userContext, data, bytes);
}
static BOOL cancel_wait(void* context, BOOL write, DWORD timeout) {
  cancel_layer* layer = context;
  if (transport_cancelled(layer)) return FALSE;
  /* Upstream uses nonblocking sockets. Keep each wait bounded so both read
   * and output-buffer flush loops recheck cancellation on their owner. */
  BOOL ready = layer->inner->Wait(layer->inner->userContext, write,
    timeout && timeout < 100 ? timeout : 100);
  return !transport_cancelled(layer) && ready;
}
static HANDLE cancel_event(void* context) {
  cancel_layer* layer = context;
  return layer->inner->GetEvent(layer->inner->userContext);
}
static BOOL cancel_close(void* context) {
  cancel_layer* layer = context;
  transport_layer_free(layer->inner);
  return TRUE;
}
static rdpTransportLayer* connect_cancel_layer(rdpTransport* transport,
    const char* hostname, int port, DWORD timeout) {
  lrdp_session* s = owner(transport_get_context(transport));
  rdpTransportLayer* inner = s->connect_layer(transport, hostname, port, timeout);
  if (!inner) return NULL;
  rdpTransportLayer* wrapped = transport_layer_new(transport, sizeof(cancel_layer));
  if (!wrapped) { transport_layer_free(inner); return NULL; }
  cancel_layer* layer = wrapped->userContext;
  layer->session = s; layer->inner = inner;
  wrapped->Read = cancel_read; wrapped->Write = cancel_write;
  wrapped->Wait = cancel_wait; wrapped->GetEvent = cancel_event;
  wrapped->Close = cancel_close;
  return wrapped;
}
static void state_set(lrdp_session* s, int state) {
  EnterCriticalSection(&s->lock); s->state = state; LeaveCriticalSection(&s->lock);
}
static void failure(lrdp_session* s, const char* error) {
  EnterCriticalSection(&s->lock);
  if (!s->error[0]) snprintf(s->error, sizeof(s->error), "%s", error ? error : "Unknown RDP error");
  if (s->state != LRDP_CERTIFICATE_REQUIRED) {
    s->state = LRDP_FAILED;
    s->end_reason = LRDP_END_PROTOCOL;
  }
  LeaveCriticalSection(&s->lock);
}
typedef struct { rdpPointer base; BYTE* pixels; size_t bytes; } lrdp_pointer;
static BOOL pointer_new(rdpContext* c, rdpPointer* pointer) {
  if (!pointer || !c->gdi || !pointer->width || !pointer->height ||
      pointer->width > MAX_CURSOR || pointer->height > MAX_CURSOR ||
      pointer->xPos >= pointer->width || pointer->yPos >= pointer->height) {
    failure(owner(c), "Invalid remote cursor dimensions or hotspot"); return FALSE;
  }
  lrdp_pointer* p = (lrdp_pointer*)pointer;
  size_t plane = (size_t)pointer->width * pointer->height * 4;
  p->bytes = plane * 2;
  p->pixels = calloc(1, p->bytes);
  if (!p->pixels) { failure(owner(c), "Unable to allocate remote cursor"); return FALSE; }
  if (!freerdp_image_copy_from_pointer_data(p->pixels, PIXEL_FORMAT_BGRA32, 0, 0, 0,
      pointer->width, pointer->height, pointer->xorMaskData, pointer->lengthXorMask,
      pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp, &c->gdi->palette)) {
    failure(owner(c), "Invalid remote cursor masks"); return FALSE;
  }
  /* Preserve XOR inversion as a separate white mask. A checkerboard substitute
   * cannot represent the actual desktop background underneath an I-beam. */
  UINT32 and_step = ((pointer->width + 7) / 8 + 1) & ~1U;
  UINT32 xor_step = ((pointer->width * pointer->xorBpp + 7) / 8 + 1) & ~1U;
  for (UINT32 y = 0; y < pointer->height; y++) {
    UINT32 src_y = pointer->xorBpp == 1 ? y : pointer->height - 1 - y;
    for (UINT32 x = 0; x < pointer->width; x++) {
      BYTE* pixel = p->pixels + ((size_t)y * pointer->width + x) * 4;
      BOOL inverted = FALSE;
      if (pointer->andMaskData && (size_t)and_step * pointer->height <= pointer->lengthAndMask &&
          (pointer->andMaskData[(size_t)src_y * and_step + x / 8] & (0x80U >> (x % 8)))) {
        const BYTE* bits = pointer->xorMaskData + (size_t)src_y * xor_step;
        if (pointer->xorBpp == 1) inverted = (bits[x / 8] & (0x80U >> (x % 8))) != 0;
        else {
          UINT32 format = pointer->xorBpp == 32 ? PIXEL_FORMAT_BGRA32 :
            pointer->xorBpp == 24 ? PIXEL_FORMAT_BGR24 :
            pointer->xorBpp == 16 ? PIXEL_FORMAT_RGB15 : c->gdi->palette.format;
          UINT32 color = pointer->xorBpp == 8 ? c->gdi->palette.palette[bits[x]] :
            FreeRDPReadColor(bits + (size_t)x * ((pointer->xorBpp + 7) / 8), format);
          inverted = FreeRDPConvertColor(color, format, PIXEL_FORMAT_ARGB32, &c->gdi->palette) == 0xFFFFFFFFU;
        }
      }
      if (inverted) { memset(pixel, 0, 4); memset(pixel + plane, 255, 4); }
      else for (int channel = 0; channel < 3; channel++)
        pixel[channel] = (BYTE)(((UINT32)pixel[channel] * pixel[3] + 127) / 255);
    }
  }
  return TRUE;
}
static void pointer_free(rdpContext* c, rdpPointer* pointer) {
  (void)c; free(((lrdp_pointer*)pointer)->pixels);
}
static BOOL pointer_set(rdpContext* c, rdpPointer* pointer) {
  lrdp_session* s = owner(c); lrdp_pointer* p = (lrdp_pointer*)pointer;
  EnterCriticalSection(&s->lock);
  BYTE* pixels = realloc(s->cursor_pixels, p->bytes);
  if (!pixels) { LeaveCriticalSection(&s->lock); failure(s, "Unable to copy remote cursor"); return FALSE; }
  s->cursor_pixels = pixels; s->cursor_bytes = p->bytes;
  memcpy(pixels, p->pixels, p->bytes);
  s->cursor_info[0] = LRDP_CURSOR_BITMAP;
  s->cursor_info[1] = (int32_t)pointer->width; s->cursor_info[2] = (int32_t)pointer->height;
  s->cursor_info[3] = (int32_t)pointer->xPos; s->cursor_info[4] = (int32_t)pointer->yPos;
  s->cursor_info[8] = (int32_t)((UINT32)s->cursor_info[8] + 1);
  s->cursor_generation++;
  LeaveCriticalSection(&s->lock); return TRUE;
}
static BOOL pointer_system(rdpContext* c, int kind) {
  lrdp_session* s = owner(c);
  EnterCriticalSection(&s->lock);
  s->cursor_info[0] = kind;
  for (int i = 1; i <= 4; i++) s->cursor_info[i] = 0;
  s->cursor_info[8] = (int32_t)((UINT32)s->cursor_info[8] + 1);
  s->cursor_generation++;
  LeaveCriticalSection(&s->lock); return TRUE;
}
static BOOL pointer_null(rdpContext* c) { return pointer_system(c, LRDP_CURSOR_HIDDEN); }
static BOOL pointer_default(rdpContext* c) { return pointer_system(c, LRDP_CURSOR_DEFAULT); }
static BOOL pointer_position(rdpContext* c, UINT32 x, UINT32 y) {
  lrdp_session* s = owner(c);
  if (x >= MAX_DIM || y >= MAX_DIM) return TRUE;
  EnterCriticalSection(&s->lock);
  s->cursor_info[5] = (int32_t)x; s->cursor_info[6] = (int32_t)y;
  s->cursor_info[7] = (int32_t)((UINT32)s->cursor_info[7] + 1);
  s->cursor_generation++;
  LeaveCriticalSection(&s->lock); return TRUE;
}
static BOOL begin_paint(rdpContext* c) {
  c->gdi->primary->hdc->hwnd->invalid->null = TRUE;
  return TRUE;
}
static BOOL end_paint(rdpContext* c) {
  lrdp_session* s = owner(c);
  rdpGdi* g = c->gdi;
  if (g->primary->hdc->hwnd->invalid->null) return TRUE;
  if (g->width < 1 || g->height < 1 || g->width > MAX_DIM || g->height > MAX_DIM) return FALSE;
  return lrdp_video_store_publish(s->video, g->primary_buffer, g->width, g->height, g->stride);
}
static BOOL desktop_resize(rdpContext* c) {
  UINT32 w = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopWidth);
  UINT32 h = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopHeight);
  if (w > MAX_DIM || h > MAX_DIM || w < 1 || h < 1) return FALSE;
  return gdi_resize(c->gdi, w, h);
}
static DWORD verify_certificate(freerdp* f, const char* host, UINT16 port,
    const char* cn, const char* subject, const char* issuer, const char* pem, DWORD flags) {
  (void)host; (void)port; (void)cn; (void)subject; (void)issuer;
  lrdp_session* s = owner(f->context);
  if (!(flags & VERIFY_CERT_FLAG_FP_IS_PEM)) return 0;
  rdpCertificate* cert = freerdp_certificate_new_from_pem(pem);
  if (!cert) return 0;
  char* fingerprint = freerdp_certificate_get_fingerprint_by_hash(cert, "sha256");
  freerdp_certificate_free(cert);
  if (!fingerprint) return 0;
  EnterCriticalSection(&s->lock);
  snprintf(s->fingerprint, sizeof(s->fingerprint), "%s", fingerprint);
  BOOL accepted = s->accepted_fingerprint[0] &&
    strcmp(s->accepted_fingerprint, fingerprint) == 0;
  if (!accepted) {
    s->state = LRDP_CERTIFICATE_REQUIRED;
    s->end_reason = LRDP_END_CERTIFICATE;
    snprintf(s->error, sizeof(s->error), "Certificate verification requires approval (SHA-256)");
  }
  LeaveCriticalSection(&s->lock);
  free(fingerprint);
  return accepted ? 2 : 0;
}
static DWORD verify_changed(freerdp* f, const char* host, UINT16 port,
    const char* cn, const char* subject, const char* issuer, const char* fp,
    const char* old_subject, const char* old_issuer, const char* old_fp, DWORD flags) {
  (void)old_subject; (void)old_issuer; (void)old_fp;
  return verify_certificate(f, host, port, cn, subject, issuer, fp, flags);
}
static int verify_pinned(freerdp* f, const BYTE* data, size_t length,
    const char* host, UINT16 port, DWORD flags) {
  char* pem = malloc(length + 1);
  if (!pem) return 0;
  memcpy(pem, data, length); pem[length] = 0;
  int rc = (int)verify_certificate(f, host, port, "", "", "", pem,
                                  flags | VERIFY_CERT_FLAG_FP_IS_PEM);
  free(pem); return rc;
}
static UINT clip_announce(CliprdrClientContext* c) {
  CLIPRDR_FORMAT fmt = { CF_UNICODETEXT, NULL };
  CLIPRDR_FORMAT_LIST list = {0};
  lrdp_session* s = c->custom;
  EnterCriticalSection(&s->lock);
  BOOL has_text = s->clipboard_out != NULL;
  LeaveCriticalSection(&s->lock);
  list.numFormats = has_text ? 1 : 0; list.formats = has_text ? &fmt : NULL;
  return c->ClientFormatList(c, &list);
}
static UINT clip_ready(CliprdrClientContext* c, const CLIPRDR_MONITOR_READY* ready) {
  (void)ready;
  lrdp_session* s = c->custom;
  EnterCriticalSection(&s->lock); s->features |= 1; LeaveCriticalSection(&s->lock);
  CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
  general.version = CB_CAPS_VERSION_2; general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  CLIPRDR_CAPABILITIES caps = {0};
  caps.cCapabilitiesSets = 1; caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
  /* Clipboard ownership is announced when the user supplies local text. */
  return c->ClientCapabilities(c, &caps);
}
static UINT clip_capabilities(CliprdrClientContext* c, const CLIPRDR_CAPABILITIES* caps) {
  (void)c; (void)caps; return CHANNEL_RC_OK;
}
static UINT clip_list_response(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST_RESPONSE* r) {
  lrdp_session* s = c->custom;
  EnterCriticalSection(&s->lock);
  if (s->clipboard_waiting) {
    s->clipboard_waiting = FALSE;
    if (s->clipboard_out_paste && s->clipboard_out_paste_serial == s->paste_serial &&
        s->paste_status == PASTE_PENDING) {
      if (r->common.msgFlags & CB_RESPONSE_OK) s->paste_ready = TRUE;
      else s->paste_status = PASTE_REJECTED;
    }
  }
  LeaveCriticalSection(&s->lock);
  SetEvent(s->wake);
  return CHANNEL_RC_OK;
}
static UINT clip_list(CliprdrClientContext* c, const CLIPRDR_FORMAT_LIST* list) {
  CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
  response.common.msgFlags = CB_RESPONSE_OK;
  UINT rc = c->ClientFormatListResponse(c, &response);
  if (rc) return rc;
  for (UINT32 i = 0; i < list->numFormats; i++) {
    if (list->formats[i].formatId == CF_UNICODETEXT) {
      CLIPRDR_FORMAT_DATA_REQUEST request = {0}; request.requestedFormatId = CF_UNICODETEXT;
      return c->ClientFormatDataRequest(c, &request);
    }
  }
  return CHANNEL_RC_OK;
}
static UINT clip_request(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_REQUEST* req) {
  lrdp_session* s = c->custom;
  CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
  WCHAR* wide = NULL;
  EnterCriticalSection(&s->lock);
  if (req->requestedFormatId == CF_UNICODETEXT && s->clipboard_out) {
    size_t count = 0;
    wide = ConvertUtf8ToWCharAlloc(s->clipboard_out, &count);
    if (wide) {
      response.common.msgFlags = CB_RESPONSE_OK;
      response.common.dataLen = ((UINT32)count + 1) * 2;
      response.requestedFormatData = (BYTE*)wide;
    }
  }
  LeaveCriticalSection(&s->lock);
  if (!wide) response.common.msgFlags = CB_RESPONSE_FAIL;
  UINT rc = c->ClientFormatDataResponse(c, &response);
  EnterCriticalSection(&s->lock);
  if (s->clipboard_out_paste && s->clipboard_out_paste_serial == s->paste_serial &&
      s->paste_status == PASTE_PENDING) {
    if (rc == CHANNEL_RC_OK && wide) {
      s->paste_data_served = TRUE;
      if (s->paste_keys_sent) s->paste_status = PASTE_SENT;
    } else s->paste_status = PASTE_REJECTED;
  }
  LeaveCriticalSection(&s->lock);
  free(wide); return rc;
}
static UINT clip_response(CliprdrClientContext* c, const CLIPRDR_FORMAT_DATA_RESPONSE* r) {
  if (!(r->common.msgFlags & CB_RESPONSE_OK) || r->common.dataLen > MAX_CLIP ||
      (r->common.dataLen & 1) || !r->requestedFormatData) return CHANNEL_RC_OK;
  size_t units = r->common.dataLen / 2;
  const WCHAR* wide = (const WCHAR*)r->requestedFormatData;
  size_t length = 0;
  while (length < units && wide[length]) length++;
  char* text = NULL;
  if (length == 0) text = _strdup("");
  else text = ConvertWCharNToUtf8Alloc(wide, length, NULL);
  if (text && strlen(text) > MAX_CLIP) { free(text); return CHANNEL_RC_OK; }
  if (text) {
    lrdp_session* s = c->custom;
    EnterCriticalSection(&s->lock);
    free(s->clipboard_in); s->clipboard_in = text;
    LeaveCriticalSection(&s->lock);
  }
  return CHANNEL_RC_OK;
}
static UINT display_caps(DispClientContext* d, UINT32 n, UINT32 a, UINT32 b) {
  (void)n; (void)a; (void)b;
  lrdp_session* s = d->custom;
  EnterCriticalSection(&s->lock);
  s->display_ready = TRUE; s->features |= 2;
  LeaveCriticalSection(&s->lock);
  return CHANNEL_RC_OK;
}
static UINT gfx_surface_command(RdpgfxClientContext* gfx, const RDPGFX_SURFACE_COMMAND* command) {
  rdpGdi* gdi = gfx ? gfx->custom : NULL;
  if (!gdi || !command) return ERROR_INVALID_PARAMETER;
  lrdp_session* s = owner(gdi->context);
  EnterCriticalSection(&s->lock);
  pcRdpgfxSurfaceCommand decode = s->gfx_surface_command;
  LeaveCriticalSection(&s->lock);
  UINT status = decode ? decode(gfx, command) : ERROR_INTERNAL_ERROR;
  if (status != CHANNEL_RC_OK) {
    failure(s, "Unable to decode remote graphics");
    return status;
  }
  if (command->codecId == RDPGFX_CODECID_AVC420 || command->codecId == RDPGFX_CODECID_AVC444 ||
      command->codecId == RDPGFX_CODECID_AVC444v2) {
    EnterCriticalSection(&s->lock); s->features |= 4; LeaveCriticalSection(&s->lock);
  }
  return status;
}
static void channel_connected(void* context, const ChannelConnectedEventArgs* e) {
  rdpContext* c = context; lrdp_session* s = owner(c);
  if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    CliprdrClientContext* clip = e->pInterface;
    clip->custom = s; clip->MonitorReady = clip_ready;
    clip->ServerCapabilities = clip_capabilities;
    clip->ServerFormatList = clip_list;
    clip->ServerFormatListResponse = clip_list_response;
    clip->ServerFormatDataRequest = clip_request;
    clip->ServerFormatDataResponse = clip_response;
    EnterCriticalSection(&s->lock); s->clip = clip; LeaveCriticalSection(&s->lock);
  } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    DispClientContext* disp = e->pInterface; disp->custom = s;
    disp->DisplayControlCaps = display_caps;
    EnterCriticalSection(&s->lock); s->disp = disp; LeaveCriticalSection(&s->lock);
  } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0 && c->gdi) {
    RdpgfxClientContext* gfx = e->pInterface;
    if (!gdi_graphics_pipeline_init(c->gdi, gfx))
      failure(s, "Unable to initialize graphics pipeline");
    else {
      EnterCriticalSection(&s->lock); s->gfx_surface_command = gfx->SurfaceCommand; LeaveCriticalSection(&s->lock);
      gfx->SurfaceCommand = gfx_surface_command;
    }
  }
}
static void channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e) {
  rdpContext* c = context; lrdp_session* s = owner(c);
  if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    EnterCriticalSection(&s->lock);
    s->clip = NULL; s->features &= ~1;
    LeaveCriticalSection(&s->lock);
  }
  else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    EnterCriticalSection(&s->lock);
    s->disp = NULL; s->display_ready = FALSE; s->features &= ~2;
    LeaveCriticalSection(&s->lock);
  } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0 && c->gdi)
    gdi_graphics_pipeline_uninit(c->gdi, e->pInterface);
}
static BOOL pre_connect(freerdp* f) {
  if (PubSub_SubscribeChannelConnected(f->context->pubSub, channel_connected) < 0 ||
      PubSub_SubscribeChannelDisconnected(f->context->pubSub, channel_disconnected) < 0)
    return FALSE;
  return TRUE;
}
static BOOL load_channels(freerdp* f) {
  lrdp_session* s = owner(f->context);
  if (s->audio_requested) {
    /* The LRDP device wraps the platform backend through the public interface.
     * Register before the RDP8 dependency inserts its silent sys:fake device. */
    const char* args[] = { "rdpsnd", "latency:250", "sys:lrdp" };
    if (!freerdp_client_add_static_channel(f->context->settings, 3, args)) return FALSE;
    if (!freerdp_client_add_dynamic_channel(f->context->settings, 3, args)) return FALSE;
  }
  if (!freerdp_client_load_addins(f->context->channels, f->context->settings)) return FALSE;
  /* Loading the RDP8 null dependency can turn playback on. Restore the
   * user's choice; microphone redirection remains disabled. */
  return freerdp_settings_set_bool(f->context->settings, FreeRDP_AudioPlayback, s->audio_requested);
}
static BOOL post_connect(freerdp* f) {
  const UINT32 width = freerdp_settings_get_uint32(f->context->settings, FreeRDP_DesktopWidth);
  const UINT32 height = freerdp_settings_get_uint32(f->context->settings, FreeRDP_DesktopHeight);
  if (!width || !height || width > MAX_DIM || height > MAX_DIM) {
    failure(owner(f->context), "Server desktop exceeds the 4096 x 4096 limit");
    return FALSE;
  }
  /* Read negotiated input capabilities on the connection thread only. */
  lrdp_session* s = owner(f->context);
  const BOOL unicode = freerdp_settings_get_bool(f->context->settings, FreeRDP_UnicodeInput);
  EnterCriticalSection(&s->lock);
  s->features = (s->features & ~8) | (unicode ? 8 : 0);
  LeaveCriticalSection(&s->lock);
  if (!gdi_init(f, PIXEL_FORMAT_BGRA32)) return FALSE;
  f->context->update->BeginPaint = begin_paint;
  f->context->update->EndPaint = end_paint;
  f->context->update->DesktopResize = desktop_resize;
  rdpPointer pointer = {0};
  pointer.size = sizeof(lrdp_pointer); pointer.New = pointer_new; pointer.Free = pointer_free;
  pointer.Set = pointer_set; pointer.SetNull = pointer_null; pointer.SetDefault = pointer_default;
  pointer.SetPosition = pointer_position;
  graphics_register_pointer(f->context->graphics, &pointer);
  /* A connected GDI buffer is not yet a server frame. Wait for real paint
   * damage instead of publishing its initial contents as a white desktop. */
  f->context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
  return TRUE;
}
static void post_disconnect(freerdp* f) { if (f->context->gdi) gdi_free(f); }
static BOOL held_key(const BYTE* bits, unsigned code) { return (bits[code / 8] & (1u << (code % 8))) != 0; }
static void remember_key(lrdp_session* s, BYTE* bits, unsigned code, BOOL down) {
  if (held_key(bits, code) == down) return;
  if (down) { bits[code / 8] |= (BYTE)(1u << (code % 8)); s->held_keys++; }
  else { bits[code / 8] &= (BYTE)~(1u << (code % 8)); s->held_keys--; }
}
static BOOL send_key(lrdp_session* s, UINT16 flags, UINT16 code, BOOL unicode) {
  rdpInput* input = s->instance->context->input;
  BOOL ok = unicode ? freerdp_input_send_unicode_keyboard_event(input, flags, code) :
    freerdp_input_send_keyboard_event(input, flags, (UINT8)code);
  if (ok) remember_key(s, unicode ? s->held_unicode : s->held_scans,
    unicode ? code : ((flags & (KBD_FLAGS_EXTENDED | KBD_FLAGS_EXTENDED1)) | (UINT8)code),
    !(flags & KBD_FLAGS_RELEASE));
  return ok;
}
static BOOL modifier_scan(unsigned code) {
  return code == 0x1d || code == 0x2a || code == 0x36 || code == 0x38 ||
    code == 0x11d || code == 0x138 || code == 0x15b || code == 0x15c;
}
static BOOL send_mouse(lrdp_session* s, UINT16 flags, UINT16 x, UINT16 y) {
  rdpInput* input = s->instance->context->input;
  const BOOL wheel = (flags & (PTR_FLAGS_WHEEL | PTR_FLAGS_HWHEEL)) != 0;
  UINT16 buttons = wheel ? 0 : flags & (PTR_FLAGS_BUTTON1 | PTR_FLAGS_BUTTON2 | PTR_FLAGS_BUTTON3);
  if (buttons) {
    /* Some peers (notably KRDP) classify DOWN, then MOVE, then RELEASE.
     * MOVE|BUTTON without DOWN is therefore not a release to them. Position
     * first, then send each button separately, including orderly shutdown.
     * Record only successfully delivered transitions if a later send fails. */
    if (!freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y)) return FALSE;
    s->mouse_x = x; s->mouse_y = y;
    for (UINT16 button = PTR_FLAGS_BUTTON1; button <= PTR_FLAGS_BUTTON3; button <<= 1) {
      if (!(buttons & button)) continue;
      if (!freerdp_input_send_mouse_event(input, button | (flags & PTR_FLAGS_DOWN), x, y)) return FALSE;
      if (flags & PTR_FLAGS_DOWN) s->held_buttons |= button;
      else s->held_buttons &= (UINT16)~button;
    }
    return TRUE;
  }
  if (!freerdp_input_send_mouse_event(input, flags, x, y)) return FALSE;
  if (!wheel) { s->mouse_x = x; s->mouse_y = y; }
  return TRUE;
}
static void release_delivered_input(lrdp_session* s) {
  /* Discard unsent input. Release only states that this connection delivered;
   * mouse releases precede modifiers to preserve the final drag operation. */
  for (UINT16 button = PTR_FLAGS_BUTTON1; button <= PTR_FLAGS_BUTTON3; button <<= 1)
    if ((s->held_buttons & button) && !send_mouse(s, button, s->mouse_x, s->mouse_y)) return;
  for (unsigned code = 0; code < 65536 && s->held_keys; code++)
    if (held_key(s->held_unicode, code) && !send_key(s, KBD_FLAGS_RELEASE, (UINT16)code, TRUE)) return;
  for (int modifiers = 0; modifiers < 2; modifiers++)
    for (unsigned code = 0; code < 1024 && s->held_keys; code++)
      if (held_key(s->held_scans, code) && modifier_scan(code) == modifiers &&
          !send_key(s, KBD_FLAGS_RELEASE | (code & 0x300), (UINT8)code, FALSE)) return;
  s->held_buttons = 0;
}
static BOOL process_clipboard(lrdp_session* s) {
  EnterCriticalSection(&s->lock);
  if (s->paste_status == PASTE_PENDING && GetTickCount64() >= s->paste_deadline) {
    s->paste_status = PASTE_TIMEOUT;
    if (s->clipboard_pending_paste) {
      free(s->clipboard_pending); s->clipboard_pending = NULL;
      s->clipboard_pending_paste = FALSE;
    }
  }
  CliprdrClientContext* clip = NULL;
  /* Format responses have no operation ID. Keep at most one announcement in
   * flight so a late ACK cannot paste
   * text from a different operation. Never reset this barrier on a timeout. */
  if (!s->clipboard_waiting && s->clipboard_pending && (s->features & 1) && s->clip) {
    free(s->clipboard_out); s->clipboard_out = s->clipboard_pending;
    s->clipboard_pending = NULL;
    s->clipboard_out_paste = s->clipboard_pending_paste;
    s->clipboard_out_paste_serial = s->clipboard_pending_paste ? s->paste_serial : 0;
    s->clipboard_pending_paste = FALSE;
    s->clipboard_waiting = TRUE;
    s->clipboard_announced_at = GetTickCount64();
    clip = s->clip;
  }
  BOOL paste = s->paste_status == PASTE_PENDING && s->paste_ready && !s->paste_keys_sent;
  LeaveCriticalSection(&s->lock);
  if (clip && clip_announce(clip) != CHANNEL_RC_OK) return FALSE;
  if (paste) {
    BOOL ok = send_key(s, 0, 0x1d, FALSE);
    /* Always attempt releases, even if a transport failure interrupted down. */
    ok = send_key(s, 0, 0x2f, FALSE) && ok;
    ok = send_key(s, 0x8000, 0x2f, FALSE) && ok;
    ok = send_key(s, 0x8000, 0x1d, FALSE) && ok;
    EnterCriticalSection(&s->lock);
    s->paste_keys_sent = TRUE;
    if (!ok) s->paste_status = PASTE_REJECTED;
    else if (s->paste_status == PASTE_PENDING && s->paste_data_served)
      s->paste_status = PASTE_SENT;
    LeaveCriticalSection(&s->lock);
    if (!ok) return FALSE;
  }
  return TRUE;
}
static BOOL process_input(lrdp_session* s) {
  /* This mailbox is independent of the bounded keyboard/mouse queue. */
  lrdp_audio_gate_apply(s->audio);
  while (WaitForSingleObject(s->stop, 0) != WAIT_OBJECT_0) {
    EnterCriticalSection(&s->lock);
    if (s->head == s->tail) { LeaveCriticalSection(&s->lock); break; }
    input_event e = s->queue[s->tail]; s->tail = (s->tail + 1) % QUEUE_SIZE;
    LeaveCriticalSection(&s->lock);
    rdpInput* in = s->instance->context->input;
    BOOL ok = TRUE;
    switch (e.type) {
      case 0: ok = send_mouse(s, (UINT16)e.a, (UINT16)e.b, (UINT16)e.c); break;
      case 1: ok = send_key(s, (UINT16)e.a, (UINT8)e.b, FALSE); break;
      case 2: ok = send_key(s, (UINT16)e.a, (UINT16)e.b, TRUE); break;
      case 3:
      {
        EnterCriticalSection(&s->lock);
        DispClientContext* disp = s->display_ready ? s->disp : NULL;
        LeaveCriticalSection(&s->lock);
        if (disp) {
          DISPLAY_CONTROL_MONITOR_LAYOUT m = {0};
          m.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY; m.Width = (UINT32)e.a & ~1u;
          m.Height = e.b; m.PhysicalWidth = 300; m.PhysicalHeight = 200;
          m.DesktopScaleFactor = 100; m.DeviceScaleFactor = 100;
          ok = disp->SendMonitorLayout(disp, 1, &m) == CHANNEL_RC_OK;
        }
        break;
      }
      case 4: ok = freerdp_input_send_synchronize_event(in, (UINT32)e.a); break;
      default: break;
    }
    if (!ok) return FALSE;
  }
  return WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0 || process_clipboard(s);
}
/* Called on the network owner before disconnect resets upstream error state. */
static void connection_ended(lrdp_session* s, BOOL connected, BOOL io_failed) {
  rdpContext* c = s->instance->context;
  UINT32 code = freerdp_get_last_error(c);
  UINT32 info = freerdp_error_info(s->instance);
  int reason = LRDP_END_PROTOCOL;
  BOOL local = WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0;
  if (local) reason = LRDP_END_LOCAL;
  else if (info != ERRINFO_SUCCESS && info != ERRINFO_NONE) reason = LRDP_END_REMOTE;
  else if (code == FREERDP_ERROR_CONNECT_TRANSPORT_FAILED ||
           code == FREERDP_ERROR_CONNECT_FAILED ||
           code == FREERDP_ERROR_DNS_ERROR || code == FREERDP_ERROR_DNS_NAME_NOT_FOUND ||
           (connected && io_failed && (code == FREERDP_ERROR_SUCCESS || code == FREERDP_ERROR_NONE)))
    reason = LRDP_END_TRANSPORT;
  else if (GET_FREERDP_ERROR_CLASS(code) == FREERDP_ERROR_CONNECT_CLASS) {
    UINT32 type = GET_FREERDP_ERROR_TYPE(code);
    if (type == ERRCONNECT_AUTHENTICATION_FAILED || type == ERRCONNECT_INSUFFICIENT_PRIVILEGES ||
        (type >= ERRCONNECT_PASSWORD_EXPIRED && type <= ERRCONNECT_NO_OR_MISSING_CREDENTIALS))
      reason = LRDP_END_AUTHENTICATION;
  }
  if (connected && !io_failed && reason == LRDP_END_PROTOCOL) reason = LRDP_END_REMOTE;
  EnterCriticalSection(&s->lock);
  if (s->paste_status == PASTE_PENDING) s->paste_status = PASTE_CANCELLED;
  if (s->state != LRDP_CERTIFICATE_REQUIRED) {
    /* A callback failure (graphics/input) takes priority over transport fallout. */
    if (s->state == LRDP_FAILED && !local) reason = s->end_reason;
    s->end_reason = reason;
    s->error_code = code;
    s->state = (reason == LRDP_END_LOCAL || reason == LRDP_END_REMOTE) ? LRDP_CLOSED : LRDP_FAILED;
    if (!local && !s->error[0]) snprintf(s->error, sizeof(s->error), "%s",
      reason == LRDP_END_REMOTE ? "Remote session ended" : freerdp_get_last_error_string(code));
  }
  LeaveCriticalSection(&s->lock);
}
static DWORD WINAPI run(LPVOID arg) {
  lrdp_session* s = arg; rdpContext* c = s->instance->context;
#if defined(_WIN32)
  WSADATA sockets;
  if (WSAStartup(MAKEWORD(2, 2), &sockets) != 0) {
    failure(s, "Unable to initialize Windows networking");
    freerdp_settings_set_string(c->settings, FreeRDP_Password, NULL);
    return 0;
  }
#endif
  BOOL connected = freerdp_connect(s->instance);
  BOOL io_failed = FALSE;
  if (connected) {
    state_set(s, LRDP_CONNECTED);
    while (WaitForSingleObject(s->stop, 0) != WAIT_OBJECT_0 && !freerdp_shall_disconnect_context(c)) {
      HANDLE handles[64] = {s->stop, s->wake};
      DWORD n = freerdp_get_event_handles(c, handles + 2, 62);
      if (!n) { io_failed = TRUE; break; }
      DWORD result = WaitForMultipleObjects(n + 2, handles, FALSE, 50);
      if (result == WAIT_FAILED) { io_failed = TRUE; break; }
      if (WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0) break;
      ResetEvent(s->wake);
      if (!process_input(s) || !freerdp_check_event_handles(c)) { io_failed = TRUE; break; }
    }
  }
  if (connected && WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0) {
    if (!io_failed) release_delivered_input(s);
    lrdp_audio_gate_apply(s->audio);
    freerdp_abort_connect_context(c);
  }
  connection_ended(s, connected, io_failed);
  freerdp_disconnect(s->instance);
  /* Clear the authentication secret as soon as the connection ends. */
  freerdp_settings_set_string(c->settings, FreeRDP_Password, NULL);
#if defined(_WIN32)
  WSACleanup();
#endif
  return 0;
}
int lrdp_abi_version(void) { return 5; }
const char* lrdp_version(void) { return FREERDP_VERSION_FULL; }
#if defined(__ANDROID__)
static INIT_ONCE directory_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK initialize_directory(PINIT_ONCE once, PVOID parameter, PVOID* context) {
  (void)once; (void)context;
  /* Android does not provide a Unix home. Match upstream's Android bootstrap
   * using the app's real private directory, without replacing an existing one. */
  if (getenv("HOME")) return TRUE;
  return SetEnvironmentVariableA("HOME", (const char*)parameter);
}
#endif
int lrdp_initialize(const char* private_directory) {
  if (!private_directory || !private_directory[0]) return 0;
#if defined(__ANDROID__)
  return InitOnceExecuteOnce(&directory_once, initialize_directory,
    (PVOID)private_directory, NULL);
#else
  return 1;
#endif
}
static INIT_ONCE addin_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK initialize_addins(PINIT_ONCE once, PVOID parameter, PVOID* context) {
  (void)once; (void)parameter; (void)context;
  if (!freerdp_setApplicationDetails("LRDP", "LRDP", 1)) return FALSE;
  return freerdp_register_addin_provider(lrdp_audio_addin, 0) == CHANNEL_RC_OK;
}
lrdp_session* lrdp_create(void) {
  if (!InitOnceExecuteOnce(&addin_once, initialize_addins, NULL, NULL)) return NULL;
  lrdp_session* s = calloc(1, sizeof(*s));
  if (!s) return NULL;
  InitializeCriticalSection(&s->lock);
  s->video = lrdp_video_store_new();
  s->audio = lrdp_audio_gate_new();
  s->cursor_info[5] = s->cursor_info[6] = -1;
  s->cursor_generation = 1;
  s->stop = CreateEvent(NULL, TRUE, FALSE, NULL);
  s->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
  s->instance = freerdp_new();
  if (!s->video || !s->audio || !s->stop || !s->wake || !s->instance) { lrdp_destroy(s); return NULL; }
  s->instance->ContextSize = sizeof(lrdp_context);
  if (!freerdp_context_new(s->instance)) { lrdp_destroy(s); return NULL; }
  ((lrdp_context*)s->instance->context)->owner = s;
  rdpTransportIo io = *freerdp_get_io_callbacks(s->instance->context);
  s->connect_layer = io.ConnectLayer;
  io.ConnectLayer = connect_cancel_layer;
  if (!s->connect_layer || !freerdp_set_io_callbacks(s->instance->context, &io)) {
    lrdp_destroy(s); return NULL;
  }
  s->instance->PreConnect = pre_connect;
  s->instance->LoadChannels = load_channels;
  s->instance->PostConnect = post_connect;
  s->instance->PostDisconnect = post_disconnect;
  s->instance->VerifyCertificateEx = verify_certificate;
  s->instance->VerifyChangedCertificateEx = verify_changed;
  s->instance->VerifyX509Certificate = NULL;
  rdpSettings* cfg = s->instance->context->settings;
  BOOL ok = freerdp_settings_set_bool(cfg, FreeRDP_CertificateCallbackPreferPEM, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SoftwareGdi, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_IgnoreCertificate, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_AutoReconnectionEnabled, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RedirectClipboard, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportDisplayControl, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, TRUE) &&
    /* Advertise only decoders compiled into the linked upstream library.
     * Some servers send no graphics at all unless AVC420 is advertised. */
#if defined(WITH_GFX_H264) && LRDP_ENABLE_H264
    freerdp_settings_set_bool(cfg, FreeRDP_GfxH264, TRUE) &&
#else
    freerdp_settings_set_bool(cfg, FreeRDP_GfxH264, FALSE) &&
#endif
    freerdp_settings_set_bool(cfg, FreeRDP_AudioPlayback, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_AudioCapture, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_DeviceRedirection, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_GrabMouse, TRUE) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_PointerCacheSize, 32) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_ColorPointerCacheSize, 32) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NetworkAutoDetect, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportHeartbeatPdu, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportMultitransport, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_CompressionEnabled, TRUE) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_ColorDepth, 32) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_DesktopWidth, 1280) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_DesktopHeight, 800) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_TcpConnectTimeout, 10000);
  if (!ok) { lrdp_destroy(s); return NULL; }
  return s;
}
int lrdp_set(lrdp_session* s, const char* key, const char* value) {
  if (!s || s->thread || !key || !value) return 0;
  rdpSettings* cfg = s->instance->context->settings;
  if (strcmp(key, "drive_path") == 0) {
    if (s->drive_configured) return 0;
    if (!value[0]) return 1;
    /* Win32's A file APIs use the system ANSI code page. Our ABI is UTF-8,
     * including Chinese directory names, so validate using the wide APIs. */
    WCHAR* wide = ConvertUtf8ToWCharAlloc(value, NULL);
    if (!wide) return 0;
    DWORD attributes = GetFileAttributesW(wide);
    BOOL relative = PathIsRelativeW(wide);
    free(wide);
    if (relative || attributes == INVALID_FILE_ATTRIBUTES ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY)) return 0;
    const char* args[] = { "LRDP", value };
    RDPDR_DEVICE* drive = freerdp_device_new(RDPDR_DTYP_FILESYSTEM, 2, args);
    if (!drive) return 0;
    if (!freerdp_device_collection_add(cfg, drive)) { freerdp_device_free(drive); return 0; }
    s->drive_configured = TRUE;
    return freerdp_settings_set_bool(cfg, FreeRDP_DeviceRedirection, TRUE);
  }
  if (strcmp(key, "fingerprint") == 0) {
    if (strlen(value) >= sizeof(s->accepted_fingerprint)) return 0;
    snprintf(s->accepted_fingerprint, sizeof(s->accepted_fingerprint), "%s", value);
    s->instance->VerifyX509Certificate = value[0] ? verify_pinned : NULL;
    return freerdp_settings_set_bool(cfg, FreeRDP_ExternalCertificateManagement, value[0] != 0);
  }
  struct { const char* name; FreeRDP_Settings_Keys_String id; } strings[] = {
    {"host", FreeRDP_ServerHostname}, {"username", FreeRDP_Username},
    {"domain", FreeRDP_Domain}, {"password", FreeRDP_Password}, {"config_path", FreeRDP_ConfigPath}};
  if (strcmp(key, "host") == 0 && (!value[0] || strlen(value) > 253)) return 0;
  for (size_t i = 0; i < sizeof(strings)/sizeof(strings[0]); i++)
    if (strcmp(key, strings[i].name) == 0) return freerdp_settings_set_string(cfg, strings[i].id, value);
  char* end = NULL; long n = strtol(value, &end, 10);
  if (!value[0] || *end) return 0;
  if (strcmp(key, "port") == 0 && n > 0 && n <= 65535)
    return freerdp_settings_set_uint32(cfg, FreeRDP_ServerPort, (UINT32)n);
  if ((strcmp(key, "width") == 0 || strcmp(key, "height") == 0) && n >= 200 && n <= MAX_DIM)
    return freerdp_settings_set_uint32(cfg, strcmp(key, "width") == 0 ? FreeRDP_DesktopWidth : FreeRDP_DesktopHeight, (UINT32)n);
  if (strcmp(key, "clipboard") == 0 && (n == 0 || n == 1))
    return freerdp_settings_set_bool(cfg, FreeRDP_RedirectClipboard, n != 0);
  if (strcmp(key, "audio") == 0 && (n == 0 || n == 1)) {
#if !LRDP_ENABLE_AUDIO
    if (n) return 0;
#endif
    s->audio_requested = n != 0;
    return freerdp_settings_set_bool(cfg, FreeRDP_AudioPlayback, s->audio_requested);
  }
  if (strcmp(key, "nla") == 0 && (n == 0 || n == 1))
    return freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, n != 0);
  return 0;
}
int lrdp_start(lrdp_session* s) {
  if (!s || s->thread || !freerdp_settings_get_string(s->instance->context->settings, FreeRDP_ServerHostname)) return 0;
  state_set(s, LRDP_CONNECTING); s->thread = CreateThread(NULL, 0, run, s, 0, NULL);
  if (!s->thread) { failure(s, "Unable to start network thread"); return 0; } return 1;
}
int lrdp_state(lrdp_session* s) {
  if (!s) return LRDP_FAILED;
  EnterCriticalSection(&s->lock); int state = s->state; LeaveCriticalSection(&s->lock); return state;
}
int lrdp_end_reason(lrdp_session* s) {
  if (!s) return LRDP_END_CONFIGURATION;
  EnterCriticalSection(&s->lock); int reason = s->end_reason; LeaveCriticalSection(&s->lock);
  return reason;
}
uint32_t lrdp_error_code(lrdp_session* s) {
  if (!s) return 0;
  EnterCriticalSection(&s->lock); UINT32 code = s->error_code; LeaveCriticalSection(&s->lock);
  return code;
}
int lrdp_features(lrdp_session* s) {
  if (!s) return 0;
  EnterCriticalSection(&s->lock); int features = s->features; LeaveCriticalSection(&s->lock);
  return features;
}
int lrdp_read(lrdp_session* s, int field, char* out, size_t capacity) {
  if (!s || !out || !capacity || field < 0 || field > 4) return -1;
  EnterCriticalSection(&s->lock);
  static const char* paste_states[] = { "idle", "pending", "sent", "rejected", "timeout", "cancelled" };
  const char* value = field == 0 ? s->error : field == 1 ? s->fingerprint :
    field == 2 ? s->clipboard_in : field == 3 ? paste_states[s->paste_status] :
    s->audio_requested ? lrdp_audio_gate_status(s->audio) : "off";
  size_t n = value ? strlen(value) : 0;
  if (field == 2 && !value) { LeaveCriticalSection(&s->lock); return -1; }
  if (n >= capacity) { LeaveCriticalSection(&s->lock); return -(int)(n + 1); }
  memcpy(out, value ? value : "", n + 1);
  if (field == 2) { free(s->clipboard_in); s->clipboard_in = NULL; }
  LeaveCriticalSection(&s->lock); return (int)n;
}
int lrdp_frame(lrdp_session* s, uint8_t* out, size_t cap, int32_t* w, int32_t* h, uint64_t* gen) {
  return s ? lrdp_video_store_copy(s->video, out, cap, w, h, gen) : 0;
}
uint64_t lrdp_video_ticket(lrdp_session* s) { return s ? lrdp_video_store_ticket(s->video) : 0; }
int lrdp_cursor(lrdp_session* s, uint8_t* out, size_t capacity, int32_t* info, uint64_t* generation) {
  if (!s || !info || !generation) return 0;
  EnterCriticalSection(&s->lock);
  if (*generation == s->cursor_generation) { LeaveCriticalSection(&s->lock); return 0; }
  size_t bytes = s->cursor_info[0] == LRDP_CURSOR_BITMAP ? s->cursor_bytes : 0;
  if (bytes && (!out || capacity < bytes)) { LeaveCriticalSection(&s->lock); return -(int)bytes; }
  if (bytes) memcpy(out, s->cursor_pixels, bytes);
  memcpy(info, s->cursor_info, sizeof(s->cursor_info)); *generation = s->cursor_generation;
  LeaveCriticalSection(&s->lock); return bytes ? (int)bytes : 1;
}
int lrdp_input(lrdp_session* s, int type, int a, int b, int c) {
  if (!s || type < 0 || type > 4 || lrdp_state(s) != LRDP_CONNECTED ||
      WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0) return 0;
  if (type == 0 && (b < 0 || b >= MAX_DIM || c < 0 || c >= MAX_DIM)) return 0;
  if (type == 3 && (a < 200 || b < 200 || a > MAX_DIM || b > MAX_DIM)) return 0;
  EnterCriticalSection(&s->lock);
  if (WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0) { LeaveCriticalSection(&s->lock); return 0; }
  unsigned next = (s->head + 1) % QUEUE_SIZE;
  if (next == s->tail) { LeaveCriticalSection(&s->lock); return 0; }
  s->queue[s->head] = (input_event){type, a, b, c}; s->head = next;
  LeaveCriticalSection(&s->lock); SetEvent(s->wake); return 1;
}
int lrdp_clipboard(lrdp_session* s, const char* text) {
  if (!s || !text || strlen(text) > MAX_CLIP) return 0;
  char* copy = _strdup(text); if (!copy) return 0;
  EnterCriticalSection(&s->lock);
  if (s->paste_status == PASTE_PENDING) { LeaveCriticalSection(&s->lock); free(copy); return 0; }
  free(s->clipboard_pending); s->clipboard_pending = copy;
  s->clipboard_pending_paste = FALSE;
  LeaveCriticalSection(&s->lock); SetEvent(s->wake); return 1;
}
int lrdp_paste(lrdp_session* s, const char* text) {
  if (!s || !text || !text[0] || strlen(text) > MAX_CLIP) return 0;
  char* copy = _strdup(text); if (!copy) return 0;
  EnterCriticalSection(&s->lock);
  if (s->state != LRDP_CONNECTED || !(s->features & 1) || !s->clip ||
      s->paste_status == PASTE_PENDING ||
      (s->clipboard_waiting && GetTickCount64() - s->clipboard_announced_at >= 5000)) {
    LeaveCriticalSection(&s->lock); free(copy); return 0;
  }
  free(s->clipboard_pending); s->clipboard_pending = copy;
  s->clipboard_pending_paste = TRUE;
  s->paste_serial++;
  s->paste_ready = s->paste_keys_sent = s->paste_data_served = FALSE;
  s->paste_status = PASTE_PENDING;
  s->paste_deadline = GetTickCount64() + 5000;
  LeaveCriticalSection(&s->lock); SetEvent(s->wake); return 1;
}
void lrdp_stop(lrdp_session* s) {
  if (!s) return;
  lrdp_audio_gate_request(s->audio, FALSE);
  EnterCriticalSection(&s->lock);
  BOOL abort = s->state != LRDP_CONNECTED;
  if (s->stop && WaitForSingleObject(s->stop, 0) != WAIT_OBJECT_0) {
    s->stop_deadline = GetTickCount64() + (abort ? 0 : STOP_GRACE_MS);
    SetEvent(s->stop);
  }
  LeaveCriticalSection(&s->lock);
  if (abort && s->thread && s->instance && s->instance->context)
    freerdp_abort_connect_context(s->instance->context);
}
void lrdp_destroy(lrdp_session* s) {
  if (!s) return;
  lrdp_stop(s);
  if (s->thread) { WaitForSingleObject(s->thread, INFINITE); CloseHandle(s->thread); }
  if (s->instance) {
    if (s->instance->context) freerdp_context_free(s->instance);
    freerdp_free(s->instance);
  }
  if (s->stop) CloseHandle(s->stop);
  if (s->wake) CloseHandle(s->wake);
  lrdp_video_store_retire(s->video);
  free(s->cursor_pixels); free(s->clipboard_in); free(s->clipboard_out); free(s->clipboard_pending);
  lrdp_audio_gate_free(s->audio);
  DeleteCriticalSection(&s->lock); free(s);
}

int lrdp_audio_active(lrdp_session* s, int active) {
  if (!s || (active != 0 && active != 1)) return 0;
  if (WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0) return 0;
  lrdp_audio_gate_request(s->audio, active != 0);
  SetEvent(s->wake);
  return 1;
}
