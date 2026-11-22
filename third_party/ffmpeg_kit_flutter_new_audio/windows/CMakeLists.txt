cmake_minimum_required(VERSION 3.14)

# Must match the pubspec package name so the generated public header lands at
# include/ffmpeg_kit_flutter_new_audio/ where generated_plugin_registrant.cc expects it.
set(PROJECT_NAME "ffmpeg_kit_flutter_new_audio")
project(${PROJECT_NAME} LANGUAGES CXX)

# Must match the Flutter plugin target name derived from the pubspec package
# name (ffmpeg_kit_flutter_new_audio): generated_plugins.cmake links ${plugin}_plugin
# and bundles ${plugin}_bundled_libraries.
set(PLUGIN_NAME "ffmpeg_kit_flutter_new_audio_plugin")

add_library(${PLUGIN_NAME} SHARED
  "ffmpeg_kit_flutter_plugin.cpp"
  "ffmpeg_kit_flutter_plugin_c_api.cpp"
)

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_STANDARD 17
  CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

set(PUBLIC_HEADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/include/${PROJECT_NAME}")
file(MAKE_DIRECTORY "${PUBLIC_HEADER_DIR}")
file(WRITE "${PUBLIC_HEADER_DIR}/f_fmpeg_kit_flutter_plugin.h" [=[
#ifndef FLUTTER_PLUGIN_FFMPEG_KIT_FLUTTER_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_FFMPEG_KIT_FLUTTER_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FFmpegKitFlutterPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}
#endif

#endif  // FLUTTER_PLUGIN_FFMPEG_KIT_FLUTTER_PLUGIN_C_API_H_
]=])

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}")
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_BINARY_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64" OR
   CMAKE_GENERATOR_PLATFORM MATCHES "^(ARM64|arm64)$" OR
   CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  # There is no upstream ARM64 bundle. The plugin reports LIBRARY_NOT_LOADED;
  # Mornye desktop runs the separately bundled native FFmpeg executables.
  if(NOT FFMPEGKIT_LOCAL_DIR AND NOT DEFINED ENV{FFMPEGKIT_LOCAL_DIR})
    set(ffmpeg_kit_flutter_new_audio_bundled_libraries "" PARENT_SCOPE)
    return()
  endif()
  set(FFMPEGKIT_ARCH "aarch64")
elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
  set(FFMPEGKIT_ARCH "x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "X86" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "i686")
  set(FFMPEGKIT_ARCH "i686")
elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "ARM64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
  set(FFMPEGKIT_ARCH "aarch64")
else()
  set(FFMPEGKIT_ARCH "x86_64")
endif()

# Unpack into the app's build tree, NOT the plugin source directory. When the
# plugin is resolved from the pub cache, Flutter points
# windows/flutter/ephemeral/.plugin_symlinks/<plugin> at the cached package, so
# ${CMAKE_CURRENT_SOURCE_DIR} lives inside the pub cache. Extracting there makes
# `cmake -E tar` fail outright, because libarchive refuses to write through a
# symlink (#165):
#
#   Cannot extract through symlink ...\.plugin_symlinks\<plugin>
#
# It also wrote the unpacked DLLs into a directory shared by every project on
# the machine, which `flutter clean` never removes.
#
# CMAKE_CURRENT_BINARY_DIR is per-project and per-configuration, so it is
# cleaned normally and is never reached through a symlink. The cost is one
# download per build configuration rather than one per machine.
set(FFMPEGKIT_PREBUILT_DIR "${CMAKE_CURRENT_BINARY_DIR}/ffmpeg-kit")
message(STATUS "FFmpegKit prebuilt dir: ${FFMPEGKIT_PREBUILT_DIR} (arch: ${FFMPEGKIT_ARCH})")

# FFmpegKit package variant to consume.
#
# This branch ships the "audio" variant, so the default is "audio": the
# audio-codec set (no GPL) — lame, libilbc, libvorbis, opencore-amr, opus, shine,
# soxr, speex, twolame. The variant name is an emergent property of that library
# set (see windows/src/Packages.cpp).
#   * The CANONICAL audio build (reports "audio") is produced by
#     `FFMPEGKIT_VARIANT=audio ./windows.sh` in ffmpeg-kit — consume a self-built bundle by setting
#     FFMPEGKIT_LOCAL_DIR.
# audio contains no GPL components and stays under the default LGPL 3.0 license.
#
# The release this plugin version uses. Plain variables, not cache entries: a
# cached value would outlive an upgrade of the plugin, or a switch to another of
# its packages, in an existing build folder, which would then keep the old
# release's libraries until `flutter clean`.
set(FFMPEGKIT_PACKAGE "audio")
set(FFMPEGKIT_VERSION "8.1.3")
set(FFMPEGKIT_LOCAL_DIR "" CACHE PATH "Path to a locally-built bundle (dir containing bin/ [+ include/]) to use instead of downloading")

# Allow pointing at a local bundle via the environment too, so it can be set
# without forwarding -D through `flutter run/build` (which inherits the env):
#   set FFMPEGKIT_LOCAL_DIR=C:/.../ffmpeg-kit/prebuilt/bundle-windows-x86_64/ffmpeg-kit
if(NOT FFMPEGKIT_LOCAL_DIR AND DEFINED ENV{FFMPEGKIT_LOCAL_DIR})
  set(FFMPEGKIT_LOCAL_DIR "$ENV{FFMPEGKIT_LOCAL_DIR}")
endif()

# The Windows native libraries are published under the per-variant GitHub
# release tag (e.g. 8.0.0-full) shared with the iOS/macOS assets; the
# windows-specific zip name keeps them from colliding with other platforms.
set(FFMPEGKIT_RELEASE_TAG "${FFMPEGKIT_VERSION}-${FFMPEGKIT_PACKAGE}")
set(FFMPEGKIT_ZIP_NAME "ffmpeg-kit-windows-${FFMPEGKIT_ARCH}-${FFMPEGKIT_PACKAGE}-${FFMPEGKIT_VERSION}.zip")
set(FFMPEGKIT_DOWNLOAD_URL "https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/${FFMPEGKIT_RELEASE_TAG}/${FFMPEGKIT_ZIP_NAME}")
set(FFMPEGKIT_ZIP_PATH "${FFMPEGKIT_PREBUILT_DIR}/${FFMPEGKIT_ZIP_NAME}")

# Marker recording which variant is currently installed, so changing
# FFMPEGKIT_PACKAGE / FFMPEGKIT_LOCAL_DIR triggers a clean re-fetch.
set(FFMPEGKIT_MARKER "${FFMPEGKIT_PREBUILT_DIR}/bin/.ffmpegkit_variant")
if(FFMPEGKIT_LOCAL_DIR)
  set(FFMPEGKIT_WANT "local:${FFMPEGKIT_LOCAL_DIR}")
else()
  set(FFMPEGKIT_WANT "${FFMPEGKIT_RELEASE_TAG}")
endif()
# Legacy workaround, off by default: rebase the bundled DLLs below 4 GB and
# clear DYNAMIC_BASE/HIGH_ENTROPY_VA on them. See the comment where it applies.
option(FFMPEGKIT_DISABLE_ASLR "Rebase the bundled DLLs and turn off ASLR on them (needs MSVC editbin)" OFF)
# Like FFMPEGKIT_LOCAL_DIR it can also come from the environment, since
# `flutter build windows` does not forward -D options. When set, it overrides
# the cached option for this configure run only, so unsetting it restores the
# cached value (OFF unless set with -D).
if(DEFINED ENV{FFMPEGKIT_DISABLE_ASLR})
  set(FFMPEGKIT_DISABLE_ASLR "$ENV{FFMPEGKIT_DISABLE_ASLR}")
endif()

# Bundle layout revision, recorded in the marker so build trees unpacked by an
# older plugin re-fetch once. 2: the archive carries LICENSES/. 3: the DLLs are
# no longer patched in place, so trees holding patched copies get fresh ones.
# 4: libffmpegkit.dll with working registered pipes (#175) and the C API fixes
# from ffmpeg-kit PR #5.
string(APPEND FFMPEGKIT_WANT " layout=4")
if(FFMPEGKIT_DISABLE_ASLR)
  # The workaround rewrites the DLLs in place, so toggling it must re-fetch.
  string(APPEND FFMPEGKIT_WANT " aslr=off")
endif()
set(FFMPEGKIT_HAVE "")
if(EXISTS "${FFMPEGKIT_MARKER}")
  file(READ "${FFMPEGKIT_MARKER}" FFMPEGKIT_HAVE)
  string(STRIP "${FFMPEGKIT_HAVE}" FFMPEGKIT_HAVE)
endif()

if(NOT "${FFMPEGKIT_HAVE}" STREQUAL "${FFMPEGKIT_WANT}")
  file(REMOVE_RECURSE "${FFMPEGKIT_PREBUILT_DIR}/bin" "${FFMPEGKIT_PREBUILT_DIR}/LICENSES")
  file(MAKE_DIRECTORY "${FFMPEGKIT_PREBUILT_DIR}")
  if(FFMPEGKIT_LOCAL_DIR)
    if(NOT EXISTS "${FFMPEGKIT_LOCAL_DIR}/bin/libffmpegkit.dll")
      message(FATAL_ERROR "FFMPEGKIT_LOCAL_DIR=${FFMPEGKIT_LOCAL_DIR} has no bin/libffmpegkit.dll")
    endif()
    message(STATUS "FFmpegKit: installing local bundle from ${FFMPEGKIT_LOCAL_DIR}")
    file(COPY "${FFMPEGKIT_LOCAL_DIR}/bin" DESTINATION "${FFMPEGKIT_PREBUILT_DIR}")
    if(EXISTS "${FFMPEGKIT_LOCAL_DIR}/include")
      file(REMOVE_RECURSE "${FFMPEGKIT_PREBUILT_DIR}/include")
      file(COPY "${FFMPEGKIT_LOCAL_DIR}/include" DESTINATION "${FFMPEGKIT_PREBUILT_DIR}")
    endif()
    if(EXISTS "${FFMPEGKIT_LOCAL_DIR}/LICENSES")
      file(COPY "${FFMPEGKIT_LOCAL_DIR}/LICENSES" DESTINATION "${FFMPEGKIT_PREBUILT_DIR}")
    endif()
  else()
    message(STATUS "FFmpegKit: downloading ${FFMPEGKIT_PACKAGE} from ${FFMPEGKIT_DOWNLOAD_URL}")
    file(DOWNLOAD
      "${FFMPEGKIT_DOWNLOAD_URL}"
      "${FFMPEGKIT_ZIP_PATH}"
      SHOW_PROGRESS
      STATUS FFMPEGKIT_DOWNLOAD_STATUS
    )
    list(GET FFMPEGKIT_DOWNLOAD_STATUS 0 FFMPEGKIT_DOWNLOAD_CODE)
    list(GET FFMPEGKIT_DOWNLOAD_STATUS 1 FFMPEGKIT_DOWNLOAD_MSG)
    if(NOT FFMPEGKIT_DOWNLOAD_CODE EQUAL 0)
      file(REMOVE "${FFMPEGKIT_ZIP_PATH}")
      message(FATAL_ERROR "Failed to download FFmpegKit (${FFMPEGKIT_PACKAGE}): ${FFMPEGKIT_DOWNLOAD_MSG}")
    endif()
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E tar xf "${FFMPEGKIT_ZIP_PATH}"
      WORKING_DIRECTORY "${FFMPEGKIT_PREBUILT_DIR}"
      RESULT_VARIABLE FFMPEGKIT_UNZIP_RESULT
    )
    file(REMOVE "${FFMPEGKIT_ZIP_PATH}")
    if(NOT FFMPEGKIT_UNZIP_RESULT EQUAL 0)
      message(FATAL_ERROR "Failed to extract FFmpegKit archive")
    endif()
  endif()
  file(WRITE "${FFMPEGKIT_MARKER}" "${FFMPEGKIT_WANT}\n")
  message(STATUS "FFmpegKit ${FFMPEGKIT_WANT} ready")
