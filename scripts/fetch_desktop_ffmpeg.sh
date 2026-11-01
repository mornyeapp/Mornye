#!/usr/bin/env bash
# Stage LGPL, audio-capable `ffmpeg` and `ffprobe` executables for a desktop
# build into build/ffmpeg/<os>-<arch>/. Binaries are never committed.
#
# Usage: bash scripts/fetch_desktop_ffmpeg.sh [<os>-<arch>]
#   <os>-<arch> defaults to the host: macos-arm64, macos-x64, linux-x64,
#   linux-arm64, windows-x64 or windows-arm64. macos-universal builds both
#   macOS architectures and merges them with lipo; release builds of the
#   universal app need it.
#
# Output: build/ffmpeg/<os>-<arch>/ffmpeg[.exe], ffprobe[.exe], LICENSE.txt
# and SOURCE.txt (where the build came from, for the LGPL source offer).
#
# Sources:
#   Linux, Windows: BtbN/FFmpeg-Builds static "lgpl" variants (no GPL or
#     nonfree parts; includes libmp3lame, libopus, libsoxr and TLS). The
#     archive is checked against the checksums.sha256 file of the same
#     release. MORNYE_FFMPEG_BTBN_TAG (default: latest) selects the release
#     and MORNYE_FFMPEG_BTBN_ASSET overrides the archive name, which a dated
#     autobuild tag needs.
#   macOS: built from source (FFmpeg, LAME, Opus, SoX Resampler) with pinned
#     SHA-256 sums. No known prebuilt macOS FFmpeg is LGPL. Needs the Xcode
#     command line tools, cmake and pkg-config. The FFmpeg configure line is
#     MACOS_FFMPEG_OPTIONS below plus the prefix, architecture and flags.
#     LAME, Opus and soxr are built as static libraries into the same prefix.
#     macOS x64 is cross-compiled with `-arch x86_64` on Apple Silicon,
#     using a pinned NASM release built for the host.
#     Every decoder, demuxer, muxer, filter and protocol stays enabled (the
#     app reads arbitrary user files, analyses audio with video filters such
#     as showspectrumpic, and copies HLS motion artwork over HTTPS). Encoders
#     are limited to the ones the app and the extension host request.
#
# Bundle layout (the desktop bundling must place the staged files here; the
# app resolves them in lib/services/ffmpeg_desktop.dart):
#   macOS:   Mornye.app/Contents/Resources/ffmpeg/{ffmpeg,ffprobe}
#            (Contents/MacOS/{ffmpeg,ffprobe} is also accepted)
#   Windows: <folder of the .exe>\ffmpeg\{ffmpeg.exe,ffprobe.exe}
#   Linux:   <folder of the executable>/lib/ffmpeg/{ffmpeg,ffprobe}
# Ship LICENSE.txt and SOURCE.txt next to the binaries.
#
# Runtime lookup order: $MORNYE_FFMPEG_DIR, then the bundle layout above,
# then PATH. PATH is a developer fallback only: a package manager FFmpeg
# (for example Homebrew's) is usually built with --enable-gpl and must never
# be bundled. This script refuses to stage a build whose configuration
# reports --enable-gpl or --enable-nonfree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
LAME_VERSION="3.100"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
SOXR_VERSION="0.1.3"
SOXR_SHA256="b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889"
# Build tool for FFmpeg's x86 assembly; not shipped.
NASM_VERSION="3.02"
NASM_SHA256="87336eba53b4acfe917424ab5d500d2b0054d9f5148d35c2273ccf2cfb712f0d"
BTBN_BRANCH="9.0"
BTBN_TAG="${MORNYE_FFMPEG_BTBN_TAG:-latest}"
MACOS_MIN_VERSION="12.0"

# Encoders the app requests: conversions and the extension host (aac, alac,
# flac, libmp3lame, libopus, opus, PCM), cover art (mjpeg, png), spectrogram
# planes (rawvideo) and `-f null` validation (wrapped_avframe).
MACOS_ENCODERS="aac,alac,flac,libmp3lame,libopus,opus,vorbis"
MACOS_ENCODERS+=",pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le"
MACOS_ENCODERS+=",pcm_f32le,pcm_u8,mjpeg,png,rawvideo,wrapped_avframe"
MACOS_FFMPEG_OPTIONS=(
  --disable-gpl --disable-nonfree --disable-version3
  --disable-shared --enable-static --disable-autodetect
  --disable-doc --disable-ffplay --disable-debug
  --disable-avdevice --disable-indevs --disable-outdevs
  --disable-encoders --enable-encoder="$MACOS_ENCODERS"
  --enable-zlib --enable-audiotoolbox --enable-securetransport
  --enable-libmp3lame --enable-libopus --enable-libsoxr
  --pkg-config-flags=--static
)

