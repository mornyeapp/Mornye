import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Headset & Remote Settings Tests', () {
    test('Headset settings have correct defaults', () {
      const settings = AppSettings();
      expect(settings.headsetTimeoutMs, defaultHeadsetTimeoutMs);
      expect(settings.headsetTimeoutMs, 350);
      expect(settings.headsetSingleClickAction, 'play_pause');
      expect(settings.headsetDoubleClickAction, 'next');
      expect(settings.headsetTripleClickAction, 'previous');
      expect(settings.headsetVibrateOnClick, true);
    });

    test('Headset timeout clamps between 200ms and 600ms', () {
      expect(headsetTimeoutMsFromJson(100), minHeadsetTimeoutMs);
      expect(headsetTimeoutMsFromJson(199), minHeadsetTimeoutMs);
      expect(headsetTimeoutMsFromJson(200), 200);
      expect(headsetTimeoutMsFromJson(400), 400);
      expect(headsetTimeoutMsFromJson(600), 600);
      expect(headsetTimeoutMsFromJson(601), maxHeadsetTimeoutMs);
      expect(headsetTimeoutMsFromJson(1000), maxHeadsetTimeoutMs);
      expect(headsetTimeoutMsFromJson(null), defaultHeadsetTimeoutMs);
      expect(headsetTimeoutMsFromJson('invalid'), defaultHeadsetTimeoutMs);
    });

    test('Headset button actions validate and fallback safely', () {
      expect(headsetSingleClickActionFromJson('play_pause'), 'play_pause');
      expect(headsetSingleClickActionFromJson('next'), 'next');
      expect(headsetSingleClickActionFromJson('previous'), 'previous');
      expect(headsetSingleClickActionFromJson('none'), 'none');
      expect(headsetSingleClickActionFromJson('invalid_action'), 'play_pause');
      expect(headsetSingleClickActionFromJson(null), 'play_pause');

      expect(headsetDoubleClickActionFromJson('next'), 'next');
      expect(headsetDoubleClickActionFromJson('invalid'), 'next');

      expect(headsetTripleClickActionFromJson('previous'), 'previous');
      expect(headsetTripleClickActionFromJson('invalid'), 'previous');
    });

    test('Headset settings serialize and deserialize correctly', () {
      final initial = const AppSettings().copyWith(
        headsetTimeoutMs: 450,
        headsetSingleClickAction: 'none',
        headsetDoubleClickAction: 'play_pause',
        headsetTripleClickAction: 'next',
        headsetVibrateOnClick: false,
      );

      final json = initial.toJson();
      expect(json['headsetTimeoutMs'], 450);
      expect(json['headsetSingleClickAction'], 'none');
      expect(json['headsetDoubleClickAction'], 'play_pause');
      expect(json['headsetTripleClickAction'], 'next');
      expect(json['headsetVibrateOnClick'], false);

      final restored = AppSettings.fromJson(json);
      expect(restored.headsetTimeoutMs, 450);
      expect(restored.headsetSingleClickAction, 'none');
      expect(restored.headsetDoubleClickAction, 'play_pause');
      expect(restored.headsetTripleClickAction, 'next');
      expect(restored.headsetVibrateOnClick, false);
    });

    test('SettingsNotifier updates headset settings properly', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      expect(container.read(settingsProvider).headsetTimeoutMs, 350);

      notifier.setHeadsetTimeoutMs(500);
      expect(container.read(settingsProvider).headsetTimeoutMs, 500);

      notifier.setHeadsetTimeoutMs(100); // clamped to 200
      expect(container.read(settingsProvider).headsetTimeoutMs, 200);

      notifier.setHeadsetTimeoutMs(800); // clamped to 600
      expect(container.read(settingsProvider).headsetTimeoutMs, 600);

      notifier.setHeadsetSingleClickAction('next');
      expect(container.read(settingsProvider).headsetSingleClickAction, 'next');

      notifier.setHeadsetSingleClickAction('invalid'); // ignored
      expect(container.read(settingsProvider).headsetSingleClickAction, 'next');

      notifier.setHeadsetDoubleClickAction('previous');
      expect(container.read(settingsProvider).headsetDoubleClickAction, 'previous');

      notifier.setHeadsetTripleClickAction('none');
      expect(container.read(settingsProvider).headsetTripleClickAction, 'none');

      notifier.setHeadsetVibrateOnClick(false);
      expect(container.read(settingsProvider).headsetVibrateOnClick, false);
    });
  });
}
