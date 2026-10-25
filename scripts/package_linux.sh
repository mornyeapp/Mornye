#!/usr/bin/env bash
# Package a Flutter Linux release bundle as an AppImage or a Debian package.
#
# Usage:
#   bash scripts/package_linux.sh appimage <bundle-dir> <version> <output.AppImage>
#   bash scripts/package_linux.sh deb <bundle-dir> <version> <output.deb>
#
# <bundle-dir> is build/linux/<x64|arm64>/release/bundle. <version> is the
# release tag (for example v5.3.0 or v5.3.0-beta.1). The package architecture
# follows the host (`uname -m`); set MORNYE_PACKAGE_ARCH to x86_64 or aarch64
# to override it.
#
# Both formats install the bundle under usr/lib/mornye with usr/bin/mornye
# pointing at it, plus linux/packaging: the desktop entry (which registers
# x-scheme-handler/mornye), the AppStream metainfo and hicolor icons.
#
# The AppImage is built with a pinned appimagetool and type2 runtime that are
# checked against SHA-256 sums. It uses the host's GTK 3, GLib and
# libsecret, like the Flutter bundle itself. The deb computes its Depends
# with dpkg-shlibdeps and falls back to a fixed list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGING_DIR="$PROJECT_DIR/linux/packaging"
APP_ID="com.zarz.mornye"
BINARY_NAME="mornye"

# Pinned packaging tools (AppImage/appimagetool 1.9.1, type2-runtime 20251108).
APPIMAGETOOL_VERSION="1.9.1"
RUNTIME_VERSION="20251108"
appimagetool_sha256() {
  case "$1" in
    x86_64) echo "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0" ;;
    aarch64) echo "f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158" ;;
  esac
}
runtime_sha256() {
  case "$1" in
    x86_64) echo "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d" ;;
    aarch64) echo "00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444" ;;
  esac
}

usage() {
  echo "Usage: bash scripts/package_linux.sh <appimage|deb> <bundle-dir> <version> <output>" >&2
  exit 1
}

[[ $# -eq 4 ]] || usage
FORMAT="$1"
BUNDLE_DIR="${2%/}"
RELEASE_VERSION="$3"
OUTPUT="$4"

case "$FORMAT" in
  appimage|deb) ;;
  *) usage ;;
esac

ARCH="${MORNYE_PACKAGE_ARCH:-$(uname -m)}"
case "$ARCH" in
  x86_64|amd64) ARCH="x86_64"; DEB_ARCH="amd64" ;;
  aarch64|arm64) ARCH="aarch64"; DEB_ARCH="arm64" ;;
  *) echo "Error: unsupported architecture $ARCH." >&2; exit 1 ;;
esac

UPSTREAM_VERSION="${RELEASE_VERSION#v}"
if [[ ! "$UPSTREAM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid version $RELEASE_VERSION." >&2
  exit 1
fi

for required in "$BINARY_NAME" lib/libapp.so lib/libflutter_linux_gtk.so data/flutter_assets; do
  if [[ ! -e "$BUNDLE_DIR/$required" ]]; then
    echo "Error: $BUNDLE_DIR is not a Flutter release bundle ($required is missing)." >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mornye-package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# Copies the bundle and the desktop integration files into <root>/usr.
install_tree() {
  local root="$1"
  local share="$root/usr/share"
  local release_date
  release_date="$(date -u +%Y-%m-%d)"

  mkdir -p "$root/usr/lib/$BINARY_NAME" "$root/usr/bin"
  cp -a "$BUNDLE_DIR/." "$root/usr/lib/$BINARY_NAME/"
  ln -s "../lib/$BINARY_NAME/$BINARY_NAME" "$root/usr/bin/$BINARY_NAME"

  install -Dm644 "$PACKAGING_DIR/$APP_ID.desktop" "$share/applications/$APP_ID.desktop"
  mkdir -p "$share/metainfo"
  awk -v version="$UPSTREAM_VERSION" -v date="$release_date" '
    /<\/component>/ {
      printf "  <releases>\n    <release version=\"%s\" date=\"%s\"/>\n  </releases>\n", version, date
    }
    { print }
  ' "$PACKAGING_DIR/$APP_ID.metainfo.xml" > "$share/metainfo/$APP_ID.metainfo.xml"
  chmod 644 "$share/metainfo/$APP_ID.metainfo.xml"

  local size
  for size in 128 256; do
    install -Dm644 "$PACKAGING_DIR/icons/mornye-$size.png" \
      "$share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  done
  install -Dm644 "$PROJECT_DIR/assets/brand/logo/png/mornye-badge@1x.png" \
    "$share/icons/hicolor/512x512/apps/$APP_ID.png"
  install -Dm644 "$PROJECT_DIR/assets/brand/logo/svg/mornye-badge.svg" \
    "$share/icons/hicolor/scalable/apps/$APP_ID.svg"

  install -Dm644 "$PROJECT_DIR/LICENSE" "$share/doc/$BINARY_NAME/copyright"
  install -m644 "$PROJECT_DIR/COPYING" "$PROJECT_DIR/NOTICE" "$share/doc/$BINARY_NAME/"
}

# Downloads a pinned file into the tool cache and checks its digest.
fetch_tool() {
  local url="$1" expected="$2" destination="$3"
  if [[ ! -f "$destination" || "$(sha256_of "$destination")" != "$expected" ]]; then
    rm -f "$destination"
    curl -fsSL --retry 3 -o "$destination.part" "$url"
    if [[ "$(sha256_of "$destination.part")" != "$expected" ]]; then
      echo "Error: checksum mismatch for $url." >&2
      rm -f "$destination.part"
      exit 1
    fi
    mv "$destination.part" "$destination"
  fi
  chmod +x "$destination"
}

build_appimage() {
  local appdir="$WORK_DIR/AppDir"
  install_tree "$appdir"

  cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/mornye/mornye" "$@"
APPRUN
  chmod 755 "$appdir/AppRun"
  cp "$appdir/usr/share/applications/$APP_ID.desktop" "$appdir/$APP_ID.desktop"
  cp "$appdir/usr/share/icons/hicolor/256x256/apps/$APP_ID.png" "$appdir/$APP_ID.png"
  ln -s "$APP_ID.png" "$appdir/.DirIcon"

  local tool_dir="${MORNYE_PACKAGING_TOOLS_DIR:-$PROJECT_DIR/build/packaging-tools}"
  local host_arch
  host_arch="$(uname -m)"
  case "$host_arch" in
    x86_64|aarch64) ;;
    arm64) host_arch="aarch64" ;;
    *) echo "Error: appimagetool does not run on $host_arch." >&2; exit 1 ;;
  esac
  mkdir -p "$tool_dir"
  local appimagetool="$tool_dir/appimagetool-$APPIMAGETOOL_VERSION-$host_arch.AppImage"
  local runtime="$tool_dir/runtime-$RUNTIME_VERSION-$ARCH"
  fetch_tool \
    "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$host_arch.AppImage" \
    "$(appimagetool_sha256 "$host_arch")" "$appimagetool"
  fetch_tool \
    "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VERSION/runtime-$ARCH" \
    "$(runtime_sha256 "$ARCH")" "$runtime"

  mkdir -p "$(dirname "$OUTPUT")"
  rm -f "$OUTPUT"
  # The AppStream file is validated separately; appimagetool's check would
  # depend on whichever appstreamcli the host has.
  ARCH="$ARCH" APPIMAGE_EXTRACT_AND_RUN=1 VERSION="$UPSTREAM_VERSION" \
    "$appimagetool" --no-appstream --runtime-file "$runtime" "$appdir" "$OUTPUT"
  chmod 755 "$OUTPUT"
}

