/* LRDP-owned playback gate using only FreeRDP's public device interface. */
#include "audio_gate.h"
#include "audio_buffer.h"
#include <freerdp/client/channels.h>
#include <freerdp/client/rdpsnd.h>
#include <winpr/synch.h>
#include <winpr/interlocked.h>
#include <winpr/sysinfo.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

typedef struct audio_device audio_device;
struct lrdp_audio_gate {
  CRITICAL_SECTION lock;
  audio_device* devices;
  BOOL requested, unavailable;
};
struct audio_device {
  rdpsndDevicePlugin proxy;
  CRITICAL_SECTION lock;
  lrdp_audio_gate* owner;
  audio_device* next;
  rdpsndDevicePlugin* device;
  AUDIO_FORMAT format;
  UINT32 latency, volume;
  BOOL requested, opened, format_valid, unavailable;
  LONG snapshot; /* 0 waiting, 1 playing, 2 unavailable; nonblocking status. */
  BOOL reset_pending;
#ifdef __ANDROID__
  lrdp_audio_buffer* buffer;
#endif
};
static audio_device* gate_of(rdpsndDevicePlugin* proxy) { return (audio_device*)proxy; }
static void close_locked(audio_device* g, BOOL pause) {
#ifdef __ANDROID__
  lrdp_audio_buffer_reset(g->buffer);
#endif
  if (g->device && g->opened) {
    /* Some backends drain on Close. Mute first when pausing, so queued audio
     * cannot remain audible while that bounded device buffer is released. */
#ifndef _WIN32
    if (pause && g->device->SetVolume) (void)g->device->SetVolume(g->device, 0);
#else
    /* WinMM Close resets pending buffers. Do not change its session volume
     * while another connection in this application may be starting. */
    (void)pause;
#endif
    if (g->device->Close) g->device->Close(g->device);
  }
  g->opened = FALSE;
  InterlockedExchange(&g->snapshot, g->unavailable ? 2 : 0);
}
static BOOL open_locked(audio_device* g) {
  if (!g->requested || g->reset_pending || !g->format_valid || !g->device || g->unavailable) return FALSE;
  if (g->opened) return TRUE;
  AUDIO_FORMAT format = g->format;
#ifdef __ANDROID__
  format.wBitsPerSample = 16;
  format.nBlockAlign = format.nChannels * 2;
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
#endif
  if (!g->device->Open(g->device, &format, g->latency)) {
    if (g->device->Close) g->device->Close(g->device);
    g->unavailable = TRUE;
    InterlockedExchange(&g->snapshot, 2);
    return FALSE;
  }
  g->opened = TRUE;
  InterlockedExchange(&g->snapshot, 1);
  /* Apply the server volume before submitting the first new audio block. */
  if (g->device->SetVolume && !g->device->SetVolume(g->device, g->volume)) {
    close_locked(g, TRUE);
    g->unavailable = TRUE;
    InterlockedExchange(&g->snapshot, 2);
    return FALSE;
  }
  return TRUE;
}
#ifdef __ANDROID__
static UINT drain_locked(audio_device* g) {
  if (!g->requested || g->reset_pending || !g->buffer || g->unavailable) return 0;
  BYTE output[9600]; /* 50 ms, PCM16 stereo at 48 kHz */
  size_t size;
  while ((size = lrdp_audio_buffer_take(g->buffer, output, sizeof(output), GetTickCount64())) > 0) {
    if (!open_locked(g)) break;
    (void)g->device->Play(g->device, output, size);
  }
  return lrdp_audio_buffer_latency(g->buffer, GetTickCount64());
}
#endif
static BOOL supports(rdpsndDevicePlugin* proxy, const AUDIO_FORMAT* format) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock);
  BOOL result = g->device && g->device->FormatSupported(g->device, format);
#ifdef __ANDROID__
  result = result && lrdp_audio_rate_supported(format->nSamplesPerSec);
#endif
  LeaveCriticalSection(&g->lock); return result;
}
static BOOL open_device(rdpsndDevicePlugin* proxy, const AUDIO_FORMAT* format, UINT32 latency) {
  audio_device* g = gate_of(proxy);
  AUDIO_FORMAT copy = *format; copy.data = NULL;
  if (format->cbSize) {
    if (!format->data) return FALSE;
    copy.data = malloc(format->cbSize);
    if (!copy.data) return FALSE;
    memcpy(copy.data, format->data, format->cbSize);
  }
  EnterCriticalSection(&g->lock);
  close_locked(g, !g->requested);
  free(g->format.data); g->format = copy;
  g->format_valid = TRUE; g->latency = latency;
  g->unavailable = FALSE; InterlockedExchange(&g->snapshot, 0);
#ifdef __ANDROID__
  lrdp_audio_buffer_free(g->buffer);
  g->buffer = lrdp_audio_buffer_new(format->wBitsPerSample, format->nChannels, format->nSamplesPerSec, latency);
  if (!g->buffer || format->wFormatTag != WAVE_FORMAT_PCM) {
    g->format_valid = FALSE; g->unavailable = TRUE; InterlockedExchange(&g->snapshot, 2);
  }
#else
  (void)open_locked(g);
#endif
  /* Device loss silences this stream rather than terminating the desktop. */
  LeaveCriticalSection(&g->lock); return TRUE;
}
static UINT32 get_volume(rdpsndDevicePlugin* proxy) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock); UINT32 volume = g->volume;
  LeaveCriticalSection(&g->lock); return volume;
}
static BOOL set_volume(rdpsndDevicePlugin* proxy, UINT32 volume) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock); g->volume = volume;
  if (g->opened && g->requested && g->device->SetVolume)
    (void)g->device->SetVolume(g->device, volume);
  LeaveCriticalSection(&g->lock); return TRUE;
}
static UINT play(rdpsndDevicePlugin* proxy, const BYTE* data, size_t size) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock);
  UINT latency = 0;
