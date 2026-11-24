# Adapted from media_kit_libs_windows_audio 1.0.9 under ../LICENSE.
cmake_minimum_required(VERSION 3.14)
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)
set(PROJECT_NAME "media_kit_libs_windows_audio")
project(${PROJECT_NAME} LANGUAGES CXX)

set(LIBMPV_RELEASE "2026-11-24-35efcf53d5")
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64" OR
   CMAKE_GENERATOR_PLATFORM MATCHES "^(ARM64|arm64)$" OR
   CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  set(LIBMPV "mpv-dev-lgpl-aarch64-20261124-git-35efcf53d5.7z")
  set(LIBMPV_HASH "SHA256=1570f8eb451fa1a239dfa30ccc1fd327ee0f0b5cb7ebfac4be92548d9ca97f19")
else()
  set(LIBMPV "mpv-dev-lgpl-x86_64-20261124-git-35efcf53d5.7z")
  set(LIBMPV_HASH "SHA256=9fbf5d6df03b914fa211f884685cf072b989840c0084f9dddcd33164de8e03f0")
endif()
set(LIBMPV_URL "https://github.com/zhongfly/mpv-winbuild/releases/download/${LIBMPV_RELEASE}/${LIBMPV}")

set(LIBMPV_ARCHIVE "${CMAKE_CURRENT_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_CURRENT_BINARY_DIR}/${LIBMPV}-extracted")
file(DOWNLOAD "${LIBMPV_URL}" "${LIBMPV_ARCHIVE}"
  EXPECTED_HASH "${LIBMPV_HASH}" TLS_VERIFY ON STATUS LIBMPV_DOWNLOAD_STATUS)
list(GET LIBMPV_DOWNLOAD_STATUS 0 LIBMPV_DOWNLOAD_CODE)
if(NOT LIBMPV_DOWNLOAD_CODE EQUAL 0)
  message(FATAL_ERROR "Downloading libmpv failed: ${LIBMPV_DOWNLOAD_STATUS}")
endif()
if(NOT EXISTS "${LIBMPV_SRC}/.complete")
  file(REMOVE_RECURSE "${LIBMPV_SRC}")
  file(MAKE_DIRECTORY "${LIBMPV_SRC}")
  find_program(LIBMPV_7ZIP NAMES 7z 7zz HINTS "$ENV{ProgramFiles}/7-Zip")
  if(LIBMPV_7ZIP)
    execute_process(COMMAND "${LIBMPV_7ZIP}" x -y "-o${LIBMPV_SRC}" "${LIBMPV_ARCHIVE}"
      RESULT_VARIABLE LIBMPV_EXTRACT_STATUS OUTPUT_QUIET)
  else()
    find_program(LIBMPV_TAR tar REQUIRED)
    execute_process(COMMAND "${LIBMPV_TAR}" xf "${LIBMPV_ARCHIVE}"
      WORKING_DIRECTORY "${LIBMPV_SRC}" RESULT_VARIABLE LIBMPV_EXTRACT_STATUS)
  endif()
  if(NOT LIBMPV_EXTRACT_STATUS EQUAL 0)
    file(REMOVE_RECURSE "${LIBMPV_SRC}")
    message(FATAL_ERROR "Extracting libmpv failed. Install 7-Zip and rebuild.")
  endif()
  if(NOT EXISTS "${LIBMPV_SRC}/libmpv-2.dll")
    message(FATAL_ERROR "The libmpv archive contains no playback DLL.")
  endif()
  file(WRITE "${LIBMPV_SRC}/.complete" "${LIBMPV_HASH}")
endif()

set(PLUGIN_NAME "media_kit_libs_windows_audio_plugin")
add_library(${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_audio/media_kit_libs_windows_audio_plugin_c_api.h"
  "media_kit_libs_windows_audio_plugin_c_api.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
set(media_kit_libs_windows_audio_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll" PARENT_SCOPE)

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../LICENSE"
  "${CMAKE_CURRENT_SOURCE_DIR}/../SOURCE.txt"
  DESTINATION "$<TARGET_FILE_DIR:${BINARY_NAME}>/licenses/${PROJECT_NAME}"
  COMPONENT Runtime)
# Flutter adds this plugin through windows/flutter/ephemeral/.plugin_symlinks,
# so a path relative to this file does not reach the app. CMAKE_SOURCE_DIR is
# the app's windows/ folder.
install(FILES "${CMAKE_SOURCE_DIR}/../assets/licenses/lgpl-3.0.txt"
  DESTINATION "$<TARGET_FILE_DIR:${BINARY_NAME}>/licenses/${PROJECT_NAME}"
  COMPONENT Runtime)
