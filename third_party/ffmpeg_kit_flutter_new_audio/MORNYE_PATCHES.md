# Local FFmpegKit patch

Based on ffmpeg_kit_flutter_new_audio 2.5.7 (license retained in LICENSE).
The upstream `example` app is not copied.

The root `pubspec.yaml` overrides the package with this copy
(`dependency_overrides: ffmpeg_kit_flutter_new_audio: path:
third_party/ffmpeg_kit_flutter_new_audio`), next to the pinned
`ffmpeg_kit_flutter_new_audio: 2.5.7`. The version is the one in this
folder's `pubspec.yaml` (2.5.7, unchanged).

## Patches

### Linux architectures without a bundle

Upstream publishes Linux bundles for x86_64 only, and `linux/CMakeLists.txt`
stopped the build with a fatal error on any other architecture, so the app
could not be built for Linux arm64 at all.

On an architecture without a bundle, and with no `FFMPEGKIT_LOCAL_DIR`, the
plugin is now built without `libffmpegkit.so` and a CMake warning says so.
The plugin already loads the library with `dlopen()` and answers every call
with an error when it is missing. Mornye desktop never calls FFmpegKit's
native layer: it runs the bundled `ffmpeg` and `ffprobe` executables
(`lib/services/ffmpeg_desktop.dart` in the app) and uses only the package's
Dart code (argument parsing and the media information model).

x86_64 builds and builds with `FFMPEGKIT_LOCAL_DIR` keep upstream behavior.

### Android: FFmpegKit loads on first use, off the main thread

`FFmpegKitFlutterPlugin.onAttachedToEngine` registered the global callbacks
inline. The first `FFmpegKitConfig` access runs its static initializer,
which loads `libffmpegkit.so` and its dependencies (about 20.6 MB for
arm64-v8a, `libavcodec.so` alone 11.5 MB), so every cold start, media
button start and Android Auto start paid that load on the main thread while
`new FlutterEngine(...)` attached plugins, before Dart `main`. Most launches
never use FFmpeg.

Now the first method call of any engine starts the registration (and with
it the load) on the plugin's executor. Calls that arrive before it is done
wait in arrival order and run on the main thread right after it, with the
callbacks registered, so they get the same replies as before; later calls
run directly. The main thread never waits for the load. A RuntimeException
in a waiting call becomes the same `error` reply and `MethodChannel#...`
log line that the channel gives (the reply has no stack trace). If the
load fails, every call answers `notImplemented`, which Dart reports as the
same `MissingPluginException` as the channel without a handler that the
failed attach left, and the failure is logged once under
`ffmpeg-kit-flutter`.

Kotlin code that uses FFmpegKit directly loads it on its own thread, or
waits on the JVM class initialization lock while the plugin loads it. Code
that wraps a global callback calls the public static
`FFmpegKitFlutterPlugin.ensureGlobalCallbacksRegistered()` first: it
registers the callbacks on the calling thread (loading FFmpegKit if
needed), waits for a registration already in progress, and throws a load
failure to the first caller. The app's download finalizer wraps the
FFmpeg complete callback; without this call, a download that ran before the
first Dart FFmpeg call (the usual order now) would wrap nothing, and the
plugin would replace the wrapper when Dart first used FFmpeg. As a side
effect, a process with no engine (the download service started on its own)
now also has the plugin's global log callback, so FFmpeg log lines of
calls without a session are no longer printed to logcat, as already
happened in every process with an engine.

The load does not start at attach on a background thread instead: the
registrant attaches `JniPlugin` a few plugins later, whose static
initializer calls `System.loadLibrary` on the main thread, and
`Runtime.loadLibrary0` (synchronized) and bionic's `dlopen` (`g_dl_mutex`)
would make it wait for the FFmpegKit load anyway.

Tests: `android/src/test` (JUnit on the host JVM, with stand-ins for the
four Android classes the path touches; the main looper stand-in is a
thread named `main` that the tests post calls through, so replies are
checked against it; `build.gradle` adds JUnit and forks one JVM per test
class, since `FFmpegKitConfig` initializes once per JVM).
From the app's `android/` folder:
`gradle --offline :ffmpeg_kit_flutter_new_audio:testDebugUnitTest -x buildRustBackend`.
