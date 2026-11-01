# Mornye Rust Backend

The Rust workspace is the app's only backend on Android and iOS. Flutter
reaches it through the native channel (see `android/README.md`); Kotlin and
Swift call it through UniFFI bindings generated from `mornye-mobile`.

The app identifies itself as Mornye in HTTP requests, exported lyrics and
new FLAC vendor metadata. Crates, native libraries and generated bindings
use Mornye names. Legacy backup and extension formats remain readable;
cryptographic domain separators retain their original values so branding
changes do not invalidate encrypted storage or external session protocols.

The toolchain is pinned in `rust_backend/rust-toolchain.toml` (Rust 1.99.1
with rustfmt and clippy). The workspace uses edition 2024, resolver 3, and
denies `unsafe_code` as a workspace lint, with a few audited local
`#[allow(unsafe_code)]` exceptions in the `extensions` and `mobile` crates.

Comments that mention "Go" describe the retired Go backend. Its observable
behavior (wire formats, parsing quirks, file layouts) remains a compatibility
contract.

## Crate Map

Dependencies point downward: `core` and `network` depend on no other
workspace crate.

| Crate | Package | Depends on |
| --- | --- | --- |
| `crates/core` | `mornye-core` | none |
| `crates/network` | `mornye-network` | none |
| `crates/providers` | `mornye-providers` | core, network |
| `crates/extensions` | `mornye-extensions` | core, network, providers |
| `crates/mobile` | `mornye-mobile` | core, network, extensions |
| `crates/desktop` | `mornye-desktop` | mobile |
| `crates/bindgen` | `mornye-bindgen` | `uniffi` CLI only |

**core.** Shared backend logic, independent of mobile bindings and UI
runtimes. Modules cover filenames, tags and metadata, covers and palette
extraction, CUE sheets, lyrics, ISRC, matching, download progress state,
Hi-Res analysis and JSON or XML helpers. It uses `image`, `claxon` (FLAC
decoding for the Hi-Res check), `roxmltree` and pinned Unicode tables.

**network.** Shared, cancellable HTTP transport for the embedded backend: the
client, cookies, DNS lookup, TLS roots, request policy, query and URL
handling. It is built on `hyper-util`, `hyper-rustls` and `tokio`; Apple
targets verify certificates with `rustls-platform-verifier`, other targets
with `rustls-native-certs`.

**providers.** Built-in provider clients and shared lookup services for the
native app owners: Deezer, MusicBrainz, lyrics, the resolver, and a request
coalescer.

**extensions.** Extension JavaScript execution and host services, isolated
from mobile UI code. It embeds QuickJS through `rquickjs` and provides the
host APIs (network, files, crypto, FFmpeg, auth, sessions, storage), the
manifest and package format, the repository, signed sessions and the
download backend. Its main types are `ExtensionRuntime` and
`ExtensionServices`.

**mobile.** The UniFFI mobile API (`uniffi::setup_scaffolding!`). This crate
is the only backend and routes the app on both platforms. It is built as
`lib`, `cdylib` (Android `libmornye_mobile.so`) and `staticlib` (iOS).
It adds native data jobs, the native library, cache, collections, playlists
and backup, lyrics, ID3 and network tags, `rusqlite`, and USB audio
(`libusb1-sys`, Android only).

**desktop.** The C ABI for macOS, Linux and Windows, loaded by Flutter
through `dart:ffi` (`cdylib` `libmornye_desktop`). It exports `mornye_init`,
`mornye_call`, `mornye_cancel`, `mornye_subscribe`, `mornye_unsubscribe` and
`mornye_free`, dispatches MethodChannel method names as JSON on a worker
pool (`src/dispatch.rs` is the single method table), pushes download and
library scan progress, and runs the bundled `ffmpeg` executable for the
backend's FFmpeg command queue. It is the only crate that allows unsafe
code, in `src/ffi.rs`.

**bindgen.** The UniFFI bindgen command line (`uniffi_bindgen_main`), used
only to generate the Kotlin and Swift bindings. It enables the `cli` and
`cargo-metadata` features of `uniffi`; the build script builds the library
in a separate cargo call so those features do not reach the shipped library.

### Vendored Patches

`Cargo.toml` patches two crates.io packages with copies in
`rust_backend/vendor/`: `rustix` 1.1.5 (Android `statx` fallback) and
`libusb1-sys` 0.7.0 (libusb 1.0.30 sources). The reasons and the upgrade
checks are in `rust_backend/vendor/README.md`. Third-party notices are in
`rust_backend/NOTICE`.

## Building

