import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_ios_now_playing.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/remote_playback.dart';

class _Remote implements RemotePlayback {
  final items = StreamController<MediaItem?>.broadcast(sync: true);
  final states = StreamController<PlaybackState>.broadcast(sync: true);
  final volume = StreamController<double>.broadcast(sync: true);

  @override
  Stream<MediaItem?> get mediaItems => items.stream;
  @override
  Stream<PlaybackState> get playbackStates => states.stream;
  @override
  Stream<double> get volumes => volume.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await items.close();
    await states.close();
    await volume.close();
  }
}

class _Native {
  bool supported = true;
  Completer<void>? configure;
  Completer<void>? update;
  final calls = <({String method, Map<String, Object?>? arguments})>[];

  Future<Object?> invoke(String method, Map<String, Object?>? arguments) async {
    calls.add((method: method, arguments: arguments));
    if (method == 'supported') return supported;
    if (method == 'configure') await configure?.future;
    if (method == 'update') await update?.future;
    return null;
  }

  List<Map<String, Object?>> get snapshots => [
    for (final call in calls)
      if (call.method == 'update')
        call.arguments!['state']! as Map<String, Object?>,
  ];
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const server = LinkServerRecord(
    serverId: 'desktop',
    name: 'Studio',
    connectionId: 'connection',
    address: 'https://example.test:3939',
    fingerprint:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );
  const item = MediaItem(
    id: 'song',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 3),
  );
  final timestamp = DateTime.utc(2026, 10, 30);
  PlaybackState state(int seconds, {bool playing = true, int? at}) =>
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: Duration(seconds: seconds),
        updateTime: timestamp.add(Duration(seconds: at ?? seconds)),
      );
  late _Remote remote;
  late _Native native;
  late IosLinkNowPlaying binding;
  late int credentialsRead;

  setUp(() {
    remote = _Remote();
    native = _Native();
    credentialsRead = 0;
    binding = IosLinkNowPlaying(
      remote: remote,
      server: server,
      apiKey: () async {
        credentialsRead++;
        return 'pairing-secret';
      },
      track: () => const TrackRef(
        title: 'Song',
        artist: 'Artist',
        songId: 'song',
        serverId: 'desktop',
      ),
      invoke: native.invoke,
    );
  });

  tearDown(() async {
    binding.dispose();
    await _flush();
    await remote.close();
  });

  test(
    'unsupported native builds do not read or publish pairing credentials',
    () async {
      native.supported = false;
      binding.start();
      remote.items.add(item);
      remote.states.add(state(0));
      await _flush();
      expect(credentialsRead, 0);
      expect(native.calls.map((call) => call.method), ['supported']);
    },
  );

  test(
    'remote metadata reaches iOS without credentials in session attributes',
    () async {
      binding.start();
      remote.items.add(item);
      remote.states.add(state(34));
      remote.volume.add(0.4);
      await _flush();
      expect(credentialsRead, 1);
      expect(native.snapshots.single, containsPair('title', 'Song'));
      expect(native.snapshots.single, containsPair('trackId', 'song'));
      // The extension loads this desktop song's cover from the computer.
      expect(native.snapshots.single, containsPair('songId', 'song'));
      expect(native.snapshots.single, containsPair('duration', 180.0));
      expect(native.snapshots.single, containsPair('position', 34.0));
      expect(native.snapshots.single, containsPair('volume', 0.4));
      expect(jsonEncode(native.snapshots), isNot(contains('pairing-secret')));
      expect(
        native.calls.singleWhere((c) => c.method == 'configure').arguments,
        containsPair('apiKey', 'pairing-secret'),
      );
    },
  );

  test(
    'position ticks extrapolate but a seek or pause publishes immediately',
    () async {
      binding.start();
      remote.items.add(item);
      remote.states.add(state(34));
      await _flush();
      remote.states.add(state(35));
      await _flush();
      expect(native.snapshots.length, 1);
      remote.states.add(state(38, at: 35));
      await _flush();
      expect(native.snapshots.last['position'], 38.0);
      remote.states.add(state(38, at: 35, playing: false));
      await _flush();
      expect(native.snapshots.last['playing'], false);
      expect(native.snapshots.length, 3);
    },
  );

  test(
    'a missing remote track clears the card instead of retaining local media',
    () async {
      binding.start();
      remote.items.add(item);
      remote.states.add(state(34));
      await _flush();
      remote.items.add(null);
      await _flush();
      expect(native.snapshots.last['trackId'], '');
      expect(native.snapshots.last['title'], '');
    },
  );

  test('a slow native update keeps only the latest pending state', () async {
    native.update = Completer<void>();
    binding.start();
    remote.items.add(item);
    remote.states.add(state(34));
    await _flush();
    for (var i = 0; i < 10; i++) {
      remote.states.add(state(35 + i));
      remote.volume.add(i / 10);
      await _flush();
    }
    remote.states.add(state(45, playing: false));
    await _flush();
    expect(native.snapshots.length, 1);
    native.update!.complete();
    await _flush();
    expect(native.snapshots.length, 2);
    expect(native.snapshots.last['position'], 45.0);
    expect(native.snapshots.last['playing'], false);
    expect(native.snapshots.last['volume'], 0.9);
  });

  test(
    'disposal during configuration ends that binding without publishing',
    () async {
      native.configure = Completer<void>();
      binding.start();
      remote.items.add(item);
      remote.states.add(state(0));
      await _flush();
      binding.dispose();
      native.configure!.complete();
      await _flush();
      expect(native.snapshots, isEmpty);
      final configured = native.calls.singleWhere(
        (c) => c.method == 'configure',
      );
      final ended = native.calls.singleWhere((c) => c.method == 'end');
      expect(ended.arguments!['binding'], configured.arguments!['binding']);
    },
  );

  test('returning to local playback ends the remote session once', () async {
    binding.start();
    remote.items.add(item);
    remote.states.add(state(0));
    await _flush();
    binding.dispose();
    binding.dispose();
    remote.states.add(state(1));
    await _flush();
    expect(native.calls.where((c) => c.method == 'end').length, 1);
    expect(native.snapshots.length, 1);
  });
}