host_target() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) echo "Error: unsupported host OS $(uname -s)." >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "Error: unsupported host architecture $(uname -m)." >&2; exit 1 ;;
  esac
  echo "$os-$arch"
}

TARGET="${1:-$(host_target)}"
case "$TARGET" in
  macos-x64|macos-arm64|macos-universal|linux-x64|linux-arm64|windows-x64|windows-arm64) ;;
  *)
    echo "Usage: bash scripts/fetch_desktop_ffmpeg.sh [macos-arm64|macos-x64|macos-universal|linux-x64|linux-arm64|windows-x64|windows-arm64]" >&2
    exit 1
    ;;
esac
OS="${TARGET%-*}"
ARCH="${TARGET#*-}"

OUT_DIR="$PROJECT_DIR/build/ffmpeg/$TARGET"
WORK_DIR="$PROJECT_DIR/build/ffmpeg/.work/$TARGET"
EXE=""
[[ "$OS" == "windows" ]] && EXE=".exe"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download() {
  local url="$1" dest="$2"
  if [[ ! -f "$dest" ]]; then
    echo "Downloading $url"
    curl -fL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
}

verify() {
  local file="$1" expected="$2" actual
  actual="$(sha256_of "$file")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    echo "Error: checksum mismatch for $(basename "$file")." >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

fetch_btbn() {
  local platform asset ext base checksum
  case "$TARGET" in
    linux-x64) platform=linux64 ext=tar.xz ;;
    linux-arm64) platform=linuxarm64 ext=tar.xz ;;
    windows-x64) platform=win64 ext=zip ;;
    windows-arm64) platform=winarm64 ext=zip ;;
  esac
  asset="${MORNYE_FFMPEG_BTBN_ASSET:-ffmpeg-n$BTBN_BRANCH-latest-$platform-lgpl-$BTBN_BRANCH.$ext}"
  base="https://github.com/BtbN/FFmpeg-Builds/releases/download/$BTBN_TAG"

  # "latest" moves; always fetch the checksums that match the archive.
  rm -f "$WORK_DIR/$asset" "$WORK_DIR/checksums.sha256"
  download "$base/checksums.sha256" "$WORK_DIR/checksums.sha256"
  download "$base/$asset" "$WORK_DIR/$asset"
  checksum="$(awk -v name="$asset" '$2 == name || $2 == "*" name {print $1}' "$WORK_DIR/checksums.sha256")"
  if [[ -z "$checksum" ]]; then
    echo "Error: $asset is not listed in the release checksums." >&2
    exit 1
  fi
  verify "$WORK_DIR/$asset" "$checksum"

  rm -rf "$WORK_DIR/extract"
  mkdir -p "$WORK_DIR/extract"
  if [[ "$ext" == "zip" ]]; then
    unzip -q "$WORK_DIR/$asset" -d "$WORK_DIR/extract"
  else
    tar -xJf "$WORK_DIR/$asset" -C "$WORK_DIR/extract"
  fi
  local root
  root="$(find "$WORK_DIR/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  cp "$root/bin/ffmpeg$EXE" "$root/bin/ffprobe$EXE" "$OUT_DIR/"
  cp "$root/LICENSE.txt" "$OUT_DIR/LICENSE.txt"
  {
    echo "FFmpeg LGPL build from BtbN/FFmpeg-Builds."
    echo "Release: https://github.com/BtbN/FFmpeg-Builds/releases/tag/$BTBN_TAG"
    echo "Archive: $asset (sha256 $checksum)"
    echo "Build scripts: https://github.com/BtbN/FFmpeg-Builds"
    echo "FFmpeg source: https://ffmpeg.org/download.html (release branch $BTBN_BRANCH)"
  } > "$OUT_DIR/SOURCE.txt"
}

