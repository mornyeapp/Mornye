import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';

/// Test audio handler implementing the headset button debouncing and multi-tap logic.
class TestHeadsetButtonHandler extends BaseAudioHandler {
  TestHeadsetButtonHandler({AppSettings? settings})
      : settings = settings ?? const AppSettings();

  AppSettings settings;
  int headsetClickCount = 0;
  Timer? headsetClickTimer;
  final List<String> executedActions = [];
  int vibratedCount = 0;

  void cancelHeadsetTimer() {
    headsetClickTimer?.cancel();
    headsetClickTimer = null;
    headsetClickCount = 0;
  }

  Future<void> dispatchHeadsetAction(String action) async {
    executedActions.add(action);
    switch (action) {
      case 'play_pause':
        if (playbackState.value.playing) {
          await pause();
        } else {
          await play();
        }
        break;
      case 'next':
        await skipToNext();
        break;
      case 'previous':
        await skipToPrevious();
        break;
      case 'fast_forward':
        await fastForward();
        break;
      case 'rewind':
        await rewind();
        break;
      case 'none':
        break;
      default:
        if (playbackState.value.playing) {
          await pause();
        } else {
          await play();
        }
    }
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (settings.headsetVibrateOnClick) {
          vibratedCount++;
        }
        headsetClickCount++;
        headsetClickTimer?.cancel();

        // 3 Taps (Triple Press) -> immediately execute without waiting
        if (headsetClickCount >= 3) {
          final action = settings.headsetTripleClickAction;
          headsetClickCount = 0;
          headsetClickTimer?.cancel();
          headsetClickTimer = null;
          await dispatchHeadsetAction(action);
          return;
        }

        // 1 or 2 Taps: wait for detection timeout window
        final timeoutMs = settings.headsetTimeoutMs.clamp(
          minHeadsetTimeoutMs,
          maxHeadsetTimeoutMs,
        );
        headsetClickTimer = Timer(Duration(milliseconds: timeoutMs), () async {
          final count = headsetClickCount;
          headsetClickCount = 0;
          headsetClickTimer = null;
          if (count == 1) {
            await dispatchHeadsetAction(settings.headsetSingleClickAction);
          } else if (count == 2) {
            await dispatchHeadsetAction(settings.headsetDoubleClickAction);
          }
        });
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  Future<void> play() async {
    playbackState.add(playbackState.value.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> skipToNext() async {
    executedActions.add('skipped_to_next');
  }

  @override
  Future<void> skipToPrevious() async {
    executedActions.add('skipped_to_previous');
  }

  @override
  Future<void> fastForward() async {
    cancelHeadsetTimer();
    executedActions.add('fast_forwarded');
  }

  @override
  Future<void> rewind() async {
    cancelHeadsetTimer();
    executedActions.add('rewound');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Headset Button Multi-Tap Controller Tests', () {
    test('1 Tap executes Single Click action (play/pause toggle) after timeout', () async {
      final handler = TestHeadsetButtonHandler(
        settings: const AppSettings(
          headsetTimeoutMs: 250,
          headsetSingleClickAction: 'play_pause',
        ),
      );

      // Initially paused
      expect(handler.playbackState.value.playing, false);

      await handler.click(MediaButton.media);
      expect(handler.headsetClickCount, 1);
      // Not yet executed before timeout expires
      expect(handler.executedActions, isEmpty);
      expect(handler.vibratedCount, 1);

      // Wait past the timeout window
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(handler.executedActions, ['play_pause']);
      expect(handler.playbackState.value.playing, true);
      expect(handler.headsetClickCount, 0);

      // Second click should pause
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(handler.playbackState.value.playing, false);
      expect(handler.vibratedCount, 2);
    });

    test('2 Taps (Double Press) skips to next track within detection window', () async {
      final handler = TestHeadsetButtonHandler(
        settings: const AppSettings(
          headsetTimeoutMs: 300,
          headsetDoubleClickAction: 'next',
        ),
      );

      // Tap 1
      await handler.click(MediaButton.media);
      expect(handler.headsetClickCount, 1);

      // Delay less than timeout (e.g. 100ms)
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Tap 2
      await handler.click(MediaButton.media);
      expect(handler.headsetClickCount, 2);
      expect(handler.vibratedCount, 2);

      // Actions should not have executed yet
      expect(handler.executedActions, isEmpty);

      // Wait for timeout to expire
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(handler.executedActions, ['next', 'skipped_to_next']);
      expect(handler.headsetClickCount, 0);
    });

    test('3 Taps (Triple Press) immediately executes skip to previous without delay', () async {
      final handler = TestHeadsetButtonHandler(
        settings: const AppSettings(
          headsetTimeoutMs: 400,
          headsetTripleClickAction: 'previous',
        ),
      );

      // Tap 1
      await handler.click(MediaButton.media);
      // Tap 2
      await handler.click(MediaButton.media);
      // Tap 3
      await handler.click(MediaButton.media);

      // Triple tap fires immediately without waiting for timer
      expect(handler.executedActions, ['previous', 'skipped_to_previous']);
      expect(handler.headsetClickCount, 0);
      expect(handler.headsetClickTimer, isNull);
      expect(handler.vibratedCount, 3);
    });

    test('Long press cancels pending click timer and seeks properly', () async {
      final handler = TestHeadsetButtonHandler(
        settings: const AppSettings(headsetTimeoutMs: 350),
      );

      // Tap down
      await handler.click(MediaButton.media);
      expect(handler.headsetClickCount, 1);
      expect(handler.headsetClickTimer, isNotNull);

      // Long press triggers fastForward
      await handler.fastForward();

      expect(handler.headsetClickCount, 0);
      expect(handler.headsetClickTimer, isNull);
      expect(handler.executedActions, ['fast_forwarded']);

      // Wait to verify single tap does not fire after
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(handler.executedActions, ['fast_forwarded']);
    });

    test('Custom Action Remapping works for single, double, and triple tap', () async {
      final handler = TestHeadsetButtonHandler(
        settings: const AppSettings(
          headsetTimeoutMs: 200,
          headsetSingleClickAction: 'next',
          headsetDoubleClickAction: 'previous',
          headsetTripleClickAction: 'none',
        ),
      );

      // Single click should trigger next
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(handler.executedActions, ['next', 'skipped_to_next']);
      handler.executedActions.clear();

      // Double click should trigger previous
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(handler.executedActions, ['previous', 'skipped_to_previous']);
      handler.executedActions.clear();

      // Triple click should trigger none
      await handler.click(MediaButton.media);
      await handler.click(MediaButton.media);
      await handler.click(MediaButton.media);
      expect(handler.executedActions, ['none']);
    });

    test('Dedicated MediaButton.next and MediaButton.previous work directly', () async {
      final handler = TestHeadsetButtonHandler();

      await handler.click(MediaButton.next);
      expect(handler.executedActions, ['skipped_to_next']);

      await handler.click(MediaButton.previous);
      expect(handler.executedActions, ['skipped_to_next', 'skipped_to_previous']);
    });
  });
}
