/* Loopback-only clipboard peer: delayed/rejected ACKs, prefetch, missing data,
 * timeout and cancellation. It never accesses a real desktop or clipboard. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/channels/channels.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/wtsapi.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <winpr/string.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *cert_path, *key_path, *mode;
static HANDLE done;
static BYTE *png_bytes, *dib_bytes;
static size_t png_size, dib_size;
static BOOL image_mode(void) { return strncmp(mode, "image_", 6) == 0; }
static BOOL receiving(void) { return strncmp(mode, "receive_", 8) == 0; }
static const char* behavior(void) { return image_mode() ? mode + 6 : mode; }
static BYTE* load_bytes(const char* path, size_t* length) {
  FILE* file = fopen(path, "rb"); if (!file) return NULL;
  if (fseek(file, 0, SEEK_END) || ftell(file) <= 0 || ftell(file) > 16 * 1024 * 1024) { fclose(file); return NULL; }
  *length = (size_t)ftell(file); rewind(file);
  BYTE* data = malloc(*length);
  if (!data || fread(data, 1, *length, file) != *length) { free(data); data = NULL; }
  fclose(file); return data;
}
static BOOL failed;
static UINT64 accept_timeout_ms = 20000;
static UINT64 io_timeout_ms = 12000;
static const char expected[] = "LRDP 中文输入验证 你好";
typedef struct {
  rdpContext base;
  HANDLE vcm;
  CliprdrServerContext* clip;
  UINT formats, key_phase, data_count, unicode_phase, image_format, requests;
  UINT64 ack_at;
  BOOL ack_sent;
} paste_context;
static void check(BOOL ok, const char* message) {
  if (!ok) { fprintf(stderr, "FAIL: %s\n", message); failed = TRUE; }
}
static UINT advertise_image(paste_context* c, BOOL dib) {
  CLIPRDR_FORMAT formats[] = {{0xd001, "PNG"}, {CF_DIB, NULL}, {CF_UNICODETEXT, NULL}};
  CLIPRDR_FORMAT_LIST list = {0}; list.common.msgType = CB_FORMAT_LIST;
  list.numFormats = dib ? 1 : 3; list.formats = dib ? &formats[1] : formats;
  return c->clip->ServerFormatList(c->clip, &list);
}
static UINT image_request(CliprdrServerContext* clip, const CLIPRDR_FORMAT_DATA_REQUEST* req) {
  paste_context* c = clip->custom; c->requests++;
  BOOL dib = strcmp(behavior(), "receive_dib") == 0 || (strcmp(behavior(), "receive_stale") == 0 && c->requests == 2);
  check(receiving() && req->requestedFormatId == (dib ? CF_DIB : 0xd001), "preferred image format and remote registered ID");
  if (strcmp(behavior(), "receive_stale") == 0 && c->requests == 1)
    check(advertise_image(c, TRUE) == CHANNEL_RC_OK, "replace clipboard before old response");
  CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
  response.common.msgType = CB_FORMAT_DATA_RESPONSE; response.common.msgFlags = CB_RESPONSE_OK;
  response.requestedFormatData = dib ? dib_bytes : png_bytes;
  response.common.dataLen = (UINT32)(dib ? dib_size : png_size);
  BYTE invalid[33] = {137,80,78,71,13,10,26,10,0,0,0,13,'I','H','D','R',127,255,255,255,0,0,0,1};
  if (strcmp(behavior(),"receive_invalid") == 0) { response.requestedFormatData = invalid; response.common.dataLen = sizeof(invalid); }
  return clip->ServerFormatDataResponse(clip, &response);
}
static UINT request_data(paste_context* c) {
  CLIPRDR_FORMAT_DATA_REQUEST request = {0};
  request.common.msgType = CB_FORMAT_DATA_REQUEST; request.common.dataLen = 4;
  request.requestedFormatId = image_mode() ? c->image_format : CF_UNICODETEXT;
  return c->clip->ServerFormatDataRequest(c->clip, &request);
}
static UINT formats(CliprdrServerContext* clip, const CLIPRDR_FORMAT_LIST* list) {
  paste_context* c = clip->custom;
  if (!list->numFormats) {
    CLIPRDR_FORMAT_LIST_RESPONSE ack = {0}; ack.common.msgFlags = CB_RESPONSE_OK;
    ack.common.msgType = CB_FORMAT_LIST_RESPONSE;
    return clip->ServerFormatListResponse(clip, &ack);
  }
  c->formats++;
  check(c->formats == 1, "one publication, no automatic retry");
  if (image_mode()) {
    BOOL dib = FALSE, png = FALSE, mime = FALSE;
    for (UINT32 i=0; i<list->numFormats; i++) {
      const CLIPRDR_FORMAT* f = &list->formats[i];
      if (f->formatId == CF_DIB) dib = TRUE;
      if (f->formatName && !strcmp(f->formatName, "PNG")) {
        png = TRUE; if (strcmp(behavior(),"dib") != 0 && strcmp(behavior(),"mime") != 0) c->image_format = f->formatId;
      }
      if (f->formatName && !strcmp(f->formatName, "image/png")) {
        mime = TRUE; if (strcmp(behavior(),"mime") == 0) c->image_format = f->formatId;
      }
    }
    if (strcmp(behavior(),"dib") == 0) c->image_format = CF_DIB;
    check(list->numFormats == 3 && dib && png && mime && c->image_format, "DIB, registered PNG and MIME formats");
  } else check(list->numFormats == 1 && list->formats[0].formatId == CF_UNICODETEXT,
    "Unicode text format advertised");
  c->ack_at = GetTickCount64() + (strcmp(behavior(), "cancel") == 0 ? 2000 : 350);
  if (strcmp(behavior(), "prefetch") == 0) return request_data(c);
  return CHANNEL_RC_OK;
}
static UINT data_response(CliprdrServerContext* clip, const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
  paste_context* c = clip->custom;
  if (image_mode()) {
    BOOL dib = c->image_format == CF_DIB;
    size_t size = dib ? dib_size : png_size;
    check((response->common.msgFlags & CB_RESPONSE_OK) && response->common.dataLen == size &&
      !memcmp(response->requestedFormatData, dib ? dib_bytes : png_bytes, size), "exact image bytes and padding over TLS");
    c->data_count++; check(c->data_count == 1,"one image delivery");
    if (!failed) { puts("PASS: full image payload received"); fflush(stdout); }
    return CHANNEL_RC_OK;
  }
  size_t units = 0;
  WCHAR* wide = ConvertUtf8ToWCharAlloc(expected, &units);
  check(wide && (response->common.msgFlags & CB_RESPONSE_OK) &&
    response->common.dataLen == (units + 1) * 2 &&
    memcmp(wide, response->requestedFormatData, (units + 1) * 2) == 0,
    "exact Chinese UTF-16 data and terminator");
  free(wide); c->data_count++;
  check(c->data_count == 1, "one data delivery");
  return CHANNEL_RC_OK;
}
static BOOL keyboard(rdpInput* input, UINT16 flags, UINT8 code) {
  paste_context* c = (paste_context*)input->context;
  static const UINT8 codes[] = {0x1d, 0x2f, 0x2f, 0x1d};
  check(c->ack_sent, "Ctrl+V must follow positive format ACK");
  check(c->key_phase < 4, "no duplicate paste keys");
  if (c->key_phase >= 4) return FALSE;
  check(code == codes[c->key_phase] && !!(flags & 0x8000) == (c->key_phase >= 2),
    "Ctrl/V press and release order");
  c->key_phase++;
  if (c->key_phase == 4 && (strcmp(behavior(), "normal") == 0 || strcmp(behavior(), "dib") == 0 || strcmp(behavior(), "mime") == 0))
    check(request_data(c) == CHANNEL_RC_OK, "request data after key releases");
  return !failed;
}
/* Direct text must arrive as paired UTF-16 keyboard events even while the
 * server advertises a working clipboard channel. No Ctrl+V is accepted. */
