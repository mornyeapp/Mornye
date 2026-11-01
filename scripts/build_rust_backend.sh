#!/usr/bin/env bash
# Stage Rust libraries and UniFFI bindings for the Rust backend, the app's only backend.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUST_BACKEND_DIR="$PROJECT_DIR/rust_backend"
PLATFORM="${1:-host}"

case "$PLATFORM" in
  host|android|ios|desktop) ;;
  *) echo "Usage: bash scripts/build_rust_backend.sh [host|android|ios|desktop]" >&2; exit 1 ;;
esac

if [[ "$PLATFORM" == "android" ]]; then
  ANDROID_ABIS_RAW="${MORNYE_RUST_ANDROID_ABIS-arm64-v8a,armeabi-v7a}"
  case "$ANDROID_ABIS_RAW" in
    arm64-v8a|armeabi-v7a|arm64-v8a,armeabi-v7a|armeabi-v7a,arm64-v8a) ;;
    *)
      echo "Error: MORNYE_RUST_ANDROID_ABIS must contain arm64-v8a and/or armeabi-v7a, comma-separated without spaces or duplicates." >&2
      exit 1
      ;;
  esac
  IFS=',' read -r -a ANDROID_ABIS <<< "$ANDROID_ABIS_RAW"
fi

cd "$RUST_BACKEND_DIR"
export CARGO_TARGET_DIR="$RUST_BACKEND_DIR/target"
# AES 0.9 detects ARM64 AES at runtime and retains the software fallback;
# do not force target-feature=+aes on Android.

# Desktop: the C ABI library loaded by dart:ffi (crates/desktop). It needs no
# UniFFI bindings. Output: target/desktop/<os>/libmornye_desktop.{dylib,so}.
# The macOS app embeds it from an Xcode build phase
# (scripts/embed_rust_backend_macos.sh); linux/CMakeLists.txt installs it.
#
# Windows is built by the PowerShell companion script
# scripts/build_rust_backend_windows.ps1 (cargo build of mornye-desktop for
# x86_64-pc-windows-msvc, or aarch64-pc-windows-msvc with -Target, staged as
# target\desktop\windows\mornye_desktop.dll for windows/CMakeLists.txt).
if [[ "$PLATFORM" == "desktop" ]]; then
  case "$(uname -s)" in
    Darwin)
      # Same default as the host build. The Flutter macOS runner's deployment
      # target must not be older than this.
      export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
      # C dependencies (ring) need the SDK headers. Inside Xcode, `cc` is the
      # toolchain clang rather than the /usr/bin shim, which finds no SDK on
      # its own; naming it here also keeps Xcode and command line builds on
      # one Cargo cache.
      export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
      DESKTOP_DIR="$CARGO_TARGET_DIR/desktop/macos"
      rustup target add aarch64-apple-darwin x86_64-apple-darwin
      for target in aarch64-apple-darwin x86_64-apple-darwin; do
        cargo build --locked --release -p mornye-desktop --target "$target"
      done
      mkdir -p "$DESKTOP_DIR"
      xcrun lipo -create \
        "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libmornye_desktop.dylib" \
        "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libmornye_desktop.dylib" \
        -output "$DESKTOP_DIR/libmornye_desktop.dylib"
      # Load by rpath from the app bundle's Frameworks directory.
      install_name_tool -id "@rpath/libmornye_desktop.dylib" \
        "$DESKTOP_DIR/libmornye_desktop.dylib"
      # install_name_tool drops the linker's ad hoc signature, and arm64
      # refuses unsigned code. The app build re-signs with its identity.
      codesign --force --sign - "$DESKTOP_DIR/libmornye_desktop.dylib"
      ;;
    Linux)
      DESKTOP_DIR="$CARGO_TARGET_DIR/desktop/linux"
      cargo build --locked --release -p mornye-desktop
      mkdir -p "$DESKTOP_DIR"
      cp "$CARGO_TARGET_DIR/release/libmornye_desktop.so" "$DESKTOP_DIR/"
      ;;
    *) echo "Error: use macOS or Linux for desktop builds (Windows: scripts/build_rust_backend_windows.ps1)." >&2; exit 1 ;;
  esac
  echo "Rust desktop library is staged in $DESKTOP_DIR."
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    HOST_LIBRARY="$CARGO_TARGET_DIR/release/libmornye_mobile.dylib"
    # Keep cc-rs (QuickJS) and Rust compatible with the Swift host executable.
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
  Linux) HOST_LIBRARY="$CARGO_TARGET_DIR/release/libmornye_mobile.so" ;;
  *) echo "Error: use macOS or Linux for this build script." >&2; exit 1 ;;
esac

# Build separately from bindgen so CLI and cargo-metadata features are not
# enabled in the shipped library through Cargo's workspace feature unification.
cargo build --locked --release -p mornye-mobile
# Bindgen discovers each crate's uniffi.toml through Cargo metadata.
for language in kotlin swift; do
  cargo run --locked -p mornye-bindgen -- generate \
    --library "$HOST_LIBRARY" \
    --language "$language" \
    --out-dir "$CARGO_TARGET_DIR/bindings/$language" \
    --no-format
done

