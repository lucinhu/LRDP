#ifndef LRDP_H264_IMAGE_H
#define LRDP_H264_IMAGE_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
  const uint8_t* data;
  size_t capacity;
  size_t row_stride;
  size_t pixel_stride;
} lrdp_h264_image_plane;
typedef struct {
  uint8_t* data;
  size_t capacity;
  size_t row_stride;
} lrdp_h264_image_output;

/* Copy Android YUV_420_888 planes to caller-owned I420. Plane data starts at
 * ByteBuffer.position(), not at the crop origin. Chroma uses floor(origin/2)
 * and ceil(size/2), including odd dimensions/origins. Output must not alias
 * input. All three source/destination layouts are validated before any write.
 * Returns 1 on success or -1 for empty, overlapping rows, bounds or overflow. */
int lrdp_h264_image_copy_i420(const lrdp_h264_image_plane planes[3],
                            size_t crop_left, size_t crop_top,
                            size_t width, size_t height,
                            const lrdp_h264_image_output output[3]);
#endif
