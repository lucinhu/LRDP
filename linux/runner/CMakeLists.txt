cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

# Embed the window icon so it also works when launched from an extracted bundle.
find_program(GLIB_COMPILE_RESOURCES glib-compile-resources REQUIRED)
set(APP_ICONS_SOURCE "${CMAKE_CURRENT_BINARY_DIR}/app_icons.c")
add_custom_command(
  OUTPUT "${APP_ICONS_SOURCE}"
  COMMAND ${GLIB_COMPILE_RESOURCES}
    --generate-source --c-name lrdp_icons --target "${APP_ICONS_SOURCE}"
    --sourcedir "${CMAKE_SOURCE_DIR}/.."
    "${CMAKE_CURRENT_SOURCE_DIR}/app_icons.gresource.xml"
  DEPENDS "app_icons.gresource.xml" "${CMAKE_SOURCE_DIR}/../assets/branding/lrdp-128.png"
  VERBATIM
)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${APP_ICONS_SOURCE}"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
