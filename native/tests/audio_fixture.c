/* Private TLS RDPSND peer. Only synthetic PCM is sent to an isolated sink. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/wtsvc.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/server/rdpsnd.h>
#include <freerdp/crypto/privatekey.h>
#include <freerdp/crypto/certificate.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *cert_path, *key_path, *mode;
static HANDLE done;
static BOOL failed;
static UINT64 accept_timeout_ms = 20000, connection_timeout_ms = 12000;
static UINT tone_chunks = 10;
typedef struct {
  rdpContext base;
  HANDLE vcm;
  RdpsndServerContext* audio;
  BOOL activated, selected, format_rejected, audio_initialized;
  UINT confirms, chunks;
  UINT64 send_at;
} audio_context;
static void check(BOOL ok, const char* message) {
  if (!ok) { fprintf(stderr, "FAIL: %s\n", message); failed = TRUE; }
}
static BOOL enabled(void) { return strcmp(mode, "off") != 0; }
static BOOL cycling(void) { return strcmp(mode, "lifecycle") == 0 || strcmp(mode, "dynamic") == 0; }
static UINT confirmed(RdpsndServerContext* snd, BYTE block, UINT16 stamp) {
  (void)block; (void)stamp;
  audio_context* c = snd->data; c->confirms++;
  return CHANNEL_RC_OK;
}
static void activated(RdpsndServerContext* snd) {
  audio_context* c = snd->data;
  c->activated = TRUE;
  for (UINT16 i = 0; i < snd->num_client_formats; i++) {
    const AUDIO_FORMAT* f = &snd->client_formats[i];
    if (f->wFormatTag == WAVE_FORMAT_PCM && f->nSamplesPerSec == 48000 &&
        f->nChannels == 2 && f->wBitsPerSample == (strcmp(mode, "pcm8") == 0 ? 8 : 16)) {
      check(snd->SelectFormat(snd, i) == CHANNEL_RC_OK, "select stereo PCM");
      c->selected = TRUE; c->send_at = GetTickCount64() + 100;
      return;
    }
  }
  check(strcmp(mode, "unsupported") == 0, "PCM format negotiated");
}
static BOOL context_new(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  audio_context* c = (audio_context*)context;
  c->vcm = WTSOpenServerA((LPSTR)context);
  if (!c->vcm || c->vcm == INVALID_HANDLE_VALUE) return FALSE;
  c->audio = rdpsnd_server_context_new(c->vcm);
  if (!c->audio) return FALSE;
  RdpsndServerContext* snd = c->audio;
  snd->data = c; snd->rdpcontext = context;
  snd->use_dynamic_virtual_channel = strcmp(mode, "dynamic") == 0;
  snd->Activated = activated; snd->ConfirmBlock = confirmed;
  snd->server_formats = calloc(1, sizeof(AUDIO_FORMAT));
  if (!snd->server_formats) return FALSE;
  snd->num_server_formats = 1;
  *snd->server_formats = (AUDIO_FORMAT){WAVE_FORMAT_PCM, 2, 48000, 192000, 4, 16, 0, NULL};
  if (strcmp(mode, "pcm8") == 0) {
    snd->server_formats->wBitsPerSample = 8;
    snd->server_formats->nBlockAlign = 2;
    snd->server_formats->nAvgBytesPerSec = 96000;
  }
  if (strcmp(mode, "unsupported") == 0) snd->server_formats->wFormatTag = 0xffff;
  snd->src_format = snd->server_formats; snd->latency = 100;
  return TRUE;
}
static void context_free(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  audio_context* c = (audio_context*)context;
  if (c->audio) rdpsnd_server_context_free(c->audio);
  if (c->vcm && c->vcm != INVALID_HANDLE_VALUE) WTSCloseServer(c->vcm);
}
static BOOL post_connect(freerdp_peer* peer) {
  audio_context* c = (audio_context*)peer->context;
  check(freerdp_settings_get_bool(c->base.settings, FreeRDP_AudioPlayback) == enabled(),
    "wire playback flag matches user preference");
  check(!freerdp_settings_get_bool(c->base.settings, FreeRDP_AudioCapture),
    "microphone remains disabled");
  if (!enabled() || c->audio->use_dynamic_virtual_channel) return TRUE;
  c->audio_initialized = c->audio->Initialize(c->audio, FALSE) == CHANNEL_RC_OK;
  return c->audio_initialized;
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  peer->ContextSize = sizeof(audio_context);
  peer->ContextNew = context_new; peer->ContextFree = context_free;
  if (!freerdp_peer_context_new(peer)) { failed = TRUE; freerdp_peer_free(peer); SetEvent(done); return TRUE; }
  rdpSettings* cfg = peer->context->settings;
  rdpPrivateKey* key = freerdp_key_new_from_file_enc(key_path, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(cert_path);
  BOOL configured = key && cert &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerRsaKey, key, 1) &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, FALSE);
  peer->PostConnect = post_connect;
  audio_context* c = (audio_context*)peer->context;
  BOOL connected = configured && peer->Initialize(peer);
  check(connected, "TLS peer initialized");
  if (connected) {
    UINT64 deadline = GetTickCount64() + connection_timeout_ms;
    while (!failed && GetTickCount64() < deadline) {
      HANDLE handles[32]; DWORD count = peer->GetEventHandles(peer, handles, 30);
      if (!count) break;
      handles[count++] = WTSVirtualChannelManagerGetEventHandle(c->vcm);
      HANDLE audio_event = c->audio_initialized && !c->format_rejected ? rdpsnd_server_get_event_handle(c->audio) : NULL;
      if (audio_event && audio_event != INVALID_HANDLE_VALUE) handles[count++] = audio_event;
      DWORD wait_ms = 20;
      UINT64 clock = GetTickCount64();
      if (c->selected && c->chunks < tone_chunks)
        wait_ms = c->send_at <= clock ? 0 : (DWORD)((c->send_at - clock) < 20 ? c->send_at - clock : 20);
      if (WaitForMultipleObjects(count, handles, FALSE, wait_ms) == WAIT_FAILED) break;
      /* The manager must not attempt its one-shot DVC open before the MCS
       * channels are joined and activation completes. Otherwise it either
       * remains INITIALIZED without a channel or sends DVC during licensing. */
      if (!peer->CheckFileDescriptor(peer) ||
          !WTSVirtualChannelManagerCheckFileDescriptorEx(c->vcm,
            peer->activated && WTSVirtualChannelManagerIsChannelJoined(c->vcm, "drdynvc"))) break;
      if (enabled() && !c->audio_initialized && c->audio->use_dynamic_virtual_channel &&
          WTSVirtualChannelManagerGetDrdynvcState(c->vcm) == DRDYNVC_STATE_READY) {
        check(c->audio->Initialize(c->audio, FALSE) == CHANNEL_RC_OK, "initialize dynamic audio");
        c->audio_initialized = !failed;
      }
      if (audio_event && audio_event != INVALID_HANDLE_VALUE &&
          WaitForSingleObject(audio_event, 0) == WAIT_OBJECT_0) {
        UINT status = rdpsnd_server_handle_messages(c->audio);
        if (status != CHANNEL_RC_OK) {
          /* The intentionally unsupported announcement receives zero formats.
           * The server may stop that audio stream while keeping RDP usable. */
          if (strcmp(mode, "unsupported") == 0 && status == ERROR_INTERNAL_ERROR &&
              c->audio->num_client_formats == 0) c->format_rejected = TRUE;
          else break;
        }
      }
      if (c->selected && c->chunks < tone_chunks && GetTickCount64() >= c->send_at) {
        INT16 pcm[4800 * 2];
        for (size_t i = 0; i < 4800; i++) {
          const size_t frame = c->chunks * 4800 + i;
          const unsigned phase = cycling() ?
            (c->chunks < 10 ? 0 : c->chunks < 30 ? 1 : 2) : 0;
          pcm[i * 2] = (INT16)(6000 * sin(2 * 3.141592653589793 * (500 + phase * 1000) * frame / 48000));
          pcm[i * 2 + 1] = (INT16)(4000 * sin(2 * 3.141592653589793 * (1000 + phase * 1000) * frame / 48000));
        }
        /* PCM is already the negotiated wire format. Send exact bytes rather
         * than involving the system server's optional FFmpeg encoder. */
        BYTE pcm8[4800 * 2];
        const BOOL eight = strcmp(mode, "pcm8") == 0;
        if (eight) for (size_t i = 0; i < 4800 * 2; i++) pcm8[i] = (BYTE)((pcm[i] + 32768) / 256);
        check(c->audio->SendSamples2(c->audio, c->audio->selected_client_format,
          eight ? (const void*)pcm8 : (const void*)pcm, eight ? sizeof(pcm8) : sizeof(pcm),
          (UINT16)(c->chunks * 100), c->chunks * 100) == CHANNEL_RC_OK,
          "send PCM samples");
        /* Keep a sample clock rather than accumulating each polling delay.
         * A host stall longer than a full block starts a fresh deadline. */
        c->chunks++; c->send_at += 100;
        if (GetTickCount64() > c->send_at + 100) c->send_at = GetTickCount64() + 100;
        if (c->chunks == tone_chunks) {
          printf("{\"audio_stream_complete\":true,\"chunks\":%u}\n", c->chunks); fflush(stdout);
        }
      }
    }
  }
  if (enabled() && strcmp(mode, "unsupported") != 0)
    check(c->activated && c->selected && c->chunks == tone_chunks && c->confirms > 0,
      "format negotiation, samples and wave confirmations completed");
  else check(c->chunks == 0, "muted/unsupported stream sends no samples");
  printf("{\"mode\":\"%s\",\"passed\":%s,\"activated\":%s,\"chunks\":%u,\"confirms\":%u}\n",
    mode, failed ? "false" : "true", c->activated ? "true" : "false", c->chunks, c->confirms);
  fflush(stdout);
  peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer);
  SetEvent(done); return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 5 && argc != 7) return 2;
  if (argc == 7) {
    char* end = NULL;
    unsigned long long timeout = strtoull(argv[5], &end, 10);
    if (!end || *end || timeout < 1000 || timeout > 300000) return 2;
    unsigned long chunks = strtoul(argv[6], &end, 10);
    if (!end || *end || chunks < 10 || chunks > 1000) return 2;
    accept_timeout_ms = timeout; tone_chunks = (UINT)chunks; connection_timeout_ms = 180000;
  }
  cert_path = argv[2]; key_path = argv[3]; mode = argv[4];
  if (cycling() && argc == 5) tone_chunks = 60;
  if (!WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi()) || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 3;
  done = CreateEvent(NULL, TRUE, FALSE, NULL);
  freerdp_listener* listener = freerdp_listener_new();
  if (!listener || !done) return 4;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 5;
  UINT64 deadline = GetTickCount64() + accept_timeout_ms;
  while (WaitForSingleObject(done, 0) != WAIT_OBJECT_0 && GetTickCount64() < deadline) {
    HANDLE handles[32]; DWORD n = listener->GetEventHandles(listener, handles, 32);
    if (!n || WaitForMultipleObjects(n, handles, FALSE, 100) == WAIT_FAILED ||
        !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  BOOL completed = WaitForSingleObject(done, 0) == WAIT_OBJECT_0;
  CloseHandle(done); return !failed && completed ? 0 : 1;
}
