cmake_minimum_required(VERSION 3.22)
project(lrdp_native LANGUAGES C CXX)
get_filename_component(LRDP_PLUGIN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)
add_subdirectory("${LRDP_PLUGIN_ROOT}/../../native" "${CMAKE_CURRENT_BINARY_DIR}/bridge")
