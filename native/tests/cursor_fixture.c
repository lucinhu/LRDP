/* Private TLS fixture. Each complete A key press acknowledges one snapshot. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/error.h>
#include <freerdp/input.h>
#include <freerdp/pointer.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static const char *certificate_path, *key_path;
static BOOL finished, success;
static int requested = -1;
static UINT64 activated_at;
static BOOL activated(freerdp_peer* peer) { (void)peer; activated_at = GetTickCount64(); return TRUE; }
static BOOL key(rdpInput* input, UINT16 flags, UINT8 code) {
  (void)input;
  /* Consume the release before advancing. In particular, stage 9 must not
   * close the socket while the client is still writing its acknowledgement. */
  if (code == 0x1e && (flags & KBD_FLAGS_RELEASE)) requested++;
  return TRUE;
}
static BOOL send_cursor(freerdp_peer* peer, int stage) {
  rdpContext* c = peer->context; rdpPointerUpdate* p = c->update->pointer;
  if (stage == 1 || stage == 5) {
    POINTER_SYSTEM_UPDATE update = { stage == 1 ? SYSPTR_NULL : SYSPTR_DEFAULT };
    return p->PointerSystem(c, &update);
  }
  if (stage == 2 || stage == 8) {
    POINTER_CACHED_UPDATE update = {stage == 2 ? 0 : 1}; return p->PointerCached(c, &update);
  }
  if (stage == 4) { POINTER_POSITION_UPDATE update = {123, 77}; return p->PointerPosition(c, &update); }
  if (stage == 9) {
    freerdp_set_error_info(c->rdp, ERRINFO_LOGOFF_BY_USER);
    return freerdp_send_error_info(c->rdp);
  }
  const UINT16 side = stage == 7 ? 384 : stage == 0 ? 8 : 16;
  const UINT16 bpp = stage == 3 ? 1 : stage == 6 ? 24 : 32;
  const UINT32 xor_step = ((side * bpp + 7) / 8 + 1) & ~1U;
  const UINT32 and_step = ((side + 7) / 8 + 1) & ~1U;
  BYTE* xor_mask = calloc(side, xor_step), *and_mask = calloc(side, and_step);
  if (!xor_mask || !and_mask) { free(xor_mask); free(and_mask); return FALSE; }
  for (UINT16 y = 0; y < side; y++) {
    if (bpp == 1) { xor_mask[y * xor_step] = 0x50; and_mask[y * and_step] = 0x30; }
    else for (UINT16 x = 0; x < side; x++) {
      BYTE* pixel = xor_mask + (size_t)y * xor_step + x * (bpp / 8);
      if (stage == 0) { pixel[0] = 40; pixel[1] = 100; pixel[2] = 200; pixel[3] = 128; }
      else if (stage == 7) { pixel[0] = 0x66; pixel[1] = 0x44; pixel[2] = 0x22; pixel[3] = 255; }
      else if (x == 1 || x == 3) memset(pixel, 255, 3);
    }
    if (stage == 6) and_mask[y * and_step] = 0x30;
  }
  BOOL ok;
  if (stage == 7) {
    POINTER_LARGE_UPDATE update = {0};
    update.xorBpp = bpp; update.cacheIndex = 1;
    update.hotSpotX = update.hotSpotY = side - 1; update.width = update.height = side;
    update.lengthAndMask = side * and_step; update.lengthXorMask = side * xor_step;
    update.xorMaskData = xor_mask; update.andMaskData = and_mask;
    ok = p->PointerLarge(c, &update);
  } else {
    POINTER_NEW_UPDATE update = {0}; update.xorBpp = bpp;
    update.colorPtrAttr.hotSpotX = stage == 0 ? 3 : 1;
    update.colorPtrAttr.hotSpotY = stage == 0 ? 5 : 2;
    update.colorPtrAttr.width = update.colorPtrAttr.height = side;
    update.colorPtrAttr.lengthAndMask = (UINT16)(side * and_step);
    update.colorPtrAttr.lengthXorMask = (UINT16)(side * xor_step);
    update.colorPtrAttr.xorMaskData = xor_mask; update.colorPtrAttr.andMaskData = and_mask;
    ok = p->PointerNew(c, &update);
  }
  free(xor_mask); free(and_mask); return ok;
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  if (!freerdp_peer_context_new(peer)) { freerdp_peer_free(peer); finished = TRUE; return TRUE; }
  rdpSettings* cfg = peer->context->settings;
  rdpPrivateKey* private_key = freerdp_key_new_from_file_enc(key_path, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(certificate_path);
  BOOL ok = private_key && cert &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerRsaKey, private_key, 1) &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, FALSE);
  peer->PostConnect = activated; peer->context->input->KeyboardEvent = key;
  if (ok && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + 120000; int sent = -1;
    while (GetTickCount64() < deadline) {
      HANDLE handles[32]; DWORD count = peer->GetEventHandles(peer, handles, 32);
      if (!count || WaitForMultipleObjects(count, handles, FALSE, 20) == WAIT_FAILED || !peer->CheckFileDescriptor(peer)) break;
      if (activated_at && requested < 0 && GetTickCount64() - activated_at >= 200) requested = 0;
      if (requested > sent && requested <= 9) {
        if (!send_cursor(peer, requested)) break;
        printf("Sent cursor stage %d\n", requested); fflush(stdout); sent = requested;
        if (sent == 9) { success = TRUE; break; }
      }
    }
  }
  peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer); finished = TRUE;
  return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 4 || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 2;
  certificate_path = argv[2]; key_path = argv[3];
  freerdp_listener* listener = freerdp_listener_new(); if (!listener) return 3;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 4;
  UINT64 deadline = GetTickCount64() + 120000;
  while (!finished && GetTickCount64() < deadline) {
    HANDLE handles[32]; DWORD count = listener->GetEventHandles(listener, handles, 32);
    if (!count || WaitForMultipleObjects(count, handles, FALSE, 50) == WAIT_FAILED || !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener); return success ? 0 : 1;
}
