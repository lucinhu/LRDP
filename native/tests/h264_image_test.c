#include "h264_image.h"
#include <stdio.h>
#include <string.h>
#define CHECK(test) do { if (!(test)) { \
  fprintf(stderr, "line %d: %s\n", __LINE__, #test); return 1; } } while (0)

static int planar_padding(void) {
  uint8_t y[24], u[8], v[8], out_y[21], out_u[10], out_v[10];
  memset(y, 0xee, sizeof(y)); memset(u, 0xee, sizeof(u)); memset(v, 0xee, sizeof(v));
  memset(out_y, 0xa5, sizeof(out_y)); memset(out_u, 0xa5, sizeof(out_u));
  memset(out_v, 0xa5, sizeof(out_v));
  for (size_t row = 0; row < 3; row++)
    for (size_t x = 0; x < 5; x++) y[row * 8 + x] = (uint8_t)(row * 10 + x);
  for (size_t row = 0; row < 2; row++)
    for (size_t x = 0; x < 3; x++) {
      u[row * 4 + x] = (uint8_t)(50 + row * 10 + x);
      v[row * 4 + x] = (uint8_t)(100 + row * 10 + x);
    }
  const lrdp_h264_image_plane source[3] = {{y, sizeof(y), 8, 1}, {u, sizeof(u), 4, 1}, {v, sizeof(v), 4, 1}};
  const lrdp_h264_image_output output[3] = {{out_y, sizeof(out_y), 7}, {out_u, sizeof(out_u), 5}, {out_v, sizeof(out_v), 5}};
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 5, 3, output) == 1);
  for (size_t row = 0; row < 3; row++) {
    CHECK(memcmp(out_y + row * 7, y + row * 8, 5) == 0);
    CHECK(out_y[row * 7 + 5] == 0xa5 && out_y[row * 7 + 6] == 0xa5);
  }
  for (size_t row = 0; row < 2; row++) {
    CHECK(memcmp(out_u + row * 5, u + row * 4, 3) == 0);
    CHECK(memcmp(out_v + row * 5, v + row * 4, 3) == 0);
    CHECK(out_u[row * 5 + 3] == 0xa5 && out_v[row * 5 + 4] == 0xa5);
  }
  return 0;
}
static int interleaved(void) {
  uint8_t y[16] = {0}, uv[] = {1, 11, 2, 12, 3, 13, 4, 14};
  uint8_t out_y[16], out_u[4], out_v[4];
  lrdp_h264_image_plane source[3] = {{y, sizeof(y), 4, 1}, {uv, 7, 4, 2}, {uv + 1, 7, 4, 2}};
  const lrdp_h264_image_output output[3] = {{out_y, 16, 4}, {out_u, 4, 2}, {out_v, 4, 2}};
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == 1);
  CHECK(memcmp(out_u, (uint8_t[]){1, 2, 3, 4}, 4) == 0);
  CHECK(memcmp(out_v, (uint8_t[]){11, 12, 13, 14}, 4) == 0);
  /* NV21 has reversed plane slices; no assumption about their address order. */
  source[1].data = uv + 1; source[2].data = uv;
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == 1);
  CHECK(memcmp(out_v, (uint8_t[]){1, 2, 3, 4}, 4) == 0);
  CHECK(memcmp(out_u, (uint8_t[]){11, 12, 13, 14}, 4) == 0);
  return 0;
}
static int cropped(void) {
  uint8_t y[36], u[9], v[9], out_y[9], out_u[4], out_v[4];
  for (int i = 0; i < 36; i++) y[i] = (uint8_t)i;
  for (int i = 0; i < 9; i++) { u[i] = (uint8_t)(50 + i); v[i] = (uint8_t)(100 + i); }
  const lrdp_h264_image_plane source[3] = {{y, 36, 6, 1}, {u, 9, 3, 1}, {v, 9, 3, 1}};
  const lrdp_h264_image_output output[3] = {{out_y, 9, 3}, {out_u, 4, 2}, {out_v, 4, 2}};
  CHECK(lrdp_h264_image_copy_i420(source, 2, 2, 3, 3, output) == 1);
  CHECK(memcmp(out_y, (uint8_t[]){14, 15, 16, 20, 21, 22, 26, 27, 28}, 9) == 0);
  CHECK(memcmp(out_u, (uint8_t[]){54, 55, 57, 58}, 4) == 0);
  CHECK(memcmp(out_v, (uint8_t[]){104, 105, 107, 108}, 4) == 0);
  CHECK(lrdp_h264_image_copy_i420(source, 1, 1, 3, 3, output) == 1);
  CHECK(memcmp(out_y, (uint8_t[]){7, 8, 9, 13, 14, 15, 19, 20, 21}, 9) == 0);
  CHECK(memcmp(out_u, (uint8_t[]){50, 51, 53, 54}, 4) == 0);
  return 0;
}
static int reject_without_write(void) {
  uint8_t input[16] = {0}, result[24];
  memset(result, 0xa5, sizeof(result));
  lrdp_h264_image_plane source[3] = {{input, 16, 4, 1}, {input, 4, 2, 1}, {input, 4, 2, 1}};
  lrdp_h264_image_output output[3] = {{result, 16, 4}, {result + 16, 4, 2}, {result + 20, 4, 2}};
  source[2].capacity = 3;
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == -1);
  for (size_t i = 0; i < sizeof(result); i++) CHECK(result[i] == 0xa5);
  source[2].capacity = 4;
  output[2].capacity = 3;
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == -1);
  output[2].capacity = 4;
  CHECK(lrdp_h264_image_copy_i420(source, 1, 0, 4, 4, output) == -1);
  CHECK(lrdp_h264_image_copy_i420(source, 0, 1, 4, 4, output) == -1);
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 0, 4, output) == -1);
  CHECK(lrdp_h264_image_copy_i420(NULL, 0, 0, 4, 4, output) == -1);
  source[0].pixel_stride = 0;
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == -1);
  source[0].pixel_stride = 2; /* Would overlap the next row. */
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == -1);
  source[0].pixel_stride = 1;
  CHECK(lrdp_h264_image_copy_i420(source, SIZE_MAX, 0, 4, 4, output) == -1);
  CHECK(lrdp_h264_image_copy_i420(source, 0, SIZE_MAX, 4, 4, output) == -1);
  source[0].row_stride = SIZE_MAX;
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == -1);
  source[0].pixel_stride = SIZE_MAX;
  CHECK(lrdp_h264_image_copy_i420(source, 0, 0, 4, 4, output) == -1);
  for (size_t i = 0; i < sizeof(result); i++) CHECK(result[i] == 0xa5);
  return 0;
}
int main(void) {
  if (planar_padding() || interleaved() || cropped() || reject_without_write()) return 1;
  puts("I420 image copy: planar, interleaved, crop, odd, padding and bounds passed");
  return 0;
}