build_deb() {
  local root="$WORK_DIR/deb"
  install_tree "$root"
  chmod -R u+rwX,go+rX,go-w "$root"

  local deb_version="${UPSTREAM_VERSION//-/\~}"
  local fallback_depends="libc6 (>= 2.35), libgcc-s1, libstdc++6, libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libsecret-1-0, libjson-glib-1.0-0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libasound2 | libasound2t64, liblzma5"
  local depends=""

  if command -v dpkg-shlibdeps >/dev/null 2>&1; then
    local shlib_dir="$WORK_DIR/shlibdeps"
    mkdir -p "$shlib_dir/debian"
    printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$BINARY_NAME" "$BINARY_NAME" \
      > "$shlib_dir/debian/control"
    local elf_files=()
    while IFS= read -r -d '' candidate; do
      if head -c 4 "$candidate" | grep -q 'ELF'; then
        elf_files+=("$candidate")
      fi
    done < <(find "$root/usr/lib/$BINARY_NAME" -type f -print0)
    local substvars
    if substvars="$(cd "$shlib_dir" && dpkg-shlibdeps -O --ignore-missing-info \
        -l"$root/usr/lib/$BINARY_NAME/lib" "${elf_files[@]}" 2>"$WORK_DIR/shlibdeps.log")"; then
      depends="$(sed -n 's/^shlibs:Depends=//p' <<< "$substvars")"
    else
      echo "Warning: dpkg-shlibdeps failed; using the fixed dependency list." >&2
      cat "$WORK_DIR/shlibdeps.log" >&2
    fi
  fi
  depends="${depends:-$fallback_depends}"

  local installed_size
  installed_size="$(du -sk --exclude=DEBIAN "$root" | cut -f1)"
  mkdir -p "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<CONTROL
Package: $BINARY_NAME
Version: $deb_version
Architecture: $DEB_ARCH
Maintainer: zarzet <42882290+zarzet@users.noreply.github.com>
Installed-Size: $installed_size
Depends: $depends
Recommends: gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, xdg-utils, xdg-desktop-portal, pulseaudio-utils
Section: sound
Priority: optional
Homepage: https://github.com/mornyeapp/Mornye
Description: Music player and library manager
 Mornye plays local and network music, edits metadata, and fetches tracks
 and lyrics through extensions you install.
CONTROL
  chmod 644 "$root/DEBIAN/control"

  mkdir -p "$(dirname "$OUTPUT")"
  rm -f "$OUTPUT"
  dpkg-deb --build --root-owner-group "$root" "$OUTPUT"
  dpkg-deb --info "$OUTPUT"
}

case "$FORMAT" in
  appimage) build_appimage ;;
  deb) build_deb ;;
esac
echo "Created $OUTPUT"
