/* Actual C ABI client; the harness redirects playback to a private audio sink. */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "lrdp.h"
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static void pause_ms(unsigned ms) { Sleep(ms); }
#else
#include <time.h>
static void pause_ms(unsigned ms) {
  struct timespec delay = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000};
  nanosleep(&delay, NULL);
}
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL: %s at %d\n", #x, __LINE__); goto fail; } } while (0)
static int wait_audio(lrdp_session* s, const char* desired) {
  for (unsigned i = 0; i < 250; i++) {
    char status[32];
    if (lrdp_read(s, 4, status, sizeof(status)) > 0 && strcmp(status, desired) == 0) return 1;
    if (lrdp_state(s) != LRDP_CONNECTED) return 0;
    pause_ms(20);
  }
  return 0;
}
int main(int argc, char** argv) {
  lrdp_session* s = NULL;
  if (argc != 6 && argc != 7) return 2;
  CHECK(lrdp_abi_version() == 5);
  s = lrdp_create(); CHECK(s);
  CHECK(lrdp_set(s, "host", "127.0.0.1"));
  CHECK(lrdp_set(s, "port", argv[1])); CHECK(lrdp_set(s, "fingerprint", argv[2]));
  CHECK(lrdp_set(s, "audio", argv[3])); CHECK(lrdp_set(s, "config_path", argv[4]));
  CHECK(lrdp_set(s, "nla", "0")); CHECK(lrdp_set(s, "username", "test"));
  CHECK(lrdp_set(s, "drive_path", argv[5]));
  CHECK(lrdp_audio_active(s, 1));
  CHECK(lrdp_start(s));
  for (unsigned i = 0; i < 500 && lrdp_state(s) == LRDP_CONNECTING; i++) pause_ms(20);
  if (lrdp_state(s) != LRDP_CONNECTED) {
    char error[512]; lrdp_read(s, 0, error, sizeof(error)); fprintf(stderr, "Connection: %s\n", error);
  }
  CHECK(lrdp_state(s) == LRDP_CONNECTED);
  if (argc == 7 && strcmp(argv[6], "lifecycle") == 0) {
    CHECK(wait_audio(s, "playing"));
    puts("{\"audio_stage\":\"playing\"}"); fflush(stdout);
    pause_ms(350);
    CHECK(lrdp_audio_active(s, 0)); CHECK(wait_audio(s, "paused"));
    puts("{\"audio_stage\":\"paused\"}"); fflush(stdout);
    pause_ms(3400);
    CHECK(lrdp_state(s) == LRDP_CONNECTED);
    CHECK(lrdp_audio_active(s, 1)); CHECK(wait_audio(s, "playing"));
    puts("{\"audio_stage\":\"resumed\"}"); fflush(stdout);
    pause_ms(2600);
  } else pause_ms(4000);
  CHECK(lrdp_state(s) == LRDP_CONNECTED);
  lrdp_stop(s); lrdp_destroy(s);
  puts("PASS: audio preference, live desktop channel and clean cancellation"); return 0;
fail:
  if (s) lrdp_destroy(s);
  return 1;
}
