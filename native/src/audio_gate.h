#ifndef LRDP_AUDIO_GATE_H
#define LRDP_AUDIO_GATE_H
#include <freerdp/addin.h>
#include <freerdp/freerdp.h>
typedef struct lrdp_audio_gate lrdp_audio_gate;
lrdp_audio_gate* lrdp_audio_gate_new(void);
void lrdp_audio_gate_free(lrdp_audio_gate* gate);
/* Request/status access does not call FreeRDP. Apply belongs to the owner. */
void lrdp_audio_gate_request(lrdp_audio_gate* gate, BOOL active);
void lrdp_audio_gate_apply(lrdp_audio_gate* gate);
const char* lrdp_audio_gate_status(lrdp_audio_gate* gate);
PVIRTUALCHANNELENTRY lrdp_audio_addin(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags);
/* Implemented by the bridge; only LRDP contexts use the lrdp subsystem. */
lrdp_audio_gate* lrdp_audio_for_context(rdpContext* context);
#endif
