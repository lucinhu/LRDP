#include "h264_freerdp.h"
#include "h264_decoder.h"
#include <freerdp/version.h>
#include <libfreerdp/codec/h264.h>
#include <string.h>

/* The surface layout is public; the codec subsystem layout is not. Keep this
 * adapter tied to the reviewed submodule instead of guessing another ABI.
 * System FreeRDP builds do not compile this adapter. */
#if FREERDP_VERSION_MAJOR != 3 || FREERDP_VERSION_MINOR != 32 || FREERDP_VERSION_REVISION != 2
#error "Review the LRDP H264 subsystem adapter for this FreeRDP version"
#endif

static BOOL decoder_init(H264_CONTEXT* context) {
  if (!context || context->Compressor) return FALSE;
  context->pSystemData = lrdp_h264_decoder_new();
  context->hwAccel = FALSE; /* GDI receives CPU-addressable I420, even after GPU decode. */
  return context->pSystemData != NULL;
}

static void decoder_uninit(H264_CONTEXT* context) {
  if (!context) return;
  lrdp_h264_decoder_free(context->pSystemData);
  context->pSystemData = NULL;
  for (size_t i = 0; i < 3; i++) {
    context->pYUVData[i] = NULL;
    context->iStride[i] = 0;
  }
  context->YUVWidth = context->YUVHeight = 0;
}

static int decoder_decompress(H264_CONTEXT* context, const BYTE* data, UINT32 size) {
  if (!context || !context->pSystemData) return -1;
  lrdp_h264_decoder* decoder = context->pSystemData;
  int result = lrdp_h264_decoder_decode(decoder, data, size);
  if (result <= 0) return result;
  const lrdp_h264_frame* frame = lrdp_h264_decoder_frame(decoder);
  if (!frame) return -1;
  for (size_t i = 0; i < 3; i++) {
    /* FreeRDP's subsystem ABI uses mutable pointers for borrowed decode planes;
     * its GDI conversion reads them only until this call's next decode. */
    context->pYUVData[i] = (BYTE*)frame->planes[i];
    context->iStride[i] = frame->strides[i];
  }
  context->YUVWidth = frame->width;
  context->YUVHeight = frame->height;
  return 1;
}

static const H264_CONTEXT_SUBSYSTEM subsystem = {
  "lrdp-auto-ffmpeg", decoder_init, decoder_uninit, decoder_decompress, NULL
};

BOOL lrdp_h264_prepare_surface(gdiGfxSurface* surface) {
  if (!surface) return FALSE;
  if (!surface->h264) {
    surface->h264 = h264_context_new(FALSE);
    if (!surface->h264) return FALSE;
    if (!h264_context_reset(surface->h264, surface->width, surface->height)) return FALSE;
  }
  H264_CONTEXT* context = surface->h264;
  if (context->subsystem == &subsystem) return TRUE;
  /* Allocate before releasing the existing subsystem. A failed allocation must
   * leave a valid upstream context for the normal FreeRDP destruction path. */
  lrdp_h264_decoder* decoder = lrdp_h264_decoder_new();
  if (!decoder) return FALSE;
  if (context->subsystem && context->subsystem->Uninit) context->subsystem->Uninit(context);
  context->pSystemData = decoder;
  context->subsystem = &subsystem;
  context->hwAccel = FALSE;
  return TRUE;
}

int lrdp_h264_surface_backend(const gdiGfxSurface* surface) {
  if (!surface || !surface->h264 || surface->h264->subsystem != &subsystem) return 0;
  if (!lrdp_h264_decoder_frame(surface->h264->pSystemData)) return 0;
  const char* backend = lrdp_h264_decoder_backend(surface->h264->pSystemData);
  if (strcmp(backend, "software") == 0) return 1;
  if (strcmp(backend, "vaapi") == 0) return 2;
  if (strcmp(backend, "cuda") == 0) return 3;
  if (strcmp(backend, "mediacodec") == 0) return 4;
  return 0;
}
