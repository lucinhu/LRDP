#include "lrdp.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "Failed: %s at %d\n", #x, __LINE__); return 1; } } while (0)
static int lifecycle(const char* transfer_directory) {
  CHECK(lrdp_abi_version() == 5);
  CHECK(lrdp_end_reason(NULL) == LRDP_END_CONFIGURATION);
  CHECK(strlen(lrdp_version()) > 0);
  CHECK(!lrdp_initialize(NULL)); CHECK(!lrdp_initialize(""));
  CHECK(lrdp_initialize("."));
  CHECK(lrdp_state(NULL) == LRDP_FAILED);
  CHECK(!lrdp_audio_active(NULL, 1));
  lrdp_destroy(NULL);
  for (int i = 0; i < 20; i++) {
    lrdp_session* s = lrdp_create(); CHECK(s);
    CHECK(lrdp_state(s) == LRDP_IDLE);
    CHECK(lrdp_end_reason(s) == LRDP_END_NONE);
    char paste_status[32];
    CHECK(lrdp_read(s, 3, paste_status, sizeof(paste_status)) == 4);
    CHECK(strcmp(paste_status, "idle") == 0);
    CHECK(lrdp_read(s, 99, paste_status, sizeof(paste_status)) == -1);
    CHECK(!lrdp_paste(s, "not connected"));
    CHECK(!lrdp_paste(s, NULL)); CHECK(!lrdp_paste(s, ""));
    CHECK(!lrdp_paste_image(s, NULL, 0, NULL, 0));
    CHECK(!lrdp_paste_image(NULL, NULL, 0, NULL, 0));
    CHECK(lrdp_read_image(s, NULL, 0, NULL) == 0);
    CHECK(lrdp_read_image(NULL, NULL, 0, NULL) == 0);
    CHECK(!lrdp_set(s, "unknown", "1"));
    CHECK(!lrdp_audio_active(s, -1)); CHECK(!lrdp_audio_active(s, 2));
    CHECK(lrdp_audio_active(s, 0)); CHECK(lrdp_audio_active(s, 1));
    CHECK(lrdp_read(s, 4, paste_status, sizeof(paste_status)) == 3);
    CHECK(strcmp(paste_status, "off") == 0);
    CHECK(!lrdp_set(s, "audio", "2")); CHECK(!lrdp_set(s, "audio", "-1"));
    CHECK(lrdp_set(s, "audio", "0"));
    CHECK(!lrdp_set(s, "drive_path", "."));
    CHECK(lrdp_set(s, "drive_path", ""));
    if (i == 0) {
      CHECK(lrdp_set(s, "drive_path", transfer_directory));
      CHECK(!lrdp_set(s, "drive_path", transfer_directory));
    }
    CHECK(!lrdp_set(s, "port", "0")); CHECK(!lrdp_set(s, "port", "65536"));
    CHECK(!lrdp_set(s, "width", "99999999")); CHECK(!lrdp_set(s, "height", "-1"));
    CHECK(!lrdp_set(s, "width", "200garbage"));
    CHECK(lrdp_set(s, "host", "127.0.0.1")); CHECK(lrdp_set(s, "port", "1"));
    CHECK(lrdp_set(s, "username", "test")); CHECK(lrdp_set(s, "password", "secret"));
    CHECK(lrdp_set(s, "width", "1280")); CHECK(lrdp_set(s, "height", "800"));
    CHECK(!lrdp_input(s, 0, 0, 0, 0));
    if (i % 2) { CHECK(lrdp_start(s)); CHECK(!lrdp_start(s)); CHECK(!lrdp_set(s, "port", "3389")); }
    lrdp_stop(s); CHECK(!lrdp_audio_active(s, 1)); lrdp_destroy(s);
  }
  puts("bridge lifecycle, validation and cancellation passed"); return 0;
}
#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
  CHECK(argc == 2);
  /* Match Dart's UTF-8 ABI even when the process ANSI code page is not UTF-8. */
  int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[1], -1,
                                  NULL, 0, NULL, NULL);
  CHECK(length > 0);
  char* directory = malloc((size_t)length);
  CHECK(directory);
  int converted = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[1], -1,
                                     directory, length, NULL, NULL);
  int result = converted == length ? lifecycle(directory) : 1;
  free(directory);
  return result;
}
#else
int main(int argc, char** argv) {
  CHECK(argc == 2);
  return lifecycle(argv[1]);
}
#endif
