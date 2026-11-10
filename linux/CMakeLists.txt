cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "mornye")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.zarz.mornye")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "Flutter build bundle" FORCE)

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

# Window icon loaded by my_application.cc. Packaging adds the desktop entry.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/brand/logo/png/mornye-badge@1x.png"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" RENAME "mornye.png"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Rust desktop backend, loaded by dart:ffi from the bundle's lib/ directory.
# It is prebuilt by `bash scripts/build_rust_backend.sh desktop`.
set(MORNYE_DESKTOP_LIBRARY
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust_backend/target/desktop/linux/libmornye_desktop.so")
if(NOT EXISTS "${MORNYE_DESKTOP_LIBRARY}")
  message(FATAL_ERROR
    "The Rust desktop backend was not built: ${MORNYE_DESKTOP_LIBRARY} "
    "is missing. Run `bash scripts/build_rust_backend.sh desktop` from the "
    "repository root, then build again.")
endif()
install(FILES "${MORNYE_DESKTOP_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# LGPL ffmpeg and ffprobe, found by lib/services/ffmpeg_desktop.dart in the
# bundle's lib/ffmpeg/ directory. They are staged by
# `bash scripts/fetch_desktop_ffmpeg.sh linux-<arch>`; without them the app
# falls back to an ffmpeg on PATH, so a missing stage is only a warning.
if(DEFINED FLUTTER_TARGET_PLATFORM)
  set(MORNYE_FFMPEG_TARGET "${FLUTTER_TARGET_PLATFORM}")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(MORNYE_FFMPEG_TARGET "linux-arm64")
else()
  set(MORNYE_FFMPEG_TARGET "linux-x64")
endif()
set(MORNYE_FFMPEG_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../build/ffmpeg/${MORNYE_FFMPEG_TARGET}")
if(EXISTS "${MORNYE_FFMPEG_DIR}/ffmpeg" AND EXISTS "${MORNYE_FFMPEG_DIR}/ffprobe")
  install(PROGRAMS "${MORNYE_FFMPEG_DIR}/ffmpeg" "${MORNYE_FFMPEG_DIR}/ffprobe"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/ffmpeg" COMPONENT Runtime)
  install(FILES "${MORNYE_FFMPEG_DIR}/LICENSE.txt" "${MORNYE_FFMPEG_DIR}/SOURCE.txt"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/ffmpeg" COMPONENT Runtime)
else()
  message(WARNING
    "No LGPL FFmpeg is staged in ${MORNYE_FFMPEG_DIR}; the bundle will use "
    "ffmpeg from PATH. Run `bash scripts/fetch_desktop_ffmpeg.sh "
    "${MORNYE_FFMPEG_TARGET}` from the repository root to bundle it.")
endif()

set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
