#ifndef LRDP_CLIPBOARD_IMAGE_H
#define LRDP_CLIPBOARD_IMAGE_H
#include <stdint.h>
#include <stddef.h>
#define LRDP_IMAGE_MAX_BYTES (16u * 1024u * 1024u)
#define LRDP_IMAGE_MAX_PIXELS (4u * 1024u * 1024u)
/* Plain bounded byte validation; no image decoder or FreeRDP calls. */
int lrdp_image_dimensions(const uint8_t*, size_t, int, uint32_t*, uint32_t*);
#endif
