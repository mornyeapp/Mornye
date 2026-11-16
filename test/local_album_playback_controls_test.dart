import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/album_track_tile.dart';
import 'package:mornye/widgets/song_row_tap.dart';

import 'support/app_icon_finder.dart';
import 'support/tooltip_finder.dart';

class _Playing extends Notifier<bool> {
  @override
  bool build() => false;

  void emit(bool playing) => state = playing;
}

final _playingProvider = NotifierProvider<_Playing, bool>(_Playing.new);

class _Player extends MusicPlayerController {
  _Player(this._emit);

  final void Function(bool) _emit;
  final _toggles = <bool>[];

  @override
  Future<void> setShuffle(bool enabled) async {}

  @override
  Future<void> togglePlayPause(bool isPlaying) async {
    _toggles.add(isPlaying);
    _emit(!isPlaying);
  }
}

class _Playback extends PlaybackController {
  _Playback(this._start);

  final void Function(LocalLibraryItem) _start;
  final _started = <String>[];

  @override
  Future<void> playLocalLibraryQueue(
    List<LocalLibraryItem> items, {
    required LocalLibraryItem startItem,
  }) async {
    _started.add(startItem.id);
    _start(startItem);
  }
}

/// The current row's equalizer glyph loops while playing, so this settles
/// with bounded pumps instead of waiting for an idle frame.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final mornye in [false, true]) {
    for (final tapPlays in [false, true]) {
      testWidgets(
        'local album controls pause and resume without restarting '
        '($mornye, tapPlays: $tapPlays)',
        (tester) => _pauseAndResume(tester, mornye: mornye, tapPlays: tapPlays),
      );
    }
  }
}

/// With [tapPlays] the row tap does what the row's Play button does
/// otherwise, and the row shows a details button instead of a play glyph.
Future<void> _pauseAndResume(
  WidgetTester tester, {
  required bool mornye,
  required bool tapPlays,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(430, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final media = StreamController<MediaItem?>();
  addTearDown(media.close);
  late final ProviderContainer container;
  void emitPlaying(bool playing) =>
      container.read(_playingProvider.notifier).emit(playing);
  final player = _Player(emitPlaying);
  final playback = _Playback((track) {
    media.add(
      MediaItem(
        id: track.id,
        title: track.trackName,
        extras: {'source': track.filePath},
      ),
    );
    emitPlaying(true);
  });
  final tracks = [
    for (final number in [1, 2])
      LocalLibraryItem(
        id: '$number',
        trackName: 'Song $number',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: 'content://library/song-$number.flac',
        trackNumber: number,
        scannedAt: DateTime(2026),
      ),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => media.stream,
        ),
        playbackPlayingProvider.overrideWith(
          (ref) => ref.watch(_playingProvider),
        ),
        musicPlayerControllerProvider.overrideWithValue(player),
        playbackProvider.overrideWith(() => playback),
        librarySongTapPlaysProvider.overrideWithValue(tapPlays),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalAlbumScreen(
          albumName: 'Album',
          artistName: 'Artist',
          tracks: tracks,
        ),
      ),
    ),
  );
  container = ProviderScope.containerOf(
    tester.element(find.byType(LocalAlbumScreen)),
  );
  await _settle(tester);
  final header = find.byType(AlbumPlayActions);
  Finder row(int number) => find.byWidgetPredicate(
    (widget) => widget is AlbumTrackTile && widget.trackName == 'Song $number',
  );
  Finder rowButton(int number) => tapPlays
      ? find.text('Song $number')
      : find.descendant(of: row(number), matching: find.byType(IconButton));
  final rowGlyph = tapPlays ? findsNothing : findsOneWidget;
  expect(
    findByTooltip('Show details'),
    tapPlays ? findsNWidgets(2) : findsNothing,
  );
  final pauseIcon = mornye ? CupertinoIcons.pause_fill : Icons.pause;
  final playIcon = mornye ? CupertinoIcons.play_fill : Icons.play_arrow;

  await tester.tap(find.descendant(of: header, matching: find.text('Play')));
  await _settle(tester);
  expect(playback._started, ['1']);
  expect(
    find.descendant(of: header, matching: find.text('Pause')),
    findsOneWidget,
  );
  expect(
    find.descendant(of: header, matching: findAppIcon(pauseIcon)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: row(1), matching: findAppIcon(pauseIcon)),
    rowGlyph,
  );
  expect(
    find.descendant(of: row(2), matching: findAppIcon(playIcon)),
    rowGlyph,
  );

  await tester.tap(find.descendant(of: header, matching: find.text('Pause')));
  await _settle(tester);
  expect(player._toggles, [true]);
  expect(
    find.descendant(of: header, matching: find.text('Play')),
    findsOneWidget,
  );
  expect(
    find.descendant(of: row(1), matching: findByTooltip('Play')),
    rowGlyph,
  );

  await tester.ensureVisible(rowButton(1));
  await tester.tap(rowButton(1));
  await _settle(tester);
  expect(player._toggles, [true, false]);
  expect(playback._started, ['1']);
  expect(
    find.descendant(of: row(1), matching: findByTooltip('Pause')),
    rowGlyph,
  );

  await tester.ensureVisible(rowButton(2));
  await tester.tap(rowButton(2));
  await _settle(tester);
  expect(playback._started, ['1', '2']);
  expect(
    find.descendant(of: row(1), matching: findAppIcon(playIcon)),
    rowGlyph,
  );
  expect(
    find.descendant(of: row(2), matching: findAppIcon(pauseIcon)),
    rowGlyph,
  );
  await tester.tap(rowButton(2));
  await _settle(tester);
  expect(player._toggles, [true, false, true]);
  expect(playback._started, ['1', '2']);

  // A queue started from a playlist uses its file path as the media ID.
  media.add(MediaItem(id: tracks.first.filePath, title: 'Song 1'));
  emitPlaying(true);
  await _settle(tester);
  expect(
    find.descendant(of: row(1), matching: findAppIcon(pauseIcon)),
    rowGlyph,
  );
  await tester.tap(rowButton(1));
  await _settle(tester);
  expect(player._toggles.last, isTrue);
  expect(playback._started, ['1', '2']);

  // A matching row ID must not pause a different file in another album.
  media.add(
    const MediaItem(id: '1', title: 'Other', extras: {'source': '/other.flac'}),
  );
  emitPlaying(true);
  await _settle(tester);
  expect(
    find.descendant(of: header, matching: find.text('Play')),
    findsOneWidget,
  );
  expect(findAppIcon(pauseIcon), findsNothing);
  await tester.ensureVisible(header);
  await tester.tap(find.descendant(of: header, matching: find.text('Play')));
  await _settle(tester);
  expect(playback._started, ['1', '2', '1']);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}