endif()

# Bundle every DLL shipped in the prebuilt bin/. The audio codecs link statically
# into the av* DLLs, so bin/ is just the av*/libffmpegkit DLLs plus the MinGW
# runtime; globbing is robust to FFmpeg soname bumps (avcodec-61 -> 62, etc.)
# without editing this list.
file(GLOB FFMPEGKIT_DLLS "${FFMPEGKIT_PREBUILT_DIR}/bin/*.dll")
if(NOT FFMPEGKIT_DLLS)
  message(FATAL_ERROR "FFmpegKit: no DLLs found in ${FFMPEGKIT_PREBUILT_DIR}/bin")
endif()

# The bundled DLLs keep DYNAMIC_BASE and HIGH_ENTROPY_VA. MinGW patches each
# reference to another DLL's data at load time (a runtime pseudo-relocation),
# and a 32-bit one overflows once the two DLLs load more than 2 GB apart. Every
# pseudo-relocation in the published bundles is 64-bit, so they work at any
# load address and need no rebasing.
#
# Earlier versions rebased every DLL below 4 GB and turned ASLR off to guard
# against that overflow. FFMPEGKIT_DISABLE_ASLR keeps the workaround for a
# self-built bundle (FFMPEGKIT_LOCAL_DIR) that does contain 32-bit ones.
if(FFMPEGKIT_DISABLE_ASLR)
  get_filename_component(MSVC_TOOLS_DIR "${CMAKE_CXX_COMPILER}" DIRECTORY)
  find_program(EDITBIN_EXECUTABLE editbin HINTS "${MSVC_TOOLS_DIR}" REQUIRED)

  add_custom_command(
      OUTPUT "${FFMPEGKIT_PREBUILT_DIR}/bin/.high_entropy_patched"
      COMMAND "${EDITBIN_EXECUTABLE}" /NOLOGO /HIGHENTROPYVA:NO /DYNAMICBASE:NO /REBASE:BASE=0x10000000 ${FFMPEGKIT_DLLS}
      COMMAND ${CMAKE_COMMAND} -E touch "${FFMPEGKIT_PREBUILT_DIR}/bin/.high_entropy_patched"
      DEPENDS ${FFMPEGKIT_DLLS}
      COMMENT "Patching MinGW FFmpegKit DLLs (ASLR off + rebase)"
  )
  add_custom_target(patch_ffmpegkit_dlls DEPENDS "${FFMPEGKIT_PREBUILT_DIR}/bin/.high_entropy_patched")
  add_dependencies(${PLUGIN_NAME} patch_ffmpegkit_dlls)
