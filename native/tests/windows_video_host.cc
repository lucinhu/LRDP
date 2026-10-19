#include <flutter_windows.h>
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "lrdp_native/lrdp_native_plugin.h"

static FlutterDesktopViewControllerRef controller;
static HWND child;
static std::wstring control;

// Wine 11.20's VirtualAlloc2 can reuse a live MEM_COMMIT-only region. Select
// Dart's supported pre-VirtualAlloc2 path in this acceptance host only. The
// original engine DLL on disk and the production plugin remain untouched.
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

static bool SelectWineLegacyAllocator() {
  if (!GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version"))
    return false;
  auto* module =
      reinterpret_cast<uint8_t*>(GetModuleHandleW(L"flutter_windows.dll"));
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
static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  LRESULT handled = 0;
  if (controller && FlutterDesktopViewControllerHandleTopLevelWindowProc(
                        controller, window, message, wparam, lparam, &handled))
    return handled;
  if (message == WM_SIZE && child) {
    RECT rect;
    GetClientRect(window, &rect);
    SetWindowPos(child, nullptr, 0, 0, rect.right, rect.bottom, SWP_NOZORDER);
  }
  if (message == WM_TIMER) {
    RECT rect;
    if (child && GetWindowRect(child, &rect)) {
      FILE* file = _wfopen((control + L"\\window.json").c_str(), L"w");
      if (file) {
        fprintf(file,
                "{\"left\":%ld,\"top\":%ld,\"width\":%ld,\"height\":%ld}\n",
                rect.left, rect.top, rect.right - rect.left,
                rect.bottom - rect.top);
        fclose(file);
      }
    }
    if (GetFileAttributesW((control + L"\\done").c_str()) !=
        INVALID_FILE_ATTRIBUTES)
      PostQuitMessage(0);
  }
  if (message == WM_CLOSE) {
    DestroyWindow(window);
    return 0;
  }
  if (message == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 4) return 2;
  if (GetEnvironmentVariableW(L"LRDP_TEST_WINE_LEGACY_ALLOCATOR", nullptr, 0) &&
      !SelectWineLegacyAllocator())
    return 6;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  control = argv[3];
  WNDCLASSW cls{};
  cls.lpfnWndProc = WindowProc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"LRDPNativeVideoAcceptance";
  cls.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&cls);
  HWND parent = CreateWindowW(
      cls.lpszClassName, L"LRDP Windows native video test", WS_OVERLAPPEDWINDOW,
      40, 40, 1020, 800, nullptr, nullptr, cls.hInstance, nullptr);
  if (!parent) return 3;
  FlutterDesktopEngineProperties properties{};
  properties.assets_path = argv[1];
  properties.icu_data_path = argv[2];
  auto engine = FlutterDesktopEngineCreate(&properties);
  if (!engine) return 4;
  LrdpNativePluginRegisterWithRegistrar(
      FlutterDesktopEngineGetPluginRegistrar(engine, "LrdpNativePlugin"));
  controller = FlutterDesktopViewControllerCreate(1000, 760, engine);
  if (!controller) return 5;
  child = FlutterDesktopViewGetHWND(
      FlutterDesktopViewControllerGetView(controller));
  SetParent(child, parent);
  RECT rect;
  GetClientRect(parent, &rect);
  SetWindowPos(child, nullptr, 0, 0, rect.right, rect.bottom, SWP_NOZORDER);
  ShowWindow(parent, SW_SHOW);
  UpdateWindow(parent);
  SetTimer(parent, 1, 100, nullptr);
  MSG message;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  KillTimer(parent, 1);
  FlutterDesktopViewControllerDestroy(controller);
  controller = nullptr;
  std::puts("PASS: Flutter Windows engine and plugin teardown returned");
  return 0;
}
