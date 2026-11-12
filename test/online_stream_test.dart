import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
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

  group('online signed-session verification', () {
    test('VERIFY_REQUIRED starts grant flow and retries once', () async {
      var attempts = 0;
      var verifications = 0;
      final result = await runExtensionOperationWithVerificationRetry<
          Map<String, dynamic>>(
        extensionId: 'qobuz-web',
        browserMode: 'external_first',
        verify: () async {
          verifications++;
          return true;
        },
        operation: () async {
          attempts++;
          if (attempts == 1) {
            throw const OnlineStreamVerificationRequired();
          }
          return {'success': true, 'full_track': true};
        },
      );
      expect(result['success'], isTrue);
      expect(verifications, 1);
      expect(attempts, 2);
    });

    test('unverified session never retries signed operation', () async {
      var attempts = 0;
      await expectLater(
        runExtensionOperationWithVerificationRetry<Map<String, dynamic>>(
          extensionId: 'qobuz-web',
          browserMode: 'external_first',
          verify: () async => false,
          operation: () async {
            attempts++;
            throw const OnlineStreamVerificationRequired();
          },
        ),
        throwsA(isA<OnlineStreamVerificationRequired>()),
      );
      expect(attempts, 1);
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
