#include "lrdp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#define PAUSE() Sleep(10)
#else
#include <time.h>
#define PAUSE() nanosleep(&(struct timespec){.tv_nsec = 10000000}, NULL)
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"Cursor failed stage %d line %d: %s\n",stage,__LINE__,#x); result=1; goto done; } } while(0)
int main(int argc, char** argv) {
  if (argc != 3) return 2;
  int result = 0, stage = -1; lrdp_session* s = lrdp_create();
  unsigned char* pixels = malloc(384 * 384 * 8); int32_t info[9]; uint64_t generation = 0;
  CHECK(s && pixels && lrdp_abi_version() == 5);
  CHECK(lrdp_set(s,"host","127.0.0.1") && lrdp_set(s,"port",argv[1]) &&
    lrdp_set(s,"nla","0") && lrdp_set(s,"fingerprint",argv[2]) && lrdp_start(s));
  int32_t shape = -1;
  for (stage=0;stage<=8;stage++) {
    int changed=0;
    for (int i=0;i<2500;i++) {
      int n = lrdp_cursor(s,pixels,384*384*8,info,&generation);
      CHECK(n >= 0);
      if (n && (stage == 0 ? info[0] == LRDP_CURSOR_BITMAP : 1)) { changed=1; break; }
      CHECK(lrdp_state(s) < LRDP_CLOSED); PAUSE();
    }
    CHECK(changed);
    if (stage==1) CHECK(info[0]==LRDP_CURSOR_HIDDEN);
    else if (stage==5) CHECK(info[0]==LRDP_CURSOR_DEFAULT);
    else {
      CHECK(info[0]==LRDP_CURSOR_BITMAP);
      int side=stage>=7?384:(stage==0||stage==2)?8:16;
      CHECK(info[1]==side && info[2]==side);
      size_t plane=(size_t)side*side*4;
      if (stage==0||stage==2) {
        CHECK(info[3]==3 && info[4]==5);
        CHECK(pixels[0]==20 && pixels[1]==50 && pixels[2]==100 && pixels[3]==128);
      } else if (stage>=7) CHECK(pixels[0]==0x66 && pixels[1]==0x44 && pixels[2]==0x22 && pixels[3]==255);
      else {
        CHECK(pixels[0]==0 && pixels[3]==255);
        CHECK(pixels[4]==255 && pixels[7]==255);
        CHECK(pixels[11]==0 && pixels[15]==0);
        CHECK(pixels[plane+15]==255 && pixels[plane+3]==0);
      }
      if (stage==4) CHECK(info[5]==123 && info[6]==77 && info[7]!=0 && info[8]==shape);
      shape=info[8];
      uint64_t probe=0; int32_t untouched[9]; memset(untouched,0x55,sizeof(untouched));
      CHECK(lrdp_cursor(s,NULL,0,untouched,&probe)==-(int)(plane*2));
      CHECK(probe==0 && untouched[0]==0x55555555);
    }
    CHECK(lrdp_cursor(s,pixels,384*384*8,info,&generation)==0);
    CHECK(lrdp_input(s,1,0,0x1e,0) && lrdp_input(s,1,0x8000,0x1e,0));
  }
  for (int i=0;i<1000 && lrdp_state(s)<LRDP_CLOSED;i++) PAUSE();
  CHECK(lrdp_state(s)==LRDP_CLOSED && lrdp_end_reason(s)==LRDP_END_REMOTE);
  puts("PASS: TLS cursor alpha, monochrome/color XOR, cache, null/default, server position, 384x384 and capacity/generation semantics");
done:
  lrdp_destroy(s); free(pixels); return result;
}
