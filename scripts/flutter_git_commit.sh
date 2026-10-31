#!/usr/bin/env bash
# Supply About's build revision without replacing explicit Flutter defines.

set -euo pipefail

BUILD_DART_DEFINES="${1:-}"
IFS=',' read -r -a ENCODED_DEFINES <<< "$BUILD_DART_DEFINES"
for encoded_define in ${ENCODED_DEFINES[@]+"${ENCODED_DEFINES[@]}"}; do
  decoded_define="$(printf '%s' "$encoded_define" | base64 --decode 2>/dev/null || true)"
  if [[ "$decoded_define" == GIT_COMMIT=* ]]; then
    printf '%s\n' "$BUILD_DART_DEFINES"
    exit 0
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_GIT_COMMIT="$(git -C "$SCRIPT_DIR/.." rev-parse --short=8 HEAD 2>/dev/null || true)"
if [[ "$BUILD_GIT_COMMIT" =~ ^[0-9a-f]{8,40}$ ]]; then
  encoded_commit="$(printf 'GIT_COMMIT=%s' "$BUILD_GIT_COMMIT" | base64 | tr -d '\r\n')"
  BUILD_DART_DEFINES="${BUILD_DART_DEFINES:+$BUILD_DART_DEFINES,}$encoded_commit"
fi
printf '%s\n' "$BUILD_DART_DEFINES"
