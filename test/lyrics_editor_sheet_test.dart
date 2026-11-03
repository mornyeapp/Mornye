import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/lyrics_editor_sheet.dart';

class _Player implements MusicPlayerController {
  final seeks = <Duration>[];

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

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

  setUp(() {
    playback = StreamController<PlaybackState>.broadcast();
    player = _Player();
    events = _Events();
    saved = [];
  });
  tearDown(() => playback.close());

  Future<PlayerMetadataController> open(
    WidgetTester tester,
    String lyrics, {
    bool desktop = false,
  }) async {
    tester.view.physicalSize = desktop
        ? const Size(1280, 900)
        : const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDesktopPlatformOverride = desktop;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final metadata = PlayerMetadataController(
      readMetadata: (_) async => {'lyrics': lyrics},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      saveOnlineLyrics: (_, raw) async => saved.add(raw),
      metadataEvents: events,
    );
    addTearDown(metadata.dispose);
    await metadata.load(_item);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
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
    await tester.pumpAndSettle();
    return metadata;
  }

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
    await tester.tap(find.byTooltip('Close'));
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
    await tester.tap(find.byTooltip('Line actions').first);
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
