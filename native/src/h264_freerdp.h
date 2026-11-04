#ifndef LRDP_H264_FREERDP_H
#define LRDP_H264_FREERDP_H
#include <freerdp/gdi/gfx.h>

/* Called only on the connection owner, before a GDI AVC surface command.
 * The upstream GDI renderer still owns surface/context teardown. */
BOOL lrdp_h264_prepare_surface(gdiGfxSurface* surface);
/* Latest successful frame: 0 pending, 1 CPU, 2 VA-API, 3 CUDA, 4 MediaCodec. */
int lrdp_h264_surface_backend(const gdiGfxSurface* surface);
#endif
