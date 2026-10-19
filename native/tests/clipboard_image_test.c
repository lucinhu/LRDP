#include "clipboard_image.h"
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
static void le(uint8_t* p, uint32_t n) { for (int i=0;i<4;i++) p[i]=(uint8_t)(n>>(8*i)); }
int main(void) {
  uint8_t png[33] = {137,80,78,71,13,10,26,10,0,0,0,13,'I','H','D','R',0,0,0,3,0,0,0,2};
  uint32_t w=0,h=0;
  CHECK(lrdp_image_dimensions(png,sizeof(png),1,&w,&h) && w==3 && h==2);
  for (size_t i=0;i<33;i++) CHECK(!lrdp_image_dimensions(png,i,1,NULL,NULL));
  png[16]=1; CHECK(!lrdp_image_dimensions(png,sizeof(png),1,NULL,NULL)); png[16]=0;
  CHECK(!lrdp_image_dimensions(png,LRDP_IMAGE_MAX_BYTES+1,1,NULL,NULL));
  CHECK(!lrdp_image_dimensions(NULL,33,1,NULL,NULL));
  uint8_t dib[160] = {0};
  le(dib,40); le(dib+4,3); le(dib+8,2); dib[12]=1; dib[14]=24;
  CHECK(lrdp_image_dimensions(dib,64,2,&w,&h) && w==3 && h==2);
  CHECK(!lrdp_image_dimensions(dib,63,2,NULL,NULL));
  le(dib+8,(uint32_t)-2); CHECK(lrdp_image_dimensions(dib,64,2,NULL,NULL));
  le(dib+8,0x80000000); CHECK(!lrdp_image_dimensions(dib,64,2,NULL,NULL));
  le(dib+8,2); le(dib+4,4096); CHECK(!lrdp_image_dimensions(dib,64,2,NULL,NULL)); le(dib+4,3);
  le(dib+16,1); CHECK(!lrdp_image_dimensions(dib,64,2,NULL,NULL)); le(dib+16,0);
  le(dib+32,1); CHECK(!lrdp_image_dimensions(dib,64,2,NULL,NULL)); le(dib+32,0);
  dib[14]=32; le(dib+16,3); le(dib+40,0xff0000); le(dib+44,0xff00); le(dib+48,0xff);
  CHECK(lrdp_image_dimensions(dib,76,2,NULL,NULL));
  CHECK(!lrdp_image_dimensions(dib,75,2,NULL,NULL));
  le(dib+48,0xf); CHECK(!lrdp_image_dimensions(dib,76,2,NULL,NULL)); le(dib+48,0xff);
  le(dib,124); le(dib+52,0xff000000); CHECK(lrdp_image_dimensions(dib,148,2,NULL,NULL));
  le(dib+112,124); CHECK(!lrdp_image_dimensions(dib,148,2,NULL,NULL));
  le(dib+112,0); le(dib+52,0x0f000000); CHECK(!lrdp_image_dimensions(dib,148,2,NULL,NULL));
  CHECK(!lrdp_image_dimensions(dib,148,3,NULL,NULL));
  puts("PASS: bounded PNG/DIB headers, strides, masks, profiles and dimensions"); return 0;
}
