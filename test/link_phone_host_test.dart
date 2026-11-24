import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_host_files.dart';
import 'package:mornye/services/link/desktop/link_phone_host_lifetime.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_desktop_fakes.dart';

class _Playing extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool playing) => state = playing;
}

final _playingProvider = NotifierProvider<_Playing, bool>(_Playing.new);

void main() {
  group('LinkPhoneHostLifetime', () {
    late List<(bool, String)> changes;
    late LinkPhoneHostLifetime lifetime;

    setUp(() {
      changes = [];
      lifetime = LinkPhoneHostLifetime(
        onChanged: (allowed, reason) => changes.add((allowed, reason)),
      );
    });

    tearDown(() => lifetime.dispose());

    testWidgets('allows while open, stops after the grace in the background', (
      tester,
    ) async {
      expect(lifetime.allowed, isTrue);
      lifetime.foreground = false;
      await tester.pump(const Duration(seconds: 9));
      expect(lifetime.allowed, isTrue);
      expect(changes, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(lifetime.allowed, isFalse);
      expect(changes, [
        (false, 'the app is in the background with nothing playing'),
      ]);

      lifetime.foreground = true;
      expect(lifetime.allowed, isTrue);
      expect(changes.last, (true, 'the app is open'));
    });

    testWidgets('a quick look at another app changes nothing', (tester) async {
      lifetime.foreground = false;
      await tester.pump(const Duration(seconds: 5));
      lifetime.foreground = true;
      await tester.pump(const Duration(seconds: 20));
      expect(lifetime.allowed, isTrue);
      expect(changes, isEmpty);
    });

    testWidgets('playing keeps it in the background until playback ends', (
      tester,
    ) async {
      lifetime.playing = true;
      lifetime.foreground = false;
      await tester.pump(const Duration(minutes: 5));
      expect(lifetime.allowed, isTrue);
      expect(lifetime.reason, 'the app plays in the background');

      lifetime.playing = false;
      await tester.pump(const Duration(seconds: 11));
      expect(lifetime.allowed, isFalse);

      lifetime.playing = true;
      expect(lifetime.allowed, isTrue);
      expect(changes.last, (true, 'the app plays in the background'));
    });

    testWidgets('starts disallowed in the background with nothing playing', (
      tester,
    ) async {
      final background = LinkPhoneHostLifetime(
        onChanged: (allowed, reason) => changes.add((allowed, reason)),
        foreground: false,
      );
      addTearDown(background.dispose);
      expect(background.allowed, isFalse);
      background.foreground = true;
      expect(background.allowed, isTrue);
      expect(changes.single.$1, isTrue);
    });
  });

  group('phone host', () {
    late FakeLinkBackend backend;
    late ProviderContainer container;
    late List<String> lent;
    late List<String> returned;

    setUp(() {
      debugDesktopPlatformOverride = false;
      backend = FakeLinkBackend()..catalogSongs = 1;
      lent = [];
      returned = [];
    });

    tearDown(() {
      debugDesktopPlatformOverride = null;
      // The binding outlives each test; the next one starts in front.
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
    });

    Future<void> flush(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
    }

    LinkDesktopHost host() => container.read(linkDesktopHostProvider.notifier);
    LinkDesktopHostState hostState() => container.read(linkDesktopHostProvider);

    Future<void> boot(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      String platform = 'android',
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      container = ProviderContainer(
        overrides: [
          ...linkHostOverrides(
            backend: backend,
            player: FakeLinkPlayer(),
            exporter: FakeLinkCatalogExporter(songs: [catalogSong('l:a')]),
          ),
          linkClientSupportedProvider.overrideWithValue(true),
          linkPhoneHostIdentityProvider.overrideWithValue((
            name: () async => 'Test phone',
            platform: platform,
          )),
          playbackPlayingProvider.overrideWith(
            (ref) => ref.watch(_playingProvider),
          ),
          linkHostFilesProvider.overrideWithValue(
            LinkHostFiles(
              open: (uri) async {
                lent.add(uri);
                return (path: '/proc/self/fd/9', token: 'token-${lent.length}');
              },
              close: (token) async => returned.add(token),
            ),
          ),
        ],
      );
      // The app listens to the host on phones; an unlistened provider would
      // pause its own listeners.
      container.listen(linkDesktopHostProvider, (_, _) {});
      await flush(tester);
    }

    Future<void> shutdown(WidgetTester tester) async {
      container.dispose();
      await tester.pump();
    }

    /// Walks the app through the lifecycle steps the platform reports.
    void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    void toBackground(WidgetTester tester) => lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);

    void toForeground(WidgetTester tester) => lifecycle(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);

    testWidgets('stays off by default and touches no server', (tester) async {
      await boot(tester);
      expect(hostState().loaded, isTrue);
      expect(hostState().enabled, isFalse);
      expect(hostState().name, 'Test phone');
      expect(backend.calls, isEmpty);
      await shutdown(tester);
    });

    testWidgets('a computer setting does not turn sharing on', (tester) async {
      await boot(tester, prefs: {linkDesktopEnabledKey: true});
      expect(hostState().enabled, isFalse);
      expect(backend.calls, isEmpty);
      await shutdown(tester);
    });

    testWidgets('sharing starts a host that announces a phone', (tester) async {
      await boot(tester);
      await host().setEnabled(true);
      await flush(tester);
      expect(hostState().running, isTrue);
      expect(backend.calls, contains('start:Test phone'));
      // A phone's server never outlives the app: nothing to adopt.
      expect(backend.calls, isNot(contains('status')));
      expect(backend.startPlatform, 'android');
      expect(backend.startFeatures, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(linkPhoneHostEnabledKey), isTrue);
      expect(prefs.getBool(linkDesktopEnabledKey), isNull);

      final router = container.read(linkHostRouterProvider);
      for (final op in [LinkOps.state, LinkOps.handoffPlay, LinkOps.resolve]) {
        expect(router.handles(op), isTrue, reason: op);
      }
      for (final op in [LinkOps.downloads, LinkOps.open, LinkOps.libraryJobs]) {
        expect(router.handles(op), isFalse, reason: op);
      }
      // The server borrows storage access songs through the app.
      const document = 'content://com.example.documents/document/a%3ASong.flac';
      final opened = await router.dispatch(
        const LinkRequest(
          requestId: '1',
          op: linkHostFileOpenOp,
          deviceId: '',
          args: {'uri': document, 'lease': '1'},
        ),
      );
      expect(opened, {'path': '/proc/self/fd/9'});
      expect(lent, [document]);

      await host().setEnabled(false);
      await flush(tester);
      expect(hostState().phase, LinkHostPhase.stopped);
      expect(backend.calls, contains('stop'));
      expect(prefs.getBool(linkPhoneHostEnabledKey), isFalse);
      expect(returned, ['token-1'], reason: 'its server is gone');
      await shutdown(tester);
    });

    testWidgets(
      'stops in the background with nothing playing, back on return',
      (tester) async {
        await boot(tester, prefs: {linkPhoneHostEnabledKey: true});
        expect(hostState().running, isTrue);
        backend.calls.clear();

        toBackground(tester);
        await tester.pump(const Duration(seconds: 5));
        await flush(tester);
        expect(hostState().running, isTrue);
        await tester.pump(const Duration(seconds: 6));
        await flush(tester);
        expect(hostState().phase, LinkHostPhase.stopped);
        expect(hostState().enabled, isTrue);
        expect(backend.calls, ['stop', 'devices']);

        toForeground(tester);
        await flush(tester);
        expect(hostState().running, isTrue);
        expect(backend.calls, contains('start:Test phone'));
        await shutdown(tester);
      },
    );

    testWidgets('keeps running in the background while playing', (
      tester,
    ) async {
      await boot(tester, prefs: {linkPhoneHostEnabledKey: true});
      container.read(_playingProvider.notifier).set(true);
      toBackground(tester);
      await tester.pump(const Duration(minutes: 1));
      await flush(tester);
      expect(hostState().running, isTrue);
      expect(backend.calls, isNot(contains('stop')));

      container.read(_playingProvider.notifier).set(false);
      await tester.pump(const Duration(seconds: 11));
      await flush(tester);
      expect(hostState().phase, LinkHostPhase.stopped);

      // Playing again from the lock screen brings it back.
      container.read(_playingProvider.notifier).set(true);
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
      expect(hostState().running, isTrue);
      toForeground(tester);
      await shutdown(tester);
    });

    testWidgets('an iPhone stops as soon as it goes silent in the background', (
      tester,
    ) async {
      await boot(
        tester,
        prefs: {linkPhoneHostEnabledKey: true},
        platform: 'ios',
      );
      expect(hostState().running, isTrue);
      expect(backend.startPlatform, 'ios');
      toBackground(tester);
      // Well inside the grace an Android phone would get.
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
      expect(hostState().phase, LinkHostPhase.stopped);
      toForeground(tester);
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
      expect(hostState().running, isTrue);
      await shutdown(tester);
    });

    testWidgets('turned off, the app lifecycle starts nothing', (tester) async {
      await boot(tester, prefs: {linkPhoneHostEnabledKey: true});
      await host().setEnabled(false);
      await flush(tester);
      backend.calls.clear();
      toBackground(tester);
      await tester.pump(const Duration(seconds: 11));
      toForeground(tester);
      await flush(tester);
      expect(backend.calls.where((call) => call.startsWith('start')), isEmpty);
      expect(hostState().running, isFalse);
      await shutdown(tester);
    });
  });
}
