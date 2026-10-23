import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_player_service.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'internal');
}

class _Handler extends Fake implements MusicPlayerHandler {}

class _Player extends MusicPlayerController {
  final calls = <(String, int)>[];

  @override
  Future<MusicPlayerHandler?> ensureInitialized() async => _Handler();

  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async => calls.add((items.map((item) => item.id).join(' '), initialIndex));
}

const _paths = {
  'blank': '  ',
  'a': '/music/a.flac',
  'cue': '/music/album.cue#track02',
  'b': '/music/b.flac',
  'c': '/music/c.flac',
};

void main() {
  late _Player player;
  late ProviderContainer container;

  setUp(() {
    player = _Player();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        musicPlayerControllerProvider.overrideWithValue(player),
      ],
    );
  });
  tearDown(() => container.dispose());

  // Blank and CUE virtual paths are skipped; the start item keeps its place
  // among the playable rows, and a skipped start falls back to the first.
  for (final (start, index) in [('b', 1), ('c', 2), ('cue', 0)]) {
    test('local queue starting at $start', () async {
      final items = [
        for (final MapEntry(:key, :value) in _paths.entries)
          LocalLibraryItem(
            id: key,
            trackName: key,
            artistName: 'Artist',
            albumName: 'Album',
            filePath: value,
            scannedAt: DateTime(2026),
          ),
      ];
      await container
          .read(playbackProvider.notifier)
          .playLocalLibraryQueue(
            items,
            startItem: items.firstWhere((item) => item.id == start),
          );
      expect(player.calls, [('a b c', index)]);
    });

    test('history queue starting at $start', () async {
      final items = [
        for (final MapEntry(:key, :value) in _paths.entries)
          DownloadHistoryItem(
            id: key,
            trackName: key,
            artistName: 'Artist',
            albumName: 'Album',
            filePath: value,
            service: 'example',
            downloadedAt: DateTime(2026),
          ),
      ];
      await container
          .read(playbackProvider.notifier)
          .playHistoryQueue(
            items,
            startItem: items.firstWhere((item) => item.id == start),
          );
      expect(player.calls, [('a b c', index)]);
    });
  }

  test('a queue without playable rows plays nothing', () async {
    final item = LocalLibraryItem(
      id: 'cue',
      trackName: 'cue',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: _paths['cue']!,
      scannedAt: DateTime(2026),
    );
    await container.read(playbackProvider.notifier).playLocalLibraryQueue([
      item,
    ], startItem: item);
    expect(player.calls, isEmpty);
  });
}
