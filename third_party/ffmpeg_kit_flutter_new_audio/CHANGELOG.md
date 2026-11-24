## 2.5.8

* **Fixed: Windows apps raised an uncaught `FileSystemException` when no log callback was set.** By default, when no log callback is set, the plugin prints FFmpeg's logs to stdout. A Windows app started from Explorer, or from a console without redirected output, has no stdout handle, so the write failed and Dart reported it afterwards as an uncaught `FileSystemException: writeFrom failed ... (OS Error: The handle is invalid, errno = 6)`. Error reporters such as Sentry recorded it once per run, and apps that treat uncaught errors as fatal exited. The plugin now handles the failure and stops printing logs for the rest of the run. Where stdout works, the printed output is unchanged. No changes to the native libraries.
* Tests: `test/ffmpeg_kit_flutter_initializer_test.dart` sends log events to a stdout that fails the same way and checks that no uncaught error is raised.

## 2.5.7

* **Fixed: macOS release builds and App Store archives failed at code signing (#170).** The prebuilt 8.1.1 and 8.1.2 iOS and macOS framework zips on the GitHub releases, which versions 2.3.0 to 2.5.6 download, contained macOS metadata files (`._*` AppleDouble files) inside every framework. `codesign` refuses to sign a macOS framework with extra files in its root, so macOS builds through CocoaPods failed at the app's CodeSign step with `code object is not signed at all` and `In subcomponent: .../<one of the frameworks>.framework`. iOS builds through CocoaPods still worked, but the files were copied into the app and sealed into its signature. macOS builds that use Swift Package Manager were not affected.
* The release zips have been repacked without those files. Everything else in them is byte-identical, so those versions work once the frameworks are downloaded again: delete `<pub-cache>/hosted/pub.dev/ffmpeg_kit_flutter_new_audio-<version>/macos/Frameworks` (and `ios/Frameworks`), then run `flutter clean` and `flutter build macos --release` (or `ios`) before archiving in Xcode. After `flutter clean`, `flutter pub get` and `pod install` alone are not enough for an Xcode archive. Upgrading to this version also downloads the frameworks fresh, on the next `flutter build`. `scripts/setup_macos.sh` and `scripts/setup_ios.sh` now also delete `._*` files after unzipping, so a zip like that can no longer break a build.
* **Fixed: iOS and macOS crashed with `-[NSNull allKeys]` when the font name map was omitted (#167).** Calling `FFmpegKitConfig.setFontDirectory` or `setFontDirectoryList` without the optional map, or with `null`, aborted the app. Omitting it now behaves like passing an empty map. No changes to the native libraries.
* Maintainers: new `scripts/check_apple_zip.sh`, a release gate for the Apple framework zips. It rejects `._*` and `__MACOSX` entries, missing frameworks and wrong bundle layouts, and checks that the frameworks sign the way CocoaPods and Xcode sign them. `scripts/build_spm_artifacts.sh` now strips `._*` files, runs that gate on the frameworks it packages, zips without extended attributes, and fails if a packed xcframework zip still has `._*` or `__MACOSX` entries.
* Tests: `scripts/tests/test_apple_setup.sh` is an offline regression test that runs the real setup scripts on zips packed the way the affected ones were (#170). `example/integration_test/font_directory_test.dart` calls both methods with and without a map and checks the `fonts.conf` they write (#167).

## 2.5.6

* **Android: the plugin no longer applies the Kotlin Gradle Plugin (#168, #171).** The plugin's Android code is Java only, so `android/build.gradle` no longer applies `kotlin-android` or adds the Kotlin Gradle Plugin to its build script. This removes Flutter's warning that the plugin applies the Kotlin Gradle Plugin (KGP), and fixes the build failure `Failed to apply plugin 'kotlin-android'` in apps that use Android Gradle Plugin 9 with built-in Kotlin (`android.builtInKotlin=true`). Apps on Android Gradle Plugin 8 are unaffected. No changes to the plugin's API or native libraries.
* README: the Android minimum no longer lists a Kotlin version, since the plugin no longer uses Kotlin.

## 2.5.5

* **Android: corrected Maven metadata.** The plugin now depends on `com.antonkarpenko:ffmpeg-kit-audio:2.2.3`. Its native libraries are byte-identical to the previous release (FFmpeg n8.1.2); only the POM changed. The POM no longer describes the libraries as "FFmpeg v8.1.1", its project and SCM URLs point to the real source repository, and it no longer lists GPL-3.0, since this variant is built without GPL components (LGPL-3.0). No other changes.

## 2.5.4

* **Windows: the bundled DLLs keep ASLR.** Earlier versions ran `editbin` on every bundled DLL to turn off address space layout randomization (`DYNAMIC_BASE`, `HIGH_ENTROPY_VA`) and rebase it below 4 GB. That guarded against MinGW 32-bit pseudo-relocations overflowing when DLLs load far apart, but the published 8.1.2 bundles contain no 32-bit pseudo-relocations, so the DLLs are now shipped exactly as built. Builds also no longer need MSVC's `editbin`. Existing build directories download the bundle once more to replace the previously patched copies.
* If you build against your own bundle (`FFMPEGKIT_LOCAL_DIR`) and need the old behaviour, set `FFMPEGKIT_DISABLE_ASLR=ON`, either as an environment variable before `flutter build windows` or as a CMake cache variable.

## 2.5.3

* **Windows: the app now ships the native libraries' license notices.** The prebuilt FFmpeg 8.1.2 Windows bundle now includes `LICENSES/`, covering FFmpeg, FFmpegKit and every bundled third-party DLL with a link to its exact source. The plugin installs it into `licenses/ffmpeg_kit_flutter_new_audio/` next to your executable. Existing build directories download the bundle once more to pick it up. The DLLs themselves are unchanged.
* **Fixed: native errors bypassed the plugin's error handling.** The async API methods returned the platform call from inside their `try` block without awaiting it, so a `PlatformException` from the native side skipped the `catch` and reached your code unwrapped. They now await it, and these failures arrive as the documented `"<method> failed."` error. If you were catching `PlatformException` from these methods, catch the returned error instead.

## 2.5.2

* **Fixed: Windows build failure `Cannot extract through symlink ... .plugin_symlinks` (#165).** The prebuilt FFmpeg archive was unpacked into the plugin's own source directory. For a package resolved from the pub cache that directory is reached through a symlink, and the extractor refuses to write through it. The archive now unpacks into the application's build directory instead.
* The same change stops the plugin writing ~19 MB of native libraries into the shared pub cache on every platform. `flutter clean` never removed those; to reclaim the space delete `<pub-cache>/hosted/pub.dev/<package>-<version>/{linux,windows}/ffmpeg-kit` or run `dart pub cache repair`. The archive is now fetched once per build configuration rather than once per machine.

## 2.5.1

* **Fixed: `FFmpegKitConfig.getPlatform()` returned `windows` on Linux.** The Linux native layer was reporting the wrong platform name, so any code branching on it took the Windows path. It now returns `linux`. The prebuilt libraries attached to the `8.1.2-<variant>` release have been rebuilt with the fix; nothing else changed.

## 2.5.0

* **Linux support (x86_64).** `flutter run -d linux` and `flutter build linux` now work. Prebuilt FFmpeg **8.1.2** libraries for the `audio` variant are downloaded at build time, the same way the Windows bundle already worked; set `FFMPEGKIT_LOCAL_DIR` (env or CMake cache variable) to build against a self-built bundle instead.
* Linux builds additionally require **`libjson-glib-dev`** (runtime: `libjson-glib`) alongside Flutter's standard Linux prerequisites. It ships with GNOME, so most desktops already have the runtime.

## 2.4.4

* **Fixed: log/statistics/complete callbacks silently dropped in apps with a second `FlutterEngine`** (e.g. a Firebase Messaging background isolate), a 4.4.1+ regression (#163). FFmpegKit's global native callbacks are now registered once and dispatched to every attached engine that is actually listening, instead of being captured by whichever engine attached last. Background-isolate execution (#155) keeps working.

## 2.4.3

* **Fixed: App Store rejection `Invalid architecture ... arm64e slice with the ios 18.5 SDK` (#164).** The iOS device slices of the bundled FFmpeg XCFrameworks are now arm64 only, for both Swift Package Manager (regenerated binary targets + checksums) and CocoaPods (setup script). arm64e was never used by App Store apps, so nothing is lost.
* SPM only: the regenerated iOS/macOS binaries now actually include the zlib/PNG decoders (#105) that the previous release added for CocoaPods and Android but not for the SPM artifacts.

## 2.4.2

* **Fixed: `Decoder (codec png) not found` (#105).** The native FFmpeg builds for this variant were compiled without zlib, which silently removed the PNG/APNG decoders. zlib is now enabled on Android (`com.antonkarpenko:ffmpeg-kit-*:2.2.2`), iOS and macOS, restoring PNG/APNG decoding (image overlays etc.) as in the original arthenica builds.

## 2.4.1

* Fixed the iOS/macOS build error `'ffmpegkit/FFmpegKitConfig.h' file not found` (#88). The framework setup scripts now download and install atomically, verify the archive, and never leave an empty `Frameworks/` directory behind after a failed download; the podspec re-runs setup until the frameworks are actually present. On restricted networks, point `FFMPEG_KIT_IOS_URL` / `FFMPEG_KIT_MACOS_URL` at a mirror of the release zip.
* Docs: made the FFmpeg badge a link and tidied the README badges.

## 2.4.0

* **Swift Package Manager support** (iOS & macOS): the plugin now integrates via Flutter's SPM support (`flutter config --enable-swift-package-manager`; enabled by default from Flutter 3.44) as well as CocoaPods. Native FFmpeg frameworks are consumed as prebuilt, checksum-pinned XCFrameworks with a native arm64 iOS-simulator slice, downloaded from the GitHub release.
* iOS/macOS plugin sources moved to the Flutter SPM plugin layout; CocoaPods integration is unchanged (and still supported).
* Example app now includes runtime integration tests (`example/integration_test/`).

## 2.3.2

* Fixes the native binary wiring for the CVE-2026-8461 (MagicYUV / "PixelSmash") security patch: Android now pulls `com.antonkarpenko:ffmpeg-kit-*:2.2.1` and iOS/macOS fetch the FFmpeg 8.1.2 frameworks (the 8.1.2 rebuild was previously only wired for Windows). Please upgrade from any earlier version.

## 2.3.1

* **Security (CVE-2026-8461):** updated **FFmpeg to v8.1.2** (arthenica `n8.1.2`) to fix a heap out-of-bounds write in the MagicYUV decoder ("PixelSmash", CVSS 8.8). All platforms (Android/iOS/macOS/Windows) rebuilt against FFmpeg 8.1.2; no API changes.

## 2.3.0

* Updated **FFmpeg to v8.1.1** (arthenica `n8.1.1`), up from 8.0.0.
* iOS/macOS `.xcframework`s, the Android Maven library (`com.antonkarpenko:ffmpeg-kit-*`), and the Windows binaries are now built against FFmpeg 8.1.1.

## 2.2.2

* Android: broadened the bundled ProGuard/R8 consumer rules to keep **all** `com.antonkarpenko.ffmpegkit.**` classes (plus `-dontwarn`), not just the JNI entry points. Fully prevents R8 from stripping FFmpegKit in release builds — fixes the release-only white screen / `channel-error` (FFmpegKit failing to initialise, which cascades into errors like `shared_preferences` `getAll`). Closes #158.

## 2.2.1

* Android: ship ProGuard/R8 **consumer rules** (`consumer-rules.pro`, applied automatically via `consumerProguardFiles`) that keep the FFmpegKit JNI bindings — `FFmpegKitConfig` native/callback methods and `AbiDetect`. Prevents release-mode crashes such as `Bad JNI version returned from JNI_OnLoad` without requiring any ProGuard rules in your app. Thanks @niclasEX (#133).

## 2.2.0

* Fixed **iOS Simulator on Apple Silicon** (`arm64`) support — required for Xcode 26 / iOS 26+ simulators. Builds previously failed with *"The following target(s) do not support arm64 architecture, which is a requirement for Apple Silicon iOS 26+ simulators"*.
* The downloaded iOS `.framework` bundles are now converted to `.xcframework`s at build time (`scripts/setup_ios.sh`), exposing a native `ios-arm64_x86_64-simulator` slice alongside the `ios-arm64_arm64e` device slice. The simulator `arm64` slice is produced by retagging the device `arm64` slice's Mach-O build-version platform to `iOS-Simulator` via `vtool`.
* The iOS podspec now vendors `.xcframework`s and no longer excludes `arm64` for the simulator (`EXCLUDED_ARCHS[sdk=iphonesimulator*]` is now `i386` only).
* If you previously added `config.build_settings["EXCLUDED_ARCHS[sdk=iphonesimulator*]"] = "arm64"` to your app's `ios/Podfile` `post_install` hook as a workaround, **remove it** — it now prevents the simulator `arm64` slice from linking.

## 2.1.0

* Added **Windows** support (x86_64) for the `audio` FFmpeg 8.0 variant (audio-codec set: lame, libilbc, libvorbis, opencore-amr, opus, shine, soxr, speex, twolame).
* Native libraries are downloaded automatically at build time from the `8.0.0-audio` release (`ffmpeg-kit-windows-x86_64-audio-8.0.0.zip`); for local development point `FFMPEGKIT_LOCAL_DIR` (CMake cache var or environment) at a locally built bundle.
* The bundled MinGW DLLs are rebased/ASLR-adjusted at build time so the plugin loads standalone.
* Shell scripts are forced to LF via `.gitattributes` so the published package never carries Windows CRLF line endings (avoids the iOS/macOS `pod install` `/bin/bash^M: bad interpreter` failure).

## 2.0.0

* FFmpeg `v8.0.0` with [all the sweet perks](https://ffmpeg.org/index.html#news)

## 1.1.0

* Added proguard-rules.pro to keep `ffmpeg` dependencies when minification is enabled
* Upgraded `freetype` from **2.13.0** to **2.13.3**
* Upgraded `harfbuzz` from **8.0.1** to **11.3.3**
* Upgraded `fontconfig` from **2.16.2** to 2.17.1
* Added support for `harfbuzz` library in order to support `drawtext` filter
* Fixed missing `libunibreak` for `libass.sh`
* Downgraded required Kotlin version to `v1.8.22`
* Upgraded com.android.library from `8.11.1` to `8.12.0`

## 1.0.1

* Updated README.md packages links and pubspec.yaml semantics

## 1.0.0

* Initial release
* FFmpeg version 7.1.1
* Removed bundled Android FFmpeg (jniLibs, cpp, bindings)
* Added FFmpeg min using new Maven Central package