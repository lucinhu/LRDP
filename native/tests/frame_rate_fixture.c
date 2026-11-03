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
#include <string.h>
#include <errno.h>

static const char *cert_path, *key_path;
static int frame_width = 320, frame_height = 240, source_fps = 240;
static BOOL finished, success;
static BOOL output_suppressed, refresh_pending;
static BOOL settle_pending, settled;
static BOOL support_suppress_output = TRUE;
enum { REACTIVATE_NONE, REACTIVATE_SAME_SIZE, REACTIVATE_UNSUPPORTED };
static int pending_reactivation;
static UINT64 activated_at;
static BOOL suppress_output(rdpContext* context, BYTE allow, const RECTANGLE_16* area) {
  (void)context; (void)area;
  if (output_suppressed && allow) refresh_pending = TRUE;
  output_suppressed = !allow;
  printf("SuppressOutput allow=%u\n", (unsigned)allow);
  fflush(stdout);
  return TRUE;
}
static BOOL activated(freerdp_peer* peer) {
  (void)peer; activated_at = GetTickCount64(); return TRUE;
}
static BOOL key(rdpInput* input, UINT16 flags, UINT8 code) {
  (void)input;
  if (flags & KBD_FLAGS_RELEASE) {
    if (code == 0x1e) success = TRUE;
    /* Defer protocol reactivation until CheckFileDescriptor has returned;
     * calling DesktopResize from the input callback would reenter the peer. */
    else if (code == 0x30) pending_reactivation = REACTIVATE_SAME_SIZE;
    else if (code == 0x2e) pending_reactivation = REACTIVATE_UNSUPPORTED;
    else if (code == 0x20) settle_pending = TRUE;
  }
  return TRUE;
}
static BOOL send_patch(freerdp_peer* peer, BYTE* pixels, UINT16 x, UINT16 y,
    UINT16 width, UINT16 height) {
  SURFACE_BITS_COMMAND cmd = {0};
  cmd.cmdType = CMDTYPE_SET_SURFACE_BITS;
  cmd.destLeft = x; cmd.destTop = y;
  cmd.destRight = x + width; cmd.destBottom = y + height;
  cmd.bmp.bpp = 32; cmd.bmp.width = width; cmd.bmp.height = height;
  cmd.bmp.bitmapDataLength = width * height * 4;
  cmd.bmp.bitmapData = pixels;
  return peer->context->update->SurfaceBits(peer->context, &cmd);
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
    freerdp_settings_set_bool(cfg, FreeRDP_SuppressOutput, support_suppress_output) &&
    freerdp_settings_set_bool(cfg, FreeRDP_SupportGraphicsPipeline, FALSE) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_DesktopWidth, (UINT32)frame_width) &&
    freerdp_settings_set_uint32(cfg, FreeRDP_DesktopHeight, (UINT32)frame_height);
  peer->PostConnect = activated;
  peer->context->input->KeyboardEvent = key;
  peer->context->update->SuppressOutput = suppress_output;
  const size_t pixel_count = (size_t)frame_width * (size_t)frame_height;
  BYTE* pixels = calloc(pixel_count, 4);
  if (ok && pixels && peer->Initialize(peer)) {
    UINT64 deadline = GetTickCount64() + 30000, sent_slot = 0;
    UINT32 sequence = 0;
    while (!success && GetTickCount64() < deadline) {
      HANDLE handles[32]; DWORD count = peer->GetEventHandles(peer, handles, 32);
      if (!count || WaitForMultipleObjects(count, handles, FALSE,
            output_suppressed ? 50 : 1) == WAIT_FAILED ||
          !peer->CheckFileDescriptor(peer)) break;
      if (pending_reactivation && peer->activated) {
        const int request = pending_reactivation;
        pending_reactivation = REACTIVATE_NONE;
        if (request == REACTIVATE_UNSUPPORTED &&
            !freerdp_settings_set_bool(cfg, FreeRDP_SuppressOutput, FALSE)) break;
        /* Model a server resetting its suppression state during activation.
         * Keep the same dimensions, clock and pixel sequence contract. */
        output_suppressed = FALSE;
        refresh_pending = TRUE;
        printf("Reactivate suppress_supported=%d\n",
          freerdp_settings_get_bool(cfg, FreeRDP_SuppressOutput) ? 1 : 0);
        fflush(stdout);
        if (!peer->context->update->DesktopResize(peer->context)) break;
        continue;
      }
      if (!activated_at || !peer->activated || output_suppressed) continue;
      if (settle_pending) {
        /* A burst ending in disjoint tiny damage, then silence. A paced client
         * must eventually publish both corners without another network frame. */
        settle_pending = FALSE; settled = TRUE;
        for (size_t i = 0; i < pixel_count; i++) {
          pixels[i * 4] = 128; pixels[i * 4 + 1] = 69;
          pixels[i * 4 + 2] = 117; pixels[i * 4 + 3] = 255;
        }
        /* Avoid upstream GDI's degenerate (0,0,1,1) invalidation boundary;
         * this oracle tests merging valid disjoint damage, not that edge case. */
        BYTE first[] = {17, 41, 177, 255, 17, 41, 177, 255,
                        17, 41, 177, 255, 17, 41, 177, 255};
        BYTE last[] = {231, 59, 93, 255, 231, 59, 93, 255,
                       231, 59, 93, 255, 231, 59, 93, 255};
        if (!send_patch(peer, pixels, 0, 0, (UINT16)frame_width, (UINT16)frame_height) ||
            !send_patch(peer, first, 0, 0, 2, 2) ||
            !send_patch(peer, last, (UINT16)(frame_width - 2),
                        (UINT16)(frame_height - 2), 2, 2)) break;
        printf("Settled disjoint damage then silence\n"); fflush(stdout);
      }
      if (settled) continue;
      const UINT64 slot = (GetTickCount64() - activated_at) * (UINT64)source_fps / 1000;
      if (slot <= sent_slot && !refresh_pending) continue;
      /* Resume immediately with a complete frame, skipping elapsed slots
       * rather than catching up. Preserve the existing sequence/color format. */
      refresh_pending = FALSE;
      sent_slot = slot; sequence++;
      for (size_t i = 0; i < pixel_count; i++) {
        pixels[i * 4] = (BYTE)sequence;
        pixels[i * 4 + 1] = (BYTE)(sequence >> 8);
        pixels[i * 4 + 2] = 0x75; pixels[i * 4 + 3] = 255;
      }
      if (!send_patch(peer, pixels, 0, 0, (UINT16)frame_width, (UINT16)frame_height)) break;
    }
    printf("Producer sent %u distinct frames; client acknowledged=%d\n", sequence, success);
  }
  free(pixels);
  peer->Disconnect(peer); freerdp_peer_context_free(peer); freerdp_peer_free(peer);
  finished = TRUE; return TRUE;
}
static BOOL positive_argument(const char* text, int maximum, int* out) {
  /* Reject whitespace/signs, trailing text and overflow rather than silently
   * accepting atoi's prefixes. All dimensions/rates must be positive decimal. */
  if (!text || text[0] < '0' || text[0] > '9') return FALSE;
  errno = 0;
  char* end = NULL;
  const long value = strtol(text, &end, 10);
  if (errno || !end || *end || value < 1 || value > maximum) return FALSE;
  *out = (int)value;
  return TRUE;
}
int main(int argc, char** argv) {
  if (argc < 4) return 2;
  BOOL size_seen = FALSE, fps_seen = FALSE;
  for (int i = 4; i < argc; i++) {
    if (strcmp(argv[i], "--no-suppress") == 0 && support_suppress_output) {
      support_suppress_output = FALSE;
    } else if (strcmp(argv[i], "--size") == 0 && !size_seen) {
      if (i + 2 >= argc || !positive_argument(argv[i + 1], 1920, &frame_width) ||
          !positive_argument(argv[i + 2], 1080, &frame_height) ||
          frame_width < 2 || frame_height < 2) return 2;
      size_seen = TRUE; i += 2;
    } else if (strcmp(argv[i], "--fps") == 0 && !fps_seen) {
      if (i + 1 >= argc || !positive_argument(argv[i + 1], 240, &source_fps)) return 2;
      fps_seen = TRUE; i++;
    } else return 2;
  }
  if (!winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 2;
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
