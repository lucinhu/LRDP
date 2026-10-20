/* Independent wire oracle for paste_fixture.c. No production file helper is
 * linked here: descriptors and deterministic content are checked by offsets. */
static UINT32 file_le32(const BYTE* p) {
  return (UINT32)p[0] | ((UINT32)p[1] << 8) | ((UINT32)p[2] << 16) | ((UINT32)p[3] << 24);
}
static UINT file_request_next(paste_context* c) {
  /* Malformed SIZE lengths/offsets are rejected by upstream before callback;
   * exercise those directly in CTest, without claiming an explicit wire reply. */
  if (c->file_step == 12 || c->file_step == 13) c->file_step = 14;
  CLIPRDR_FILE_CONTENTS_REQUEST r = {0};
  r.common.msgType = CB_FILECONTENTS_REQUEST;
  r.streamId = 0x12340000 + c->file_step; r.dwFlags = FILECONTENTS_RANGE;
  r.cbRequested = 16;
  switch (c->file_step) {
    case 0: case 1: case 2: r.listIndex = c->file_step; r.dwFlags = FILECONTENTS_SIZE; r.cbRequested = 8; break;
    case 3: r.cbRequested = 1048576; break;
    case 4: r.nPositionLow = 1048576; r.cbRequested = 10000; break;
    case 5: r.listIndex = 2; r.cbRequested = 12345; break;
    case 6: r.nPositionLow = 17; r.cbRequested = 105; break;
    case 7: r.nPositionLow = 1048576 + 731; break;
    case 8: r.listIndex = 1; break;
    case 9: r.listIndex = 2; r.nPositionLow = 7; r.cbRequested = 0; break;
    case 10: r.listIndex = 32; break;
    case 11: r.dwFlags = 3; r.cbRequested = 8; break;
    case 12: r.dwFlags = FILECONTENTS_SIZE; r.cbRequested = 4; break;
    case 13: r.dwFlags = FILECONTENTS_SIZE; r.cbRequested = 8; r.nPositionLow = 1; break;
    case 14: r.cbRequested = 1048577; break;
    case 15: r.nPositionLow = 1048576 + 732; break;
    case 16: r.nPositionHigh = 1; break;
    case 17: r.haveClipDataId = TRUE; r.clipDataId = 99; break;
    case 18: r.dwFlags = 0; break;
    default:
      c->file_complete = TRUE;
      if (!failed) { puts("PASS: full files and invalid requests checked"); fflush(stdout); }
      return CHANNEL_RC_OK;
  }
  c->file_request = r;
  return c->clip->ServerFileContentsRequest(c->clip, &r);
}
static UINT file_contents_response(CliprdrServerContext* clip, const CLIPRDR_FILE_CONTENTS_RESPONSE* response) {
  paste_context* c = clip->custom;
  if (!strcmp(behavior(), "cancel_stream")) { c->file_responses++; return CHANNEL_RC_OK; }
  const CLIPRDR_FILE_CONTENTS_REQUEST* r = &c->file_request;
  BOOL revoked = !strcmp(behavior(), "revoke") || !strcmp(behavior(), "replace");
  BOOL valid = !revoked && c->file_step < 10;
  check(response->streamId == r->streamId, "stream ID echoed unchanged");
  check(response->common.msgFlags == (valid ? CB_RESPONSE_OK : CB_RESPONSE_FAIL), "size/range or explicit failure status");
  c->file_responses++;
  if (valid) {
    UINT32 size = r->listIndex == 0 ? 1048576 + 731 : r->listIndex == 1 ? 0 : 12345;
    UINT32 expected_size = r->dwFlags == FILECONTENTS_SIZE ? 8 :
      (r->cbRequested < size - r->nPositionLow ? r->cbRequested : size - r->nPositionLow);
    check(response->cbRequested == expected_size, "bounded size, EOF and empty-file response length");
    if (response->cbRequested != expected_size) return CHANNEL_RC_OK;
    if (r->dwFlags == FILECONTENTS_SIZE) {
      check(file_le32(response->requestedData) == size && file_le32(response->requestedData + 4) == 0,
        "little-endian 64-bit file size");
    } else {
      for (UINT32 i = 0; i < expected_size; i++) {
        BYTE golden = (BYTE)((r->nPositionLow + i) * (r->listIndex == 0 ? 31 : 13) + (r->listIndex == 0 ? 17 : 9));
        if (response->requestedData[i] != golden) { check(FALSE,"exact binary bytes including random-offset repeat"); break; }
      }
      c->file_bytes += expected_size;
    }
  } else check(response->cbRequested == 0, "failed request exposes no file bytes");
  if (revoked) c->file_step = 19; else c->file_step++;
  return failed ? CHANNEL_RC_OK : file_request_next(c);
}
static UINT file_descriptor_response(paste_context* c, const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
  c->data_count++;
  check(response->common.msgFlags == CB_RESPONSE_OK && response->common.dataLen == 4 + 3 * 592,
    "three packed FILEDESCRIPTORW entries");
  if (response->common.dataLen != 4 + 3 * 592) return CHANNEL_RC_OK;
  const BYTE* data = response->requestedFormatData;
  check(file_le32(data) == 3, "descriptor count");
  const char* names[] = {"中文 😀.bin", "empty.txt", "second.bin"};
  const UINT32 sizes[] = {1048576 + 731, 0, 12345};
  for (UINT i = 0; i < 3; i++) {
    const BYTE* d = data + 4 + i * 592;
    size_t units = 0; WCHAR* name = ConvertUtf8ToWCharAlloc(names[i], &units);
    check((file_le32(d) & (4 | 64)) == (4 | 64) && file_le32(d + 36) == FILE_ATTRIBUTE_NORMAL &&
      file_le32(d + 64) == 0 && file_le32(d + 68) == sizes[i], "descriptor attributes and 64-bit sizes");
    check(name && !memcmp(d + 72, name, (units + 1) * 2), "UTF-16 filename without local path"); free(name);
  }
  if (!strcmp(behavior(), "replace")) {
    puts("READY: replace local clipboard"); fflush(stdout); return CHANNEL_RC_OK;
  }
  if (!strcmp(behavior(), "cancel_stream")) {
    CLIPRDR_FILE_CONTENTS_REQUEST r = {0}; r.common.msgType = CB_FILECONTENTS_REQUEST;
    r.dwFlags = FILECONTENTS_RANGE; r.cbRequested = 1048576;
    for (UINT i = 0; i < 32; i++) {
      r.streamId = i + 100;
      check(c->clip->ServerFileContentsRequest(c->clip, &r) == CHANNEL_RC_OK, "queue requests before blocked peer read");
    }
    puts("READY: blocked file reader"); fflush(stdout);
    Sleep(1500); return CHANNEL_RC_OK;
  }
  if (!strcmp(behavior(), "revoke")) {
    CLIPRDR_FORMAT_LIST list = {0}; list.common.msgType = CB_FORMAT_LIST;
    check(c->clip->ServerFormatList(c->clip, &list) == CHANNEL_RC_OK, "remote clipboard ownership replacement");
  }
  return failed ? CHANNEL_RC_OK : file_request_next(c);
}
static UINT file_formats(paste_context* c, const CLIPRDR_FORMAT_LIST* list) {
  if (!strcmp(behavior(), "replace") && c->formats == 2) {
    check(list->numFormats == 1 && list->formats[0].formatId == CF_UNICODETEXT, "local text replaces files");
    CLIPRDR_FORMAT_LIST_RESPONSE ack = {0}; ack.common.msgType = CB_FORMAT_LIST_RESPONSE;
    ack.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = c->clip->ServerFormatListResponse(c->clip, &ack);
    return rc ? rc : file_request_next(c);
  }
  check(c->formats == 1 && list->numFormats == 1 && list->formats[0].formatName &&
    !strcmp(list->formats[0].formatName, "FileGroupDescriptorW"), "one registered file-list format, no local paths or auto retry");
  c->file_format = list->formats[0].formatId;
  c->ack_at = GetTickCount64() + (!strcmp(behavior(), "cancel") ? 2000 : 350);
  if (!strcmp(behavior(), "prefetch")) {
    CLIPRDR_FORMAT_DATA_REQUEST r = {0}; r.common.msgType = CB_FORMAT_DATA_REQUEST;
    r.requestedFormatId = c->file_format;
    return c->clip->ServerFormatDataRequest(c->clip, &r);
  }
  return CHANNEL_RC_OK;
}
static UINT file_client_caps(CliprdrServerContext* clip, const CLIPRDR_CAPABILITIES* caps) {
  (void)clip;
  check(caps->cCapabilitiesSets == 1 && caps->capabilitySets, "one general capability");
  if (!caps->capabilitySets) return CHANNEL_RC_OK;
  const CLIPRDR_GENERAL_CAPABILITY_SET* g = (const void*)caps->capabilitySets;
  check(!(g->generalFlags & (CB_CAN_LOCK_CLIPDATA | CB_HUGE_FILE_SUPPORT_ENABLED)), "no unsupported locking or huge-file promises");
  check(!!(g->generalFlags & CB_STREAM_FILECLIP_ENABLED) == !!strcmp(behavior(), "unsupported"), "file-stream capability negotiation");
  return CHANNEL_RC_OK;
}
