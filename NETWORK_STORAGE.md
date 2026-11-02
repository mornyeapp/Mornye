# Network storage

Open Settings → Network storage in Material or Mornye. Add a named connection,
choose the protocol, enter its address and optional credentials, then choose
**Connect and save**. The app checks access before saving. Edit the connection
to change credentials or remove it. Removing a connection never deletes files
from the server.

- SMB: `smb://nas/Music/`, optional username, password, and domain. Defaults to
  port 445; explicit ports are supported. The native libsmb2 client negotiates
  SMB 2.0.2, 2.1, 3.0, 3.0.2 or 3.1.1 and supports required signing and encryption.
  SMB1 is never offered. Leave the domain empty unless your server requires it.
  OpenWRT can run Samba4 or ksmbd; use the share name and the same account as
  the other client. Guest access is only attempted when credentials are blank,
  never as an automatic fallback after a named account fails.
- WebDAV: `https://nas.example/dav/music/`, optional HTTP Basic authentication.
  Routers such as GL.iNet use self-signed HTTPS certificates. If validation
  fails, the connection form shows the server origin and SHA-256 fingerprint.
  **Trust certificate and retry** saves that exact certificate exception with
  the connection only after a successful access check. Changing the server
  address or certificate requires a new approval. This applies to browsing,
  artwork, metadata and audio requests through the same transport; certificate
  checking stays enabled for other servers. Paste the `https://` link supplied
  by the router, including its WebDAV port (e.g. 6008), rather than `dav://`.
  GL.iNet documents its self-signed certificate behavior at
  https://docs.gl-inet.com/router/en/4/interface_guide/network_storage/.
- HTTP/HTTPS: direct audio URL or an HTML directory index. This does not scrape
  arbitrary websites, access cloud account APIs, or discover media hidden behind
  JavaScript/login forms. Use the final directory URL; canonical trailing-slash
  redirects are supported. Cross-origin redirects are rejected.

Connections are stored in the platform secure store. Playback sessions contain
opaque connection IDs and relative paths instead of server credentials. A
random-token loopback proxy handles GET, HEAD and byte ranges. Files stream on
demand without making a full local copy; HTTP seeking depends on the server's
range support. Requests have a 20-second connection/read-inactivity timeout.

Browsing alone does not add anything to the Library. Inside an SMB or WebDAV
folder, choose **Add folder to Library** to index that folder and its subfolders.
The source can then be rescanned, disabled or removed in Local Library settings.
Scans read one file's tags at a time and persist embedded artwork on the device;
audio stays on the server. Failed folder/tag reads preserve previously indexed
rows, and a temporarily unreachable NAS does not hide the cached collection.
Network Library tracks use the built-in player and remote file editing/deletion
is unavailable. Adding a folder does not make it a download destination.

## Download destination

Choose **Settings → Files → Network download destination**, browse to an SMB or
WebDAV folder, and select **Download to this folder**. The same button is present
when browsing Network storage normally. A temporary write/delete probe must
succeed before the selection is saved. **Use local download folder** restores
the previously configured local/SAF destination. HTTP directory indexes are
read-only.

Each queued download records its selected network destination. Audio is first
downloaded to a private per-item staging directory. Metadata, embedded cover,
lyrics, track ReplayGain, extension post-processing and automatic conversion
finish locally. Folder organization and the final filename are retained when
uploading; an existing name receives a numbered suffix instead of being
overwritten. LRC sidecars, when enabled, are uploaded alongside the audio.

