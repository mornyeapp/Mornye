# FFmpegKit for Flutter: Audio

[![pub package](https://img.shields.io/pub/v/ffmpeg_kit_flutter_new_audio?logo=dart)](https://pub.dev/packages/ffmpeg_kit_flutter_new_audio)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-8.1.3-green)](https://ffmpeg.org/download.html)
[![License](https://img.shields.io/badge/license-LGPL--3.0-blue)](LICENSE)
[![Discord](https://img.shields.io/discord/1387108888452665427?logo=discord&logoColor=white&label=discord)](https://discord.gg/8NVwykjA)

Run FFmpeg and FFprobe commands from Dart on Android, iOS, macOS, Windows and Linux.

This is a maintained fork of [FFmpegKit](https://github.com/arthenica/ffmpeg-kit/tree/main/flutter/flutter), which is no longer developed upstream, updated for the Android V2 embedding and current Flutter releases. `ffmpeg_kit_flutter_new_audio` is the **Audio** variant: a build focused on audio codecs. See [Choosing a package](#choosing-a-package) for the alternatives.

## Features

- FFmpeg 8.1.3 and FFprobe, with per-session logs, statistics and completion callbacks.
- One Dart API for Android, iOS, macOS, Windows (x86_64) and Linux (x86_64).
- Prebuilt native libraries for every platform, so nothing is compiled during your build.
- Android Storage Access Framework (SAF) URIs can be used directly as inputs and outputs.
- iOS and macOS integrate through Swift Package Manager, with checksum-pinned XCFrameworks, or through CocoaPods, which can check the download's SHA-256.

## Installation

Requires Flutter 3.41 or later.

```yaml
dependencies:
  ffmpeg_kit_flutter_new_audio: ^3.0.0
```

```dart
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
```

## Quick start

```dart
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';

final session = await FFmpegKit.execute('-i input.mp4 -c:v mpeg4 output.mp4');
final returnCode = await session.getReturnCode();

if (ReturnCode.isSuccess(returnCode)) {
  // Success
} else if (ReturnCode.isCancel(returnCode)) {
  // Cancelled
} else {
  // Failed: inspect await session.getLogs()
}
```

## Choosing a package

The plugin is published as nine packages that share the same Dart API and differ only in the native libraries they bundle. Choose the smallest one that covers the codecs you need. The GPL-licensed codecs (`x264`, `x265`, `xvidcore`, `vid.stab`) are only included in the `-gpl` packages.

| Package | Contents |
|---|---|
| [`_min`](https://pub.dev/packages/ffmpeg_kit_flutter_new_min) | Smallest build, core FFmpeg only |
| [`_min_gpl`](https://pub.dev/packages/ffmpeg_kit_flutter_new_min_gpl) | Minimal plus GPL codecs (x264, x265, xvid, vid.stab) |
| [`_https`](https://pub.dev/packages/ffmpeg_kit_flutter_new_https) | Adds TLS (`gnutls`) for `https://` inputs |
| [`_https_gpl`](https://pub.dev/packages/ffmpeg_kit_flutter_new_https_gpl) | HTTPS plus GPL codecs |
| [`_audio`](https://pub.dev/packages/ffmpeg_kit_flutter_new_audio) (this package) | Audio codecs (mp3, opus, vorbis, speex and others) |
| [`_video`](https://pub.dev/packages/ffmpeg_kit_flutter_new_video) | Video codecs (dav1d, vpx, theora, webp and others) |
| [`_converter_gpl`](https://pub.dev/packages/ffmpeg_kit_flutter_new_converter_gpl) | Converting between common formats: x264, x265, lame, opus, vorbis, vpx, webp and dav1d (GPL) |
| [`_full`](https://pub.dev/packages/ffmpeg_kit_flutter_new_full) | Every library except the GPL codecs |
| [`ffmpeg_kit_flutter_new`](https://pub.dev/packages/ffmpeg_kit_flutter_new) | Every library, including the GPL codecs |

## Enabled libraries

The table lists the system and external libraries enabled in each package's Android, iOS and macOS builds. The Windows and Linux bundles are built against MSYS2 and system packages respectively; the Windows bundle lists every DLL it contains in `LICENSES/NOTICE.txt`.

<table>
<thead>
<tr>
<th align="center"></th>
<th align="center"><sup>min</sup></th>
<th align="center"><sup>min-gpl</sup></th>
<th align="center"><sup>https</sup></th>
<th align="center"><sup>https-gpl</sup></th>
<th align="center"><sup>audio</sup></th>
<th align="center"><sup>video</sup></th>
<th align="center"><sup>converter-gpl</sup></th>
<th align="center"><sup>full</sup></th>
<th align="center"><sup>full-gpl</sup></th>
</tr>
</thead>
<tbody>
<tr>
<td align="center"><sup>external libraries</sup></td>
<td align="center">-</td>
<td align="center"><sup>vid.stab</sup><br><sup>x264</sup><br><sup>x265</sup><br><sup>xvidcore</sup></td>
<td align="center"><sup>gmp</sup><br><sup>gnutls</sup></td>
<td align="center"><sup>gmp</sup><br><sup>gnutls</sup><br><sup>vid.stab</sup><br><sup>x264</sup><br><sup>x265</sup><br><sup>xvidcore</sup></td>
<td align="center"><sup>lame</sup><br><sup>libilbc</sup><br><sup>libvorbis</sup><br><sup>opencore-amr</sup><br><sup>opus</sup><br><sup>shine</sup><br><sup>soxr</sup><br><sup>speex</sup><br><sup>twolame</sup><br><sup>vo-amrwbenc</sup></td>
<td align="center"><sup>dav1d</sup><br><sup>fontconfig</sup><br><sup>freetype</sup><br><sup>fribidi</sup><br><sup>kvazaar</sup><br><sup>libass</sup><br><sup>libiconv</sup><br><sup>libtheora</sup><br><sup>libvpx</sup><br><sup>libwebp</sup><br><sup>snappy</sup><br><sup>zimg</sup></td>
<td align="center"><sup>dav1d</sup><br><sup>lame</sup><br><sup>libiconv</sup><br><sup>libvorbis</sup><br><sup>libvpx</sup><br><sup>libwebp</sup><br><sup>opus</sup><br><sup>x264</sup><br><sup>x265</sup></td>
<td align="center"><sup>chromaprint</sup><br><sup>dav1d</sup><br><sup>fontconfig</sup><br><sup>freetype</sup><br><sup>fribidi</sup><br><sup>gmp</sup><br><sup>gnutls</sup><br><sup>kvazaar</sup><br><sup>lame</sup><br><sup>libaom</sup><br><sup>libass</sup><br><sup>libiconv</sup><br><sup>libilbc</sup><br><sup>libtheora</sup><br><sup>libvorbis</sup><br><sup>libvpx</sup><br><sup>libwebp</sup><br><sup>libxml2</sup><br><sup>opencore-amr</sup><br><sup>openh264</sup><br><sup>openssl</sup><br><sup>opus</sup><br><sup>shine</sup><br><sup>snappy</sup><br><sup>soxr</sup><br><sup>speex</sup><br><sup>srt</sup><br><sup>tesseract</sup><br><sup>twolame</sup><br><sup>vo-amrwbenc</sup><br><sup>zimg</sup></td>
<td align="center"><sup>chromaprint</sup><br><sup>dav1d</sup><br><sup>fontconfig</sup><br><sup>freetype</sup><br><sup>fribidi</sup><br><sup>gmp</sup><br><sup>gnutls</sup><br><sup>kvazaar</sup><br><sup>lame</sup><br><sup>libaom</sup><br><sup>libass</sup><br><sup>libiconv</sup><br><sup>libilbc</sup><br><sup>libtheora</sup><br><sup>libvorbis</sup><br><sup>libvpx</sup><br><sup>libwebp</sup><br><sup>libxml2</sup><br><sup>opencore-amr</sup><br><sup>openh264</sup><br><sup>openssl</sup><br><sup>opus</sup><br><sup>rubberband</sup><br><sup>shine</sup><br><sup>snappy</sup><br><sup>soxr</sup><br><sup>speex</sup><br><sup>srt</sup><br><sup>tesseract</sup><br><sup>twolame</sup><br><sup>vid.stab</sup><br><sup>vo-amrwbenc</sup><br><sup>x264</sup><br><sup>x265</sup><br><sup>xvidcore</sup><br><sup>zimg</sup></td>
</tr>
<tr>
<td align="center"><sup>android system libraries</sup></td>
<td align="center" colspan=9><sup>zlib</sup><br><sup>MediaCodec</sup></td>
</tr>
<tr>
<td align="center"><sup>ios system libraries</sup></td>
<td align="center" colspan=9><sup>bzip2</sup><br><sup>AudioToolbox</sup><br><sup>AVFoundation</sup><br><sup>iconv</sup><br><sup>zlib</sup></td>
</tr>
<tr>
<td align="center"><sup>ios VideoToolbox</sup></td>
<td align="center"><sup>VideoToolbox</sup></td>
<td align="center"><sup>VideoToolbox</sup></td>
<td align="center">-</td>
<td align="center">-</td>
<td align="center">-</td>
<td align="center">-</td>
<td align="center"><sup>VideoToolbox</sup></td>
<td align="center"><sup>VideoToolbox</sup></td>
<td align="center"><sup>VideoToolbox</sup></td>
</tr>
<tr>
<td align="center"><sup>macos system libraries</sup></td>
<td align="center" colspan=9><sup>bzip2</sup><br><sup>AudioToolbox</sup><br><sup>AVFoundation</sup><br><sup>Core Image</sup><br><sup>iconv</sup><br><sup>OpenCL</sup><br><sup>OpenGL</sup><br><sup>VideoToolbox</sup><br><sup>zlib</sup></td>
</tr>
</tbody>
</table>

## Platform support

| Platform | Minimum version | Architectures |
|---|---|---|
| Android | API 24 | `arm-v7a`, `arm-v7a-neon`, `arm64-v8a`, `x86`, `x86_64` |
| iOS | 15.0 | `arm64` (device); `arm64`, `x86_64` (simulator), shipped as `.xcframework` |
| macOS | 11.0 | `arm64`, `x86_64` |
| Windows | 10 | `x86_64` |
| Linux | - | `x86_64` |

### iOS and macOS

With Swift Package Manager, Xcode downloads the XCFrameworks and checks them against the checksums pinned in the package.

With CocoaPods, `pod install` downloads the prebuilt frameworks as a zip from the [`8.1.3-audio` release](https://github.com/sk3llo/ffmpeg_kit_flutter/releases/tag/8.1.3-audio) the first time it installs the plugin. To have that download checked, set `FFMPEG_KIT_IOS_SHA256` (or `FFMPEG_KIT_MACOS_SHA256`) to the zip's SHA-256 before running `pod install`. The release page shows the SHA-256 of each file. A zip with another SHA-256 is refused and nothing is installed. Frameworks that are already installed are not downloaded or checked again. A plugin version with new frameworks downloads a different zip, so update the value when you upgrade to one.

If your network cannot reach GitHub, mirror the zip and set `FFMPEG_KIT_IOS_URL` (or `FFMPEG_KIT_MACOS_URL`) to the mirror's address. The SHA-256 check applies to a mirror too.

With either package manager, the frameworks come with their dSYMs, so Xcode puts them in your app's archives and crash reports symbolicate inside FFmpeg.

### Windows

Prebuilt FFmpeg 8.1.3 libraries are downloaded into your application's build directory the first time you build. To build against a locally built bundle instead, set `FFMPEGKIT_LOCAL_DIR` (as an environment variable or a CMake cache variable) to the bundle directory before running `flutter run` or `flutter build windows`.

The bundle's license notices are installed next to your executable in `licenses/ffmpeg_kit_flutter_new_audio/`. See [License](#license).

### Linux

Prebuilt FFmpeg 8.1.3 libraries are downloaded at build time in the same way as on Windows, and `FFMPEGKIT_LOCAL_DIR` works the same way. In addition to Flutter's standard Linux prerequisites (`clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`), the plugin requires `libjson-glib-dev`:

```bash
sudo apt-get install libjson-glib-dev   # Debian, Ubuntu
sudo dnf install json-glib-devel        # Fedora
```

## Usage

<details open>
<summary><strong>Execute a command and read the result</strong></summary>

```dart
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';

FFmpegKit.execute('-i file1.mp4 -c:v mpeg4 file2.mp4').then((session) async {
  final returnCode = await session.getReturnCode();
  if (ReturnCode.isSuccess(returnCode)) {
    // Success
  } else if (ReturnCode.isCancel(returnCode)) {
    // Cancelled
  } else {
    // Failed
  }
});
```

</details>

<details>
<summary><strong>Inspect a session</strong></summary>

```dart
FFmpegKit.execute('-i file1.mp4 -c:v mpeg4 file2.mp4').then((session) async {
  final sessionId = session.getSessionId();
  final command = session.getCommand();
  final state = await session.getState();
  final returnCode = await session.getReturnCode();
  final duration = await session.getDuration();
  final output = await session.getOutput();
  final logs = await session.getLogs();
  final statistics = await (session as FFmpegSession).getStatistics();
});
```

</details>

<details>
<summary><strong>Run asynchronously with callbacks</strong></summary>

```dart
FFmpegKit.executeAsync('-i file1.mp4 -c:v mpeg4 file2.mp4', (Session session) async {
  // Called when the session completes
}, (Log log) {
  // Called for each log line
}, (Statistics statistics) {
  // Called when the session reports statistics
});
```

</details>

<details>
<summary><strong>Read media information with FFprobe</strong></summary>

```dart
FFprobeKit.getMediaInformation('<file path or url>').then((session) async {
  final information = await session.getMediaInformation();
});
```

</details>

<details>
<summary><strong>Cancel sessions</strong></summary>

```dart
FFmpegKit.cancel();          // Cancel all sessions
FFmpegKit.cancel(sessionId); // Cancel one session
```

</details>

<details>
<summary><strong>Android: Storage Access Framework (SAF)</strong></summary>

```dart
// Read from a document
FFmpegKitConfig.selectDocumentForRead('*/*').then((uri) {
  FFmpegKitConfig.getSafParameterForRead(uri!).then((safUrl) {
    FFmpegKit.executeAsync("-i ${safUrl!} -c:v mpeg4 file2.mp4");
  });
});

// Write to a document
FFmpegKitConfig.selectDocumentForWrite('video.mp4', 'video/*').then((uri) {
  FFmpegKitConfig.getSafParameterForWrite(uri!).then((safUrl) {
    FFmpegKit.executeAsync("-i file1.mp4 -c:v mpeg4 ${safUrl}");
  });
});
```

</details>

<details>
<summary><strong>Global callbacks and fonts</strong></summary>

```dart
FFmpegKitConfig.enableLogCallback((log) { final message = log.getMessage(); });
FFmpegKitConfig.enableStatisticsCallback((statistics) { final size = statistics.getSize(); });
FFmpegKitConfig.setFontDirectoryList(["/system/fonts", "/System/Library/Fonts", "<folder with fonts>"]);
```

</details>

## License

The plugin is licensed under LGPL 3.0. This package contains no GPL components. If you need `x264`, `x265`, `xvidcore` or `vid.stab`, use the matching `-gpl` package.

FFmpeg and the bundled third-party libraries keep their own licenses. On Windows, the prebuilt bundle includes a `LICENSES/` directory with the FFmpeg and FFmpegKit license texts, and a `NOTICE.txt` that lists every bundled DLL with its license, version and a link to its exact source. The plugin installs it into `licenses/ffmpeg_kit_flutter_new_audio/` next to your executable; ship that directory with your application. The other platforms' downloads carry the same kind of `LICENSES/` directory, whose `NOTICE.txt` lists FFmpeg, FFmpegKit and each library compiled into the binaries: at the root of the Android AAR and of the iOS and macOS zips on the GitHub release, and in `ffmpeg-kit/LICENSES/` in the Linux bundle. The plugin doesn't copy those into your app.

## Support

- Questions and discussion: [Discord](https://discord.gg/8NVwykjA)
- Bug reports and feature requests: [GitHub issues](https://github.com/sk3llo/ffmpeg_kit_flutter/issues)
- Support development: [Buy Me a Coffee](https://buymeacoffee.com/sk3llo)
