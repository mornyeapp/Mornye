import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/discord_presence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/discord');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  MediaItem track(String title, {String? artwork}) => MediaItem(
    id: '/private/music/$title.flac',
    title: title,
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 4),
    artUri: artwork == null ? null : Uri.parse(artwork),
    extras: const {'source': 'content://private/tree/music'},
  );

  PlaybackState playing(DateTime now, {int position = 20, double speed = 1}) =>
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: Duration(seconds: position),
        updateTime: now,
        speed: speed,
      );

  test('old settings default to private and opt-in survives round trip', () {
    expect(AppSettings.fromJson({}).discordRichPresenceEnabled, isFalse);
    final settings = const AppSettings().copyWith(
      discordRichPresenceEnabled: true,
    );
    expect(
      AppSettings.fromJson(settings.toJson()).discordRichPresenceEnabled,
      isTrue,
    );
  });

  test('payload uses seconds, extrapolates progress and omits local data', () {
    final now = DateTime.utc(2026, 10, 2, 12);
    final payload = discordPresencePayload(
      track('Title', artwork: 'file:///private/cover.jpg'),
      playing(now.subtract(const Duration(seconds: 5))),
      now,
    )!;
    expect(payload['start'], now.millisecondsSinceEpoch ~/ 1000 - 25);
    expect(payload['end'], now.millisecondsSinceEpoch ~/ 1000 + 215);
    expect(payload['state'], 'Artist');
    expect(payload.containsKey('album'), isFalse);
    expect(payload['artwork'], '');
    expect(payload.toString(), isNot(contains('/private')));
    expect(payload.toString(), isNot(contains('content://')));
    final fast = discordPresencePayload(
      track('Title'),
      playing(now, speed: 2),
      now,
    )!;
    expect(fast['end'], now.millisecondsSinceEpoch ~/ 1000 + 110);
  });

  test('only public HTTPS artwork is eligible; metadata handles Unicode', () {
    final now = DateTime.utc(2026);
    for (final uri in [
      'content://media/1',
      'http://example.com/cover.jpg',
      'https://user:secret@example.com/cover.jpg',
      'https://example.com/cover.jpg?token=private',
    ]) {
      expect(
        discordPresencePayload(
          track('Title', artwork: uri),
          playing(now),
          now,
        )!['artwork'],
        '',
      );
    }
    final payload = discordPresencePayload(
      track('🎵' * 150, artwork: 'https://example.com/cover.jpg'),
      playing(now),
      now,
    )!;
    expect((payload['title']! as String).runes.length, 128);
    expect(payload['artwork'], 'https://example.com/cover.jpg');
    expect(
      discordPresencePayload(track('Title'), PlaybackState(), now),
      isNull,
    );
  });

  testWidgets(
    'off makes no SDK calls; updates coalesce and pause cancels pending track',
    (tester) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'initialize' ? true : null;
      });
      final service = DiscordPresenceService(
        channel: channel,
        requiresLink: false,
        resolveArtwork: (_) async => null,
        now: tester.binding.clock.now,
      );
      final player = BaseAudioHandler();
      service.bind(player);
      player.mediaItem.add(track('First'));
      player.playbackState.add(playing(tester.binding.clock.now()));
      await tester.pump();
      expect(calls, isEmpty);
      await service.setEnabled(true);
      await tester.pump();
      expect(calls.where((c) => c.method == 'update'), hasLength(1));
      player.mediaItem.add(track('Second'));
      await tester.pump(const Duration(seconds: 3));
      player.mediaItem.add(track('Latest'));
      await tester.pump(const Duration(seconds: 12));
      final updates = calls.where((c) => c.method == 'update').toList();
      expect(updates, hasLength(2));
      expect((updates.last.arguments as Map)['title'], 'Latest');
      player.mediaItem.add(track('Must not send'));
      player.playbackState.add(PlaybackState());
      await tester.pump();
      expect(calls.last.method, 'clear');
      await tester.pump(const Duration(seconds: 30));
      expect(calls.where((c) => c.method == 'update'), hasLength(2));
      await tester.runAsync(service.dispose);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );

  testWidgets('position ticks do not publish, but a seek updates timestamps', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? true : null;
    });
    final service = DiscordPresenceService(
      channel: channel,
      requiresLink: false,
      resolveArtwork: (_) async => null,
      now: tester.binding.clock.now,
    );
    final player = BaseAudioHandler();
    service.bind(player);
    player.mediaItem.add(track('First'));
    player.playbackState.add(playing(tester.binding.clock.now()));
    await service.setEnabled(true);
    await tester.pump();
    for (var i = 1; i <= 20; i++) {
      await tester.pump(const Duration(seconds: 1));
      player.playbackState.add(
        playing(tester.binding.clock.now(), position: 20 + i),
      );
      await tester.pump();
    }
    expect(calls.where((c) => c.method == 'update'), hasLength(1));
    player.playbackState.add(
      playing(tester.binding.clock.now(), position: 120),
    );
    await tester.pump();
    expect(calls.where((c) => c.method == 'update'), hasLength(2));
    await tester.runAsync(service.dispose);
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'late artwork follows the current track and stops when disabled',
    (tester) async {
      final calls = <MethodCall>[];
      final requests = <String, Completer<String?>>{};
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'initialize' ? true : null;
      });
      final service = DiscordPresenceService(
        channel: channel,
        requiresLink: false,
        now: tester.binding.clock.now,
        resolveArtwork: (item) =>
            (requests[item.title] = Completer<String?>()).future,
      );
      final player = BaseAudioHandler();
      service.bind(player);
      player.mediaItem.add(track('First'));
      player.playbackState.add(playing(tester.binding.clock.now()));
      await tester.pump();
      expect(requests, isEmpty);
      await service.setEnabled(true);
      await tester.pump();
      player.mediaItem.add(track('Second'));
      await tester.pump();
      requests['First']!.complete('https://example.com/first.jpg');
      requests['Second']!.complete('https://example.com/second.jpg');
      await tester.pump(const Duration(seconds: 15));
      final updates = calls.where((call) => call.method == 'update').toList();
      expect(updates, hasLength(2));
      expect((updates.last.arguments as Map)['title'], 'Second');
      expect(
        (updates.last.arguments as Map)['artwork'],
        'https://example.com/second.jpg',
      );
      expect(
        updates.any(
          (call) =>
              (call.arguments as Map)['artwork'] ==
              'https://example.com/first.jpg',
        ),
        isFalse,
      );

      player.mediaItem.add(track('Third'));
      await tester.pump();
      await service.setEnabled(false);
      requests['Third']!.complete('https://example.com/third.jpg');
      await tester.pump(const Duration(seconds: 30));
      expect(calls.where((call) => call.method == 'update'), hasLength(2));
      await tester.runAsync(service.dispose);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );

  testWidgets(
    'iOS never opens authorization automatically; disabling ignores a late login',
    (tester) async {
      final calls = <MethodCall>[];
      final login = Completer<Map<String, Object>>();
      final stored = <String?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'initialize') return true;
        if (call.method == 'authorize') return login.future;
        return null;
      });
      final service = DiscordPresenceService(
        channel: channel,
        requiresLink: true,
        resolveArtwork: (_) async => null,
        readRefreshToken: () async => null,
        writeRefreshToken: (token) async => stored.add(token),
      );
      await service.setEnabled(true);
      expect(service.status.value, DiscordPresenceStatus.linkRequired);
      expect(calls.map((c) => c.method), ['initialize']);
      final linking = service.link();
      await tester.pump();
      await service.setEnabled(false);
      login.complete({
        'access': 'test-access',
        'refresh': 'test-refresh',
        'expiresIn': 3600,
      });
      await linking;
      expect(stored, isEmpty);
      expect(calls.where((c) => c.method == 'connect'), isEmpty);
      expect(service.status.value, DiscordPresenceStatus.disabled);
      await tester.runAsync(service.dispose);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );

  testWidgets('SDK failure stays isolated from playback', (tester) async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'sdk_unavailable'),
    );
    final service = DiscordPresenceService(
      channel: channel,
      requiresLink: false,
      resolveArtwork: (_) async => null,
    );
    final player = BaseAudioHandler();
    service.bind(player);
    player.mediaItem.add(track('First'));
    player.playbackState.add(playing(DateTime.now()));
    await service.setEnabled(true);
    expect(service.status.value, DiscordPresenceStatus.sdkUnavailable);
    expect(player.playbackState.value.playing, isTrue);
    await tester.runAsync(service.dispose);
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('saved iOS account rotates refresh token and waits for ready', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final stored = <String?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return true;
      if (call.method == 'refresh') {
        expect((call.arguments as Map)['refresh'], 'previous-refresh');
        return {
          'access': 'temporary-access',
          'refresh': 'rotated-refresh',
          'expiresIn': 3600,
        };
      }
      return null;
    });
    final service = DiscordPresenceService(
      channel: channel,
      requiresLink: true,
      resolveArtwork: (_) async => null,
      readRefreshToken: () async => 'previous-refresh',
      writeRefreshToken: (token) async => stored.add(token),
      now: tester.binding.clock.now,
    );
    final player = BaseAudioHandler();
    service.bind(player);
    player.mediaItem.add(track('First'));
    player.playbackState.add(playing(tester.binding.clock.now()));
    await service.setEnabled(true);
    await tester.pump();
    expect(stored, ['rotated-refresh']);
    expect(calls.where((c) => c.method == 'authorize'), isEmpty);
    expect(calls.where((c) => c.method == 'update'), isEmpty);
    final handled = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('status', 'ready')),
      (_) => handled.complete(),
    );
    await tester.pump();
    await handled.future;
    expect(calls.where((c) => c.method == 'update'), hasLength(1));
    await service.forgetAccount();
    expect(stored, ['rotated-refresh', null]);
    expect(service.status.value, DiscordPresenceStatus.disabled);
    await tester.runAsync(service.dispose);
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('a start that found no activity is repeated when one appears', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    var hasActivity = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return hasActivity;
      return null;
    });
    final service = DiscordPresenceService(
      channel: channel,
      requiresLink: false,
      resolveArtwork: (_) async => null,
      now: tester.binding.clock.now,
    );
    final player = BaseAudioHandler();
    service.bind(player);
    player.mediaItem.add(track('First'));
    player.playbackState.add(playing(tester.binding.clock.now()));
    await service.setEnabled(true);
    expect(service.status.value, DiscordPresenceStatus.sdkUnavailable);
    hasActivity = true;
    final handled = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('status', 'available')),
      (_) => handled.complete(),
    );
    await tester.pump();
    await handled.future;
    await tester.pump();
    expect(calls.where((c) => c.method == 'initialize'), hasLength(2));
    expect(calls.where((c) => c.method == 'update'), hasLength(1));
    await tester.runAsync(service.dispose);
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('an offline refresh keeps the account and is repeated', (
    tester,
  ) async {
    final stored = <String?>[];
    var online = false;
    var rejected = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'refresh') {
        if (rejected) throw PlatformException(code: 'authorization_failed');
        if (!online) throw PlatformException(code: 'network');
        return {
          'access': 'temporary-access',
          'refresh': 'rotated-refresh',
          'expiresIn': 3600,
        };
      }
      return null;
    });
    final service = DiscordPresenceService(
      channel: channel,
      requiresLink: true,
      resolveArtwork: (_) async => null,
      readRefreshToken: () async => 'previous-refresh',
      writeRefreshToken: (token) async => stored.add(token),
    );
    await service.setEnabled(true);
    expect(service.status.value, DiscordPresenceStatus.unavailable);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(service.status.value, DiscordPresenceStatus.unavailable);
    expect(stored, isEmpty);
    online = true;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(stored, ['rotated-refresh']);
    expect(service.status.value, DiscordPresenceStatus.connecting);

    // A token Discord rejects still asks for the link again.
    rejected = true;
    await service.setEnabled(false);
    await service.setEnabled(true);
    expect(service.status.value, DiscordPresenceStatus.linkRequired);
    await tester.runAsync(service.dispose);
    messenger.setMockMethodCallHandler(channel, null);
  });
}
