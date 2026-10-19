/* Loopback-only TLS producer. The client's frame counter must reflect real
 * distinct protocol updates, rather than a UI timer or duplicate images. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <stdio.h>
#include <stdlib.h>

static const char *cert_path, *key_path;
static BOOL finished, success;
static UINT64 activated_at;
static BOOL activated(freerdp_peer* peer) {
  (void)peer; activated_at = GetTickCount64(); return TRUE;
}
static BOOL key(rdpInput* input, UINT16 flags, UINT8 code) {
  (void)input;
  if (code == 0x1e && (flags & KBD_FLAGS_RELEASE)) success = TRUE;
  return TRUE;
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  if (!freerdp_peer_context_new(peer)) { freerdp_peer_free(peer); finished = TRUE; return TRUE; }
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
  peer->PostConnect = activated;
  peer->context->input->KeyboardEvent = key;
  BYTE* pixels = calloc(320 * 240, 4);
  if (ok && pixels && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + 30000, sent_slot = 0;
    UINT32 sequence = 0;
    while (!success && GetTickCount64() < deadline) {
      HANDLE handles[32]; DWORD count = peer->GetEventHandles(peer, handles, 32);
      if (!count || WaitForMultipleObjects(count, handles, FALSE, 1) == WAIT_FAILED ||
          !peer->CheckFileDescriptor(peer)) break;
      if (!activated_at) continue;
      const UINT64 slot = (GetTickCount64() - activated_at) * 240 / 1000;
      if (slot <= sent_slot) continue;
      sent_slot = slot; sequence++;
      for (unsigned i = 0; i < 320 * 240; i++) {
        pixels[i * 4] = (BYTE)sequence;
        pixels[i * 4 + 1] = (BYTE)(sequence >> 8);
        pixels[i * 4 + 2] = 0x75; pixels[i * 4 + 3] = 255;
      }
      SURFACE_BITS_COMMAND cmd = {0};
      cmd.cmdType = CMDTYPE_SET_SURFACE_BITS;
      cmd.destRight = 320; cmd.destBottom = 240;
      cmd.bmp.bpp = 32; cmd.bmp.width = 320; cmd.bmp.height = 240;
      cmd.bmp.bitmapDataLength = 320 * 240 * 4;
      cmd.bmp.bitmapData = pixels;
      if (!peer->context->update->SurfaceBits(peer->context, &cmd)) break;
    }
    printf("Producer sent %u distinct frames; client acknowledged=%d\n", sequence, success);
  }
  free(pixels);
  peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer);
  finished = TRUE; return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 4 || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 2;
  cert_path = argv[2]; key_path = argv[3];
  freerdp_listener* listener = freerdp_listener_new(); if (!listener) return 3;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 4;
  UINT64 deadline = GetTickCount64() + 30000;
  while (!finished && GetTickCount64() < deadline) {
    HANDLE handles[32]; DWORD count = listener->GetEventHandles(listener, handles, 32);
    if (!count || WaitForMultipleObjects(count, handles, FALSE, 50) == WAIT_FAILED ||
        !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  return success ? 0 : 1;
}