| Command | Result |
| --- | --- |
| `bash scripts/build_rust_backend.sh host` | Release host library and Kotlin and Swift bindings |
| `bash scripts/build_rust_backend.sh android` | Host step, then `libmornye_mobile.so` for each ABI |
| `bash scripts/build_rust_backend.sh ios` | Host step, then the XCFramework and CocoaPods staging |
| `bash scripts/build_rust_backend.sh desktop` | `libmornye_desktop` in `target/desktop/<os>/` (macOS universal, Linux host); Windows commands are in the script |
| `bash scripts/check_rust_backend.sh` | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` |

Every `cargo build`, `cargo run`, `cargo clippy` and `cargo test` call in
both scripts passes `--locked`, so `Cargo.lock` must be up to date. The
scripts do not pass `--offline`; dependencies come from crates.io except the
vendored patches.

The host step always runs first. It builds `mornye-mobile` in release
mode, then runs `mornye-bindgen generate` against the host library for
Kotlin and Swift. Output goes to `rust_backend/target/`:

- `target/release/`: host library (`.dylib` on macOS, `.so` on Linux)
- `target/bindings/kotlin/`, `target/bindings/swift/`: generated bindings
- `target/android/jniLibs/<abi>/`: Android libraries
- `target/ios/`: the XCFramework, Swift binding and podspec for CocoaPods

### Android

Android Gradle runs `scripts/build_rust_backend.sh android` in its
`buildRustBackend` task before `preBuild`, so a normal Flutter build is
enough. For a manual build:

- Set `ANDROID_NDK_HOME` to NDK 30.0.16248370 (the version CI installs in
  `.github/workflows/ci.yml` and `android/app/build.gradle.kts` uses).
- `MORNYE_RUST_ANDROID_ABIS` selects `arm64-v8a`, `armeabi-v7a` or both
  (comma-separated; the default is both).
- Libraries link against API 24 with 16 KB page alignment.

`bash scripts/check_android_statx.sh arm64-v8a` checks the vendored Rustix
fallback on a connected device (see `rust_backend/vendor/README.md`).

### iOS

On macOS, `bash scripts/build_rust_backend.sh ios` builds
`aarch64-apple-ios`, `aarch64-apple-ios-sim` and `x86_64-apple-ios` (iOS 16.0
deployment target), merges the two simulator slices, and stages
`target/ios/` with `rust_backend/MornyeBackend.podspec`. Run
`(cd ios && pod install)` afterwards; `ios/Podfile` refuses to install
without the staged files.

## Where the Bindings Are Used

The binding names come from `rust_backend/crates/mobile/uniffi.toml`.

| Platform | Generated | Consumed by |
| --- | --- | --- |
| Android | Kotlin package `com.mornye.backend`, loading `mornye_mobile` through JNA | `android/app/build.gradle.kts` adds `target/bindings/kotlin` and `target/android/jniLibs` as source dirs; used by `android/app/src/rust/kotlin/com/zarz/mornye/SelectedCoreBackend.kt` and its neighbors |
| iOS | Swift module `MornyeBackend` with FFI module `MornyeBackendFFI` | `ios/Podfile` pod `MornyeBackend` at `../rust_backend/target/ios`; imported by `ios/Runner/CoreBackend.swift` |

The generated files are build output under `target/` and are not tracked.
After changing an exported function, rebuild for the platform you test; the
Kotlin and Swift call sites must match the new signatures.

## Tests

```bash
bash scripts/check_rust_backend.sh
(cd rust_backend && cargo test --locked -p mornye-core)
(cd rust_backend && cargo test --locked -p mornye-mobile network_tags --lib)
```

- Unit tests sit in `#[cfg(test)] mod tests` blocks. Larger modules keep them
  in a sibling `tests.rs` declared with `mod tests;`, for example
  `rust_backend/crates/mobile/src/native_library/tests.rs` and
  `rust_backend/crates/extensions/src/manager/tests.rs`.
- Cargo integration tests live in `rust_backend/crates/core/tests/` and
  `rust_backend/crates/extensions/tests/`.
- `rust_backend/crates/core/src/metadata/musicbrainz/case_data.rs` is a frozen
  generated table (Unicode 15.0.0 ranges and case mappings for MusicBrainz
  title casing, kept for parity with the Go backend). It is marked
  `DO NOT EDIT`; the generator is no longer in the repository, and it must not
  be regenerated from newer tables.
- CI runs `scripts/check_rust_backend.sh` on Linux, the iOS build on macOS,
  and the Android build with Kotlin unit tests (`gradle -p android
  :app:assembleDebug :app:testDebugUnitTest`).
