#ifndef LRDP_CLIPBOARD_FILES_H
#define LRDP_CLIPBOARD_FILES_H
#include <freerdp/channels/cliprdr.h>
#define LRDP_FILE_MAX_COUNT 32
#define LRDP_FILE_MAX_BYTES (256u * 1024u * 1024u)
#define LRDP_FILES_MAX_BYTES (512u * 1024u * 1024u)
#define LRDP_FILE_MAX_CHUNK (1024u * 1024u)
typedef struct lrdp_clip_files lrdp_clip_files;
/* Private, immutable staged regular files. Opens/pins handles, never sends paths.
 * All operations on one set are serialized by the session lock. */
lrdp_clip_files* lrdp_files_open(const char* const* paths, size_t count);
void lrdp_files_free(lrdp_clip_files* files);
BOOL lrdp_files_descriptor(const lrdp_clip_files* files, BYTE** data, UINT32* size);
BOOL lrdp_files_read(lrdp_clip_files* files, const CLIPRDR_FILE_CONTENTS_REQUEST* request,
                     BYTE** data, UINT32* size);
#endif
