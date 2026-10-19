#ifndef LRDP_NATIVE_PLUGIN_H
#define LRDP_NATIVE_PLUGIN_H
#include <flutter_linux/flutter_linux.h>
G_BEGIN_DECLS
G_MODULE_EXPORT void lrdp_native_plugin_register_with_registrar(FlPluginRegistrar* registrar);
G_END_DECLS
#endif
