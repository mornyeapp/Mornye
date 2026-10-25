import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/exclusive_output_deck.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/fake_mpv_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        final arguments = call.arguments;
        if (call.method == 'create' && arguments is Map) {
          messenger.setMockMethodCallHandler(
            MethodChannel(
              'xyz.luan/audioplayers/events/${arguments['playerId']}',
            ),
            (_) async => null,
          );
        }
        return null;
      });
    }
    MediaKitPlaybackDeck.debugEngineFactory = FakeMpvEngine.new;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    debugPlaybackEngineOverride = null;
    MediaKitPlaybackDeck.debugAvailableOverride = null;
    MediaKitPlaybackDeck.debugEngineFactory = null;
  });

  void select(TargetPlatform platform, {required bool desktop}) {
    debugDefaultTargetPlatformOverride = platform;
    debugDesktopPlatformOverride = desktop;
  }

  test('Windows and Linux play through media_kit', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      select(platform, desktop: true);
      expect(playbackEngine, PlaybackEngine.mediaKit, reason: '$platform');
    }
  });

  test('macOS and mobile keep audioplayers', () {
    select(TargetPlatform.macOS, desktop: true);
    expect(playbackEngine, PlaybackEngine.audioplayers);
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      select(platform, desktop: false);
      expect(playbackEngine, PlaybackEngine.audioplayers, reason: '$platform');
    }
  });

  test('tests can force an engine on any host', () {
    select(TargetPlatform.macOS, desktop: true);
    debugPlaybackEngineOverride = PlaybackEngine.mediaKit;
    expect(playbackEngine, PlaybackEngine.mediaKit);
  });

  test('the runtime creates the deck of the selected engine', () async {
    const dependencies = PlaybackDependencies();
    final created = <PlaybackDeck>[];
    MediaKitPlaybackDeck.debugAvailableOverride = true;
    try {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        select(platform, desktop: true);
        created
          ..add(dependencies.createDeck('main'))
          ..add(dependencies.createPreviewDeck('preview'));
        expect(
          created.reversed.take(2),
          everyElement(isA<MediaKitPlaybackDeck>()),
        );
      }
      // macOS plays through AVPlayer and switches to libmpv only for
      // exclusive output.
      select(TargetPlatform.macOS, desktop: true);
      created.add(dependencies.createDeck('main'));
      expect(created.last, isA<ExclusiveOutputDeck>());
      select(TargetPlatform.android, desktop: false);
      created
        ..add(dependencies.createDeck('main'))
        ..add(dependencies.createPreviewDeck('preview'));
      expect(
        created.reversed.take(2),
        everyElement(isA<AudioplayersPlaybackDeck>()),
      );
    } finally {
      for (final deck in created) {
        await deck.dispose();
      }
    }
  });

  test('without libmpv Windows and Linux fall back to audioplayers', () async {
    MediaKitPlaybackDeck.debugAvailableOverride = false;
    select(TargetPlatform.linux, desktop: true);
    final deck = const PlaybackDependencies().createDeck('main');
    expect(deck, isA<AudioplayersPlaybackDeck>());
    await deck.dispose();
  });
}
