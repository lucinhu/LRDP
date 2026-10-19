#include "lrdp.h"
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static void check(int ok, const char* message, lrdp_session* session) {
  if (ok) return;
  char error[4096] = {0};
  if (session) lrdp_read(session, 0, error, sizeof(error));
  fprintf(stderr, "FAIL: %s: %s\n", message, error);
  if (session) lrdp_destroy(session);
  exit(1);
}

static void line(FILE* file, char* out, size_t size) {
  check(fgets(out, (int)size, file) != NULL, "Missing fixture configuration", NULL);
  out[strcspn(out, "\r\n")] = 0;
  check(out[0] != 0, "Empty fixture configuration", NULL);
}

static lrdp_session* connect_to(const char* port, const char* pin,
                               const char* directory, const char* drive,
                               int nla, const char* password) {
  lrdp_session* s = lrdp_create();
  check(s != NULL, "Create Windows session", NULL);
  const char* keys[] = {"host", "port", "username", "password", "nla", "domain",
                         "width", "height", "fingerprint", "config_path"};
  const char* values[] = {"127.0.0.1", port, nla ? "lrdptest" : "test", password,
                           nla ? "1" : "0", "", "1280", "800", pin, directory};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    check(lrdp_set(s, keys[i], values[i]), keys[i], s);
  if (drive) check(lrdp_set(s, "drive_path", drive), "UTF-8 Windows drive path", s);
  check(lrdp_start(s), "Start Windows session", s);
  ULONGLONG deadline = GetTickCount64() + 20000;
  while (lrdp_state(s) == LRDP_CONNECTING && GetTickCount64() < deadline) Sleep(20);
  return s;
}

static void color(lrdp_session* s, BYTE* data, uint64_t* generation,
                  int blue, int green, int red) {
  ULONGLONG deadline = GetTickCount64() + 30000;
  int last[4] = {-1, -1, -1, -1};
  while (GetTickCount64() < deadline) {
    int32_t width = 0, height = 0;
    int bytes = lrdp_frame(s, data, 4096u * 4096u * 4u, &width, &height, generation);
    check(lrdp_state(s) == LRDP_CONNECTED, "Connection during graphics", s);
    if (bytes > 0) {
      check(width == 1280 && height == 800 && bytes == 1280 * 800 * 4,
            "Real desktop dimensions", s);
      BYTE* pixel = data + (400 * width + 640) * 4;
      for (int i = 0; i < 4; i++) last[i] = pixel[i];
      BOOL avc = (lrdp_features(s) & 4) != 0;
      int tolerance = avc ? 4 : 2;
      if (abs(pixel[0] - blue) <= tolerance && abs(pixel[1] - green) <= tolerance &&
          abs(pixel[2] - red) <= tolerance && pixel[3] == 255 &&
          (!getenv("LRDP_TEST_CODEC") || avc)) {
        printf("PASS: palette BGRA=%d,%d,%d,%d avc_decoded=%d tolerance=%d\n",
          last[0], last[1], last[2], last[3], avc, tolerance); fflush(stdout);
        return;
      }
    }
    Sleep(20);
  }
  fprintf(stderr, "Expected BGRA=%d,%d,%d,255 last=%d,%d,%d,%d features=%d\n",
    blue, green, red, last[0], last[1], last[2], last[3], lrdp_features(s));
  check(0, "Live server palette not received", s);
}

