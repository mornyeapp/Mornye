import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/collection_track_files_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: true);

  @override
  void setLocalLibraryEnabled(bool enabled) {
    state = state.copyWith(localLibraryEnabled: enabled);
  }
}

class _Library extends LocalLibraryNotifier {
  final requests = <List<LocalLibraryBatchLookupRequest>>[];
  final matches = <LocalLibraryItem?>[];

  @override
  LocalLibraryState build() => LocalLibraryState();

  @override
  Future<List<LocalLibraryItem?>> findExistingBatchAsync(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async {
    this.requests.add(requests);
    return matches;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'FLAC upgrade keeps scanned metadata and counts each file once',
    () async {
      final library = _Library();
      LocalLibraryItem item(String id, String path, String? format) =>
          LocalLibraryItem(
            id: id,
            trackName: 'Song $id',
            artistName: 'Artist',
            albumName: 'Album',
            filePath: path,
            format: format,
            isrc: 'EXAMPLE$id',
            duration: 180,
            scannedAt: DateTime(2026),
          );
      final mp3 = item('mp3', 'content://library/opaque-mp3', 'mp3');
      library.matches.addAll([
        mp3,
        item('repeat', mp3.filePath, 'mp3'),
        item('saf-flac', 'content://library/opaque-flac', 'FLAC'),
        item('flac-path', '/music/song.FLAC', null),
        null,
      ]);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          localLibraryProvider.overrideWith(() => library),
        ],
      );
      addTearDown(container.dispose);
      final request = CollectionTrackFilesRequest([
        for (var index = 0; index < library.matches.length; index++)
          Track(
            id: 'local-$index',
            name: 'Selected $index',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
            source: 'local',
          ),
      ]);
      final provider = collectionTrackFlacCandidatesProvider(request);
      container.listen(provider, (_, _) {});
      expect(await container.read(provider.future), [same(mp3)]);
      expect(library.requests.single.map((r) => r.id), [
        for (var index = 0; index < library.matches.length; index++)
          'local-$index',
      ]);

      container.read(settingsProvider.notifier).setLocalLibraryEnabled(false);
      expect(await container.read(provider.future), isEmpty);
      expect(library.requests, hasLength(1));
      container.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      expect(await container.read(provider.future), [same(mp3)]);
    },
  );
}
