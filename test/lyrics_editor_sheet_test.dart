import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/lyrics_editor_sheet.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

import 'support/tooltip_finder.dart';

class _Player implements MusicPlayerController {
  final seeks = <Duration>[];
  int playPauseCalls = 0;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> togglePlayPause(bool playing) async => playPauseCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Events extends SourceMetadataEvents {
  final published = <String>[];

  @override
  Future<void> publish(String source) async => published.add(source);
}

const _source = '/music/Album/song.flac';

const _item = MediaItem(
  id: _source,
  title: 'Song',
  artist: 'Artist',
  duration: Duration(minutes: 3),
  extras: {'source': _source},
);

void main() {
  late StreamController<PlaybackState> playback;
  late _Player player;
  late _Events events;
  late List<String> saved;
  late List<String> savedSources;

  setUp(() {
    playback = StreamController<PlaybackState>.broadcast();
    player = _Player();
    events = _Events();
    saved = [];
    savedSources = [];
  });
  tearDown(() => playback.close());

  Future<PlayerMetadataController> open(
    WidgetTester tester,
    String lyrics, {
    bool desktop = false,
    bool mornye = false,
    MediaItem item = _item,
    Future<void> Function(PlayerMetadataController metadata)? beforeBuild,
  }) async {
    tester.view.physicalSize = desktop
        ? const Size(1280, 900)
        : const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDesktopPlatformOverride = desktop;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final metadata = PlayerMetadataController(
      readMetadata: (path) async => {
        'lyrics': path.contains('next') ? '[00:02.00]Next lyrics' : lyrics,
      },
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      saveOnlineLyrics: (source, raw) async {
        savedSources.add(source);
        saved.add(raw);
      },
      metadataEvents: events,
    );
    addTearDown(metadata.dispose);
    await metadata.load(item);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openLyricsEditor(context, metadata),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    playback.add(PlaybackState(updatePosition: const Duration(seconds: 12)));
    await tester.pump();
    await tester.tap(find.text('open'));
    await beforeBuild?.call(metadata);
    await tester.pumpAndSettle();
    return metadata;
  }

  for (final source in [
    _source,
    'content://example.documents/tree/music/document/original.flac',
  ]) {
    for (final desktop in [false, true]) {
      testWidgets(
        'saves the original song after playback advances ($source, desktop: $desktop)',
        (tester) async {
          final original = _item.copyWith(
            extras: {
              'source': source,
              if (source.startsWith('content://'))
                'resolvedSource': '/cache/original.flac',
            },
          );
          final metadata = await open(
            tester,
            '[00:01.00]Original lyrics',
            desktop: desktop,
            item: original,
          );
          await tester.enterText(
            find.byType(TextField),
            'Edited original lyrics',
          );
          await tester.pump();
          final next = _item.copyWith(
            id: 'next',
            title: 'Next song',
            extras: const {
              'source': 'content://example.documents/next.flac',
              'resolvedSource': '/cache/next.flac',
            },
          );
          await metadata.load(next);
          await tester.pump();
          expect(find.text('Edited original lyrics'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('lyrics-editor-save')));
          await tester.pumpAndSettle();
          expect(savedSources, [source]);
          expect(saved, ['[00:01.00]Edited original lyrics']);
          expect(events.published, [source]);
          expect(metadata.item?.id, next.id);
          expect(metadata.rawLyrics, '[00:02.00]Next lyrics');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('the editor snapshots lyrics before its route builds', (
    tester,
  ) async {
    final metadata = await open(
      tester,
      '[00:01.00]Original lyrics',
      beforeBuild: (metadata) async {
        await metadata.load(
          _item.copyWith(
            id: 'next',
            title: 'Next song',
            extras: const {'source': '/music/next.flac'},
          ),
        );
      },
    );
    expect(metadata.rawLyrics, '[00:02.00]Next lyrics');
    expect(find.widgetWithText(TextField, 'Original lyrics'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Next lyrics'), findsNothing);
  });

  for (final mornye in [false, true]) {
    testWidgets('sync controls only affect the edited song (Mornye: $mornye)', (
      tester,
    ) async {
      final metadata = await open(
        tester,
        '[00:01.00]Original lyrics',
        mornye: mornye,
      );
      await metadata.load(
        _item.copyWith(
          id: 'next',
          title: 'Next song',
          extras: const {'source': '/music/next.flac'},
        ),
      );
      playback.add(PlaybackState(updatePosition: const Duration(seconds: 90)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('lyrics-editor-set-time')));
      await tester.tap(find.text('00:01.00'));
      await tester.tap(findByTooltip('Play'));
      await tester.pump();
      expect(find.text('00:01.00'), findsOneWidget);
      expect(find.text('01:30.00'), findsNothing);
      expect(player.seeks, isEmpty);
      expect(player.playPauseCalls, 0);
      final seek = tester.widget<PlaybackSeekSlider>(
        find.byType(PlaybackSeekSlider),
      );
      expect(seek.duration, Duration.zero);
      // A gesture that began before the change cannot seek the next song.
      await seek.onSeek(const Duration(seconds: 25));
      expect(player.seeks, isEmpty);
      // Manual timestamp adjustments and text edits remain usable.
      await tester.tap(find.text('+0.1'));
      await tester.pump();
      expect(find.text('00:01.10'), findsOneWidget);
      await metadata.load(_item);
      await tester.pumpAndSettle();
      await tester.tap(find.text('00:01.10'));
      await tester.tap(find.byKey(const ValueKey('lyrics-editor-set-time')));
      await tester.pump();
      expect(player.seeks, [const Duration(milliseconds: 1100)]);
      expect(find.text('01:30.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lyrics-editor-save')));
      await tester.pumpAndSettle();
      expect(savedSources, [_source]);
    });
  }

  testWidgets('a draft can be saved after the queue is cleared', (
    tester,
  ) async {
    final metadata = await open(tester, '[00:01.00]Original lyrics');
    await tester.enterText(find.byType(TextField), 'Edited original lyrics');
    await metadata.load(null);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lyrics-editor-save')));
    await tester.pumpAndSettle();
    expect(savedSources, [_source]);
    expect(saved, ['[00:01.00]Edited original lyrics']);
    expect(metadata.item, isNull);
    expect(metadata.lyrics.isEmpty, isTrue);
  });

  testWidgets('Set time syncs plain lyrics line by line and saves them', (
    tester,
  ) async {
    final metadata = await open(tester, 'First line\nSecond line');
    expect(find.text('Edit lyrics'), findsOneWidget);
    expect(find.text('--:--'), findsNWidgets(2));

    playback.add(
      PlaybackState(updatePosition: const Duration(milliseconds: 12345)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lyrics-editor-set-time')));
    await tester.pump();
    expect(find.text('00:12.35'), findsOneWidget);

    // The next line is selected; nudge it after stamping.
    playback.add(PlaybackState(updatePosition: const Duration(seconds: 15)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lyrics-editor-set-time')));
    await tester.pump();
    await tester.tap(find.text('+0.1'));
    await tester.pump();
    expect(find.text('00:15.10'), findsOneWidget);

    // A line's time plays from there.
    await tester.tap(find.text('00:12.35'));
    await tester.pump();
    expect(player.seeks, [const Duration(milliseconds: 12350)]);

    await tester.tap(find.byKey(const ValueKey('lyrics-editor-save')));
    await tester.pumpAndSettle();
    expect(saved, ['[00:12.35]First line\n[00:15.10]Second line']);
    expect(events.published, [_source]);
    expect(find.text('Edit lyrics'), findsNothing);
    expect(find.text('Lyrics saved'), findsOneWidget);
    expect(metadata.lyrics.synced, isTrue);
    expect(metadata.rawLyrics, saved.single);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing with changes asks before discarding them', (
    tester,
  ) async {
    await open(tester, '[00:01.00]Line');
    // Save waits for a change.
    await tester.tap(find.byKey(const ValueKey('lyrics-editor-save')));
    await tester.pumpAndSettle();
    expect(find.text('Edit lyrics'), findsOneWidget);
    expect(saved, isEmpty);
    await tester.enterText(find.byType(TextField), 'Edited line');
    await tester.pump();
    await tester.tap(findByTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard Changes?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Edit lyrics'), findsNothing);
    expect(saved, isEmpty);
  });

  testWidgets('scrolling over a line scrolls the list, not its text', (
    tester,
  ) async {
    await open(
      tester,
      [for (var i = 0; i < 40; i++) '[00:${(i + 10)}.00]Line $i'].join('\n'),
      desktop: true,
    );
    final field = find.widgetWithText(TextField, 'Line 3');
    final before = tester.getTopLeft(field).dy;
    final pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(tester.getCenter(field));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(field).dy, before - 120);
    // The text keeps its place inside the row.
    final editable = tester.state<EditableTextState>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(editable.renderEditable.offset.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line can be inserted and deleted from its menu', (
    tester,
  ) async {
    await open(tester, '[00:01.00]One\n[00:02.00]Two', desktop: true);
    expect(find.byKey(const ValueKey('app-sheet-dialog')), findsOneWidget);
    await tester.tap(findByTooltip('Line actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete line'));
    await tester.pumpAndSettle();
    expect(find.text('One'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lyrics-editor-save')));
    await tester.pumpAndSettle();
    expect(saved, ['[00:02.00]Two']);
    expect(tester.takeException(), isNull);
  });
}
