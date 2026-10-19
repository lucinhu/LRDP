/* Sends a real RDP ErrorInfo logoff on a private loopback-only TLS server. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/error.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <stdio.h>
#include <stdlib.h>

static const char *certificate_path, *key_path;
static BOOL finished, sent;
static UINT64 activated_at;
static BOOL activated(freerdp_peer* peer) {
  (void)peer;
  activated_at = GetTickCount64();
  return TRUE;
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  if (!freerdp_peer_context_new(peer)) { freerdp_peer_free(peer); finished = TRUE; return TRUE; }
  rdpSettings* cfg = peer->context->settings;
  rdpPrivateKey* key = freerdp_key_new_from_file_enc(key_path, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(certificate_path);
  BOOL ok = key && cert &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerRsaKey, key, 1) &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, FALSE);
  peer->PostConnect = activated;
  if (ok && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + 15000;
    while (GetTickCount64() < deadline) {
      HANDLE handles[32];
      DWORD count = peer->GetEventHandles(peer, handles, 32);
      if (!count || WaitForMultipleObjects(count, handles, FALSE, 20) == WAIT_FAILED ||
          !peer->CheckFileDescriptor(peer)) break;
      if (activated_at && GetTickCount64() - activated_at >= 500) {
        freerdp_set_error_info(peer->context->rdp, ERRINFO_LOGOFF_BY_USER);
        sent = freerdp_send_error_info(peer->context->rdp);
        if (sent) puts("Sent ERRINFO_LOGOFF_BY_USER over TLS");
        break;
      }
    }
  }
  peer->Disconnect(peer);
  freerdp_peer_context_free(peer);
  freerdp_peer_free(peer);
  finished = TRUE;
  return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 4 || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 2;
  certificate_path = argv[2]; key_path = argv[3];
  freerdp_listener* listener = freerdp_listener_new();
  if (!listener) return 3;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 4;
  UINT64 deadline = GetTickCount64() + 20000;
  while (!finished && GetTickCount64() < deadline) {
    HANDLE handles[32];
    DWORD count = listener->GetEventHandles(listener, handles, 32);
    if (!count || WaitForMultipleObjects(count, handles, FALSE, 50) == WAIT_FAILED ||
        !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  return sent ? 0 : 1;
}
