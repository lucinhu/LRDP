#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "lrdp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static unsigned long long now(void) { return GetTickCount64(); }
static void pause_ms(unsigned ms) { Sleep(ms); }
#else
#include <time.h>
static unsigned long long now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (unsigned long long)t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void pause_ms(unsigned ms) { struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000}; nanosleep(&t, NULL); }
#endif
#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); goto fail; } } while (0)
int main(int argc, char** argv) {
  lrdp_session* session = NULL;
  if (argc != 5) return 2;
  CHECK(lrdp_abi_version() == 5);
  session = lrdp_create(); CHECK(session);
  CHECK(lrdp_set(session, "host", "127.0.0.1")); CHECK(lrdp_set(session, "port", argv[1]));
  CHECK(lrdp_set(session, "fingerprint", argv[2])); CHECK(lrdp_set(session, "config_path", argv[3]));
  CHECK(lrdp_set(session, "nla", "0")); CHECK(lrdp_set(session, "username", "test"));
  CHECK(lrdp_set(session, "clipboard", "0")); CHECK(lrdp_start(session));
  unsigned long long deadline = now() + 10000;
  while (lrdp_state(session) == LRDP_CONNECTING && now() < deadline) pause_ms(10);
  CHECK(lrdp_state(session) == LRDP_CONNECTED);
  /* Use the same combined input flags as the Flutter surface. A peer using
   * KRDP's DOWN / MOVE / RELEASE precedence must see a complete drag and
   * subsequent left, right and middle clicks before testing shutdown. */
  CHECK(lrdp_input(session, 0, 0x9800, 120, 80));
  CHECK(lrdp_input(session, 0, 0x0800, 180, 120));
  CHECK(lrdp_input(session, 0, 0x1800, 200, 140));
  for (unsigned button = 0x1000, x = 260; button <= 0x4000; button <<= 1, x += 20) {
    CHECK(lrdp_input(session, 0, 0x8800 | button, (int)x, 160));
    CHECK(lrdp_input(session, 0, 0x0800 | button, (int)x, 160));
  }
  int32_t info[9]; uint64_t generation = 0;
  int preflight = 0; deadline = now() + 10000;
  while (now() < deadline && lrdp_state(session) == LRDP_CONNECTED) {
    if (lrdp_cursor(session, NULL, 0, info, &generation) > 0 && info[5] == 77 && info[6] == 98) { preflight = 1; break; }
    pause_ms(10);
  }
  CHECK(preflight);
  const unsigned scans[] = {0x1e, 0x1d, 0x2a, 0x11d, 0x138, 0x15b};
  for (unsigned i = 0; i < 6; i++) CHECK(lrdp_input(session, 1, scans[i] & 0x300, scans[i] & 0xff, 0));
  CHECK(lrdp_input(session, 1, 0x4000, 0x1e, 0)); /* repeat must not need two ups */
  CHECK(lrdp_input(session, 1, 0, 0x30, 0)); CHECK(lrdp_input(session, 1, 0x8000, 0x30, 0));
  const unsigned unicode[] = {0x4e2d, 0xd83d, 0xde42};
  for (unsigned i = 0; i < 3; i++) CHECK(lrdp_input(session, 2, 0, unicode[i], 0));
  for (unsigned button = 0x1000; button <= 0x4000; button <<= 1)
    CHECK(lrdp_input(session, 0, 0x8800 | button, 320, 180));
  CHECK(lrdp_input(session, 0, 0x0800, 330, 190));
  CHECK(lrdp_input(session, 0, 0x0200 | 120, 0, 0));
  int acknowledged = 0; deadline = now() + 10000;
  while (now() < deadline && lrdp_state(session) == LRDP_CONNECTED) {
    if (lrdp_cursor(session, NULL, 0, info, &generation) > 0 && info[5] == 77 && info[6] == 99) { acknowledged = 1; break; }
    pause_ms(10);
  }
  CHECK(acknowledged);
  int pressure = strcmp(argv[4], "blocked") == 0;
  unsigned long long full_since = 0; unsigned accepted = 0;
  if (pressure) {
    /* Wine's TCP buffering can need more than eight seconds to fill. The
     * oracle still requires a continuously full queue for 300 ms; only the
     * setup budget changes, never the two-second stop bound below. */
    deadline = now() + 20000;
    while (now() < deadline) {
      if (lrdp_input(session, 0, 0x0800, 330, 190)) { accepted++; full_since = 0; }
      else {
        if (!full_since) full_since = now();
        if (now() - full_since >= 300) break;
        pause_ms(1);
      }
    }
    fprintf(stderr, "pressure inputs=%u, continuously full=%llu ms\n", accepted,
      full_since ? now() - full_since : 0);
    CHECK(full_since && now() - full_since >= 300);
    CHECK(lrdp_state(session) == LRDP_CONNECTED);
  }
  unsigned long long began = now();
  lrdp_stop(session); lrdp_stop(session);
  CHECK(!lrdp_input(session, 1, 0, 0x1e, 0));
  deadline = now() + 2000;
  while (lrdp_state(session) == LRDP_CONNECTED && now() < deadline) pause_ms(10);
  CHECK(lrdp_state(session) == LRDP_CLOSED);
  CHECK(lrdp_end_reason(session) == LRDP_END_LOCAL);
  lrdp_destroy(session); session = NULL;
  unsigned long long elapsed = now() - began; CHECK(elapsed < 2000);
  printf("{\"passed\":true,\"mode\":\"%s\",\"stop_ms\":%llu,\"pressure_inputs\":%u}\n", argv[4], elapsed, accepted);
  return 0;
fail:
  if (session) lrdp_destroy(session);
  return 1;
}
