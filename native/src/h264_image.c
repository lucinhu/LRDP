#include "h264_image.h"
#include <string.h>

static int add(size_t a, size_t b, size_t* result) {
  if (a > SIZE_MAX - b) return 0;
  *result = a + b;
  return 1;
}
static int multiply(size_t a, size_t b, size_t* result) {
  if (b && a > SIZE_MAX / b) return 0;
  *result = a * b;
  return 1;
}
static int layout(size_t capacity, size_t row_stride, size_t pixel_stride,
                  size_t x, size_t y, size_t width, size_t height,
                  size_t* offset) {
  size_t last_x, last_y, row_end, end, x_offset, y_offset;
  if (!capacity || !row_stride || !pixel_stride || !width || !height ||
      !add(x, width - 1, &last_x) || !add(y, height - 1, &last_y) ||
      !multiply(last_x, pixel_stride, &row_end) || !add(row_end, 1, &row_end) ||
      row_end > row_stride || !multiply(last_y, row_stride, &end) ||
      !add(end, row_end, &end) || end > capacity ||
      !multiply(x, pixel_stride, &x_offset) || !multiply(y, row_stride, &y_offset) ||
      !add(x_offset, y_offset, offset)) return 0;
  return 1;
}
int lrdp_h264_image_copy_i420(const lrdp_h264_image_plane planes[3],
                            size_t crop_left, size_t crop_top,
                            size_t width, size_t height,
                            const lrdp_h264_image_output output[3]) {
  if (!planes || !output || !width || !height) return -1;
  const size_t widths[3] = {width, width / 2 + width % 2, width / 2 + width % 2};
  const size_t heights[3] = {height, height / 2 + height % 2, height / 2 + height % 2};
  size_t offsets[3], ignored;
  for (int p = 0; p < 3; p++) {
    if (!planes[p].data || !output[p].data ||
        !layout(planes[p].capacity, planes[p].row_stride, planes[p].pixel_stride,
                p ? crop_left / 2 : crop_left, p ? crop_top / 2 : crop_top,
                widths[p], heights[p], &offsets[p]) ||
        !layout(output[p].capacity, output[p].row_stride, 1, 0, 0,
                widths[p], heights[p], &ignored)) return -1;
  }
  for (int p = 0; p < 3; p++) {
    const uint8_t* source = planes[p].data + offsets[p];
    uint8_t* destination = output[p].data;
    for (size_t y = 0; y < heights[p]; y++) {
      const uint8_t* row = source + y * planes[p].row_stride;
      uint8_t* out = destination + y * output[p].row_stride;
      if (planes[p].pixel_stride == 1) memcpy(out, row, widths[p]);
      else for (size_t x = 0; x < widths[p]; x++) out[x] = row[x * planes[p].pixel_stride];
    }
  }
  return 1;
}
