#ifndef LRDP_NATIVE_WINDOWS_PLUGIN_H_
#define LRDP_NATIVE_WINDOWS_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef LRDP_NATIVE_PLUGIN_IMPL
#define LRDP_PLUGIN_EXPORT __declspec(dllexport)
#else
#define LRDP_PLUGIN_EXPORT __declspec(dllimport)
#endif

extern "C" LRDP_PLUGIN_EXPORT void LrdpNativePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif
