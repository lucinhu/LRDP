#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
static FARPROC WINAPI LegacyAllocatorGetProcAddress(HMODULE module,
                                                    LPCSTR name) {
  if (reinterpret_cast<ULONG_PTR>(name) > 0xffff &&
      module == GetModuleHandleW(L"kernelbase.dll") &&
      std::strcmp(name, "VirtualAlloc2") == 0) {
    SetLastError(ERROR_PROC_NOT_FOUND);
    return nullptr;
  }
  return GetProcAddress(module, name);
}

static bool SelectWineLegacyAllocator(HMODULE target) {
  if (!GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version"))
    return false;
  auto* module =
      reinterpret_cast<uint8_t*>(target);
  if (!module) return false;
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(module);
  auto* pe = reinterpret_cast<IMAGE_NT_HEADERS*>(module + dos->e_lfanew);
  auto directory =
      pe->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (!directory.VirtualAddress) return false;
  auto* imported = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
      module + directory.VirtualAddress);
  for (; imported->Name; ++imported) {
    if (!imported->OriginalFirstThunk) continue;
    auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(
        module + imported->OriginalFirstThunk);
    auto* addresses =
        reinterpret_cast<IMAGE_THUNK_DATA*>(module + imported->FirstThunk);
    for (; names->u1.AddressOfData; ++names, ++addresses) {
      if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
      auto* symbol = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(
          module + names->u1.AddressOfData);
      if (std::strcmp(reinterpret_cast<const char*>(symbol->Name),
                      "GetProcAddress") != 0)
        continue;
      DWORD previous;
      if (!VirtualProtect(&addresses->u1.Function,
                          sizeof(addresses->u1.Function), PAGE_READWRITE,
                          &previous))
        return false;
      addresses->u1.Function =
          reinterpret_cast<ULONG_PTR>(LegacyAllocatorGetProcAddress);
      DWORD ignored;
      if (!VirtualProtect(&addresses->u1.Function,
                          sizeof(addresses->u1.Function), previous, &ignored))
        return false;
      std::puts("Wine test host: Dart legacy VirtualAlloc fallback selected");
      std::fflush(stdout);
      return true;
    }
  }
  return false;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
  if (reason != DLL_PROCESS_ATTACH) return TRUE;
  HMODULE target = GetModuleHandleW(L"flutter_windows.dll");
  if (!target) target = GetModuleHandleW(nullptr);
  return SelectWineLegacyAllocator(target);
}