#ifdef __ANDROID__
  if (g->requested && !g->reset_pending && g->buffer && !g->unavailable) {
    if (!lrdp_audio_buffer_push(g->buffer, data, size, GetTickCount64())) {
      g->unavailable = TRUE; InterlockedExchange(&g->snapshot, 2);
    }
    latency = drain_locked(g);
  }
#else
  latency = open_locked(g) && g->device->Play ? g->device->Play(g->device, data, size) : 0;
#endif
  LeaveCriticalSection(&g->lock); return latency;
}
static UINT play_ex(rdpsndDevicePlugin* proxy, const AUDIO_FORMAT* format, const BYTE* data, size_t size) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock);
  UINT latency = open_locked(g) ? g->device->PlayEx(g->device, format, data, size) : 0;
  LeaveCriticalSection(&g->lock); return latency;
}
static BOOL default_format(rdpsndDevicePlugin* proxy, const AUDIO_FORMAT* desired, AUDIO_FORMAT* output) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock);
  BOOL ok = g->device && g->device->DefaultFormat && g->device->DefaultFormat(g->device, desired, output);
  LeaveCriticalSection(&g->lock); return ok;
}
static UINT announce(rdpsndDevicePlugin* proxy, const AUDIO_FORMAT* formats, size_t count) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock);
  UINT status = g->device && g->device->ServerFormatAnnounce ?
    g->device->ServerFormatAnnounce(g->device, formats, count) : CHANNEL_RC_OK;
  LeaveCriticalSection(&g->lock); return status;
}
static void close_device(rdpsndDevicePlugin* proxy) {
  audio_device* g = gate_of(proxy);
  EnterCriticalSection(&g->lock); close_locked(g, !g->requested);
  g->format_valid = FALSE;
  LeaveCriticalSection(&g->lock);
}
static void free_device(rdpsndDevicePlugin* proxy) {
  audio_device* g = gate_of(proxy);
  lrdp_audio_gate* owner = g->owner;
  EnterCriticalSection(&owner->lock);
  EnterCriticalSection(&g->lock);
  close_locked(g, TRUE);
  if (g->device && g->device->Free) g->device->Free(g->device);
  g->device = NULL; g->format_valid = FALSE;
#ifdef __ANDROID__
  lrdp_audio_buffer_free(g->buffer); g->buffer = NULL;
#endif
  free(g->format.data); memset(&g->format, 0, sizeof(g->format));
  LeaveCriticalSection(&g->lock);
  audio_device** link = &owner->devices;
  while (*link && *link != g) link = &(*link)->next;
  if (*link) *link = g->next;
  DeleteCriticalSection(&g->lock); free(g);
  LeaveCriticalSection(&owner->lock);
}
lrdp_audio_gate* lrdp_audio_gate_new(void) {
  lrdp_audio_gate* g = calloc(1, sizeof(*g));
  if (g) InitializeCriticalSection(&g->lock);
  return g;
}
void lrdp_audio_gate_free(lrdp_audio_gate* g) {
  if (!g) return;
  while (g->devices) free_device(&g->devices->proxy);
  DeleteCriticalSection(&g->lock); free(g);
}
void lrdp_audio_gate_request(lrdp_audio_gate* g, BOOL active) {
  if (!g) return;
  EnterCriticalSection(&g->lock);
  g->requested = active;
  for (audio_device* d = g->devices; d; d = d->next) {
    EnterCriticalSection(&d->lock);
    if (active && !d->requested) {
      d->unavailable = FALSE;
      InterlockedExchange(&d->snapshot, d->opened ? (d->reset_pending ? 3 : 1) : 0);
    }
    d->requested = active;
    if (!active) {
      d->reset_pending = TRUE;
      if (d->opened) InterlockedExchange(&d->snapshot, 3);
#ifdef __ANDROID__
      lrdp_audio_buffer_reset(d->buffer);
#endif
    }
    LeaveCriticalSection(&d->lock);
  }
  LeaveCriticalSection(&g->lock);
}
void lrdp_audio_gate_apply(lrdp_audio_gate* g) {
  EnterCriticalSection(&g->lock);
  for (audio_device* d = g->devices; d; d = d->next) {
    EnterCriticalSection(&d->lock);
    if (!d->requested || d->reset_pending || d->unavailable) {
      close_locked(d, TRUE); d->reset_pending = FALSE;
    }
#ifdef __ANDROID__
    if (d->requested) (void)drain_locked(d);
#endif
    LeaveCriticalSection(&d->lock);
  }
  LeaveCriticalSection(&g->lock);
}
const char* lrdp_audio_gate_status(lrdp_audio_gate* g) {
  EnterCriticalSection(&g->lock);
  BOOL opened = FALSE, resetting = FALSE, unavailable = g->unavailable;
  for (audio_device* d = g->devices; d; d = d->next) {
    LONG status = InterlockedCompareExchange(&d->snapshot, 0, 0);
    opened |= status == 1; resetting |= status == 3; unavailable |= status == 2;
  }
  const char* status = !g->requested ? (opened || resetting ? "pausing" : "paused") :
    resetting ? "pausing" : opened ? "playing" :
    unavailable ? "unavailable" : "waiting";
  LeaveCriticalSection(&g->lock); return status;
}
static void registered(rdpsndPlugin* plugin, rdpsndDevicePlugin* device) {
  lrdp_audio_gate* hub = lrdp_audio_for_context(freerdp_rdpsnd_get_context(plugin));
  device->rdpsnd = plugin;
  EnterCriticalSection(&hub->lock);
  for (audio_device* d = hub->devices; d; d = d->next) {
    if (d->proxy.rdpsnd == plugin) { d->device = device; break; }
  }
  LeaveCriticalSection(&hub->lock);
}
static UINT VCAPITYPE subsystem(PFREERDP_RDPSND_DEVICE_ENTRY_POINTS entry) {
  lrdp_audio_gate* hub = lrdp_audio_for_context(freerdp_rdpsnd_get_context(entry->rdpsnd));
  if (!hub) return ERROR_INVALID_STATE;
#if defined(__ANDROID__)
  const char* backend = "opensles";
#elif defined(_WIN32)
  const char* backend = "winmm";
#elif defined(__APPLE__) && defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
  const char* backend = "ios";
#elif defined(__APPLE__)
  const char* backend = "mac";
#else
  const char* backend = "pulse";
#endif
  const DWORD flags = FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX;
  PVIRTUALCHANNELENTRY raw = freerdp_channels_load_static_addin_entry("rdpsnd", backend, NULL, flags);
  PFREERDP_RDPSND_DEVICE_ENTRY load = WINPR_FUNC_PTR_CAST(raw, PFREERDP_RDPSND_DEVICE_ENTRY);
  if (!load) {
    EnterCriticalSection(&hub->lock); hub->unavailable = TRUE; LeaveCriticalSection(&hub->lock);
    return ERROR_NOT_SUPPORTED;
  }
  audio_device* g = calloc(1, sizeof(*g));
  if (!g) return CHANNEL_RC_NO_MEMORY;
  InitializeCriticalSection(&g->lock);
  g->owner = hub; g->volume = 0xffffffffU; g->proxy.rdpsnd = entry->rdpsnd;
  EnterCriticalSection(&hub->lock);
  g->requested = hub->requested; g->next = hub->devices; hub->devices = g;
  LeaveCriticalSection(&hub->lock);
  FREERDP_RDPSND_DEVICE_ENTRY_POINTS inner = *entry;
  inner.pRegisterRdpsndDevice = registered;
  UINT status = load(&inner);
  if (status || !g->device || !g->device->Open || !g->device->FormatSupported) {
    EnterCriticalSection(&hub->lock); hub->unavailable = TRUE; LeaveCriticalSection(&hub->lock);
    free_device(&g->proxy); return status ? status : ERROR_INVALID_DATA;
  }
  g->proxy = (rdpsndDevicePlugin){0};
  g->proxy.FormatSupported = supports; g->proxy.Open = open_device;
  g->proxy.GetVolume = get_volume; g->proxy.SetVolume = set_volume;
  g->proxy.Play = play; g->proxy.PlayEx = g->device->PlayEx ? play_ex : NULL;
  g->proxy.DefaultFormat = default_format; g->proxy.ServerFormatAnnounce = announce;
  g->proxy.Close = close_device; g->proxy.Free = free_device;
  entry->pRegisterRdpsndDevice(entry->rdpsnd, &g->proxy);
  return CHANNEL_RC_OK;
}
PVIRTUALCHANNELENTRY lrdp_audio_addin(LPCSTR name, LPCSTR backend, LPCSTR type, DWORD flags) {
  if (name && backend && strcmp(name, "rdpsnd") == 0 && strcmp(backend, "lrdp") == 0)
    return WINPR_FUNC_PTR_CAST(&subsystem, PVIRTUALCHANNELENTRY);
  return freerdp_channels_load_static_addin_entry(name, backend, type, flags);
}
