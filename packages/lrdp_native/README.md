# LRDP native integration

Builds the bridge in `../../native` against the pinned, unmodified FreeRDP
submodule. Linux and Windows use CMake; Android uses the NDK. Apple targets
consume the XCFramework built by `scripts/build_apple.sh`. See the root
`docs/BUILDING.md`. This package is internal to the LRDP checkout.

Linux also registers a Flutter GL texture plugin alongside the FFI bridge.
Keep the plugin and core together; its `$ORIGIN` runtime path and the Dart
SONAME loader must resolve the same core registry. Unsupported texture backends
use the existing CPU image path. Renderer threads consume retained frame-memory
handles only; FreeRDP calls remain on the native session thread.

Android also registers a SurfaceProducer/EGL plugin. Its frame-memory readers
and GL objects live on a dedicated handler; Surface lifecycle callbacks remain
on main. C ABI v5 keeps 24 public exports, with seven private Android JNI methods.
Only metadata crosses the platform channel; missing or failed backends use CPU
images. Build the plugin Java and its liblrdp.so together.

Windows also registers the `dev.lrdp/video` channel and a native pixel buffer
texture. RGBA conversion stays outside Dart; frame slots and outstanding leases
are bounded. The Flutter release callback and asynchronous unregister completion
retain the reader until the engine is finished with it. The ticker sleeps when
all views are hidden, failed or closed. This is a native CPU upload path, without
Direct3D shared surfaces or hardware decoding. Build the plugin DLL and lrdp.dll
together, and see the platform-specific verification limits in the root docs.
