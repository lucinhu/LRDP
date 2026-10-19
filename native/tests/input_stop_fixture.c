/* Private TLS peer: independently observes delivered input and its releases. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/pointer.h>
#include <freerdp/channels/wtsvc.h>
#include <freerdp/channels/channels.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <sys/socket.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *certificate, *private_key, *mode;
static BOOL finished, failed, marker, wheel, transient_down, transient_up;
static BOOL scans[6], unicode_keys[3];
static const UINT16 scan_codes[] = {0x1e, 0x1d, 0x2a, 0x11d, 0x138, 0x15b};
static const UINT16 unicode_codes[] = {0x4e2d, 0xd83d, 0xde42};
static UINT16 buttons, x, y;
static unsigned released_scans, released_unicode, released_buttons;
static unsigned preflight, combined_events;
static BOOL preflight_drag, preflight_ack;
static unsigned trackpad_wheels;
static void check(BOOL condition, const char* message) {
  if (!condition) { failed = TRUE; fprintf(stderr, "FAIL: %s\n", message); }
}
static BOOL keyboard(rdpInput* input, UINT16 flags, UINT8 code) {
  (void)input;
  UINT16 scan = (flags & 0x300) | code;
  BOOL up = (flags & KBD_FLAGS_RELEASE) != 0;
  if (strcmp(mode, "trackpad") == 0) {
    check(scan == 0x1e, "only the test completion marker is a keyboard event");
    if (up) marker = TRUE;
    return !failed;
  }
  if (scan == 0x30) {
    check(!marker && (up ? transient_down && !transient_up : !transient_down), "transient B is not released twice");
    if (up) transient_up = TRUE; else transient_down = TRUE;
    return !failed;
  }
  for (unsigned i = 0; i < 6; i++) if (scan_codes[i] == scan) {
    if (up) {
      check(marker && scans[i], "one release per delivered scan code");
      if (i > 0) check(!buttons && !scans[0], "mouse and ordinary key released before modifiers");
      scans[i] = FALSE; released_scans++;
    } else { check(!marker, "no new key-down after stop"); scans[i] = TRUE; }
    return !failed;
  }
  check(FALSE, "unexpected scan code"); return FALSE;
}
static BOOL unicode_key(rdpInput* input, UINT16 flags, UINT16 code) {
  (void)input;
  for (unsigned i = 0; i < 3; i++) if (unicode_codes[i] == code) {
    if (flags & KBD_FLAGS_RELEASE) {
      check(marker && unicode_keys[i], "one release per delivered Unicode unit");
      unicode_keys[i] = FALSE; released_unicode++;
    } else { check(!marker, "no Unicode down after stop"); unicode_keys[i] = TRUE; }
    return !failed;
  }
  check(FALSE, "unexpected Unicode unit"); return FALSE;
}
static BOOL mouse(rdpInput* input, UINT16 flags, UINT16 px, UINT16 py) {
  (void)input;
  if (strcmp(mode, "trackpad") == 0) {
    static const UINT16 expected[] = {
      0x278, 0x588, 0x278, 0x588, 0x388, 0x478, 0x388, 0x478,
      0x388, 0x478
    };
    check(trackpad_wheels < sizeof(expected) / sizeof(expected[0]) &&
      flags == expected[trackpad_wheels], "trackpad wheel axis, direction and count");
    trackpad_wheels++;
    return !failed;
  }
  if (flags & PTR_FLAGS_WHEEL) { wheel = TRUE; return TRUE; }
  x = px; y = py;
  UINT16 changed = flags & (PTR_FLAGS_BUTTON1 | PTR_FLAGS_BUTTON2 | PTR_FLAGS_BUTTON3);
  if (changed && (flags & PTR_FLAGS_MOVE)) combined_events++;
  /* Deliberately use KRDP InputHandler::mouseEvent's event precedence:
   * DOWN, else MOVE, else RELEASE. MOVE|BUTTON must not mask a release.
   * https://invent.kde.org/plasma/krdp/-/blob/master/src/InputHandler.cpp */
  if (!(flags & PTR_FLAGS_DOWN) && (flags & PTR_FLAGS_MOVE)) {
    if (preflight == 1 && px == 180 && py == 120) preflight_drag = TRUE;
    return TRUE;
  }
  if (changed && preflight < 8) {
    static const UINT16 expected[] = {0x9000, 0x1000, 0x9000, 0x1000, 0xa000, 0x2000, 0xc000, 0x4000};
    static const UINT16 xs[] = {120, 200, 260, 260, 280, 280, 300, 300};
    static const UINT16 ys[] = {80, 140, 160, 160, 160, 160, 160, 160};
    check((flags & ~PTR_FLAGS_MOVE) == expected[preflight], "drag release followed by working left/right/middle clicks");
    check(px == xs[preflight] && py == ys[preflight], "button delivered at its exact target");
    preflight++;
    return !failed;
  }
  for (UINT16 bit = PTR_FLAGS_BUTTON1; bit <= PTR_FLAGS_BUTTON3; bit <<= 1) if (flags & bit) {
    if (flags & PTR_FLAGS_DOWN) { check(!marker, "no new mouse down after stop"); buttons |= bit; }
    else {
      check(marker && (buttons & bit), "one release per delivered mouse button");
      check(px == 330 && py == 190, "release stays at last motion, not wheel coordinates");
      buttons &= (UINT16)~bit; released_buttons++;
    }
  }
  return !failed;
}
static BOOL all_down(void) {
  if (!wheel || !transient_up || buttons != 0x7000 || x != 330 || y != 190) return FALSE;
  for (unsigned i = 0; i < 6; i++) if (!scans[i]) return FALSE;
  for (unsigned i = 0; i < 3; i++) if (!unicode_keys[i]) return FALSE;
  return TRUE;
}
static BOOL post_connect(freerdp_peer* peer) { (void)peer; return TRUE; }
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  int peer_socket = peer->sockfd; /* Context creation transfers socket ownership. */
  if (!freerdp_peer_context_new(peer)) { failed = finished = TRUE; freerdp_peer_free(peer); return TRUE; }
  rdpSettings* cfg = peer->context->settings;
  rdpPrivateKey* key = freerdp_key_new_from_file_enc(private_key, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(certificate);
  BOOL ok = key && cert && freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerRsaKey, key, 1) &&
    freerdp_settings_set_pointer_len(cfg, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(cfg, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, FALSE);
  peer->context->input->KeyboardEvent = keyboard;
  peer->context->input->UnicodeKeyboardEvent = unicode_key;
  peer->context->input->MouseEvent = mouse;
  peer->PostConnect = post_connect;
  BOOL blocked = strcmp(mode, "blocked") == 0;
  BOOL trackpad = strcmp(mode, "trackpad") == 0;
  BOOL trackpad_frame = FALSE;
  if (blocked) {
    int receive_bytes = 1024;
    check(setsockopt(peer_socket, SOL_SOCKET, SO_RCVBUF, &receive_bytes, sizeof(receive_bytes)) == 0, "small receiver buffer");
  }
  if (ok && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + 45000;
    while (!failed && !(trackpad && marker) && GetTickCount64() < deadline) {
      if (blocked && marker) { Sleep(20); continue; }
      HANDLE handles[32]; DWORD n = peer->GetEventHandles(peer, handles, 32);
      if (!n || WaitForMultipleObjects(n, handles, FALSE, 20) == WAIT_FAILED || !peer->CheckFileDescriptor(peer)) break;
      if (trackpad) {
        if (peer->activated && !trackpad_frame) {
          BYTE pixels[16 * 16 * 4]; memset(pixels, 0x75, sizeof(pixels));
          SURFACE_BITS_COMMAND frame = {0};
          frame.cmdType = CMDTYPE_SET_SURFACE_BITS; frame.destRight = frame.destBottom = 16;
          frame.bmp.bpp = 32; frame.bmp.width = frame.bmp.height = 16;
          frame.bmp.bitmapDataLength = sizeof(pixels); frame.bmp.bitmapData = pixels;
          check(peer->context->update->SurfaceBits(peer->context, &frame), "initial trackpad desktop frame");
          trackpad_frame = TRUE;
        }
        if (trackpad_wheels == 10 && !preflight_ack) {
          POINTER_POSITION_UPDATE update = {77, 100};
          check(peer->context->update->pointer->PointerPosition(peer->context, &update), "acknowledge wheel PDUs");
          preflight_ack = TRUE;
        }
        continue;
      }
      if (!preflight_ack && preflight == 8) {
        POINTER_POSITION_UPDATE update = {77, 98};
        check(preflight_drag && !combined_events, "drag motion and separate move/button PDUs");
        check(peer->context->update->pointer->PointerPosition(peer->context, &update), "acknowledge actual drag and follow-up clicks");
        preflight_ack = TRUE; puts("{\"drag_and_clicks_acknowledged\":true}"); fflush(stdout);
      }
      if (!marker && preflight_ack && all_down()) {
        POINTER_POSITION_UPDATE update = {77, 99};
        check(peer->context->update->pointer->PointerPosition(peer->context, &update), "acknowledge actual held states over RDP");
        marker = TRUE; puts("{\"held_acknowledged\":true}"); fflush(stdout);
      }
    }
  }
  if (trackpad) {
    check(marker && preflight_ack && trackpad_wheels == 10, "trackpad completion and exact wheel count");
    printf("{\"trackpad_passed\":%s,\"wheel_pdus\":%u}\n", failed ? "false" : "true", trackpad_wheels);
    fflush(stdout);
    peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer);
    finished = TRUE; return TRUE;
  }
  if (!blocked) check(marker && !buttons && released_scans == 6 && released_unicode == 3 && released_buttons == 3,
    "all delivered inputs released before transport teardown");
  check(preflight_ack && !combined_events, "button events never combined with movement, including shutdown");
  printf("{\"passed\":%s,\"scan_releases\":%u,\"unicode_releases\":%u,\"mouse_releases\":%u,\"drag_and_follow_up_clicks\":%s,\"combined_mouse_events\":%u}\n",
    failed ? "false" : "true", released_scans, released_unicode, released_buttons,
    preflight_ack ? "true" : "false", combined_events); fflush(stdout);
  peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer);
  finished = TRUE; return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 5) return 2;
  certificate = argv[2]; private_key = argv[3]; mode = argv[4];
  if (!WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi()) || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 3;
  freerdp_listener* listener = freerdp_listener_new(); if (!listener) return 4;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 5;
  UINT64 deadline = GetTickCount64() + (strcmp(mode, "trackpad") == 0 ? 120000 : 30000);
  while (!finished && GetTickCount64() < deadline) {
    HANDLE handles[32]; DWORD n = listener->GetEventHandles(listener, handles, 32);
    if (!n || WaitForMultipleObjects(n, handles, FALSE, 100) == WAIT_FAILED || !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  return finished && !failed ? 0 : 1;
}
