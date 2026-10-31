cmake_minimum_required(VERSION 3.14)
project(mornye LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "mornye")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

add_subdirectory("runner")


include(flutter/generated_plugins.cmake)

# permission_handler_windows still includes <experimental/coroutine>, which
# MSVC 14.5x rejects unless its deprecation is silenced.
if(TARGET permission_handler_windows_plugin)
  target_compile_definitions(permission_handler_windows_plugin PRIVATE
    "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
endif()

if(TARGET audioplayers_windows_plugin)
  target_include_directories(audioplayers_windows_plugin BEFORE PRIVATE "${CMAKE_BINARY_DIR}/include")
  target_compile_options(audioplayers_windows_plugin PRIVATE "/await")
endif()

if(TARGET flutter_local_notifications_windows)
  target_include_directories(flutter_local_notifications_windows PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/atl_shim")
endif()
if(TARGET flutter_secure_storage_windows_plugin)
  target_include_directories(flutter_secure_storage_windows_plugin PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/atl_shim")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Rust desktop backend, loaded by dart:ffi from next to the executable.
# It is prebuilt by scripts\build_rust_backend_windows.ps1.
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64" OR
   CMAKE_GENERATOR_PLATFORM MATCHES "^(ARM64|arm64)$")
  set(MORNYE_WINDOWS_ARCH "arm64")
  set(MORNYE_RUST_TARGET "aarch64-pc-windows-msvc")
else()
  set(MORNYE_WINDOWS_ARCH "x64")
  set(MORNYE_RUST_TARGET "x86_64-pc-windows-msvc")
endif()
set(MORNYE_DESKTOP_LIBRARY
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust_backend/target/desktop/windows/${MORNYE_WINDOWS_ARCH}/mornye_desktop.dll")
if(NOT EXISTS "${MORNYE_DESKTOP_LIBRARY}")
  message(FATAL_ERROR
    "The Rust desktop backend was not built: ${MORNYE_DESKTOP_LIBRARY} "
    "is missing. Run `pwsh scripts\\build_rust_backend_windows.ps1 "
    "-Target ${MORNYE_RUST_TARGET}` from the "
    "repository root, then build again.")
endif()
install(FILES "${MORNYE_DESKTOP_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# mornye.exe and mornye_desktop.dll link the Visual C++ runtime dynamically.
# Deploy it app-local, next to them, so the installer and the portable zip run
# on PCs without the Visual C++ Redistributable.
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include(InstallRequiredSystemLibraries)
if(MORNYE_WINDOWS_ARCH STREQUAL "arm64")
  # The ARM64 redist also carries the x64 exception-handling runtime.
  # Native ARM64 uses vcruntime140.dll and cannot load that companion.
  list(FILTER CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS EXCLUDE
    REGEX "/vcruntime140_1\\.dll$")
endif()
install(PROGRAMS ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)

# LGPL ffmpeg.exe and ffprobe.exe, found by lib/services/ffmpeg_desktop.dart
# in the ffmpeg\ folder next to the executable. They are staged by
# `bash scripts/fetch_desktop_ffmpeg.sh windows-<arch>`; without them the app
# falls back to an ffmpeg on Path, so a missing stage is only a warning.
set(MORNYE_FFMPEG_TARGET "windows-${MORNYE_WINDOWS_ARCH}")
set(MORNYE_FFMPEG_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../build/ffmpeg/${MORNYE_FFMPEG_TARGET}")
if(EXISTS "${MORNYE_FFMPEG_DIR}/ffmpeg.exe" AND EXISTS "${MORNYE_FFMPEG_DIR}/ffprobe.exe")
  install(PROGRAMS "${MORNYE_FFMPEG_DIR}/ffmpeg.exe" "${MORNYE_FFMPEG_DIR}/ffprobe.exe"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/ffmpeg" COMPONENT Runtime)
  install(FILES "${MORNYE_FFMPEG_DIR}/LICENSE.txt" "${MORNYE_FFMPEG_DIR}/SOURCE.txt"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/ffmpeg" COMPONENT Runtime)
else()
  message(WARNING
    "No LGPL FFmpeg is staged in ${MORNYE_FFMPEG_DIR}; the bundle will use "
    "ffmpeg from Path. Run `bash scripts/fetch_desktop_ffmpeg.sh "
    "${MORNYE_FFMPEG_TARGET}` from the repository root to bundle it.")
endif()

set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
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

install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
