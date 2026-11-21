#!/usr/bin/env bash
# Package the macOS release app into a compressed, read-only disk image.
#
# Usage: bash scripts/package_macos_dmg.sh <Mornye.app> <output.dmg>
#
# The image holds the app and an Applications symlink (no background or
# window layout). The app is re-signed inside out with the stable self-signed
# identity from scripts/setup_macos_signing.sh when one is given (it keeps
# keychain access across updates), otherwise ad hoc. Releases are not
# notarized yet (docs: users open it once through System Settings >
# Privacy & Security > "Open Anyway"). The script mounts the result read-only
# and checks its contents, the universal binaries and the signature.
#
# Environment:
#   MORNYE_DMG_VOLUME_NAME     volume name (default: Mornye)
#   MORNYE_CODE_SIGN_IDENTITY  signing identity (default: - for ad hoc)
#   MORNYE_MACOS_ARCH          arm64, x86_64/x64, or universal (default: universal)

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: bash scripts/package_macos_dmg.sh <Mornye.app> <output.dmg>" >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: disk images are built on macOS." >&2
  exit 1
fi

APP_SOURCE="${1%/}"
OUTPUT="$2"
VOLUME_NAME="${MORNYE_DMG_VOLUME_NAME:-Mornye}"
SIGN_IDENTITY="${MORNYE_CODE_SIGN_IDENTITY:--}"
APP_NAME="$(basename "$APP_SOURCE")"
case "${MORNYE_MACOS_ARCH:-universal}" in
  arm64) TARGET_ARCH="arm64"; VERIFY_ARCHS=(arm64) ;;
  x86_64|x64) TARGET_ARCH="x86_64"; VERIFY_ARCHS=(x86_64) ;;
  universal) TARGET_ARCH="universal"; VERIFY_ARCHS=(arm64 x86_64) ;;
  *)
    echo "Error: MORNYE_MACOS_ARCH must be arm64, x86_64, x64, or universal." >&2
    exit 1
    ;;
esac

if [[ ! -f "$APP_SOURCE/Contents/Info.plist" ]]; then
  echo "Error: $APP_SOURCE is not an app bundle." >&2
  exit 1
fi
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_SOURCE/Contents/Info.plist")"
case "$OUTPUT" in
  *.dmg) ;;
  *) echo "Error: the output must end in .dmg." >&2; exit 1 ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mornye-dmg.XXXXXX")"
MOUNT_POINT="$WORK_DIR/mount"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    if ! hdiutil detach "$MOUNT_POINT" -quiet && ! hdiutil detach "$MOUNT_POINT" -force -quiet; then
      # Never delete through a mounted image.
      echo "Warning: could not detach $MOUNT_POINT; leaving $WORK_DIR in place." >&2
      return
    fi
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGE_DIR="$WORK_DIR/stage"
STAGED_APP="$STAGE_DIR/$APP_NAME"
mkdir -p "$STAGE_DIR"
# ditto keeps symlinks, extended attributes and existing signatures.
ditto "$APP_SOURCE" "$STAGED_APP"
ln -s /Applications "$STAGE_DIR/Applications"

is_macho() {
  file -b "$1" | grep -q '^Mach-O'
}

# Remove non-macOS Flutter assets before signing and imaging.
FLUTTER_ASSETS_DIR="$STAGED_APP/Contents/Frameworks/App.framework/Resources/flutter_assets"
if [[ -d "$FLUTTER_ASSETS_DIR" ]]; then
  rm -rf \
    "$FLUTTER_ASSETS_DIR/packages/media_kit/assets/web" \
    "$FLUTTER_ASSETS_DIR/packages/record_web" \
    "$FLUTTER_ASSETS_DIR/packages/flutter_local_notifications_web"
  rm -f \
    "$FLUTTER_ASSETS_DIR/packages/liquid_glass_easy/lib/assets/shaders/metaball_"* \
    "$FLUTTER_ASSETS_DIR/packages/liquid_glass_easy/lib/assets/shaders/liquid_glass_desktop.frag" \
    "$FLUTTER_ASSETS_DIR/packages/liquid_glass_easy/lib/assets/shaders/liquid_glass_border.frag" \
    "$FLUTTER_ASSETS_DIR/assets/licenses/usb.txt" \
    "$FLUTTER_ASSETS_DIR/assets/licenses/oboe.txt" \
    "$FLUTTER_ASSETS_DIR/assets/licenses/wavpack.txt" \
    "$FLUTTER_ASSETS_DIR/assets/licenses/flac.txt"
fi

# When packaging a single-architecture DMG, thin every universal Mach-O slice
# (including FlutterMacOS, media_kit, and plugin frameworks) before signing.
if [[ "$TARGET_ARCH" != "universal" ]]; then
  echo "Thinning universal Mach-O binaries in $APP_NAME to $TARGET_ARCH"
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q '^Mach-O universal binary'; then
      if lipo "$candidate" -verify_arch "$TARGET_ARCH" 2>/dev/null; then
        lipo -thin "$TARGET_ARCH" "$candidate" -output "$candidate.thin"
        mv -f "$candidate.thin" "$candidate"
      fi
    fi
  done < <(find "$STAGED_APP" -type f ! -lname '*' -print0)
fi

# Sign nested code first (shared libraries, helper executables such as a
# bundled ffmpeg, loose dylibs, then frameworks), and the app itself last with
# the entitlements it was built with.
echo "Signing $APP_NAME with identity $SIGN_IDENTITY"
while IFS= read -r -d '' library; do
  if is_macho "$library"; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$library"
  fi
done < <(find "$STAGED_APP/Contents/Resources" -type f -name '*.dylib' -print0)

while IFS= read -r -d '' candidate; do
  if is_macho "$candidate"; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$candidate"
  fi
done < <(find "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" \
  -type f -perm -u+x ! -name '*.dylib' ! -path "$STAGED_APP/Contents/MacOS/$EXECUTABLE" -print0)

if [[ -d "$STAGED_APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' library; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$library"
  done < <(find "$STAGED_APP/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print0)
  while IFS= read -r -d '' framework; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$framework"
  done < <(find "$STAGED_APP/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0)
fi

ENTITLEMENTS="$WORK_DIR/entitlements.plist"
codesign -d --entitlements - --xml "$APP_SOURCE" > "$ENTITLEMENTS" 2>/dev/null || true
if [[ -s "$ENTITLEMENTS" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$STAGED_APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
echo "Creating $OUTPUT"
# ULMO (LZMA) is natively supported since macOS 10.15; Mornye targets 12.0+.
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format ULMO \
  -ov \
  "$OUTPUT" >/dev/null
hdiutil verify "$OUTPUT" >/dev/null

# Check the image as a user would receive it.
mkdir -p "$MOUNT_POINT"
hdiutil attach "$OUTPUT" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
MOUNTED_APP="$MOUNT_POINT/$APP_NAME"
test -d "$MOUNTED_APP"
test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
codesign --verify --deep --strict "$MOUNTED_APP"
for binary in "$MOUNTED_APP/Contents/MacOS/$EXECUTABLE" \
  "$MOUNTED_APP/Contents/Frameworks/libmornye_desktop.dylib"; do
  [[ -f "$binary" ]] || continue
  # One architecture per call: some lipo builds reject several at once.
  for arch in "${VERIFY_ARCHS[@]}"; do
    if ! lipo "$binary" -verify_arch "$arch"; then
      echo "Error: $binary has no $arch slice." >&2
      exit 1
    fi
  done
done
echo "Disk image contents:"
ls -la "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

echo "Created $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