endif()

set(ffmpeg_kit_flutter_new_audio_bundled_libraries
  ${FFMPEGKIT_DLLS}
  PARENT_SCOPE
)

# Ship the bundle's license notices (FFmpeg, FFmpegKit and every third-party
# DLL above) with the app, in licenses/<package>/ next to the executable.
# The runner only points CMAKE_INSTALL_PREFIX at its output directory after the
# plugins are added, and a relative DESTINATION would be joined to that
# unevaluated generator expression, so on a fresh build tree target the
# runner's output directory directly, the same way the runner does.
if(EXISTS "${FFMPEGKIT_PREBUILT_DIR}/LICENSES")
  if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT AND DEFINED BINARY_NAME)
    set(FFMPEGKIT_LICENSES_DEST "$<TARGET_FILE_DIR:${BINARY_NAME}>")
  else()
    set(FFMPEGKIT_LICENSES_DEST "${CMAKE_INSTALL_PREFIX}")
  endif()
  install(DIRECTORY "${FFMPEGKIT_PREBUILT_DIR}/LICENSES/"
    DESTINATION "${FFMPEGKIT_LICENSES_DEST}/licenses/${PROJECT_NAME}"
    COMPONENT Runtime)
else()
  message(WARNING "FFmpegKit: the bundle has no LICENSES/ directory, so no "
    "license notices are installed with the app. Ship the FFmpeg and "
    "third-party DLL notices yourself.")
endif()