# Builds one macOS architecture (arm64 or x64) into build/ffmpeg/macos-<arch>.
build_macos_arch() {
  local arch="$1"
  local out="$PROJECT_DIR/build/ffmpeg/macos-$arch"
  local work="$PROJECT_DIR/build/ffmpeg/.work/macos-$arch"
  local downloads="$PROJECT_DIR/build/ffmpeg/.work/downloads"
  local clang_arch host_triple ffmpeg_arch jobs prefix src
  case "$arch" in
    arm64) clang_arch=arm64 host_triple=aarch64-apple-darwin ffmpeg_arch=arm64 ;;
    x64) clang_arch=x86_64 host_triple=x86_64-apple-darwin ffmpeg_arch=x86_64 ;;
  esac
  jobs="$(sysctl -n hw.ncpu)"
  prefix="$work/deps"
  src="$work/src"
  local flags="-arch $clang_arch -mmacosx-version-min=$MACOS_MIN_VERSION -O2"

  mkdir -p "$out" "$work" "$downloads"
  rm -f "$out/ffmpeg" "$out/ffprobe"
  download "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "$downloads/ffmpeg-$FFMPEG_VERSION.tar.xz"
  verify "$downloads/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
  download "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
    "$downloads/lame-$LAME_VERSION.tar.gz"
  verify "$downloads/lame-$LAME_VERSION.tar.gz" "$LAME_SHA256"
  download "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" \
    "$downloads/opus-$OPUS_VERSION.tar.gz"
  verify "$downloads/opus-$OPUS_VERSION.tar.gz" "$OPUS_SHA256"
  download "https://downloads.sourceforge.net/project/soxr/soxr-$SOXR_VERSION-Source.tar.xz" \
    "$downloads/soxr-$SOXR_VERSION-Source.tar.xz"
  verify "$downloads/soxr-$SOXR_VERSION-Source.tar.xz" "$SOXR_SHA256"

  rm -rf "$src" "$prefix"
  mkdir -p "$src" "$prefix"
  tar -xJf "$downloads/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$src"
  tar -xzf "$downloads/lame-$LAME_VERSION.tar.gz" -C "$src"
  tar -xzf "$downloads/opus-$OPUS_VERSION.tar.gz" -C "$src"
  tar -xJf "$downloads/soxr-$SOXR_VERSION-Source.tar.xz" -C "$src"

  # Keep package managers' libraries (for example Homebrew's) out of the
  # build so the binaries only link system frameworks.
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  export PKG_CONFIG_PATH=""

  if [[ "$arch" == "x64" ]]; then
    # FFmpeg's x86 assembly needs NASM, built for the host from a pinned
    # release so the build does not depend on a package manager.
    download "https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/nasm-$NASM_VERSION.tar.xz" \
      "$downloads/nasm-$NASM_VERSION.tar.xz"
    verify "$downloads/nasm-$NASM_VERSION.tar.xz" "$NASM_SHA256"
    tar -xJf "$downloads/nasm-$NASM_VERSION.tar.xz" -C "$src"
    (
      cd "$src/nasm-$NASM_VERSION"
      ./configure --prefix="$src/nasm-install"
      make -j"$jobs" nasm
      mkdir -p "$src/nasm-install/bin"
      cp nasm "$src/nasm-install/bin/nasm"
    )
    export PATH="$src/nasm-install/bin:$PATH"
  fi

  (
    cd "$src/lame-$LAME_VERSION"
    # LAME 3.100 exports a symbol that no longer exists.
    sed -i '' '/lame_init_old/d' include/libmp3lame.sym
    CFLAGS="$flags" LDFLAGS="-arch $clang_arch" ./configure \
      --host="$host_triple" --prefix="$prefix" \
      --disable-shared --enable-static --disable-frontend --disable-decoder \
      --disable-dependency-tracking
    make -j"$jobs"
    make install
  )
  (
    cd "$src/opus-$OPUS_VERSION"
    CFLAGS="$flags" LDFLAGS="-arch $clang_arch" ./configure \
      --host="$host_triple" --prefix="$prefix" \
      --disable-shared --enable-static --disable-doc --disable-extra-programs \
      --disable-dependency-tracking
    make -j"$jobs"
    make install
  )
  (
    # soxr 0.1.3 declares CMake 3.1; CMake 4 needs the policy floor raised.
    cmake -S "$src/soxr-$SOXR_VERSION-Source" -B "$src/soxr-build" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES="$clang_arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
      -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF
    cmake --build "$src/soxr-build" -j "$jobs"
    cmake --install "$src/soxr-build"
  )
  local cross=()
  [[ "$clang_arch" != "$(uname -m)" ]] && cross=(--enable-cross-compile)
  local configure=(
    --prefix="$prefix"
    --arch="$ffmpeg_arch" --target-os=darwin --cc=clang
    # Bash 3.2 (macOS) treats an empty "${cross[@]}" as unbound.
    ${cross[@]+"${cross[@]}"}
    --extra-cflags="$flags -I$prefix/include"
    --extra-ldflags="-arch $clang_arch -mmacosx-version-min=$MACOS_MIN_VERSION -L$prefix/lib"
    "${MACOS_FFMPEG_OPTIONS[@]}"
  )
  (
    cd "$src/ffmpeg-$FFMPEG_VERSION"
    ./configure "${configure[@]}"
    make -j"$jobs"
    cp ffmpeg ffprobe "$out/"
    cp COPYING.LGPLv2.1 "$out/LICENSE.txt"
  )
  {
    echo "FFmpeg $FFMPEG_VERSION built from source by scripts/fetch_desktop_ffmpeg.sh."
    echo "FFmpeg: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz (sha256 $FFMPEG_SHA256)"
    echo "LAME: https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz (sha256 $LAME_SHA256)"
    echo "Opus: https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz (sha256 $OPUS_SHA256)"
    echo "SoX Resampler: https://downloads.sourceforge.net/project/soxr/soxr-$SOXR_VERSION-Source.tar.xz (sha256 $SOXR_SHA256)"
    echo "FFmpeg configure ($arch): ${configure[*]//"$prefix"/<deps>}"
  } > "$out/SOURCE.txt"
  # The object files take about a gigabyte; only the outputs are kept.
  rm -rf "$src" "$prefix"
}

