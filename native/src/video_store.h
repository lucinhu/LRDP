#ifndef LRDP_VIDEO_STORE_H
#define LRDP_VIDEO_STORE_H
#include "lrdp.h"

lrdp_video* lrdp_video_store_new(void);
void lrdp_video_store_retire(lrdp_video*);
uint64_t lrdp_video_store_ticket(lrdp_video*);
int lrdp_video_store_publish(lrdp_video*, const uint8_t*, int32_t, int32_t, size_t);
int lrdp_video_store_copy(lrdp_video*, uint8_t*, size_t, int32_t*, int32_t*, uint64_t*);
#endif
