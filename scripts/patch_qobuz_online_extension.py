#!/usr/bin/env python3
"""Create an experimental Qobuz extension with a direct-stream action.

This script modifies an existing checkout of the open-source
mornyeapp/Mornye-Extension repository. The upstream archive is never
redistributed with modified branding; the extension is explicitly marked
experimental. No secret keys are embedded in the package.
"""
from __future__ import annotations

import json
import pathlib
import sys

EXTENSION_FUNCTION = r'''
// Experimental full-track direct playback; this reuses the same authorized
// download resolver but DOES NOT call file.download or write an audio file.
// The returned signed URL may expire, require an unusual User-Agent, or be a
// short provider preview. A consumer must treat such failures explicitly.
function resolvePlaybackStream(request) {
  request = request || {};
  try {
    var requestedDuration = Number(request.duration_ms || 0);
    var requestedId = parseTrackID(String(request.qobuz_id || request.id || ""));
    var matched = checkAvailability(
      String(request.isrc || ""),
      String(request.title || ""),
      String(request.artist || ""),
      {
        qobuz_id: requestedId || "",
        duration_ms: requestedDuration,
        track: {
          album_name: String(request.album || "")
        }
      }
    );
    if (!matched || matched.available !== true || !matched.track_id) {
      return {
        success: false,
        error: "Qobuz recording could not be verified against the requested track"
      };
    }

    // resolveDownloadInfo fetches an expiring URL; the normal download
    // implementation calls file.download on it. We return the URL instead.
    var requestedQuality = String(request.quality || "HI_RES_LOSSLESS");
    if (["HI_RES_LOSSLESS", "HI_RES", "LOSSLESS"].indexOf(requestedQuality) < 0) {
      requestedQuality = "HI_RES_LOSSLESS";
    }
    var info = resolveDownloadInfo(matched.track_id, requestedQuality, {});
    var url = String(info && info.directURL || "").trim();
    if (!/^https:\/\//i.test(url)) {
      return { success: false, error: "Qobuz did not return a secure stream URL" };
    }

    return {
      success: true,
      url: url,
      full_track: true,
      format: "flac",
      bit_depth: Number(info.bitDepth || 0),
      sample_rate: Number(info.sampleRate || 0),
      quality_requested: requestedQuality,
      provider: "qobuz-web",
      expires: "provider-controlled"
    };
  } catch (error) {
    return {
      success: false,
      error: String(error && error.message || error || "stream resolver failed")
    };
  }
}

'''
def main(root: pathlib.Path) -> None:
    src = root / "sources" / "qobuz-web" / "index.js"
    manifest_file = root / "sources" / "qobuz-web" / "manifest.json"
    js = src.read_text(encoding="utf-8")
    marker = "registerExtension({"
    assert js.count(marker) == 1, "Could not find unique registration point"
    assert "resolvePlaybackStream" not in js, "Source already provides streaming"
    js = js.replace(marker, EXTENSION_FUNCTION + marker, 1)
    registration = "  resolvePreview: resolvePreview\n});"
    assert js.count(registration) == 1, "Unexpected registration layout"
    js = js.replace(
        registration,
        "  resolvePreview: resolvePreview,\n  resolvePlaybackStream: resolvePlaybackStream\n});",
        1,
    )
    src.write_text(js, encoding="utf-8")

    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    assert manifest["name"] == "qobuz-web"
    manifest["version"] = "1.2.29"
    manifest["displayName"] = "Qobuz (Experimental Online)"
    manifest["description"] += (
        " Experimental direct HTTPS audio playback. Signed URLs may expire or "
        "be rejected by players; preview-length results cannot be ruled out."
    )
    manifest.setdefault("capabilities", {})["fullTrackStreaming"] = True
    manifest_file.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Patched Qobuz extension:", manifest["name"], manifest["version"])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: patch_qobuz_online_extension.py <extension-registry-checkout>")
    main(pathlib.Path(sys.argv[1]).resolve())
