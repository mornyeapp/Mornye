cmake_minimum_required(VERSION 3.22.1)
project(mornye_audio LANGUAGES C CXX)

include(FetchContent)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
if(ANDROID)
    # Optimize WavPack and Oboe for size and strip unused C++
    # exception/RTTI/section overhead; JNI entry points remain visible via
    # native_audio.map.
    add_compile_options(
        -Os
        -ffunction-sections
        -fdata-sections
        $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions>
        $<$<COMPILE_LANGUAGE:CXX>:-fno-rtti>
    )
    if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
        add_compile_options(-flto=thin)
    endif()
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_CXXLIBS OFF CACHE BOOL "" FORCE)
set(BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(INSTALL_MANPAGES OFF CACHE BOOL "" FORCE)
set(INSTALL_PKGCONFIG_MODULES OFF CACHE BOOL "" FORCE)
set(INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(WITH_OGG OFF CACHE BOOL "" FORCE)
set(ENABLE_MULTITHREADING OFF CACHE BOOL "" FORCE)
FetchContent_Declare(flac
    URL https://github.com/xiph/flac/archive/refs/tags/1.5.0.tar.gz
    URL_HASH SHA256=aea54ed186ad07a34750399cb27fc216a2b62d0ffcd6dc2e3064a3518c3146f8)
function(mornye_add_flac)
    if(ANDROID)
        # The NDK's legacy toolchain reports CMAKE_SYSTEM_VERSION=1. libFLAC
        # uses it to gate 64-bit file seeks, which Android supports from API 24.
        set(CMAKE_SYSTEM_VERSION ${ANDROID_NATIVE_API_LEVEL})
        include(CheckSymbolExists)
        check_symbol_exists(fseeko "stdio.h" MORNYE_HAVE_FSEEKO)
        set(HAVE_FSEEKO ${MORNYE_HAVE_FSEEKO} CACHE INTERNAL "fseeko is declared" FORCE)
    endif()
    FetchContent_MakeAvailable(flac)
endfunction()
mornye_add_flac()
if(ANDROID)
    # FLAC decoding and our sample loops keep the speed level: at -Os the
    # decoder is 4 percent slower and the conversion loops are not vectorized.
    set(MORNYE_AUDIO_SPEED -O2)
    target_compile_options(FLAC PRIVATE ${MORNYE_AUDIO_SPEED})
endif()
add_library(mornye_flac STATIC flac_pcm_source.cpp)
target_compile_features(mornye_flac PRIVATE cxx_std_17)
target_compile_options(mornye_flac PRIVATE
    -Wall -Wextra -Werror -fvisibility=hidden ${MORNYE_AUDIO_SPEED})
target_link_libraries(mornye_flac PUBLIC FLAC::FLAC)

option(MORNYE_AUDIO_HOST_TESTS "Test the lossless decoder without Android" OFF)
if(MORNYE_AUDIO_HOST_TESTS)
    enable_testing()
    add_executable(flac_pcm_source_test tests/flac_pcm_source_test.cpp)
    target_compile_features(flac_pcm_source_test PRIVATE cxx_std_17)
    target_compile_options(flac_pcm_source_test PRIVATE -Wall -Wextra -Werror)
    target_link_libraries(flac_pcm_source_test PRIVATE mornye_flac)
    add_test(NAME flac_pcm_source COMMAND flac_pcm_source_test)
    return()
endif()

set(OBOE_DISABLE_CONVERSION ON CACHE BOOL "" FORCE)
set(WAVPACK_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_DSD ON CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_THREADS OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_ASM OFF CACHE BOOL "" FORCE)

# Immutable releases plus checksums keep local and CI builds identical.
FetchContent_Declare(oboe
    URL https://github.com/google/oboe/archive/refs/tags/1.11.0.tar.gz
    URL_HASH SHA256=0ccf2110640a2b4489f1c93a404f2978656b434d8c5dc9cb6258f9cc95c79b15)
FetchContent_Declare(wavpack
    URL https://github.com/dbry/WavPack/archive/refs/tags/5.9.0.tar.gz
    URL_HASH SHA256=2a53e50aefd8c9f04a0828a0e1ef77b6f4c17b0ef6964ad234ab295f313b7d6d)
FetchContent_MakeAvailable(oboe wavpack)

add_library(mornye_audio SHARED native_audio.cpp)
target_compile_features(mornye_audio PRIVATE cxx_std_17)
target_compile_options(mornye_audio PRIVATE
    -Wall -Wextra -Werror -fvisibility=hidden ${MORNYE_AUDIO_SPEED})
target_link_libraries(mornye_audio PRIVATE oboe WavPack::WavPack mornye_flac log)
# Only JNI is public; static Oboe/WavPack/C++ implementation symbols must not
# keep otherwise unused code alive. APS2 is supported by our minimum API 24.
target_link_options(mornye_audio PRIVATE
    "-Wl,--gc-sections"
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script,${CMAKE_CURRENT_SOURCE_DIR}/native_audio.map"
    "-Wl,--icf=safe"
    "-Wl,--pack-dyn-relocs=android"
    $<$<OR:$<CONFIG:Release>,$<CONFIG:RelWithDebInfo>>:-flto=thin>)
set_property(TARGET mornye_audio APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/native_audio.map")
