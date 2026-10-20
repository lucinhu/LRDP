#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "clipboard_files.h"
#include <winpr/string.h>
#include <winpr/file.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#endif
struct lrdp_clip_files {
  size_t count;
  FILEDESCRIPTORW descriptors[LRDP_FILE_MAX_COUNT];
#ifdef _WIN32
  HANDLE handles[LRDP_FILE_MAX_COUNT];
#else
  int handles[LRDP_FILE_MAX_COUNT];
#endif
};
static BOOL same_name(const WCHAR* a, const WCHAR* b) {
  WCHAR left[260], right[260];
  memcpy(left, a, sizeof(left)); memcpy(right, b, sizeof(right));
  CharUpperBuffW(left, 260); CharUpperBuffW(right, 260);
  return memcmp(left, right, sizeof(left)) == 0;
}
static BOOL valid_name(const WCHAR* name, size_t units) {
  if (!units || units >= 260 || name[units - 1] == '.' || name[units - 1] == ' ') return FALSE;
  for (size_t i = 0; i < units; i++) {
    WCHAR ch = name[i];
    if (ch < 32 || ch == '<' || ch == '>' || ch == ':' || ch == '"' ||
        ch == '/' || ch == '\\' || ch == '|' || ch == '?' || ch == '*') return FALSE;
  }
  /* DOS device basenames remain reserved even with an extension. */
  char stem[8] = {0}; size_t n = 0;
  while (n < units && name[n] != '.' && n < sizeof(stem) - 1) {
    WCHAR ch = name[n]; if (ch > 127) return TRUE;
    stem[n++] = (char)((ch >= 'a' && ch <= 'z') ? ch - 'a' + 'A' : ch);
  }
  return strcmp(stem, "CON") && strcmp(stem, "PRN") && strcmp(stem, "AUX") &&
    strcmp(stem, "NUL") && !(n == 4 && (!memcmp(stem, "COM", 3) || !memcmp(stem, "LPT", 3)) &&
      stem[3] >= '1' && stem[3] <= '9');
}
void lrdp_files_free(lrdp_clip_files* files) {
  if (!files) return;
  for (size_t i = 0; i < files->count; i++) {
#ifdef _WIN32
    CloseHandle(files->handles[i]);
#else
    close(files->handles[i]);
#endif
  }
  free(files);
}
lrdp_clip_files* lrdp_files_open(const char* const* paths, size_t count) {
  if (!paths || !count || count > LRDP_FILE_MAX_COUNT) return NULL;
  lrdp_clip_files* files = calloc(1, sizeof(*files));
  if (!files) return NULL;
  UINT64 total = 0;
  for (size_t i = 0; i < count; i++) {
    if (!paths[i] || strlen(paths[i]) > 32768) goto fail;
    const char* name = paths[i];
    for (const char* at = paths[i]; *at; at++) if (*at == '/' || *at == '\\') name = at + 1;
    size_t units = 0;
    WCHAR* wide = ConvertUtf8ToWCharAlloc(name, &units);
    BOOL valid = wide && valid_name(wide, units);
    if (valid) memcpy(files->descriptors[i].cFileName, wide, (units + 1) * sizeof(WCHAR));
    free(wide);
    if (!valid) goto fail;
    for (size_t j = 0; j < i; j++)
      if (same_name(files->descriptors[j].cFileName, files->descriptors[i].cFileName)) goto fail;
    UINT64 size = 0;
#ifdef _WIN32
    WCHAR* path = ConvertUtf8ToWCharAlloc(paths[i], NULL);
    if (!path) goto fail;
    HANDLE handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(path);
    if (handle == INVALID_HANDLE_VALUE) goto fail;
    files->handles[files->count++] = handle;
    BY_HANDLE_FILE_INFORMATION info = {0};
    if (GetFileType(handle) != FILE_TYPE_DISK || !GetFileInformationByHandle(handle, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) goto fail;
    size = ((UINT64)info.nFileSizeHigh << 32) | info.nFileSizeLow;
#else
    int handle = open(paths[i], O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (handle < 0) goto fail;
    files->handles[files->count++] = handle;
    struct stat info;
    if (fstat(handle, &info) || !S_ISREG(info.st_mode) || info.st_size < 0) goto fail;
    size = (UINT64)info.st_size;
#endif
    if (size > LRDP_FILE_MAX_BYTES || total + size > LRDP_FILES_MAX_BYTES) goto fail;
    total += size;
    files->descriptors[i].dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI;
    files->descriptors[i].dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
    files->descriptors[i].nFileSizeLow = (UINT32)size;
  }
  return files;
fail:
  lrdp_files_free(files); return NULL;
}
BOOL lrdp_files_descriptor(const lrdp_clip_files* files, BYTE** data, UINT32* size) {
  if (!files || !data || !size) return FALSE;
  return cliprdr_serialize_file_list(files->descriptors, (UINT32)files->count, data, size) == CHANNEL_RC_OK;
}
BOOL lrdp_files_read(lrdp_clip_files* files, const CLIPRDR_FILE_CONTENTS_REQUEST* r,
                     BYTE** data, UINT32* length) {
  if (!files || !r || !data || !length || r->haveClipDataId || r->listIndex >= files->count) return FALSE;
  UINT64 size = files->descriptors[r->listIndex].nFileSizeLow;
  UINT64 offset = ((UINT64)r->nPositionHigh << 32) | r->nPositionLow;
  *data = NULL; *length = 0;
  if (r->dwFlags == FILECONTENTS_SIZE) {
    if (r->cbRequested != 8 || offset) return FALSE;
    *data = calloc(1, 8); if (!*data) return FALSE;
    for (int i = 0; i < 8; i++) (*data)[i] = (BYTE)(size >> (i * 8));
    *length = 8; return TRUE;
  }
  if (r->dwFlags != FILECONTENTS_RANGE || r->cbRequested > LRDP_FILE_MAX_CHUNK || offset > size) return FALSE;
  UINT32 count = (UINT32)((size - offset < r->cbRequested) ? size - offset : r->cbRequested);
  if (!count) return TRUE;
  BYTE* bytes = malloc(count); if (!bytes) return FALSE;
  size_t copied = 0;
#ifdef _WIN32
  LARGE_INTEGER position; position.QuadPart = (LONGLONG)offset;
  if (!SetFilePointerEx(files->handles[r->listIndex], position, NULL, FILE_BEGIN)) { free(bytes); return FALSE; }
#endif
  while (copied < count) {
#ifdef _WIN32
    DWORD n = 0;
    if (!ReadFile(files->handles[r->listIndex], bytes + copied, count - (DWORD)copied, &n, NULL) || !n) break;
#else
    ssize_t n = pread(files->handles[r->listIndex], bytes + copied, count - copied, (off_t)(offset + copied));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
#endif
    copied += (size_t)n;
  }
  if (copied != count) { free(bytes); return FALSE; }
  *data = bytes; *length = count; return TRUE;
}