int main(int argc, char** argv) {
  check(argc == 2, "Expected private fixture configuration path", NULL);
  FILE* configuration = fopen(argv[1], "rb");
  check(configuration != NULL, "Open private fixture configuration", NULL);
  char graphics_port[16], file_port[16], nla_port[16], file_pin[128];
  char directory[4096], drive[4096], marker[4096];
  line(configuration, graphics_port, sizeof(graphics_port));
  line(configuration, file_port, sizeof(file_port));
  line(configuration, file_pin, sizeof(file_pin));
  line(configuration, directory, sizeof(directory));
  line(configuration, drive, sizeof(drive));
  line(configuration, marker, sizeof(marker));
  line(configuration, nla_port, sizeof(nla_port));
  fclose(configuration);
  check(lrdp_initialize(directory), "Initialize private Windows storage", NULL);
  check(strstr(lrdp_version(), "3.32.2") != NULL, "Pinned FreeRDP version", NULL);

  lrdp_session* s = connect_to(graphics_port, "", directory, NULL, 0, "");
  check(lrdp_state(s) == LRDP_CERTIFICATE_REQUIRED, "Untrusted certificate rejection", s);
  char pin[128] = {0};
  check(lrdp_read(s, 1, pin, sizeof(pin)) == 95, "SHA-256 fingerprint", s);
  lrdp_destroy(s);
  puts("PASS: Windows DLL rejects untrusted certificate"); fflush(stdout);

  char wrong[128];
  memcpy(wrong, pin, sizeof(wrong));
  wrong[0] = wrong[0] == '0' ? '1' : '0';
  s = connect_to(graphics_port, wrong, directory, NULL, 0, "");
  check(lrdp_state(s) == LRDP_CERTIFICATE_REQUIRED, "Wrong certificate pin rejection", s);
  lrdp_destroy(s);
  puts("PASS: Windows DLL rejects wrong pin"); fflush(stdout);

  s = connect_to(graphics_port, pin, directory, NULL, 0, "");
  check(lrdp_state(s) == LRDP_CONNECTED, "Pinned Windows TLS connection", s);
  BYTE* pixels = malloc(4096u * 4096u * 4u);
  check(pixels != NULL, "Allocate frame snapshot", s);
  uint64_t generation = 0;
  color(s, pixels, &generation, 0x28, 0x2d, 0x18);
  check(lrdp_input(s, 0, 0x0800, 80, 80), "Mouse motion", s);
  check(lrdp_input(s, 1, 0, 0x1e, 0), "A press", s);
  check(lrdp_input(s, 1, 0x8000, 0x1e, 0), "A release", s);
  check(lrdp_input(s, 0, 0x9000, 80, 80), "Mouse press", s);
  check(lrdp_input(s, 0, 0x1000, 80, 80), "Mouse release", s);
  FILE* ready = fopen(marker, "wb");
  check(ready != NULL, "Write private graphics stage", s);
  fputs("input-ready", ready); fclose(ready);
  color(s, pixels, &generation, 0x65, 0x84, 0x2a);
  free(pixels);
  lrdp_destroy(s);
  puts("PASS: Windows DLL receives actual changed graphics and sends input"); fflush(stdout);

  s = connect_to(nla_port, "", directory, NULL, 1, "wrong-password");
  check(lrdp_state(s) == LRDP_CERTIFICATE_REQUIRED, "NLA first verifies certificate", s);
  memset(pin, 0, sizeof(pin));
  check(lrdp_read(s, 1, pin, sizeof(pin)) == 95, "NLA TLS fingerprint", s);
  lrdp_destroy(s);
  s = connect_to(nla_port, pin, directory, NULL, 1, "wrong-password");
  check(lrdp_state(s) == LRDP_FAILED, "NLA rejects wrong password", s);
  char authentication_error[4096] = {0};
  lrdp_read(s, 0, authentication_error, sizeof(authentication_error));
  for (size_t i = 0; authentication_error[i]; i++)
    authentication_error[i] = (char)tolower((unsigned char)authentication_error[i]);
  check(strstr(authentication_error, "log") != NULL || strstr(authentication_error, "auth") != NULL,
        "Wrong password returns an authentication error", s);
  lrdp_destroy(s);
  /* Disposable SAM identity only; no system account or user credential. */
  s = connect_to(nla_port, pin, directory, NULL, 1, "LRDP-test-password-2026");
  check(lrdp_state(s) == LRDP_CONNECTED, "NLA authenticates correct password", s);
  lrdp_destroy(s);
  puts("PASS: Windows DLL NLA wrong/correct credentials over pinned TLS"); fflush(stdout);

  s = connect_to(file_port, file_pin, directory, drive, 0, "");
  check(lrdp_state(s) == LRDP_CONNECTED, "Windows RDPDR TLS connection", s);
  int32_t width = 0, height = 0;
  generation = 0;
  check(lrdp_frame(s, NULL, 0, &width, &height, &generation) == 0,
        "No fabricated frame before server paint", s);
  const int chinese[] = {0x4e2d, 0x6587, 0x8f93, 0x5165};
  for (size_t i = 0; i < sizeof(chinese) / sizeof(chinese[0]); i++) {
    check(lrdp_input(s, 2, 0, chinese[i], 0), "Unicode press", s);
    check(lrdp_input(s, 2, 0x8000, chinese[i], 0), "Unicode release", s);
  }
  ULONGLONG deadline = GetTickCount64() + 30000;
  while (lrdp_state(s) == LRDP_CONNECTED && GetTickCount64() < deadline) Sleep(20);
  check(lrdp_state(s) != LRDP_CONNECTED, "File fixture completed", s);
  lrdp_destroy(s);
  puts("PASS: Windows DLL file/Unicode fixture session completed");
  return 0;
}
