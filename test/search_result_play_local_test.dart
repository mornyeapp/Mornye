import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/history_database.dart';

import 'support/search_results_fixture.dart';

const _path = 'network://nas/found-track-0.flac';
const _notice = 'No extensions with download provider';

/// The first found song has a download.
class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<DownloadHistoryItem?> getBySpotifyIdAsync(String spotifyId) async =>
      spotifyId == 'track-0'
      ? DownloadHistoryItem(
          id: 'download',
          trackName: 'Found track 0',
          artistName: 'Example artist 0',
          albumName: 'Example album 0',
          filePath: _path,
          service: 'test',
          downloadedAt: DateTime(2026),
        )
      : null;

  @override
  Future<DownloadHistoryItem?> findExistingTrackAsync(
    HistoryLookupRequest request,
  ) async => null;

  @override
  Future<DownloadHistoryItem?> getByIsrcAsync(String isrc) async => null;

  @override
  Future<DownloadHistoryItem?> findByTrackAndArtistAsync(
    String trackName,
    String artistName,
  ) async => null;
}

class _Playback extends PlaybackController {
  final played = <String>[];

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
  }) async => played.add(path);
}

void main() {
  Future<_Playback> pump(
    WidgetTester tester, {
    required bool mornye,
    AppSettings settings = const AppSettings(
      searchProvider: 'example',
      hasSearchedBefore: true,
      askQualityBeforeDownload: false,
      localLibraryEnabled: false,
    ),
  }) async {
    final playback = _Playback();
    await pumpSearchFixture(
      tester,
      size: const Size(420, 1400),
      mornye: mornye,
      settings: settings,
      history: _History.new,
      downloadedIds: const {'track-0'},
      overrides: [playbackProvider.overrideWith(() => playback)],
    );
    return playback;
  }

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: a tap on a song the person has plays it', (
      tester,
    ) async {
      final playback = await pump(tester, mornye: mornye);

      await tester.tap(find.text('Found track 0'));
      await tester.pumpAndSettle();
      expect(playback.played, [_path]);
      expect(find.text(_notice), findsNothing);

      // A song they do not have is still downloaded.
      await tester.tap(find.text('Found track 1'));
      await tester.pumpAndSettle();
      expect(playback.played, [_path]);
      expect(find.text(_notice), findsOneWidget);
    });
  }

  testWidgets('with duplicates allowed a tap downloads the song again', (
    tester,
  ) async {
    final playback = await pump(
      tester,
      mornye: false,
      settings: const AppSettings(
        searchProvider: 'example',
        hasSearchedBefore: true,
        askQualityBeforeDownload: false,
        localLibraryEnabled: false,
        deduplicateDownloads: false,
      ),
    );

    await tester.tap(find.text('Found track 0'));
    await tester.pump();
    expect(playback.played, isEmpty);
    expect(find.text(_notice), findsOneWidget);
  });
}
