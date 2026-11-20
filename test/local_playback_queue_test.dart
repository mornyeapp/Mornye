import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

const _path = 'network://nas/second.flac';

final _album = [
  for (final id in ['first', 'second', 'third'])
    Track(
      id: id,
      name: id,
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
    ),
];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: false);
}

/// Only the second song has a download.
class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<DownloadHistoryItem?> getBySpotifyIdAsync(String spotifyId) async =>
      spotifyId == 'second'
      ? DownloadHistoryItem(
          id: 'download',
          trackName: 'second',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: _path,
          service: 'test',
          downloadedAt: DateTime(2026),
        )
      : null;

  @override
  Future<DownloadHistoryItem?> getByIsrcAsync(String isrc) async => null;

  @override
  Future<DownloadHistoryItem?> findByTrackAndArtistAsync(
    String trackName,
    String artistName,
  ) async => null;
}

class _Playback extends PlaybackController {
  final calls = <String>[];

  @override
  Future<void> playTrackList(
    List<Track> tracks, {
    int startIndex = 0,
    String? startPath,
  }) async => calls.add(
    'list ${tracks.map((track) => track.id).join(',')} $startIndex $startPath',
  );

  @override
  Future<void> playLocalPath({
    required String path,
    required String title,
    required String artist,
    String album = '',
    String? genre,
    String coverUrl = '',
    Duration? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    bool? explicit,
  }) async => calls.add('single $path');
}

void main() {
  late _Playback playback;
  late BuildContext context;
  late WidgetRef ref;

  Future<void> pump(WidgetTester tester) async {
    playback = _Playback();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadHistoryProvider.overrideWith(_History.new),
          playbackProvider.overrideWith(() => playback),
        ],
        child: Consumer(
          builder: (buildContext, widgetRef, _) {
            context = buildContext;
            ref = widgetRef;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  testWidgets('a local song plays on through its album', (tester) async {
    await pump(tester);
    expect(
      await playLocalIfAvailable(
        context,
        ref,
        _album[1],
        queue: _album,
        queueIndex: 1,
      ),
      isTrue,
    );
    expect(playback.calls, ['list first,second,third 1 $_path']);
  });

  testWidgets('without a list, or with a list that does not hold the song, '
      'only the song plays', (tester) async {
    await pump(tester);
    await playLocalIfAvailable(context, ref, _album[1]);
    await playLocalIfAvailable(
      context,
      ref,
      _album[1],
      queue: _album,
      queueIndex: 0,
    );
    expect(playback.calls, ['single $_path', 'single $_path']);
  });

  testWidgets('a song with no local file leaves the download to the caller', (
    tester,
  ) async {
    await pump(tester);
    expect(
      await playLocalIfAvailable(
        context,
        ref,
        _album.first,
        queue: _album,
        queueIndex: 0,
      ),
      isFalse,
    );
    expect(playback.calls, isEmpty);
  });
}
