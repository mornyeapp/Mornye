#!/usr/bin/env bash
# Build the supported Android release APKs for Mornye.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/build/app/outputs/flutter-apk"
FLUTTER_ARGS=()
PRODUCTION_BUILD=0
LITE_BUILD=0
for argument in "$@"; do
  case "$argument" in
    --production) PRODUCTION_BUILD=1 ;;
    --lite) LITE_BUILD=1; export MORNYE_DISCORD_SDK=0 ;;
    --target-platform|--target-platform=*|--split-per-abi|--no-split-per-abi)
      echo "Error: set MORNYE_RUST_ANDROID_ABIS to select the release APK architectures." >&2
      exit 1
      ;;
    *) FLUTTER_ARGS+=("$argument") ;;
  esac
done

if [[ "$PRODUCTION_BUILD" == "1" ]]; then
  if [[ "$LITE_BUILD" == "1" ]]; then
    echo "Error: production builds require Discord; --production cannot be combined with --lite." >&2
    exit 1
  fi
  export MORNYE_DISCORD_SDK=1
fi

case "${MORNYE_DISCORD_SDK:-1}" in
  0|1) ;;
  *) echo "Error: MORNYE_DISCORD_SDK must be 0 (Lite) or 1 (full)." >&2; exit 1 ;;
esac

ANDROID_ABIS_RAW="${MORNYE_RUST_ANDROID_ABIS-arm64-v8a,armeabi-v7a}"
case "$ANDROID_ABIS_RAW" in
  arm64-v8a|armeabi-v7a|arm64-v8a,armeabi-v7a|armeabi-v7a,arm64-v8a) ;;
  *)
    echo "Error: MORNYE_RUST_ANDROID_ABIS must contain arm64-v8a and/or armeabi-v7a, comma-separated without spaces or duplicates." >&2
    exit 1
    ;;
esac
export MORNYE_RUST_ANDROID_ABIS="$ANDROID_ABIS_RAW"
IFS=',' read -r -a ANDROID_ABIS <<< "$ANDROID_ABIS_RAW"
TARGET_PLATFORMS=()
for abi in "${ANDROID_ABIS[@]}"; do
  case "$abi" in
    arm64-v8a) TARGET_PLATFORMS+=(android-arm64) ;;
    armeabi-v7a) TARGET_PLATFORMS+=(android-arm) ;;
  esac
done
TARGET_PLATFORM_LIST="$(IFS=','; echo "${TARGET_PLATFORMS[*]}")"

if [[ "$PRODUCTION_BUILD" == "1" ]]; then
  SDK_ROOT="$PROJECT_DIR/third_party/mornye_discord/sdk"
  for sdk_file in discord_partner_sdk.aar notices/Discord-License-Notices.txt android/prefab/modules/discord_partner_sdk/include/discordpp.h; do
    if [[ ! -f "$SDK_ROOT/$sdk_file" ]]; then
      echo "Error: production requires the staged Discord SDK ($sdk_file). Run scripts/setup_discord_sdk.sh with the official SDK first." >&2
      exit 1
    fi
  done
  for abi in "${ANDROID_ABIS[@]}"; do
    if [[ ! -f "$SDK_ROOT/android/jni/$abi/libdiscord_partner_sdk.so" ]]; then
      echo "Error: production requires the Discord SDK library for $abi." >&2
      exit 1
    fi
  done
fi

AUDIT_FLAGS=()
if [[ "${MORNYE_DISCORD_SDK:-1}" != "0" && -f "$PROJECT_DIR/third_party/mornye_discord/sdk/discord_partner_sdk.aar" ]]; then
  AUDIT_FLAGS+=(--discord-sdk)
fi

cd "$PROJECT_DIR"
if [[ -x "$PROJECT_DIR/.fvm/flutter_sdk/bin/flutter" ]]; then
  FLUTTER_COMMAND=("$PROJECT_DIR/.fvm/flutter_sdk/bin/flutter")
  DART_COMMAND=("$PROJECT_DIR/.fvm/flutter_sdk/bin/dart")
elif command -v fvm >/dev/null 2>&1; then
  FLUTTER_COMMAND=(fvm flutter)
  DART_COMMAND=(fvm dart)
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER_COMMAND=(flutter)
  DART_COMMAND=(dart)
else
  echo "Error: install the Flutter version pinned in .fvmrc with FVM." >&2
  exit 1
fi
PINNED_FLUTTER_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["flutter"])' "$PROJECT_DIR/.fvmrc")"
FLUTTER_VERSION="$("${FLUTTER_COMMAND[@]}" --version --machine | python3 -c 'import json, sys; print(json.load(sys.stdin)["frameworkVersion"])')"
if [[ "$FLUTTER_VERSION" != "$PINNED_FLUTTER_VERSION" ]]; then
  echo "Error: Flutter $PINNED_FLUTTER_VERSION is required; found $FLUTTER_VERSION." >&2
  exit 1
fi
"${DART_COMMAND[@]}" scripts/prepare_flutter_sdk.dart
BUILD_GIT_COMMIT="$(git rev-parse --short=8 HEAD)"
"${FLUTTER_COMMAND[@]}" build apk \
  --release \
  --obfuscate \
  --split-debug-info "$PROJECT_DIR/build/symbols/android" \
  --split-per-abi \
  --target-platform "$TARGET_PLATFORM_LIST" \
  --dart-define="GIT_COMMIT=$BUILD_GIT_COMMIT" \
  ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}

APKSIGNER="$(find "${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools" -name apksigner -type f 2>/dev/null | sort -V | tail -n 1 || command -v apksigner || true)"
DEBUG_KEYSTORE="$HOME/.android/debug.keystore"
if [[ ! -f "$PROJECT_DIR/android/key.properties" && -n "$APKSIGNER" && -x "$APKSIGNER" && -f "$DEBUG_KEYSTORE" ]]; then
  for target in "${ANDROID_ABIS[@]}" universal; do
    apk="app-$target-release.apk"
    if [[ "$target" == "universal" ]]; then
      apk=app-release.apk
    fi
    if [[ -f "$OUTPUT_DIR/$apk" ]]; then
      "$APKSIGNER" sign \
        --ks "$DEBUG_KEYSTORE" \
        --ks-pass pass:android \
        --key-pass pass:android \
        --ks-key-alias androiddebugkey \
        --v1-signing-enabled true \
        --v2-signing-enabled true \
        --v3-signing-enabled true \
        "$OUTPUT_DIR/$apk"
    fi
  done
fi

for target in "${ANDROID_ABIS[@]}" universal; do
  apk="app-$target-release.apk"
  abis="$target"
  if [[ "$target" == "universal" ]]; then
    apk=app-release.apk
    abis="$ANDROID_ABIS_RAW"
  fi
  if [[ ! -f "$OUTPUT_DIR/$apk" ]]; then
    echo "Error: expected APK was not created: $OUTPUT_DIR/$apk" >&2
    exit 1
  fi
  python3 scripts/check_backend_apk.py "$OUTPUT_DIR/$apk" \
    --backend rust --abis "$abis" ${AUDIT_FLAGS[@]+"${AUDIT_FLAGS[@]}"}
done

echo "Built Android release APKs in $OUTPUT_DIR"
