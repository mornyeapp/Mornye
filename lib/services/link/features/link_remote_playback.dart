import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/features/link_desktop_remote.dart';
import 'package:mornye/services/link/features/link_handoff.dart';
import 'package:mornye/services/link/features/link_ios_now_playing.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:mornye/services/link/features/link_playback_preferences.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_mirrored_playback.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkRemotePlayback');

/// Whether the paired desktop plays in this phone's place, as after Play on
/// desktop or, with [LinkPhoneOptions.followDesktop], when the desktop
/// starts playing while this phone does not. The phone takes over again
/// after Continue on this phone, when the desktop is unpaired, and when the
/// phone's own player starts, such as for a Library song picked in the car.
/// It also takes over when the desktop cannot be reached, so songs picked
/// then play here instead of waiting for it. The notification and headset
/// drive the desktop meanwhile.
class LinkPlaysOnDesktop extends Notifier<bool> {
  @override
  bool build() {
    final client = ref.watch(linkPhoneClientProvider);
    if (client == null) return false;
    bool? playing;
    // Whether the desktop played when last heard from on this connection.
    bool? desktopPlaying;
    void heard(LinkPlayerState? desktop) {
      final was = desktopPlaying;
      final now = desktopPlaying =
          desktop != null && desktop.playing && desktop.track != null;
      // The desktop starting to play takes over the player screens, as
      // choosing it in Devices does, unless this phone plays meanwhile.
      if (was == true || !now || playing == true || state) return;
      final options = ref.read(linkPhoneOptionsProvider);
      if (options.loaded && options.followDesktop) state = true;
    }

    // A failed attempt goes from connecting to disconnected. The session
    // pausing in the background disconnects a connected one instead, which
    // keeps the desktop.
    var connection = client.connectionState;
    var connects = 0;
    Future<void> readDesktop() async {
      final attempt = ++connects;
      try {
        final desktop = LinkPlayerState.fromJson(
          await client.get(LinkOps.state),
        );
        if (ref.mounted &&
            attempt == connects &&
            connection == LinkConnectionState.connected) {
          heard(desktop);
        }
      } on Object {
        // Its next push tells.
      }
    }

    final connections = client.connectionStates.listen((next) {
      final was = connection;
      connection = next;
      if (next != LinkConnectionState.connected) {
        connects++;
        desktopPlaying = null;
      } else if (was != next) {
        unawaited(readDesktop());
      }
      if (was == LinkConnectionState.connecting &&
          next == LinkConnectionState.disconnected &&
          state) {
        state = false;
      }
    });
    ref.onDispose(connections.cancel);
    Future<void> pauseDesktop() async {
      try {
        await client.post(
          LinkOps.command,
          const LinkCommand(LinkActions.pause).toJson(),
        );
      } on Object catch (error) {
        _log.w('Could not pause the computer: $error');
      }
    }

    final messages = client.messages.listen((message) {
      if (message['type'] != LinkMessageTypes.playerState) return;
      heard(LinkPlayerState.fromJson(message['state']));
    });
    ref.onDispose(messages.cancel);
    if (connection == LinkConnectionState.connected) {
      unawaited(readDesktop());
    }
    final subscription = ref
        .watch(musicPlayerRuntimeProvider)
        .playbackStateEvents()
        .listen((playback) {
          final was = playing;
          playing = playback.playing;
          if (was == false && playback.playing) {
            if (state) state = false;
            // One player at a time: this phone starting pauses the desktop.
            if (desktopPlaying == true) unawaited(pauseDesktop());
          } else if (was == true &&
              !playback.playing &&
              desktopPlaying == true &&
              !state) {
            // Paused for the desktop, which started meanwhile.
            final options = ref.read(linkPhoneOptionsProvider);
            if (options.loaded && options.followDesktop) state = true;
          }
        });
    ref.onDispose(subscription.cancel);
    return false;
  }

  void set(bool onDesktop) {
    // A pairing that ended meanwhile already moved playback back here.
    if (ref.mounted) state = onDesktop;
  }
}

final linkPlaysOnDesktopProvider = NotifierProvider<LinkPlaysOnDesktop, bool>(
  LinkPlaysOnDesktop.new,
);

