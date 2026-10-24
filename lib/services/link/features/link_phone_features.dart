import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_library_lookup.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_phone_files.dart';
import 'package:mornye/services/link/features/link_phone_player.dart';
import 'package:mornye/services/link/features/link_phone_session.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/share_intent_service.dart';
import 'package:mornye/services/system_volume_service.dart';

export 'package:mornye/services/link/features/link_phone_client.dart';

/// Opens a link the way a link shared to the app opens: through
/// [ShareIntentService.injectUrl], which `MainShell` handles like any shared
/// URL (Search tab, metadata lookup, error snackbars).
final linkOpenUrlProvider = Provider<LinkOpenUrl>(
  (ref) => ShareIntentService().injectUrl,
);

/// The phone's downloads and Library for resolving desktop tracks.
final linkLibraryLookupProvider = Provider<LinkLibraryLookup>(
  (ref) => LinkDatabaseLookup(
    history: () => ref.read(downloadHistoryProvider.notifier),
    library: ref.watch(musicPlayerRuntimeProvider).dependencies.libraryDatabase,
    includeLibrary: () => ref.read(settingsProvider).localLibraryEnabled,
  ),
);

/// The phone's player as the link features drive it.
final linkPhonePlayerProvider = Provider<LinkPhonePlayer>(
  (ref) => LinkMusicPhonePlayer(
    runtime: ref.watch(musicPlayerRuntimeProvider),
    // This phone's own player, also while the desktop plays in its place.
    controller: MusicPlayerController(
      runtime: ref.watch(musicPlayerRuntimeProvider),
    ),
    writeVolume: ref.watch(systemVolumeWriterProvider),
    volumeChanges: SystemVolumeService.instance.changes,
  ),
);

/// Queue item refs for the paired desktop, remembered for its session.
final linkTrackRefCacheProvider = Provider<LinkTrackRefCache>(
  (ref) => LinkTrackRefCache(
    lookup: ref.watch(linkLibraryLookupProvider),
    server: ref.watch(linkPhoneClientProvider)?.server,
  ),
);

final linkTrackResolverProvider = Provider<LinkTrackResolver>(
  (ref) => LinkTrackResolver(
    lookup: ref.watch(linkLibraryLookupProvider),
    server: ref.watch(linkPhoneClientProvider)?.server,
  ),
);

/// Sends this phone's song files to the paired desktop. One instance for the
/// app, so a new handoff stops the uploads of the one before.
final linkPhoneFilesProvider = Provider<LinkPhoneFiles>(
  (ref) => LinkPhoneFiles(),
);

/// Handoff with the paired desktop, or null when none is paired.
final linkHandoffProvider = Provider<LinkHandoff?>((ref) {
  final client = ref.watch(linkPhoneClientProvider);
  if (client == null) return null;
  return LinkHandoff(
    client: client,
    player: ref.watch(linkPhonePlayerProvider),
    refs: ref.watch(linkTrackRefCacheProvider),
    resolver: ref.watch(linkTrackResolverProvider),
    files: ref.watch(linkPhoneFilesProvider),
  );
});

/// Saves the paired desktop's songs to this phone, or null when none is
/// paired. A run keeps the folder settings it started with.
final linkOfflineSaverProvider = Provider<LinkOfflineSaver?>((ref) {
  final client = ref.watch(linkPhoneClientProvider);
  if (client == null) return null;
  final connectionId = client.server.connectionId;
  // Captured rather than read through `ref` later: a run outlives a rebuild
  // of this provider.
  final history = ref.watch(downloadHistoryProvider.notifier);
  return LinkOfflineSaver(
    connectionId: connectionId,
    openTransport: () => LinkSubsonicTransport(connectionId: connectionId),
    destination: LinkDownloadFolderDestination(ref.watch(settingsProvider)),
    record: history.addToHistory,
    temporaryDirectory: getTemporaryDirectory,
  );
});

/// The phone's side of the paired desktop's session, for the app's
/// lifetime: watched at the app root on phones, it reports this phone's
/// player to the desktop and applies the desktop's `command` and `open`
/// messages. Null while no desktop is paired.
final linkPhoneFeaturesProvider = Provider<LinkPhoneSession?>((ref) {
  final client = ref.watch(linkPhoneClientProvider);
  final handoff = ref.watch(linkHandoffProvider);
  if (client == null || handoff == null) return null;
  final session = LinkPhoneSession(
    client: client,
    player: handoff.player,
    refs: handoff.refs,
    handoff: handoff,
    openUrl: ref.watch(linkOpenUrlProvider),
  )..start();
  ref.onDispose(session.dispose);
  return session;
});