static BOOL unicode_keyboard(rdpInput* input, UINT16 flags, UINT16 code) {
  paste_context* c = (paste_context*)input->context;
  size_t units = 0;
  WCHAR* wide = ConvertUtf8ToWCharAlloc("LRDP 中文输入验证 你好 😀", &units);
  check(strcmp(behavior(), "unicode") == 0 && wide && c->unicode_phase < units * 2,
    "expected direct Unicode keyboard input");
  if (failed) { free(wide); return FALSE; }
  check(code == wide[c->unicode_phase / 2] &&
    !!(flags & KBD_FLAGS_RELEASE) == (c->unicode_phase % 2),
    "exact Chinese and surrogate-pair UTF-16 key down/up order");
  c->unicode_phase++;
  if (c->unicode_phase == units * 2) { puts("PASS: direct Chinese UTF-16 input complete"); fflush(stdout); }
  free(wide);
  return !failed;
}
static BOOL context_new(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  paste_context* c = (paste_context*)context;
  c->vcm = WTSOpenServerA((LPSTR)context);
  if (!c->vcm || c->vcm == INVALID_HANDLE_VALUE) return FALSE;
  c->clip = cliprdr_server_context_new(c->vcm);
  if (!c->clip) return FALSE;
  c->clip->custom = c; c->clip->rdpcontext = context;
  c->clip->useLongFormatNames = TRUE;
  c->clip->ClientFormatList = formats;
  c->clip->ClientFormatDataResponse = data_response;
  c->clip->ClientFormatDataRequest = image_request;
  return TRUE;
}
static void context_free(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  paste_context* c = (paste_context*)context;
  if (c->clip) { c->clip->Close(c->clip); cliprdr_server_context_free(c->clip); }
  if (c->vcm && c->vcm != INVALID_HANDLE_VALUE) WTSCloseServer(c->vcm);
}
static BOOL post_connect(freerdp_peer* peer) {
  paste_context* c = (paste_context*)peer->context;
  if (c->clip->Open(c->clip) != CHANNEL_RC_OK) return FALSE;
  CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
  general.version = CB_CAPS_VERSION_2; general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  CLIPRDR_CAPABILITIES caps = {0};
  caps.common.msgType = CB_CLIP_CAPS;
  caps.common.dataLen = 4 + CB_CAPSTYPE_GENERAL_LEN;
  caps.cCapabilitiesSets = 1; caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
  CLIPRDR_MONITOR_READY ready = {0};
  ready.common.msgType = CB_MONITOR_READY;
  BOOL initialized = c->clip->ServerCapabilities(c->clip, &caps) == CHANNEL_RC_OK &&
    c->clip->MonitorReady(c->clip, &ready) == CHANNEL_RC_OK;
  return initialized && (!receiving() || advertise_image(c, strcmp(mode,"receive_dib") == 0) == CHANNEL_RC_OK);
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  peer->ContextSize = sizeof(paste_context);
  peer->ContextNew = context_new; peer->ContextFree = context_free;
  if (!freerdp_peer_context_new(peer)) { failed = TRUE; freerdp_peer_free(peer); SetEvent(done); return TRUE; }
  rdpSettings* settings = peer->context->settings;
  rdpPrivateKey* key = freerdp_key_new_from_file_enc(key_path, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(cert_path);
  BOOL configured = key && cert &&
    freerdp_settings_set_pointer_len(settings, FreeRDP_RdpServerRsaKey, key, 1) &&
    freerdp_settings_set_pointer_len(settings, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_UnicodeInput, strcmp(behavior(), "unicode_unsupported") != 0) &&
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE);
  peer->PostConnect = post_connect;
  peer->context->input->KeyboardEvent = keyboard;
  peer->context->input->UnicodeKeyboardEvent = unicode_keyboard;
  paste_context* c = (paste_context*)peer->context;
  if (configured && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + io_timeout_ms;
    while (!failed && GetTickCount64() < deadline) {
      HANDLE handles[32];
      DWORD count = peer->GetEventHandles(peer, handles, 30);
      if (!count) break;
      handles[count++] = WTSVirtualChannelManagerGetEventHandle(c->vcm);
      HANDLE clip_event = c->clip->GetEventHandle(c->clip);
      if (clip_event) handles[count++] = clip_event;
      if (WaitForMultipleObjects(count, handles, FALSE, 20) == WAIT_FAILED) break;
      if (!peer->CheckFileDescriptor(peer) || !WTSVirtualChannelManagerCheckFileDescriptor(c->vcm) ||
          (clip_event && WaitForSingleObject(clip_event, 0) == WAIT_OBJECT_0 &&
           c->clip->CheckEventHandle(c->clip) != CHANNEL_RC_OK)) break;
      if (c->ack_at && !c->ack_sent && GetTickCount64() >= c->ack_at && strcmp(behavior(), "no_ack") != 0) {
        CLIPRDR_FORMAT_LIST_RESPONSE ack = {0};
        ack.common.msgType = CB_FORMAT_LIST_RESPONSE;
        BOOL reject = strcmp(behavior(), "reject") == 0;
        ack.common.msgFlags = reject ? CB_RESPONSE_FAIL : CB_RESPONSE_OK;
        c->ack_sent = TRUE;
        check(c->clip->ServerFormatListResponse(c->clip, &ack) == CHANNEL_RC_OK, "send format ACK");
      }
    }
  } else check(FALSE, "initialize private TLS clipboard peer");
  BOOL success = strcmp(behavior(), "normal") == 0 || strcmp(behavior(), "prefetch") == 0 || strcmp(behavior(), "dib") == 0 || strcmp(behavior(), "mime") == 0;
  if (receiving()) {
    check(c->requests == (strcmp(mode,"receive_stale") == 0 ? 2u : 1u) &&
      c->formats == (strcmp(mode,"receive_clear") == 0 ? 1u : 0u) && c->key_phase == 0,
      "serialized image requests, no feedback publication or paste keys");
  }
  else if (strcmp(behavior(), "unicode") == 0) {
    size_t units = 0;
    WCHAR* wide = ConvertUtf8ToWCharAlloc("LRDP 中文输入验证 你好 😀", &units);
    check(wide && c->unicode_phase == units * 2 && c->key_phase == 0 &&
      c->data_count == 0 && c->formats == 0, "complete direct input, no clipboard publication or paste keys");
    free(wide);
  }
  else if (strcmp(behavior(), "unicode_unsupported") == 0)
    check(c->unicode_phase == 0 && c->key_phase == 0 && c->data_count == 0 && c->formats == 0,
      "unsupported input preserves the connection without sending keys");
  else if (success) check(c->key_phase == 4 && c->data_count == 1 && c->formats == 1, "complete paste transaction");
  else if (strcmp(behavior(), "no_data") == 0) check(c->key_phase == 4 && c->data_count == 0 && c->formats == 1, "missing data has no retry");
  else check(c->key_phase == 0 && c->data_count == 0 &&
    (c->formats == 1 || strcmp(behavior(), "cancel") == 0), "reject/timeout/cancel sends no paste keys");
  if (strcmp(behavior(), "unicode") == 0)
    printf("{\"mode\":\"unicode\",\"passed\":%s,\"unicode_events\":%u,\"keys\":%u,\"data\":%u,\"publications\":%u}\n",
      failed ? "false" : "true", c->unicode_phase, c->key_phase, c->data_count, c->formats);
  else printf("{\"mode\":\"%s\",\"passed\":%s,\"keys\":%u,\"data\":%u,\"publications\":%u}\n",
    mode, failed ? "false" : "true", c->key_phase, c->data_count, c->formats); fflush(stdout);
  peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer);
  SetEvent(done); return TRUE;
}
int main(int argc, char** argv) {
  if (argc < 5 || (argc > 7 && argc != 9)) return 2;
  if (argc >= 6) {
    char* end = NULL;
    unsigned long long value = strtoull(argv[5], &end, 10);
    if (!end || *end || value < 1000 || value > 300000) return 2;
    accept_timeout_ms = (UINT64)value;
  }
  if (argc >= 7) {
    char* end = NULL;
    unsigned long long value = strtoull(argv[6], &end, 10);
    if (!end || *end || value < 1000 || value > 300000) return 2;
    io_timeout_ms = (UINT64)value;
  }
  cert_path = argv[2]; key_path = argv[3]; mode = argv[4];
  if (argc == 9) { png_bytes=load_bytes(argv[7], &png_size); dib_bytes=load_bytes(argv[8], &dib_size); if(!png_bytes || !dib_bytes) return 2; }
  if ((image_mode() || receiving()) && argc != 9) return 2;
  if (!WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi()) || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 3;
  done = CreateEvent(NULL, TRUE, FALSE, NULL);
  freerdp_listener* listener = freerdp_listener_new();
  if (!listener || !done) return 4;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 5;
  UINT64 deadline = GetTickCount64() + accept_timeout_ms;
  while (WaitForSingleObject(done, 0) != WAIT_OBJECT_0 && GetTickCount64() < deadline) {
    HANDLE handles[32]; DWORD count = listener->GetEventHandles(listener, handles, 32);
    if (!count || WaitForMultipleObjects(count, handles, FALSE, 100) == WAIT_FAILED ||
        !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  BOOL completed = WaitForSingleObject(done, 0) == WAIT_OBJECT_0;
  CloseHandle(done); free(png_bytes); free(dib_bytes); return !failed && completed ? 0 : 1;
}