if [[ "$PLATFORM" == "android" ]]; then
  if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    echo "Error: set ANDROID_NDK_HOME to Android NDK 30.0.16248370." >&2
    exit 1
  fi
  case "$(uname -s)" in
    Darwin) NDK_HOST="darwin-x86_64" ;;
    Linux) NDK_HOST="linux-x86_64" ;;
  esac
  NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/bin"
  NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot"

  ANDROID_TARGETS=()
  ANDROID_LINKERS=()
  for ABI in "${ANDROID_ABIS[@]}"; do
    case "$ABI" in
      arm64-v8a)
        ANDROID_TARGETS+=(aarch64-linux-android)
        ANDROID_LINKERS+=("$NDK_BIN/aarch64-linux-android24-clang")
        # QuickJS is compiled C. Configure cc-rs and libclang for the same
        # target/API as Rust; the host SDK cannot supply Android headers or
        # ABI layouts.
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android24-clang"
        export CC_aarch64_linux_android="$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"
        export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
        export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=\"$NDK_SYSROOT\" --target=aarch64-linux-android24"
        ;;
      armeabi-v7a)
        ANDROID_TARGETS+=(armv7-linux-androideabi)
        ANDROID_LINKERS+=("$NDK_BIN/armv7a-linux-androideabi24-clang")
        export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$NDK_BIN/armv7a-linux-androideabi24-clang"
        export CC_armv7_linux_androideabi="$CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER"
        export AR_armv7_linux_androideabi="$NDK_BIN/llvm-ar"
        export BINDGEN_EXTRA_CLANG_ARGS_armv7_linux_androideabi="--sysroot=\"$NDK_SYSROOT\" --target=armv7a-linux-androideabi24"
        ;;
    esac
  done

  for linker in "${ANDROID_LINKERS[@]}"; do
    if [[ ! -x "$linker" ]]; then
      echo "Error: Android API 24 linker was not found: $linker" >&2
      exit 1
    fi
  done

  rustup target add "${ANDROID_TARGETS[@]}"
  # Align ELF segments for 16 KB pages and pack relocations (Android API 23+).
  # Keep APS2 rather than RELR, which requires API 28; our minimum is API 24.
  # Fold only identical functions whose addresses are not significant.
  export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,--pack-dyn-relocs=android -C link-arg=-Wl,--icf=safe"
  for target in "${ANDROID_TARGETS[@]}"; do
    cargo build --locked --release -p mornye-mobile --target "$target"
    case "$target" in
      aarch64-linux-android) ABI="arm64-v8a" ;;
      armv7-linux-androideabi) ABI="armeabi-v7a" ;;
    esac
    mkdir -p "$CARGO_TARGET_DIR/android/jniLibs/$ABI"
    cp "$CARGO_TARGET_DIR/$target/release/libmornye_mobile.so" \
      "$CARGO_TARGET_DIR/android/jniLibs/$ABI/"
  done
elif [[ "$PLATFORM" == "ios" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: iOS builds require macOS and Xcode." >&2
    exit 1
  fi
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  export IPHONEOS_DEPLOYMENT_TARGET=16.0
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="-isysroot \"$(xcrun --sdk iphoneos --show-sdk-path)\" --target=arm64-apple-ios16.0"
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="-isysroot \"$(xcrun --sdk iphonesimulator --show-sdk-path)\" --target=arm64-apple-ios16.0-simulator"
  export BINDGEN_EXTRA_CLANG_ARGS_x86_64_apple_ios="-isysroot \"$(xcrun --sdk iphonesimulator --show-sdk-path)\" --target=x86_64-apple-ios16.0-simulator"
  for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    cargo build --locked --release -p mornye-mobile --target "$target"
  done
  HEADERS_DIR="$CARGO_TARGET_DIR/ios/headers"
  FRAMEWORK_DIR="$CARGO_TARGET_DIR/ios/MornyeBackendFFI.xcframework"
  SIMULATOR_LIBRARY="$CARGO_TARGET_DIR/ios/simulator/libmornye_mobile.a"
  mkdir -p "$HEADERS_DIR" "$(dirname "$SIMULATOR_LIBRARY")"
  cp "$CARGO_TARGET_DIR/bindings/swift/MornyeBackendFFI.h" "$HEADERS_DIR/"
  cp "$CARGO_TARGET_DIR/bindings/swift/MornyeBackendFFI.modulemap" "$HEADERS_DIR/module.modulemap"
  # Flutter/CocoaPods may request both simulator architectures, even on an
  # ARM64 Mac. Supply one universal simulator slice.
  xcrun lipo -create \
    "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libmornye_mobile.a" \
    "$CARGO_TARGET_DIR/x86_64-apple-ios/release/libmornye_mobile.a" \
    -output "$SIMULATOR_LIBRARY"
  # xcodebuild refuses to overwrite an existing generated XCFramework.
  if [[ -d "$FRAMEWORK_DIR" ]]; then
    rm -rf "$FRAMEWORK_DIR"
  fi
  xcodebuild -create-xcframework \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libmornye_mobile.a" -headers "$HEADERS_DIR" \
    -library "$SIMULATOR_LIBRARY" -headers "$HEADERS_DIR" \
    -output "$FRAMEWORK_DIR"
  # CocoaPods does not traverse nested symlinks, including a relocated target/.
  # Stage one pod root that Podfile can resolve before scanning its files.
  cp "$CARGO_TARGET_DIR/bindings/swift/MornyeBackend.swift" "$CARGO_TARGET_DIR/ios/"
  cp "$RUST_BACKEND_DIR/MornyeBackend.podspec" "$CARGO_TARGET_DIR/ios/"
  cp "$PROJECT_DIR/LICENSE" "$CARGO_TARGET_DIR/ios/"
fi

echo "Rust $PLATFORM artifacts are staged in $CARGO_TARGET_DIR."
