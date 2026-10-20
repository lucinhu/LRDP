#include "clipboard_files.h"
#include <winpr/file.h>
#include <winpr/string.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(int argc, char** argv) {
  CHECK(argc == 2);
  char path[4096]; CHECK(snprintf(path, sizeof(path), "%s/file.bin", argv[1]) < (int)sizeof(path));
  WCHAR* wide = ConvertUtf8ToWCharAlloc(path, NULL); CHECK(wide);
  HANDLE h = CreateFileW(wide, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  CHECK(h != INVALID_HANDLE_VALUE);
  BYTE golden[] = {0, 1, 255, 3, 128}; DWORD n = 0;
  CHECK(WriteFile(h, golden, sizeof(golden), &n, NULL) && n == sizeof(golden)); CloseHandle(h);
  const char* paths[] = {path};
  CHECK(!lrdp_files_open(NULL, 1) && !lrdp_files_open(paths, 0) && !lrdp_files_open(paths, 33));
  lrdp_clip_files* files = lrdp_files_open(paths, 1); CHECK(files);
  const char* duplicates[] = {path, path}; CHECK(!lrdp_files_open(duplicates, 2));
  BYTE* data = NULL; UINT32 length = 0;
  CHECK(lrdp_files_descriptor(files, &data, &length) && length == 596 && data[0] == 1);
  CHECK(data[4] == (FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI) % 256 && data[72] == sizeof(golden)); free(data);
  /* Unlinking the private snapshot cannot change the pinned object. */
  CHECK(DeleteFileW(wide));
  CLIPRDR_FILE_CONTENTS_REQUEST r = {0}; r.dwFlags = FILECONTENTS_SIZE; r.cbRequested = 8;
  CHECK(lrdp_files_read(files, &r, &data, &length) && length == 8 && data[0] == 5 && !data[7]); free(data);
  r.dwFlags = FILECONTENTS_RANGE; r.cbRequested = 10; r.nPositionLow = 1;
  CHECK(lrdp_files_read(files, &r, &data, &length) && length == 4 && !memcmp(data, golden + 1, 4)); free(data);
  r.nPositionLow = 5; CHECK(lrdp_files_read(files, &r, &data, &length) && length == 0 && !data);
  r.nPositionLow = 6; CHECK(!lrdp_files_read(files, &r, &data, &length));
  r.nPositionLow = 0; r.cbRequested = LRDP_FILE_MAX_CHUNK + 1; CHECK(!lrdp_files_read(files, &r, &data, &length));
  r.cbRequested = 8; r.dwFlags = 3; CHECK(!lrdp_files_read(files, &r, &data, &length));
  r.dwFlags = FILECONTENTS_SIZE; r.haveClipDataId = TRUE; CHECK(!lrdp_files_read(files, &r, &data, &length));
  r.haveClipDataId = FALSE; r.listIndex = 1; CHECK(!lrdp_files_read(files, &r, &data, &length));
  r.listIndex = 0; r.cbRequested = 4; CHECK(!lrdp_files_read(files, &r, &data, &length));
  r.cbRequested = 8; r.nPositionLow = 1; CHECK(!lrdp_files_read(files, &r, &data, &length));
  lrdp_files_free(files); free(wide);
#ifndef _WIN32
  FILE* source = fopen(path, "wb"); CHECK(source); fclose(source);
  char link[4096]; CHECK(snprintf(link, sizeof(link), "%s/link.bin", argv[1]) < (int)sizeof(link));
  unlink(link); CHECK(!symlink(path, link));
  const char* links[] = {link}; CHECK(!lrdp_files_open(links, 1)); unlink(link);
  CHECK(!truncate(path, LRDP_FILE_MAX_BYTES + 1)); CHECK(!lrdp_files_open(paths, 1)); unlink(path);
#endif
  const char* invalid[] = {"con.txt", "NUL", "test.", "test ", "test?.txt", "x/"};
  for (size_t i = 0; i < sizeof(invalid)/sizeof(*invalid); i++) CHECK(!lrdp_files_open(&invalid[i], 1));
  const char* directory[] = {argv[1]}; CHECK(!lrdp_files_open(directory, 1));
  puts("PASS: pinned file snapshot, packed descriptors, size/range/EOF and bounded invalid requests");
  return 0;
}
