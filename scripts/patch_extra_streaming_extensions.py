#!/usr/bin/env python3
"""Add experimental authorized full-track streaming actions to Jellyfin and SoundCloud.

Run against a checkout of mornyeapp/Mornye-Extension. Provider credentials
and media remain on the user's server; no authentication or DRM bypass.
"""
from __future__ import annotations

import json
import pathlib
import sys


JELLYFIN = r'''
// Stream the user's own Jellyfin library; never attempt third-party content.
function resolvePlaybackStream(request) {
  request = request || {};
  try {
    var source = String(request.source || "").toLowerCase();
    var title = String(request.title || "");
    var artist = String(request.artist || "");
    var durationMs = Number(request.duration_ms || 0);
    var item = null;
    if (source === "jellyfin" && isId(String(request.id || ""))) {
      item = getItem(String(request.id), "MediaSources,Path");
    } else {
      item = findTrack(title, artist, Math.round(durationMs / 1000));
    }
    if (!item || !isId(String(item.Id || ""))) {
      return { success: false, error: "Recording not found in your Jellyfin library" };
    }
    var chosenQuality = String(request.quality || "ORIGINAL");
    // Qobuz Hi-Res quality codes mean "best available" for Jellyfin.
    if (["HI_RES_LOSSLESS", "HI_RES", "LOSSLESS"].indexOf(chosenQuality) >= 0) {
      chosenQuality = "ORIGINAL";
    }
    if (["ORIGINAL", "MP3_320", "MP3_192", "OPUS_128"].indexOf(chosenQuality) < 0) {
      chosenQuality = "ORIGINAL";
    }
    var result = getDownloadUrl(String(item.Id), chosenQuality);
    if (!result || result.success !== true) {
      return { success: false, error: String(result && result.error || "Unable to resolve Jellyfin stream") };
    }
    var stream = String(result.url || "");
    // Jellyfin places its private access token in the stream URL. Do not
    // permit transmitting credentials over plaintext HTTP, even on LAN.
    if (!/^https:\/\/[^/?#]+/i.test(stream)) {
      return { success: false, error: "Jellyfin streaming requires an HTTPS server URL (access token protection)" };
    }
    return {
      success: true,
      url: stream,
      full_track: true,
      provider: "jellyfin",
      format: String(result.format || "unknown"),
      quality_requested: chosenQuality,
      url_contains_credentials: true
    };
  } catch (error) {
    return { success: false, error: String(error && error.message || error || "Jellyfin stream failed") };
  }
}
'''

SOUNDCLOUD = r'''
// Play only full tracks explicitly marked playable by SoundCloud.
// No snippets, gated tracks, credential extraction beyond the existing
// extension's public playback resolver or encrypted HLS playlists.
function resolvePlaybackStream(request) {
  request = request || {};
  try {
    var source = String(request.source || "").toLowerCase();
    var id = String(request.id || "");
    var requestedDuration = Number(request.duration_ms || 0);
    var track = null;
    if (source === "soundcloud" && /^\d{5,}$/.test(id)) {
      track = trackCacheGet(id) || fetchTrackData(id);
    } else {
      var result = checkAvailability(
        String(request.isrc || ""),
        String(request.title || ""),
        String(request.artist || ""),
        { duration_ms: requestedDuration }
      );
      if (result && result.available && result.track_id) {
        track = result.prepared_context && result.prepared_context.track ||
          trackCacheGet(String(result.track_id)) || fetchTrackData(result.track_id);
      }
    }
    if (!track || track.streamable === false || track.access !== "playable") {
      return { success: false, error: "SoundCloud does not provide a full playable track" };
    }
    ensureClientId();
    // Prioritize progressive audio for native Android audio player support.
    // Signed HLS audio is a fallback only when the playlist can be verified
    // as a complete, unencrypted track. No media is downloaded here.
    var candidates = rankTranscodings(
      (track.media && track.media.transcodings) || [], "aac"
    ).sort(function(a, b) {
      return (a.format.protocol === "progressive" ? -1 : 0) -
        (b.format.protocol === "progressive" ? -1 : 0);
    });
    var failures = [];
    for (var i = 0; i < candidates.length && i < 6; i++) {
      var candidate = candidates[i];
      if (!candidate || candidate.snipped) continue;
      try {
        var stream = resolveStreamURL(candidate, track);
        if (!/^https:\/\/[^/?#]+/i.test(stream)) {
          throw new Error("SoundCloud did not return an HTTPS stream");
        }
        var protocol = candidate.format.protocol;
        if (protocol === "hls") {
          var playlist = readHlsPlaylist(stream, 0);
          var expected = requestedDuration > 0 ? requestedDuration / 1000 :
            Number(track.duration || 0) / 1000;
          if (expected > 0 &&
              Math.abs(playlist.duration - expected) > Math.max(5, expected * 0.02)) {
            throw new Error("HLS duration does not match the full track");
          }
        } else if (protocol !== "progressive") {
          continue;
        }
        var format = transcodingFormat(candidate);
        if (!format) continue;
        return {
          success: true,
          url: stream,
          full_track: true,
          provider: "soundcloud",
          format: format === "m4a" ? "aac" : format,
          quality_requested: "best playable",
          stream_protocol: protocol
        };
      } catch (e) {
        failures.push(String(e && e.message || e));
      }
    }
    return { success: false, error: "No compatible full SoundCloud stream: " + failures.join("; ") };
  } catch (error) {
    return { success: false, error: String(error && error.message || error || "SoundCloud stream failed") };
  }
}
'''


def patch(root: pathlib.Path, name: str, code: str, version: str) -> None:
    source = root / "sources" / name / "index.js"
    manifest_path = root / "sources" / name / "manifest.json"
    js = source.read_text(encoding="utf-8")
    marker = "registerExtension({"
    if js.count(marker) != 1 or "function resolvePlaybackStream(" in js:
        raise ValueError(f"Unexpected {name} extension registration")
    js = js.replace(marker, code + "\n" + marker, 1)
    last_registration = js.rfind("\n});")
    if last_registration < 0:
        raise ValueError(f"Missing {name} extension registration end")
    js = js[:last_registration] + ",\n  resolvePlaybackStream: resolvePlaybackStream" + js[last_registration:]
    source.write_text(js, encoding="utf-8")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("name") != name:
        raise ValueError(f"Unexpected manifest for {name}")
    manifest["version"] = version
    manifest["displayName"] = manifest.get("displayName", name) + " (Online Experimental)"
    manifest["description"] += " Experimental full-track playback through the user's authorized source."
    manifest.setdefault("capabilities", {})["fullTrackStreaming"] = True
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main(path: pathlib.Path) -> None:
    patch(path, "jellyfin", JELLYFIN, "1.1.2")
    patch(path, "soundcloud", SOUNDCLOUD, "1.0.15")
    print("Patched Jellyfin 1.1.2 and SoundCloud 1.0.15 for experimental online playback")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: patch_extra_streaming_extensions.py <Mornye-Extension checkout>")
    main(pathlib.Path(sys.argv[1]).resolve())