build_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: macOS FFmpeg is built from source on a macOS host." >&2
    exit 1
  fi
  local tool
  for tool in cmake pkg-config make clang lipo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Error: $tool is required to build FFmpeg for macOS." >&2
      exit 1
    fi
  done
  if [[ "$ARCH" != "universal" ]]; then
    build_macos_arch "$ARCH"
    return
  fi
  build_macos_arch arm64
  build_macos_arch x64
  local base="$PROJECT_DIR/build/ffmpeg"
  for tool in ffmpeg ffprobe; do
    lipo -create "$base/macos-arm64/$tool" "$base/macos-x64/$tool" \
      -output "$OUT_DIR/$tool"
  done
  cp "$base/macos-arm64/LICENSE.txt" "$OUT_DIR/LICENSE.txt"
  {
    cat "$base/macos-arm64/SOURCE.txt"
    grep '^FFmpeg configure (x64)' "$base/macos-x64/SOURCE.txt"
    echo "Universal binaries: lipo of the arm64 and x64 builds above."
  } > "$OUT_DIR/SOURCE.txt"
}

# Rejects GPL or nonfree builds when the binary can run on this host.
check_license() {
  local binary="$OUT_DIR/ffmpeg$EXE" config
  if ! config="$("$binary" -hide_banner -version 2>/dev/null)"; then
    echo "Note: $TARGET binaries cannot run on this host; license check skipped."
    return
  fi
  if grep -Eq -- '--enable-(gpl|nonfree)( |$)' <<< "$config"; then
    rm -f "$OUT_DIR/ffmpeg$EXE" "$OUT_DIR/ffprobe$EXE"
    echo "Error: the staged FFmpeg is GPL or nonfree and cannot be bundled." >&2
    exit 1
  fi
  local encoders
  encoders="$("$binary" -hide_banner -encoders 2>/dev/null || true)"
  if ! grep -q libmp3lame <<< "$encoders" || ! grep -q libopus <<< "$encoders"; then
    echo "Error: the staged FFmpeg lacks the libmp3lame or libopus encoder." >&2
    exit 1
  fi
  # The lossless conversion settings offer the soxr resampler.
  if ! grep -q -- '--enable-libsoxr' <<< "$config"; then
    echo "Error: the staged FFmpeg lacks libsoxr." >&2
    exit 1
  fi
  if [[ "$OS" == "macos" ]]; then
    local tool library
    for tool in ffmpeg ffprobe; do
      # The first line names the binary itself; the rest are its libraries.
      while read -r library _; do
        case "$library" in
          /usr/lib/*|/System/Library/*) ;;
          *)
            echo "Error: $tool links $library, which is not a system library." >&2
            exit 1
            ;;
        esac
      done < <(otool -L "$OUT_DIR/$tool" | tail -n +2 | grep -v ':$')
    done
  fi
}

mkdir -p "$OUT_DIR" "$WORK_DIR"
rm -f "$OUT_DIR/ffmpeg$EXE" "$OUT_DIR/ffprobe$EXE"
case "$OS" in
  macos) build_macos ;;
  linux|windows) fetch_btbn ;;
esac
chmod +x "$OUT_DIR/ffmpeg$EXE" "$OUT_DIR/ffprobe$EXE"
check_license
echo "Staged LGPL FFmpeg for $TARGET in $OUT_DIR"
