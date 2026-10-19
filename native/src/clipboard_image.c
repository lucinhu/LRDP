#include "clipboard_image.h"
#include <string.h>
static uint32_t le32(const uint8_t* p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint32_t be32(const uint8_t* p) {
  return (uint32_t)p[3] | (uint32_t)p[2] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[0] << 24;
}
int lrdp_image_dimensions(const uint8_t* data, size_t size, int kind, uint32_t* w, uint32_t* h) {
  if (!data || size > LRDP_IMAGE_MAX_BYTES) return 0;
  uint32_t width, height;
  if (kind == 1) {
    static const uint8_t signature[] = {137,80,78,71,13,10,26,10};
    if (size < 33 || memcmp(data, signature, 8) || be32(data + 8) != 13 ||
        memcmp(data + 12, "IHDR", 4)) return 0;
    width = be32(data + 16); height = be32(data + 20);
  } else if (kind == 2) {
    if (size < 40) return 0;
    uint32_t header = le32(data), bits = (uint32_t)data[14] | (uint32_t)data[15] << 8;
    uint32_t compression = le32(data + 16), colors = le32(data + 32);
    if ((header != 40 && header != 108 && header != 124) || size < header ||
        data[12] != 1 || data[13] != 0 || (bits != 24 && bits != 32) ||
        colors != 0 || (compression != 0 && compression != 3)) return 0;
    width = le32(data + 4);
    int32_t signed_height = (int32_t)le32(data + 8);
    if (signed_height == INT32_MIN) return 0;
    height = signed_height < 0 ? (uint32_t)-signed_height : (uint32_t)signed_height;
    size_t offset = header;
    if (compression == 3) {
      if (bits != 32 || size < 52 || le32(data + 40) != 0xff0000 ||
          le32(data + 44) != 0xff00 || le32(data + 48) != 0xff) return 0;
      if (header == 40) offset += 12;
      else if (le32(data + 52) != 0 && le32(data + 52) != 0xff000000) return 0;
    }
    if (header == 124 && (le32(data + 112) || le32(data + 116))) return 0;
    if (!width || width > 4096 || !height || height > 4096 ||
        (uint64_t)width * height > LRDP_IMAGE_MAX_PIXELS) return 0;
    size_t stride = ((size_t)width * bits + 31) / 32 * 4;
    if (offset > size || stride * height > size - offset) return 0;
  } else return 0;
  if (!width || !height || width > 4096 || height > 4096 ||
      (uint64_t)width * height > LRDP_IMAGE_MAX_PIXELS) return 0;
  if (w) *w = width;
  if (h) *h = height;
  return 1;
}
