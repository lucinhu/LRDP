/* Private loopback-only integration fixture, built against system FreeRDP 3.
 * Exercises the shipped LRDP client over real TLS/RDPDR/Unicode input PDUs.
 * No user desktop, accounts or filesystem directories are exposed. */
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/listener.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/server/rdpdr.h>
#include <freerdp/channels/channels.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <winpr/wtsapi.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/ssl.h>
#include <winpr/nt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HANDLE files_done, text_done, failed;
static UINT64 accept_timeout_ms = 30000, io_timeout_ms = 20000;
static const char *certificate_path, *key_path;
static const char upload[] = "LRDP upload: 中文文件\n";
static const char download[] = "LRDP download: 远程写回\n";
static const UINT16 chinese[] = {0x4E2D, 0x6587, 0x8F93, 0x5165};
typedef struct {
  rdpContext base;
  HANDLE vcm;
  RdpdrServerContext* drive;
  UINT32 device, file;
  unsigned stage, unit;
  UINT32 offset, chunk;
  char buffer[16384];
} fixture_context;
static void check(BOOL ok, const char* operation) {
  if (!ok) { fprintf(stderr, "FAIL: %s\n", operation); SetEvent(failed); }
}
static void closed(RdpdrServerContext* drive, void* data, UINT32 status) {
  (void)data;
  fixture_context* c = drive->data;
  check(status == 0, "close redirected file");
  if (c->stage == 1) {
    c->stage = 2;
    check(drive->DriveOpenFile(drive, NULL, c->device, "\\收到的文件.txt",
      GENERIC_READ | GENERIC_WRITE, FILE_OVERWRITE_IF) == 0, "create remote download");
  } else {
    c->stage = 3;
    check(drive->DriveOpenFile(drive, NULL, c->device, "\\..\\outside.txt", GENERIC_READ, FILE_OPEN) == 0, "request outside path for refusal");
  }
}
static BYTE expected(UINT32 offset, const char* header, size_t size, BOOL reverse) {
  if (offset < size) return (BYTE)header[offset];
  BYTE value = (BYTE)(offset - size);
  return reverse ? (BYTE)(255 - value) : value;
}
static void write_chunk(RdpdrServerContext* drive) {
  fixture_context* c = drive->data;
  const UINT32 left = 1024 * 1024 + sizeof(download) - 1 - c->offset;
  c->chunk = left < sizeof(c->buffer) ? left : sizeof(c->buffer);
  for (UINT32 i = 0; i < c->chunk; i++)
    c->buffer[i] = (char)expected(c->offset + i, download, sizeof(download) - 1, TRUE);
  check(drive->DriveWriteFile(drive, NULL, c->device, c->file, c->buffer, c->chunk, c->offset) == 0, "write download chunk");
}
static void written(RdpdrServerContext* drive, void* data, UINT32 status, UINT32 length) {
  (void)data;
  fixture_context* c = drive->data;
  check(status == 0 && length == c->chunk, "write redirected file contents");
  c->offset += length;
  if (c->offset < 1024 * 1024 + sizeof(download) - 1) write_chunk(drive);
  else check(drive->DriveCloseFile(drive, NULL, c->device, c->file) == 0, "close download");
}
static void read_file(RdpdrServerContext* drive, void* data, UINT32 status,
    const char* buffer, UINT32 length) {
  (void)data;
  fixture_context* c = drive->data;
  if (c->stage == 3) {
    check(status != 0 && length == 0, "outside-directory contents must not be readable");
    if (status != 0 && length == 0) {
      puts("PASS: 1 MiB bidirectional binary files, Chinese names, outside-directory access refused");
      fflush(stdout); SetEvent(files_done);
    }
    return;
  }
  const UINT32 left = 1024 * 1024 + sizeof(upload) - 1 - c->offset;
  check(status == 0 && length > 0 && length <= left, "read upload chunk length");
  for (UINT32 i = 0; i < length; i++) {
    if ((BYTE)buffer[i] != expected(c->offset + i, upload, sizeof(upload) - 1, FALSE)) {
      check(FALSE, "uploaded binary content integrity"); return;
    }
  }
  c->offset += length;
  if (c->offset < 1024 * 1024 + sizeof(upload) - 1)
    check(drive->DriveReadFile(drive, NULL, c->device, c->file, sizeof(c->buffer), c->offset) == 0, "read next upload chunk");
  else check(drive->DriveCloseFile(drive, NULL, c->device, c->file) == 0, "close upload");
}
static void opened(RdpdrServerContext* drive, void* data, UINT32 status,
    UINT32 device, UINT32 file) {
  (void)data;
  fixture_context* c = drive->data;
  if (c->stage == 3) {
    check(drive->DriveReadFile(drive, NULL, device, file, sizeof(c->buffer), 0) == 0, "verify outside file cannot be read");
    return;
  }
  check(status == 0, "open redirected file");
  if (status) return;
  c->file = file; c->offset = 0;
  if (c->stage == 1)
    check(drive->DriveReadFile(drive, NULL, device, file, sizeof(c->buffer), 0) == 0, "read upload");
  else write_chunk(drive);
}
static UINT announced(RdpdrServerContext* drive, const RdpdrDevice* device) {
  fixture_context* c = drive->data;
  check(memcmp(device->PreferredDosName, "LRDP", 4) == 0, "only explicitly shared LRDP drive");
  c->device = device->DeviceId; c->stage = 1;
  return drive->DriveOpenFile(drive, NULL, c->device, "\\上传测试.txt", GENERIC_READ, FILE_OPEN);
}
static BOOL unicode_key(rdpInput* input, UINT16 flags, UINT16 code) {
  fixture_context* c = (fixture_context*)input->context;
  if (c->unit >= sizeof(chinese)/sizeof(chinese[0]) * 2) return FALSE;
  check(code == chinese[c->unit / 2] && !!(flags & 0x8000) == (c->unit % 2), "Unicode key down/up order");
  c->unit++;
  if (c->unit == sizeof(chinese)/sizeof(chinese[0]) * 2) {
    puts("PASS: server received 中文输入 Unicode key down/up events");
    fflush(stdout); SetEvent(text_done);
  }
  return TRUE;
}
static BOOL context_new(freerdp_peer* peer, rdpContext* context) {
  fixture_context* c = (fixture_context*)context;
  c->vcm = WTSOpenServerA((LPSTR)peer->context);
  if (!c->vcm || c->vcm == INVALID_HANDLE_VALUE) return FALSE;
  c->drive = rdpdr_server_context_new(c->vcm);
  if (!c->drive) return FALSE;
  c->drive->data = c;
  c->drive->supported = RDPDR_DTYP_FILESYSTEM;
  c->drive->OnDriveCreate = announced;
  c->drive->OnDriveOpenFileComplete = opened;
  c->drive->OnDriveReadFileComplete = read_file;
  c->drive->OnDriveWriteFileComplete = written;
  c->drive->OnDriveCloseFileComplete = closed;
  return TRUE;
}
static void context_free(freerdp_peer* peer, rdpContext* context) {
  (void)peer;
  fixture_context* c = (fixture_context*)context;
  if (c->drive) { c->drive->Stop(c->drive); rdpdr_server_context_free(c->drive); }
  if (c->vcm && c->vcm != INVALID_HANDLE_VALUE) WTSCloseServer(c->vcm);
}
static BOOL post_connect(freerdp_peer* peer) {
  fixture_context* c = (fixture_context*)peer->context;
  return c->drive->Start(c->drive) == 0;
}
static BOOL accepted(freerdp_listener* listener, freerdp_peer* peer) {
  (void)listener;
  peer->ContextSize = sizeof(fixture_context);
  peer->ContextNew = context_new; peer->ContextFree = context_free;
  if (!freerdp_peer_context_new(peer)) { freerdp_peer_free(peer); return TRUE; }
  rdpSettings* settings = peer->context->settings;
  rdpPrivateKey* key = freerdp_key_new_from_file_enc(key_path, NULL);
  rdpCertificate* cert = freerdp_certificate_new_from_file(certificate_path);
  BOOL configured = key && cert &&
    freerdp_settings_set_pointer_len(settings, FreeRDP_RdpServerRsaKey, key, 1) &&
    freerdp_settings_set_pointer_len(settings, FreeRDP_RdpServerCertificate, cert, 1) &&
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
    freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, FALSE) &&
    freerdp_settings_set_bool(settings, FreeRDP_NSCodec, FALSE) &&
    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);
  peer->PostConnect = post_connect;
  peer->context->input->UnicodeKeyboardEvent = unicode_key;
  fixture_context* c = (fixture_context*)peer->context;
  if (configured && peer->Initialize(peer)) {
    const UINT64 deadline = GetTickCount64() + io_timeout_ms;
    while (GetTickCount64() < deadline && WaitForSingleObject(failed, 0) != WAIT_OBJECT_0) {
      HANDLE completion[] = { files_done, text_done };
      if (WaitForMultipleObjects(2, completion, TRUE, 0) == WAIT_OBJECT_0) break;
      HANDLE handles[32];
      DWORD count = peer->GetEventHandles(peer, handles, 31);
      if (!count) break;
      handles[count++] = WTSVirtualChannelManagerGetEventHandle(c->vcm);
      if (WaitForMultipleObjects(count, handles, FALSE, 50) == WAIT_FAILED) break;
      if (!peer->CheckFileDescriptor(peer) || !WTSVirtualChannelManagerCheckFileDescriptor(c->vcm)) break;
    }
  }
  peer->Disconnect(peer);
  freerdp_peer_context_free(peer); freerdp_peer_free(peer);
  return TRUE;
}
int main(int argc, char** argv) {
  if (argc != 4 && argc != 5) return 2;
  if (argc == 5) {
    char* end = NULL;
    unsigned long long timeout = strtoull(argv[4], &end, 10);
    if (!end || *end || timeout < 1000 || timeout > 300000) return 2;
    accept_timeout_ms = io_timeout_ms = (UINT64)timeout;
  }
  certificate_path = argv[2]; key_path = argv[3];
  if (!WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi()) || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) return 3;
  files_done = CreateEvent(NULL, TRUE, FALSE, NULL);
  text_done = CreateEvent(NULL, TRUE, FALSE, NULL);
  failed = CreateEvent(NULL, TRUE, FALSE, NULL);
  freerdp_listener* listener = freerdp_listener_new();
  if (!listener) return 4;
  listener->PeerAccepted = accepted;
  if (!listener->Open(listener, "127.0.0.1", (UINT16)atoi(argv[1]))) return 5;
  const UINT64 deadline = GetTickCount64() + accept_timeout_ms;
  HANDLE completion[] = { files_done, text_done };
  while (GetTickCount64() < deadline && WaitForSingleObject(failed, 0) != WAIT_OBJECT_0 &&
    WaitForMultipleObjects(2, completion, TRUE, 0) != WAIT_OBJECT_0) {
    HANDLE handles[32];
    DWORD count = listener->GetEventHandles(listener, handles, 32);
    if (!count || WaitForMultipleObjects(count, handles, FALSE, 100) == WAIT_FAILED ||
        !listener->CheckFileDescriptor(listener)) break;
  }
  listener->Close(listener); freerdp_listener_free(listener);
  int result = WaitForSingleObject(failed, 0) != WAIT_OBJECT_0 &&
    WaitForMultipleObjects(2, completion, TRUE, 0) == WAIT_OBJECT_0 ? 0 : 1;
  CloseHandle(files_done); CloseHandle(text_done); CloseHandle(failed);
  return result;
}
