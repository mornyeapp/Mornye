cmake_minimum_required(VERSION 3.13)

# Must match the pubspec package name: the Flutter tool looks for the public
# header under include/<package_name>/ and generated_plugins.cmake links
# ${plugin}_plugin and bundles ${plugin}_bundled_libraries.
set(PROJECT_NAME "ffmpeg_kit_flutter_new_audio")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "ffmpeg_kit_flutter_new_audio_plugin")

add_library(${PLUGIN_NAME} SHARED
  "ffmpeg_kit_flutter_plugin.cc"
  "ffmpeg_kit_library_loader.cc"
)

# apply_standard_settings comes from the host application's linux/CMakeLists.txt.
apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# json-glib turns the native layer's JSON strings (session/log/statistics/media
# information) into FlValue. It ships with GNOME and is present on essentially
# every Linux desktop; on Debian/Ubuntu the build-time package is
# libjson-glib-dev, on Fedora json-glib-devel.
pkg_check_modules(JSONGLIB REQUIRED IMPORTED_TARGET json-glib-1.0)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  PkgConfig::GTK
  PkgConfig::JSONGLIB
  ${CMAKE_DL_LIBS}   # dlopen/dlsym for libffmpegkit.so
)

# --- native bundle -----------------------------------------------------------

if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64")
  set(FFMPEGKIT_ARCH "x86_64")
elseif(NOT FFMPEGKIT_LOCAL_DIR AND NOT DEFINED ENV{FFMPEGKIT_LOCAL_DIR})
  # The upstream Linux build only defines ARCH_X86_64
  # (enable_default_linux_architectures in ffmpeg-kit); there is no aarch64
  # plumbing in linux.sh, so no other architecture can be served yet.
  # Mornye patch: build the plugin without the native bundle instead of
  # failing. The plugin dlopen()s libffmpegkit.so and answers every call with
  # an error when it is missing; Mornye desktop runs the bundled ffmpeg CLI.
  message(WARNING
    "ffmpeg_kit_flutter: no Linux bundle for '${CMAKE_SYSTEM_PROCESSOR}'; "
    "building without libffmpegkit. Point FFMPEGKIT_LOCAL_DIR at a bundle "
    "for this architecture to include one.")
  set(ffmpeg_kit_flutter_new_audio_bundled_libraries "" PARENT_SCOPE)
  return()
