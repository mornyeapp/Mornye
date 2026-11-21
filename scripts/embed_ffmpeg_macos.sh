#!/usr/bin/env bash
# Xcode Run Script phase of the macOS Runner target ("Embed FFmpeg").
# Copies the LGPL ffmpeg and ffprobe staged by scripts/fetch_desktop_ffmpeg.sh
# (with LICENSE.txt and SOURCE.txt) into <App>.app/Contents/Resources/ffmpeg,
# where lib/services/ffmpeg_desktop.dart looks first, and signs them.
#
# Staged folders, in order of preference:
#   build/ffmpeg/macos-universal  (bash scripts/fetch_desktop_ffmpeg.sh macos-universal)
#   build/ffmpeg/macos-<host arch>
# When none is staged the phase only warns, so developer builds keep working
# with an ffmpeg on PATH. Set MORNYE_REQUIRE_FFMPEG=1 (CI and releases) to
# fail instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGE_ROOT="$PROJECT_DIR/build/ffmpeg"
FILES=(ffmpeg ffprobe LICENSE.txt SOURCE.txt)

: "${TARGET_BUILD_DIR:?Run this script from the Xcode build of the macOS Runner target.}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Run this script from the Xcode build of the macOS Runner target.}"

DESTINATION_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ffmpeg"

host_arch() {
  case "$(uname -m)" in
    arm64) echo arm64 ;;
    *) echo x64 ;;
  esac
}

is_staged() {
  local file
  for file in "${FILES[@]}"; do
    [[ -f "$1/$file" ]] || return 1
  done
}

SOURCE_DIR=""
CANDIDATES=()
case "${MORNYE_MACOS_ARCH:-}" in
  arm64) CANDIDATES=("$STAGE_ROOT/macos-arm64" "$STAGE_ROOT/macos-universal") ;;
  x64|x86_64) CANDIDATES=("$STAGE_ROOT/macos-x64" "$STAGE_ROOT/macos-universal") ;;
  *) CANDIDATES=("$STAGE_ROOT/macos-universal" "$STAGE_ROOT/macos-$(host_arch)") ;;
esac
for candidate in "${CANDIDATES[@]}"; do
  if is_staged "$candidate"; then
    SOURCE_DIR="$candidate"
    break
  fi
done

# Never leave binaries from an earlier build in the bundle.
rm -rf "$DESTINATION_DIR"

if [[ -z "$SOURCE_DIR" ]]; then
  message="no LGPL FFmpeg is staged in $STAGE_ROOT/macos-universal or macos-$(host_arch). Run: bash scripts/fetch_desktop_ffmpeg.sh macos-universal"
  if [[ "${MORNYE_REQUIRE_FFMPEG:-0}" == "1" ]]; then
    echo "error: $message" >&2
    exit 1
  fi
  echo "warning: $message. The app falls back to ffmpeg on PATH."
  exit 0
fi

# A single-architecture FFmpeg cannot serve every slice of a universal app.
for arch in ${ARCHS:-}; do
  if ! lipo "$SOURCE_DIR/ffmpeg" -verify_arch "$arch" 2>/dev/null; then
    echo "warning: $SOURCE_DIR/ffmpeg has no $arch slice; that architecture falls back to ffmpeg on PATH."
  fi
done

mkdir -p "$DESTINATION_DIR"
for file in "${FILES[@]}"; do
  cp -f "$SOURCE_DIR/$file" "$DESTINATION_DIR/$file"
done
for lib in "$SOURCE_DIR"/lib*.dylib; do
  [[ -e "$lib" || -L "$lib" ]] || continue
  cp -a "$lib" "$DESTINATION_DIR/$(basename "$lib")"
done
chmod 755 "$DESTINATION_DIR/ffmpeg" "$DESTINATION_DIR/ffprobe"

# Nested code must be signed before Xcode signs the app. The app ships
# unsigned for now (ad hoc, "-"); a configured identity is used when present.
# The hardened runtime is what notarization requires of executables.
SIGN_IDENTITY="-"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY"
fi
for lib in "$DESTINATION_DIR"/lib*.dylib; do
  [[ -f "$lib" && ! -L "$lib" ]] || continue
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$lib"
done
for tool in ffmpeg ffprobe; do
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    "$DESTINATION_DIR/$tool"
done
echo "Embedded FFmpeg from $SOURCE_DIR in $DESTINATION_DIR (signed with identity $SIGN_IDENTITY)."
