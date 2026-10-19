cmake_minimum_required(VERSION 3.22)
project(lrdp_windows_main LANGUAGES C CXX RC)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_DISABLE_FIND_PACKAGE_JNI TRUE)
get_filename_component(LRDP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
include("${LRDP_APP_INPUTS}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${LRDP_APP_BUNDLE}")
add_compile_definitions(UNICODE _UNICODE NOMINMAX _WIN32_WINNT=0x0A00)

function(apply_standard_settings target)
  target_compile_options(${target} PRIVATE /W4 /WX /wd4100 /EHsc)
  target_compile_definitions(${target} PRIVATE _HAS_EXCEPTIONS=0)
endfunction()

set(platform "${LRDP_FLUTTER_ROOT}/engine/src/flutter/shell/platform")
set(wrapper "${platform}/common/client_wrapper")
add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE "${LRDP_FLUTTER_ENGINE}")
target_link_libraries(flutter INTERFACE "${LRDP_FLUTTER_ENGINE}/flutter_windows.dll.lib")
add_library(flutter_wrapper_plugin STATIC
  "${wrapper}/core_implementations.cc" "${wrapper}/standard_codec.cc"
  "${wrapper}/plugin_registrar.cc")
add_library(flutter_wrapper_app STATIC
  "${wrapper}/core_implementations.cc" "${wrapper}/standard_codec.cc"
  "${platform}/windows/client_wrapper/flutter_engine.cc"
  "${platform}/windows/client_wrapper/flutter_view_controller.cc")
foreach(target flutter_wrapper_plugin flutter_wrapper_app)
  target_include_directories(${target} SYSTEM PUBLIC
    "${wrapper}/include" "${wrapper}/include/flutter" "${wrapper}"
    "${platform}/windows/client_wrapper/include")
  target_link_libraries(${target} PUBLIC flutter)
endforeach()

add_library(lrdp_core SHARED IMPORTED)
set_target_properties(lrdp_core PROPERTIES
  IMPORTED_IMPLIB "${LRDP_CORE_DIR}/liblrdp.dll.a"
  IMPORTED_LOCATION "${LRDP_CORE_DIR}/lrdp.dll"
  INTERFACE_INCLUDE_DIRECTORIES "${LRDP_ROOT}/native/include")
add_library(lrdp_native_plugin SHARED
  "${LRDP_ROOT}/packages/lrdp_native/windows/lrdp_native_plugin.cpp"
  "${LRDP_ROOT}/packages/lrdp_native/windows/video_texture.cc")
apply_standard_settings(lrdp_native_plugin)
target_compile_definitions(lrdp_native_plugin PRIVATE LRDP_NATIVE_PLUGIN_IMPL)
target_include_directories(lrdp_native_plugin PUBLIC
  "${LRDP_ROOT}/packages/lrdp_native/windows/include")
target_link_libraries(lrdp_native_plugin PRIVATE flutter flutter_wrapper_plugin lrdp_core)

foreach(plugin dynamic_color file_selector_windows flutter_secure_storage_windows share_plus url_launcher_windows jni)
  add_subdirectory("${LRDP_PLUGIN_${plugin}}/windows" "plugins/${plugin}")
endforeach()
include("${LRDP_ROOT}/native/cmake/dynamic_color_compat.cmake")
lrdp_dynamic_color_windows_compat()

add_executable(lrdp WIN32
  "${LRDP_ROOT}/windows/runner/main.cpp"
  "${LRDP_ROOT}/windows/runner/flutter_window.cpp"
  "${LRDP_ROOT}/windows/runner/win32_window.cpp"
  "${LRDP_ROOT}/windows/runner/utils.cpp"
  "${LRDP_RUNNER_RESOURCE}"
  "${LRDP_ROOT}/windows/runner/runner.exe.manifest"
  "${LRDP_ROOT}/windows/flutter/generated_plugin_registrant.cc")
apply_standard_settings(lrdp)
target_include_directories(lrdp PRIVATE
  "${LRDP_ROOT}/windows" "${LRDP_ROOT}/windows/runner"
  "${LRDP_XWIN_ROOT}/Windows Kits/10/Include/${LRDP_WINDOWS_SDK_VERSION}/um"
  "${LRDP_XWIN_ROOT}/Windows Kits/10/Include/${LRDP_WINDOWS_SDK_VERSION}/shared")
target_compile_definitions(lrdp PRIVATE FLUTTER_VERSION="${LRDP_VERSION}"
  FLUTTER_VERSION_MAJOR=${LRDP_VERSION_MAJOR} FLUTTER_VERSION_MINOR=${LRDP_VERSION_MINOR}
  FLUTTER_VERSION_PATCH=${LRDP_VERSION_PATCH} FLUTTER_VERSION_BUILD=${LRDP_VERSION_BUILD})
target_link_libraries(lrdp PRIVATE flutter_wrapper_app lrdp_native_plugin
  dynamic_color_plugin file_selector_windows_plugin flutter_secure_storage_windows_plugin
  share_plus_plugin url_launcher_windows_plugin
  dwmapi ole32 shell32 shlwapi advapi32 uuid user32 gdi32 bcrypt version windowsapp)

# Preserve the plugins' effective MSVC settings under clang-cl. Diagnostics
# remain visible; these exceptions do not apply to LRDP sources.
get_target_property(file_selector_defines file_selector_windows_plugin COMPILE_DEFINITIONS)
list(REMOVE_ITEM file_selector_defines "_HAS_EXCEPTIONS=0")
set_target_properties(file_selector_windows_plugin PROPERTIES COMPILE_DEFINITIONS "${file_selector_defines}")
target_compile_options(share_plus_plugin PRIVATE
  -Wno-error=inconsistent-missing-override -Wno-error=overloaded-virtual)
target_compile_options(flutter_secure_storage_windows_plugin PRIVATE
  -Wno-error=tautological-pointer-compare -Wno-error=missing-field-initializers)
target_compile_options(url_launcher_windows_plugin PRIVATE -Wno-error=unused-function)