else()
  set(FFMPEGKIT_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
endif()

# Unpack into the app's build tree, NOT the plugin source directory. When the
# plugin is resolved from the pub cache, Flutter points
# linux/flutter/ephemeral/.plugin_symlinks/<plugin> at the cached package, so
# ${CMAKE_CURRENT_SOURCE_DIR} lives inside ~/.pub-cache. Extracting there writes
# ~19 MB of native libraries into a directory shared by every project on the
# machine, which `flutter clean` never removes and `dart pub cache repair` sees
# as a modified package. It is also what makes the equivalent Windows extract
# fail outright (#165): libarchive refuses to write through the symlink.
#
# CMAKE_CURRENT_BINARY_DIR is per-project and per-configuration
# (build/linux/x64/<config>/plugins/<plugin>), so it is cleaned normally and is
# never reached through a symlink. The cost is one download per build
# configuration rather than one per machine.
set(FFMPEGKIT_PREBUILT_DIR "${CMAKE_CURRENT_BINARY_DIR}/ffmpeg-kit")
# The release this plugin version uses. Plain variables, not cache entries: a
# cached value would outlive an upgrade of the plugin, or a switch to another of
# its packages, in an existing build folder, which would then keep the old
# release's libraries until `flutter clean`.
set(FFMPEGKIT_PACKAGE "audio")
set(FFMPEGKIT_VERSION "8.1.3")
set(FFMPEGKIT_LOCAL_DIR "" CACHE PATH "Path to a locally-built bundle (a dir containing lib/) to use instead of downloading")

if(NOT FFMPEGKIT_LOCAL_DIR AND DEFINED ENV{FFMPEGKIT_LOCAL_DIR})
  set(FFMPEGKIT_LOCAL_DIR "$ENV{FFMPEGKIT_LOCAL_DIR}")
endif()

set(FFMPEGKIT_RELEASE_TAG "${FFMPEGKIT_VERSION}-${FFMPEGKIT_PACKAGE}")
set(FFMPEGKIT_TAR_NAME "ffmpeg-kit-linux-${FFMPEGKIT_ARCH}-${FFMPEGKIT_PACKAGE}-${FFMPEGKIT_VERSION}.tar.gz")
set(FFMPEGKIT_DOWNLOAD_URL "https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/${FFMPEGKIT_RELEASE_TAG}/${FFMPEGKIT_TAR_NAME}")
set(FFMPEGKIT_TAR_PATH "${FFMPEGKIT_PREBUILT_DIR}/${FFMPEGKIT_TAR_NAME}")

# The tarball produced by ffmpeg-kit's linux-variant-builds.yml is created with
# `tar czf ... -C prebuilt/bundle-linux .`, so its root holds ./ffmpeg-kit/lib.
set(FFMPEGKIT_LIB_DIR "${FFMPEGKIT_PREBUILT_DIR}/ffmpeg-kit/lib")

# Marker recording what is installed, so switching variant or pointing at a
# local bundle forces a clean re-fetch instead of mixing two variants' .so files.
set(FFMPEGKIT_MARKER "${FFMPEGKIT_PREBUILT_DIR}/.ffmpegkit_variant")
if(FFMPEGKIT_LOCAL_DIR)
  set(FFMPEGKIT_WANT "local:${FFMPEGKIT_LOCAL_DIR}")
else()
  set(FFMPEGKIT_WANT "${FFMPEGKIT_RELEASE_TAG}-${FFMPEGKIT_ARCH}")
endif()
# Bundle layout revision, recorded in the marker so build trees unpacked by an
# older plugin re-fetch once. 2: libffmpegkit.so with the C API fixes from
# ffmpeg-kit PR #5.
string(APPEND FFMPEGKIT_WANT " layout=2")
set(FFMPEGKIT_HAVE "")
if(EXISTS "${FFMPEGKIT_MARKER}")
  file(READ "${FFMPEGKIT_MARKER}" FFMPEGKIT_HAVE)
  string(STRIP "${FFMPEGKIT_HAVE}" FFMPEGKIT_HAVE)
endif()

if(NOT "${FFMPEGKIT_HAVE}" STREQUAL "${FFMPEGKIT_WANT}")
  file(REMOVE_RECURSE "${FFMPEGKIT_PREBUILT_DIR}/ffmpeg-kit")
  file(MAKE_DIRECTORY "${FFMPEGKIT_PREBUILT_DIR}")
  if(FFMPEGKIT_LOCAL_DIR)
    if(NOT EXISTS "${FFMPEGKIT_LOCAL_DIR}/lib/libffmpegkit.so")
      message(FATAL_ERROR "FFMPEGKIT_LOCAL_DIR=${FFMPEGKIT_LOCAL_DIR} has no lib/libffmpegkit.so")
    endif()
    message(STATUS "FFmpegKit: installing local bundle from ${FFMPEGKIT_LOCAL_DIR}")
    file(MAKE_DIRECTORY "${FFMPEGKIT_PREBUILT_DIR}/ffmpeg-kit")
    file(COPY "${FFMPEGKIT_LOCAL_DIR}/lib" DESTINATION "${FFMPEGKIT_PREBUILT_DIR}/ffmpeg-kit")
  else()
    message(STATUS "FFmpegKit: downloading ${FFMPEGKIT_PACKAGE} from ${FFMPEGKIT_DOWNLOAD_URL}")
    file(DOWNLOAD
      "${FFMPEGKIT_DOWNLOAD_URL}"
      "${FFMPEGKIT_TAR_PATH}"
      SHOW_PROGRESS
      STATUS FFMPEGKIT_DOWNLOAD_STATUS
    )
    list(GET FFMPEGKIT_DOWNLOAD_STATUS 0 FFMPEGKIT_DOWNLOAD_CODE)
    list(GET FFMPEGKIT_DOWNLOAD_STATUS 1 FFMPEGKIT_DOWNLOAD_MSG)
    if(NOT FFMPEGKIT_DOWNLOAD_CODE EQUAL 0)
      file(REMOVE "${FFMPEGKIT_TAR_PATH}")
      message(FATAL_ERROR
        "Failed to download FFmpegKit (${FFMPEGKIT_PACKAGE}): ${FFMPEGKIT_DOWNLOAD_MSG}\n"
        "The Linux bundles are built by ffmpeg-kit's linux-variant-builds.yml; if they "
        "are not yet attached to release ${FFMPEGKIT_RELEASE_TAG}, build locally and set "
        "FFMPEGKIT_LOCAL_DIR to <ffmpeg-kit>/prebuilt/bundle-linux/ffmpeg-kit.")
    endif()
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E tar xzf "${FFMPEGKIT_TAR_PATH}"
      WORKING_DIRECTORY "${FFMPEGKIT_PREBUILT_DIR}"
      RESULT_VARIABLE FFMPEGKIT_UNTAR_RESULT
    )
    file(REMOVE "${FFMPEGKIT_TAR_PATH}")
    if(NOT FFMPEGKIT_UNTAR_RESULT EQUAL 0)
      message(FATAL_ERROR "Failed to extract ${FFMPEGKIT_TAR_NAME}")
    endif()
  endif()
  file(WRITE "${FFMPEGKIT_MARKER}" "${FFMPEGKIT_WANT}\n")
  message(STATUS "FFmpegKit ${FFMPEGKIT_WANT} ready")
endif()

# Glob rather than list: FFmpeg soname bumps (libavcodec.so.61 -> .62) must not
# require editing this file, and the set of external codec .so files differs per
# variant.
file(GLOB FFMPEGKIT_LIBS
  "${FFMPEGKIT_LIB_DIR}/*.so"
  "${FFMPEGKIT_LIB_DIR}/*.so.*")
if(NOT FFMPEGKIT_LIBS)
  message(FATAL_ERROR "FFmpegKit: no shared libraries found in ${FFMPEGKIT_LIB_DIR}")
endif()

# The plugin resolves libffmpegkit.so at runtime with dlopen() rather than
# linking it, so the bundled copy stays the single source of truth and the
# plugin still loads when a variant ships extra codec libraries.
set(ffmpeg_kit_flutter_new_audio_bundled_libraries
  ${FFMPEGKIT_LIBS}
  PARENT_SCOPE
)
