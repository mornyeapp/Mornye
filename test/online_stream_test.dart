import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/online_stream_settings.dart';
import 'package:mornye/controllers/play_online.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('full online audio stream validation', () {
    test('accepts a complete secure stream', () {
      expect(
        isFullOnlineStream({
          'success': true,
          'full_track': true,
          'url': 'https://cdn.example.net/audio.flac',
          'bit_depth': 24,
          'sample_rate': 96000,
        }),
        isTrue,
      );
    });

    test('rejects previews, downloads without URLs, and encrypted streams', () {
      expect(
        isFullOnlineStream({
          'success': true,
          'url': 'https://cdn.example.net/preview.mp3',
        }),
        isFalse,
      );
      expect(
        isFullOnlineStream({
          'success': true,
          'full_track': true,
          'url': 'http://cdn.example.net/audio.flac',
        }),
        isFalse,
      );
      expect(
        isFullOnlineStream({
          'success': true,
          'full_track': true,
          'encrypted': true,
          'url': 'https://cdn.example.net/audio.flac',
        }),
        isFalse,
      );
      expect(
        isFullOnlineStream({
          'success': true,
          'full_track': true,
          'requires_headers': true,
          'url': 'https://cdn.example.net/audio.flac',
        }),
        isFalse,
      );
    });
  });

  test(
    'highest online FLAC quality is selected by default and persists',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(await OnlineStreamSettings.current(), OnlineStreamSettings.best);
      await OnlineStreamSettings.save('LOSSLESS');
      expect(await OnlineStreamSettings.current(), 'LOSSLESS');
    },
  );
}
