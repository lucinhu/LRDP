#ifndef LRDP_VIDEO_STORE_H
#define LRDP_VIDEO_STORE_H
#include "lrdp.h"

lrdp_video* lrdp_video_store_new(void);
void lrdp_video_store_retire(lrdp_video*);
uint64_t lrdp_video_store_ticket(lrdp_video*);
/* damage is the changed bounding box in frame pixels; NULL publishes the whole
 * frame. A rectangle that misses the frame means no visible pixel changed: the
 * generation still advances but the damage entry stays empty. */
int lrdp_video_store_publish(lrdp_video*, const uint8_t*, int32_t, int32_t, size_t,
                             const lrdp_video_rect* damage);
int lrdp_video_store_copy(lrdp_video*, uint8_t*, size_t, int32_t*, int32_t*, uint64_t*);
#endif
