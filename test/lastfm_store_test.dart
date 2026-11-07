import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lastfm/lastfm_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/lastfm_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'account session stays in secure storage, outside preferences and queue',
    () async {
      final store = LocalLastfmStore();
      await store.writeSession(lastfmTestSession);
      await store.write(
        enabled: true,
        nowPlaying: false,
        queue: [lastfmQueued(1)],
      );
      final restored = LocalLastfmStore();
      expect((await restored.readSession())?.key, lastfmTestSession.key);
      final state = await restored.read();
      expect(state.enabled, isTrue);
      expect(state.nowPlaying, isFalse);
      expect(state.queue.single.parameters, lastfmQueued(1).parameters);
      final preferences = await SharedPreferences.getInstance();
      for (final key in preferences.getKeys()) {
        expect(
          '${preferences.get(key)}',
          isNot(contains(lastfmTestSession.key)),
        );
      }
      await restored.writeSession(null);
      expect(await store.readSession(), isNull);
    },
  );

  test('a request waiting for approval survives in secure storage', () async {
    final store = LocalLastfmStore();
    expect(await store.readAuthorization(), isNull);
    final created = DateTime.utc(2026, 11, 7, 10);
    await store.writeAuthorization((token: 'request-token', created: created));
    final restored = await LocalLastfmStore().readAuthorization();
    expect(restored?.token, 'request-token');
    expect(restored?.created, created);
    final preferences = await SharedPreferences.getInstance();
    for (final key in preferences.getKeys()) {
      expect('${preferences.get(key)}', isNot(contains('request-token')));
    }
    await store.writeAuthorization(null);
    expect(await store.readAuthorization(), isNull);
    FlutterSecureStorage.setMockInitialValues({
      'lastfm_authorization_v1': '{"token":"","created":1}',
    });
    expect(await LocalLastfmStore().readAuthorization(), isNull);
  });

  test(
    'new installations opt out and malformed state is not overwritten',
    () async {
      final store = LocalLastfmStore();
      expect((await store.read()).enabled, isFalse);
      expect(await store.readSession(), isNull);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('lastfm_scrobbles_v1', 'invalid');
      await expectLater(store.read(), throwsFormatException);
      expect(preferences.getString('lastfm_scrobbles_v1'), 'invalid');
    },
  );
}
