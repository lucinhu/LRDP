/* Portable client for sanitizer and Windows PE clipboard protocol gates. */
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
  struct timespec delay = { (time_t)(ms / 1000), (long)(ms % 1000) * 1000000 };
  nanosleep(&delay, NULL);
}
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL: %s at %d\n", #x, __LINE__); goto fail; } } while (0)
int main(int argc, char** argv) {
  lrdp_session* session = NULL;
  if (argc != 5) return 2;
  CHECK(lrdp_abi_version() == 5);
  session = lrdp_create(); CHECK(session);
  CHECK(lrdp_set(session, "host", "127.0.0.1"));
  CHECK(lrdp_set(session, "port", argv[1]));
  CHECK(lrdp_set(session, "fingerprint", argv[2]));
  CHECK(lrdp_set(session, "config_path", argv[4]));
  CHECK(lrdp_set(session, "username", "test"));
  CHECK(lrdp_set(session, "nla", "0"));
  CHECK(lrdp_set(session, "clipboard", "1"));
  CHECK(lrdp_start(session));
  for (unsigned i = 0; i < 500 && lrdp_state(session) == LRDP_CONNECTING; i++) pause_ms(20);
  CHECK(lrdp_state(session) == LRDP_CONNECTED);
  for (unsigned i = 0; i < 500 && !(lrdp_features(session) & 1); i++) pause_ms(20);
  CHECK(lrdp_features(session) & 1);
  CHECK(lrdp_paste(session, "LRDP 中文输入验证 你好"));
  CHECK(!lrdp_paste(session, "duplicate"));
  CHECK(!lrdp_clipboard(session, "must not replace pending paste"));
  if (strcmp(argv[3], "cancel") == 0) pause_ms(50);
  else {
    char status[32] = {0};
    for (unsigned i = 0; i < 350; i++) {
      CHECK(lrdp_read(session, 3, status, sizeof(status)) > 0);
      if (strcmp(status, "pending") != 0) break;
      pause_ms(20);
    }
    const char* expected = strcmp(argv[3], "normal") == 0 || strcmp(argv[3], "prefetch") == 0
      ? "sent" : strcmp(argv[3], "reject") == 0 ? "rejected" : "timeout";
    if (strcmp(status, expected) != 0) fprintf(stderr, "status=%s, expected=%s\n", status, expected);
    CHECK(strcmp(status, expected) == 0);
    CHECK(lrdp_state(session) == LRDP_CONNECTED);
  }
  lrdp_destroy(session);
  puts("PASS: bounded clipboard paste client"); return 0;
fail:
  lrdp_destroy(session); return 1;
}
