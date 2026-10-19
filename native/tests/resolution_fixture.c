/* Private TLS/DISP peer. Verify actual handshake sizes and monitor-layout PDUs.
 * The DISP callback runs on its channel thread; reactivation stays on the peer. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/channels/wtsvc.h>
#include <freerdp/channels/channels.h>
#include <freerdp/server/disp.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <stdio.h>
#include <stdlib.h>

static const char *cert_path, *key_path;
static BOOL finished, success, failed;
typedef struct {
  rdpContext base;
  HANDLE vcm;
  DispServerContext* disp;
  CRITICAL_SECTION lock;
  UINT32 pending_width, pending_height, count;
  BOOL opened;
} resolution_context;

static UINT layout(DispServerContext* disp, const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU* pdu) {
  resolution_context* c = disp->custom;
  if (pdu->NumMonitors != 1) return ERROR_INVALID_DATA;
  const DISPLAY_CONTROL_MONITOR_LAYOUT* m = pdu->Monitors;
  EnterCriticalSection(&c->lock);
  c->count++;
  if ((c->count == 1 && (m->Width != 1000 || m->Height != 700)) ||
      (c->count == 2 && (m->Width != 720 || m->Height != 960)) || c->count > 2)
    failed = TRUE;
  c->pending_width = m->Width; c->pending_height = m->Height;
  LeaveCriticalSection(&c->lock);
  printf("{\"layout\":[%u,%u]}\n", m->Width, m->Height); fflush(stdout);
  return CHANNEL_RC_OK;
}
static BOOL context_new(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  resolution_context* c = (resolution_context*)context;
  InitializeCriticalSection(&c->lock);
  c->vcm = WTSOpenServerA((LPSTR)context);
  if (!c->vcm || c->vcm == INVALID_HANDLE_VALUE) return FALSE;
  c->disp = disp_server_context_new(c->vcm);
  if (!c->disp) return FALSE;
  c->disp->custom = c; c->disp->rdpcontext = context;
  c->disp->MaxNumMonitors = 1;
  c->disp->MaxMonitorAreaFactorA = 4096; c->disp->MaxMonitorAreaFactorB = 4096;
  c->disp->DispMonitorLayout = layout;
  return TRUE;
}
static void context_free(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  resolution_context* c = (resolution_context*)context;
  if (c->disp) disp_server_context_free(c->disp);
  if (c->vcm && c->vcm != INVALID_HANDLE_VALUE) WTSCloseServer(c->vcm);
  DeleteCriticalSection(&c->lock);
}
static BOOL post_connect(freerdp_peer* peer) {
  rdpSettings* cfg = peer->context->settings;
  const UINT32 w = freerdp_settings_get_uint32(cfg, FreeRDP_DesktopWidth);
  const UINT32 h = freerdp_settings_get_uint32(cfg, FreeRDP_DesktopHeight);
  printf("{\"handshake\":[%u,%u]}\n", w, h); fflush(stdout);
  return w == 802 && h == 602;
}
static BOOL key(rdpInput* input, UINT16 flags, UINT8 code) {
  (void)input;
  if (code == 0x1e && (flags & KBD_FLAGS_RELEASE)) success = TRUE;
  return TRUE;
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  peer->ContextSize = sizeof(resolution_context);
  peer->ContextNew = context_new; peer->ContextFree = context_free;
  if (!freerdp_peer_context_new(peer)) { finished = TRUE; freerdp_peer_free(peer); return TRUE; }
  resolution_context* c = (resolution_context*)peer->context;
  rdpSettings* cfg = peer->context->settings;
  rdpPrivateKey* private_key = freerdp_key_new_from_file_enc(key_path, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(cert_path);
  BOOL ok = private_key && cert &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerRsaKey, private_key, 1) &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, FALSE);
  peer->PostConnect = post_connect; peer->context->input->KeyboardEvent = key;
  if (ok && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + 25000, next_frame = 0;
    while (!success && GetTickCount64() < deadline) {
      HANDLE handles[32]; DWORD count = peer->GetEventHandles(peer, handles, 31);
      if (!count) break;
      handles[count++] = WTSVirtualChannelManagerGetEventHandle(c->vcm);
      if (WaitForMultipleObjects(count, handles, FALSE, 10) == WAIT_FAILED ||
          !peer->CheckFileDescriptor(peer) ||
          !WTSVirtualChannelManagerCheckFileDescriptorEx(c->vcm,
            peer->activated && WTSVirtualChannelManagerIsChannelJoined(c->vcm, "drdynvc"))) break;
      if (!c->opened && WTSVirtualChannelManagerGetDrdynvcState(c->vcm) == DRDYNVC_STATE_READY) {
        c->opened = c->disp->Open(c->disp) == CHANNEL_RC_OK;
        if (!c->opened || c->disp->DisplayControlCaps(c->disp) != CHANNEL_RC_OK) break;
      }
      EnterCriticalSection(&c->lock);
      const UINT32 width = c->pending_width, height = c->pending_height;
      c->pending_width = c->pending_height = 0;
      LeaveCriticalSection(&c->lock);
      if (width) {
        if (!freerdp_settings_set_uint32(cfg, FreeRDP_DesktopWidth, width) ||
            !freerdp_settings_set_uint32(cfg, FreeRDP_DesktopHeight, height) ||
            !peer->context->update->DesktopResize(peer->context)) break;
      }
      if (!peer->activated || GetTickCount64() < next_frame) continue;
      next_frame = GetTickCount64() + 80;
      BYTE pixels[16 * 16 * 4];
      for (unsigned i = 0; i < sizeof(pixels); i++) pixels[i] = 0x75;
      SURFACE_BITS_COMMAND cmd = {0};
      cmd.cmdType = CMDTYPE_SET_SURFACE_BITS; cmd.destRight = cmd.destBottom = 16;
      cmd.bmp.bpp = 32; cmd.bmp.width = cmd.bmp.height = 16;
      cmd.bmp.bitmapDataLength = sizeof(pixels); cmd.bmp.bitmapData = pixels;
      if (!peer->context->update->SurfaceBits(peer->context, &cmd)) break;
    }
  }
  peer->Disconnect(peer);
  if (c->disp && c->opened && c->disp->Close(c->disp) != CHANNEL_RC_OK) failed = TRUE;
  success = success && !failed && c->count == 2;
  freerdp_peer_context_free(peer); freerdp_peer_free(peer); finished = TRUE;
  return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 4 || !WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi()) ||
      !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 2;
  cert_path = argv[2]; key_path = argv[3];
  freerdp_listener* listener = freerdp_listener_new(); if (!listener) return 3;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 4;
  const UINT64 deadline = GetTickCount64() + 30000;
  while (!finished && GetTickCount64() < deadline) {
    HANDLE handles[32]; DWORD count = listener->GetEventHandles(listener, handles, 32);
    if (!count || WaitForMultipleObjects(count, handles, FALSE, 50) == WAIT_FAILED ||
        !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  return success ? 0 : 1;
}