Transfers stream bounded chunks to a hidden `.part` file, verify its size and
publish with a non-overwriting SMB rename or WebDAV MOVE (`Overwrite: F`, as
specified in https://www.rfc-editor.org/rfc/rfc4918.html#section-9.9.3).
libsmb2 also sets `replace_if_exist=0` for rename. Completion/history is published
only after the transfer succeeds, so the normal Library download history
refresh exposes the playable `network://` entry immediately. Credentials stay
in the secure connection store, never in the transfer journal or history.

A failed transfer retains finalized local audio and an atomic on-disk journal.
Retry, including after an app restart, uploads that audio again without fetching
or processing the song again. A lost publication response is reconciled by
streaming SHA-256 comparison before adopting an existing remote file. Local
staging is removed after history completion or when a failed item is dismissed.
An unreachable NAS may leave a hidden partial file until the same transfer is
retried; existing completed music is never deleted.

Network destinations currently use the shared Flutter queue even when Native
Download Worker is enabled, because the autonomous worker cannot yet perform
the network publication handoff. Keep the app open until upload finishes; this
does not promise transfers after force-stop or indefinite iOS background time.
Track ReplayGain is supported; later album-wide ReplayGain rewriting across
already-published tracks is not. Failed uploads occupy staging space until
retried or removed.

Selecting a song queues audio files in its current folder. Titles initially use
filenames; standard `cover.jpg`, `folder.jpg`, `front.jpg`, `cover.png` and
`folder.png` images in that folder provide initial artwork. When a song plays
or its Lyrics/Details view opens, embedded metadata and lyrics are read using
the same native tag parsers as local files. Embedded artwork takes precedence
over the folder image. LRC timestamps embedded in the lyrics use the regular
synchronized lyrics renderer; plain lyrics remain plain text.

Metadata uses 256 KiB range reads through the same proxy for SMB, WebDAV and
HTTP. Tags at the end of M4A files are reached by seeking past audio data. Each
read has a 20-second budget and a 16 MiB transfer cap, with bounded memory and
cover caches. Playback and Lyrics share in-flight reads and cache results for
five minutes. Large HTTP files require server byte-range support; a tag read
failure leaves playback available with filename/folder artwork fallbacks.

Library songs can be saved for offline playback from their song menu, selection
toolbar, album, playlist or folder. This copies the original audio file into the
device's normal download folder, preserving the relative server folder and file
name (Subsonic uses its original path when supplied, otherwise artist/album).
No conversion or quality selection is applied. A stable network origin links
the independent local History file to the retained scanned server row. Library
shows one preferred local entry and offers an On this device filter, availability
status, and separate removal of the local and server copies. A later scan that
finds the server file gone leaves the offline copy alone. Playback prefers an
available local copy even for network songs already queued. This does not change
the network destination for new provider downloads or synchronize later edits.

Remote metadata editing, separate sidecar lyric files,
AutoMix and direct USB/DAP bit-perfect output are not part of this browser.
Normal playback uses the platform audio decoder, so codec support follows the
device.

## Validation

`flutter test test/network_upload_test.dart test/network_download_destination_test.dart`
checks authenticated WebDAV writes, MKCOL, MOVE, collision handling, sidecars,
interrupted transfers, lost responses, restart journals, and destination UI in
both themes. The SMB upload test uses the pinned native library and a disposable
Samba fixture with encryption mandatory:
`python3 scripts/smb3_fixture_server.py --port 1446 --writable` and
`TEST_SMB_UPLOAD=1 TEST_SMB_PORT=1446 TEST_SMB_LIBRARY=<host-library> flutter test test/network_smb_upload_test.dart`.
It validates upload, non-overwriting publication and retry reconciliation in
existing folders. This host's unprivileged macOS Samba creates new directories
with mode 000 even with its own smbclient; nested folder creation is covered by
the WebDAV fixture, not claimed as a successful SMB host-device check.

`flutter test test/network_storage_service_test.dart test/network_storage_screen_test.dart`
checks URL/path handling, HTML/WebDAV parsing, authenticated HTTP transport,
range/HEAD requests, connection persistence/removal and browser navigation.

For the optional signed, authenticated SMB2 test, install `impacket` in a
temporary Python virtual environment and run `scripts/smb2_fixture_server.py`.
Then run `TEST_SMB=1 flutter test test/network_storage_service_test.dart`.
Set `TEST_SMB_PORT` for the fixture's port (default 1445). For host Flutter tests,
set `TEST_SMB_LIBRARY` to the matching libsmb2 native binary from the pinned
dart_smb2 release. Stop the fixture after testing. `network_smb_transport_test.dart`
captures the actual negotiation packet and checks that SMB3 is offered without
an SMB1 negotiate. Run the same service test against Samba restricted to each
SMB2/3 dialect, with signing mandatory and encryption required for SMB3 tests.

The pinned dart_smb2 0.1.3 plugin verifies native download checksums at build time
(libsmb2-r8). Its LGPL library is dynamically linked. License text is included
in the app's licenses; corresponding build scripts, patches and source are at
https://github.com/ales-drnz/libsmb2-scripts and
https://github.com/sahlberg/libsmb2.

Samba4 fixture (isolated account database, loopback only, no system service):
`python3 scripts/smb3_fixture_server.py --dialect SMB3_11 --encryption required`.
Use `--dialect SMB3_00`, `SMB3_02`, `SMB2_10` or `SMB2_02` to constrain negotiation;
SMB2 requires `--encryption off`. Guest validation uses `--guest --encryption off`
on a second port, passed to the test as `TEST_SMB_GUEST_PORT`.

Android emulator transport validation:
`flutter test integration_test/network_smb_test.dart -d emulator-5554 --dart-define=SMB_TEST_URL=smb://10.0.2.2:1445/MUSIC/`.
For the iOS simulator, use `127.0.0.1` instead of `10.0.2.2`.

The transport was validated against an isolated Samba 4.25 server with mandatory
signing for SMB 2.0.2/2.1 and mandatory encryption for SMB 3.0/3.0.2/3.1.1.
Checks cover empty/WORKGROUP domains, explicit guest access, failed credentials,
share enumeration, file listing, HEAD and byte ranges. These fixtures validate
protocol behavior, not the configuration of a particular OpenWRT router.

`flutter test integration_test/network_playback_test.dart -d <device>` exercises
the real native tag reader with embedded FLAC tags/lyrics and verifies bounded
range transfers and cache reuse. It also exercises the platform decoder with
silent WAV data through the loopback proxy, including preparation, playback
and seeking.

`cargo test -p mornye-mobile network_tags --lib` from `rust_backend` checks
FLAC metadata/cover extraction, seeking past M4A audio to tail tags, and rejection
of external URLs and large non-range responses. Flutter metadata service tests
cover shared reads, recoverable failures, and embedded cover caching; the Now
Playing tests also check that network lyrics use the shared metadata result.
