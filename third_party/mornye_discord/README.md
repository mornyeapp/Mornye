# Playback presence

Small Android/iOS bridge to Discord's official Social SDK (tested with
1.10.19337). It publishes a Listening activity and never joins voice calls or
changes the app's audio session. The SDK is initialized only after opt-in.

## Build setup

Download the C++ Social SDK from the Mornye application's **Social SDK
→ Downloads** page in the Discord Developer Portal. Extract it, then run:

```sh
bash scripts/setup_discord_sdk.sh /path/to/discord_social_sdk
flutter pub get
```

CI prepares the pinned mobile SDK with `.github/actions/discord-sdk` before
building. Its AES-256 encrypted payload contains only the Android AAR, iOS
XCFramework, C++ header and license notices from the official download. Set the
Actions repository secret `DISCORD_MOBILE_SDK_PASSPHRASE` to the payload's key.
The helper verifies SHA-256 checksums for all 16 required files before staging
them. A missing key, failed decryption or changed SDK stops the build.

Decrypted vendor binaries and notices stay under the ignored `.dart_tool/`,
`sdk/` and `ios/Frameworks/` directories. Do not commit the encryption key,
developer credentials or unencrypted SDK downloads. This uses GitHub's
[large-secret storage pattern](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#storing-large-secrets);
the portal's signed download link expires after one hour and is unsuitable for
release automation. Distributions containing the SDK must include its license notices
and follow Discord's SDK terms. The setup script stages notices for inclusion
in Android assets and iOS resources. Without these files the app still builds, but
the presence setting reports that the SDK is unavailable. A clean clone alone
does not produce a Discord-enabled build.

To deliberately omit a staged SDK, set `MORNYE_DISCORD_SDK=0` during Android
builds or iOS `pod install` and app builds. `bash scripts/build_android.sh --lite`
sets this flag for Android. The bridge remains registered and reports presence
as unavailable; the staged SDK files are retained for subsequent full builds.

Production Android builds use `bash scripts/build_android.sh --production`,
which forces Discord on, checks the staged SDK and audits it in every APK ABI.
`--production --lite` is rejected. Release CI requires the SDK on both platforms
and stops before publication if the SDK is absent. CI on trusted branches also
builds with Discord; fork PRs run native/debug checks and explicit Lite builds
without receiving the decryption key.

Android uses the installed Discord app's signed-in session (Social SDK 1.10+).
The AAR and CMake use the same staged native library; the host packages one copy
with `jniLibs.pickFirsts`. Microphone/Bluetooth permissions and the SDK voice
service are removed by the host manifest. Do not remove the app's own audio
service or playback permissions.

iOS uses the SDK's OAuth PKCE flow with `openid sdk.social_layer_presence`.
SDK-enabled simulator builds require an Apple Silicon Mac (arm64). The setup
script stages an optional simulator configuration; builds without the SDK keep
Flutter's normal simulator architecture support.
Configure the application as a **Public Client**, and register exactly:

```text
discord-1549854098801692862:/authorize/callback
```

The Application ID is public. Never embed a client secret or a Discord user
token. Only the OAuth refresh token is persisted, using the host's secure
storage; access tokens stay in memory. Disabling presence clears the activity
and closes the SDK. Disconnecting also removes the locally stored refresh
token. Users can revoke authorization in Discord's Authorized Apps settings.

## Runtime

`DiscordPresenceService` subscribes to the audio handler, not a player widget.
Track/seek changes are coalesced to one update per 15 seconds. Pause, stop and
disable clear immediately. Presence displays title and artist only. Public
HTTPS artwork may include image-sizing parameters, but never credentials or
signed URL parameters. For local artwork, the resolver first checks download
history, then searches enabled metadata providers for an exact title,
artist and album match (and compatible duration). Results are cached, and late
lookups cannot update a different track or a disabled session. Local artwork
is never uploaded. If no public match exists, artwork is omitted; Discord
controls its own fallback presentation. SDK failures cannot interrupt music
playback. Presence depends on
Discord's activity privacy settings, connectivity and mobile background limits.

On Android the SDK binds to the Discord app through the activity it was given,
and Android releases that connection when the activity is destroyed, while the
plugin lives on with the shared Flutter engine. The plugin therefore creates a
new client for each new activity and has the service send the current song
again. An update that stays unanswered for 20 seconds counts as failed, and a
client whose update failed is replaced before the next attempt (at most every
two minutes, and only while the Discord app is installed). Presence that was
switched on while no activity existed starts when one appears. Without an
activity (the app swiped away while music plays) presence can lapse until the
app is opened again. On iOS a token refresh that could not reach Discord keeps
the account linked and is repeated every 30 seconds.

After staging the SDK, run `flutter test integration_test/discord_sdk_test.dart
-d <device-id>` on an iOS simulator or Android device to test native startup,
shutdown and restart without linking an account or publishing any activity.
