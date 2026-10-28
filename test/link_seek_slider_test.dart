import 'package:audio_service/audio_service.dart' show PlaybackState;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_phone_playback.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/mornye_player_slider.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

void main() {
  const song = TrackRef(
    title: 'Phone song',
    artist: 'Artist',
    fileId: 'phone-song',
    durationMs: 60000,
  );
  LinkPlayerState at(int seconds, {int updatedMs = 0}) => LinkPlayerState(
    track: song,
    playing: true,
    positionMs: seconds * 1000,
    durationMs: 60000,
    updatedMs: updatedMs,
    queue: const [song],
    index: 0,
  );

  for (final mornye in [false, true]) {
    testWidgets(
      'phone seek never returns to the old desktop slider position ($mornye)',
      (tester) async {
        var nowMs = 0;
        final playback = LinkPhonePlayback(
          name: 'Phone',
          send: (_) async => true,
          resolve: (_) async => null,
          playHere: (_, _) async {},
          enqueueHere: (_, _) async {},
          resolveArtwork: (source) async => source,
          nowMs: () => nowMs,
        );
        final preview = PlaybackSeekPreview();
        final states = <PlaybackState>[];
        final subscription = playback.playbackStates.listen(states.add);
        addTearDown(subscription.cancel);
        addTearDown(() {
          playback.dispose();
          preview.dispose();
        });
        playback.show(at(34));
        await tester.pumpWidget(
          MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            home: Scaffold(
              body: StreamBuilder<PlaybackState>(
                stream: playback.playbackStates,
                builder: (context, state) => Column(
                  children: [
                    Text(
                      '${state.data?.updatePosition.inSeconds ?? 0}',
                      key: const ValueKey('elapsed'),
                    ),
                    PlaybackSeekSlider(
                      position: state.data?.updatePosition ?? Duration.zero,
                      duration: const Duration(seconds: 60),
                      preview: preview,
                      onSeek: playback.seek,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (mornye) {
          final slider = tester.widget<MornyePlayerSlider>(
            find.byType(MornyePlayerSlider),
          );
          slider.onChangeStart!(38000);
          slider.onChanged(38000);
          slider.onChangeEnd!(38000);
        } else {
          final slider = tester.widget<Slider>(find.byType(Slider));
          slider.onChangeStart!(38000);
          slider.onChanged!(38000);
          slider.onChangeEnd!(38000);
        }
        await tester.pump();
        playback.show(at(34));
        nowMs = 1000;
        await tester.pump(const Duration(seconds: 1));
        final pending = states.last;
        expect(pending.playing, isTrue);
        expect(pending.speed, 0);
        expect(preview.value, const Duration(seconds: 38));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
          '38',
        );
        expect(
          mornye
              ? tester
                    .widget<MornyePlayerSlider>(find.byType(MornyePlayerSlider))
                    .value
              : tester.widget<Slider>(find.byType(Slider)).value,
          38000,
        );
        playback.show(at(38, updatedMs: nowMs));
        await tester.pumpAndSettle();
        expect(preview.value, isNull);
        expect(states.last.speed, 1);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
          '38',
        );
        playback.show(null);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