/// The paired desktop while it plays in this phone's place, else null. The
/// app root installs it as [activeRemotePlaybackProvider].
final linkRemotePlaybackProvider = Provider<LinkRemotePlayback?>((ref) {
  if (!ref.watch(linkPlaysOnDesktopProvider)) return null;
  final client = ref.watch(linkPhoneClientProvider);
  final handoff = ref.watch(linkHandoffProvider);
  if (client == null || handoff == null) return null;
  late final LinkRemotePlayback playback;
  final remote = ref.read(linkDesktopRemoteProvider.notifier);
  final preferences = LinkPlaybackPreferencesSync(
    readAutoplay: () => ref.read(settingsProvider).autoplay,
    readAutoMix: () => ref.read(settingsProvider).autoMix,
    writeAutoplay: (enabled) =>
        ref.read(settingsProvider.notifier).setAutoplay(enabled),
    writeAutoMix: (enabled) =>
        ref.read(settingsProvider.notifier).setAutoMix(enabled),
    sendAutoplay: remote.setAutoplay,
    sendAutoMix: remote.setAutoMix,
  );
  var revision = 0;
  void update(LinkRemoteState state) {
    playback.update(state);
    final current = ++revision;
    scheduleMicrotask(() {
      if (ref.mounted && current == revision) {
        preferences.updateRemote(state.player);
      }
    });
  }

  // Listening keeps the desktop's state alive while it plays for the phone.
  ref.listen(linkDesktopRemoteProvider, (_, next) => update(next));
  ref.listen(settingsProvider.select((s) => (s.autoplay, s.autoMix)), (_, _) {
    unawaited(
      preferences.updateLocal().catchError((Object error) {
        _log.w('Could not update the computer playback preferences: $error');
      }),
    );
  });
  final runtime = ref.watch(musicPlayerRuntimeProvider);
  playback = LinkRemotePlayback(
    name: linkDesktopName(client),
    remote: remote,
    handoff: handoff,
    covers: runtime.dependencies.coverStore,
    initialItem: ref.read(localMediaItemProvider).value,
    initialState: runtime.handler?.playbackState.value,
  );
  update(ref.read(linkDesktopRemoteProvider));
  ref.onDispose(
    SourceMetadataEvents.instance.subscribe((source) async {
      final songId = linkDesktopSongId(source, client.server);
      if (songId == null) return;
      playback
        ..refreshCover(linkDesktopCoverSource(client.server, songId))
        ..refreshTracks();
      await remote.refresh();
    }),
  );
  if (Platform.isIOS) {
    final nowPlaying = IosLinkNowPlaying(
      remote: playback,
      server: client.server,
      apiKey: () async =>
          (await ref
                  .read(linkLibraryBridgeProvider)
                  .connection(client.server.connectionId))
              ?.apiKey,
      track: () => ref.read(linkDesktopRemoteProvider).player?.track,
    )..start();
    ref.onDispose(nowPlaying.dispose);
  }
  ref.onDispose(playback.dispose);
  return playback;
});

/// The paired desktop's player as the phone's player screens show and drive
/// it. Each desktop track shows as the phone would play it: its own file
/// when it has one, so lyrics, details and favorites work as usual, else
/// the desktop's song with its cover.
class LinkRemotePlayback extends LinkMirroredPlayback {
  LinkRemotePlayback({
    required super.name,
    required LinkDesktopRemote remote,
    required LinkHandoff handoff,
    required super.covers,
    super.extractArtwork,
    super.initialItem,
    super.initialState,
    super.tick,
    super.seekTimeout,
    super.nowMs,
  }) : _remote = remote,
       _handoff = handoff;

  final LinkDesktopRemote _remote;
  final LinkHandoff _handoff;
  LinkConnectionState? _connection;

  /// Shows the desktop's [state].
  void update(LinkRemoteState state) {
    if (disposed || (state.loading && state.player == null)) return;
    if (state.connection == LinkConnectionState.connected &&
        _connection != LinkConnectionState.connected) {
      retryFailed();
    }
    _connection = state.connection;
    show(state.player);
  }

  @override
  Future<void> send(LinkCommand command) => _remote.command(command);

  @override
  PlayableMedia? immediatePlayable(TrackRef ref) =>
      linkDesktopPlayable(ref, _handoff.resolver.server);

  /// The phone's file for [ref], else the desktop's song with its cover.
  @override
  Future<PlayableMedia?> resolvePlayable(TrackRef ref) =>
      _handoff.resolver.resolve(ref);

  @override
  Future<void> playAll(List<PlayableMedia> items, {int initialIndex = 0}) =>
      sending(
        (onSending) => _handoff.playItemsOnDesktop(
          [for (final item in items) item.toMediaItem()],
          index: initialIndex,
          modes: player,
          onSending: onSending,
        ),
      );

  @override
  Future<void> enqueue(List<PlayableMedia> items, {bool playNext = false}) =>
      sending(
        (onSending) => _handoff.addToDesktopQueue(
          [for (final item in items) item.toMediaItem()],
          playNext: playNext,
          onSending: onSending,
        ),
      );
}
