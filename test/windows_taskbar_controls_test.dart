import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/windows_taskbar_controls.dart';

class _Callbacks implements AudioHandlerCallbacks {
  final requests = <Object>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    requests.add(invocation.positionalArguments.single as Object);
    return Future<void>.value();
  }
}

PlaybackStateMessage _state({
  bool playing = true,
  bool skip = true,
  int position = 0,
}) => PlaybackStateMessage(
  processingState: AudioProcessingStateMessage.ready,
  playing: playing,
  updatePosition: Duration(seconds: position),
  controls: [
    MediaControlMessage(
      androidIcon: 'unused',
      label: playing ? 'Jeda' : 'Putar',
      action: playing ? MediaActionMessage.pause : MediaActionMessage.play,
    ),
    if (skip) ...[
      const MediaControlMessage(
        androidIcon: 'unused',
        label: 'Sebelumnya',
        action: MediaActionMessage.skipToPrevious,
      ),
      const MediaControlMessage(
        androidIcon: 'unused',
        label: 'Berikutnya',
        action: MediaActionMessage.skipToNext,
      ),
    ],
  ],
);

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('test/taskbar');
  late WindowsTaskbarControls toolbar;
  late _Callbacks callbacks;
  late List<Map<Object?, Object?>> updates;
  Completer<void>? pending;
  bool reject = false;

  Future<void> press(String action) => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('button', action)),
    (_) {},
  );

  setUp(() {
    updates = [];
    pending = null;
    reject = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'update');
      if (reject) throw PlatformException(code: 'unavailable');
      updates.add(call.arguments as Map<Object?, Object?>);
      await pending?.future;
      return null;
    });
    toolbar = WindowsTaskbarControls(channel: channel)
      ..callbacks = callbacks = _Callbacks()
      ..initialize();
  });
  tearDown(() async {
    await toolbar.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('playback and localized labels reach the native toolbar', () async {
    await toolbar.update(_state());
    expect(updates.single, {
      'visible': true,
      'playing': true,
      'toggle': true,
      'previous': true,
      'next': true,
      'toggleLabel': 'Jeda',
      'previousLabel': 'Sebelumnya',
      'nextLabel': 'Berikutnya',
    });
    await toolbar.update(_state(playing: false));
    expect(updates.last['playing'], isFalse);
    expect(updates.last['toggleLabel'], 'Putar');
    await toolbar.stop();
    expect(updates.last['visible'], isFalse);
  });

  test('thumbnail clicks use the same playback handler', () async {
    await toolbar.update(_state());
    await press('pause');
    await press('previous');
    await press('next');
    await toolbar.update(_state(playing: false));
    await press('play');
    expect(callbacks.requests.map((request) => request.runtimeType), [
      PauseRequest,
      SkipToPreviousRequest,
      SkipToNextRequest,
      PlayRequest,
    ]);
  });

  test('unavailable and stopped controls ignore stale clicks', () async {
    await toolbar.update(_state(skip: false));
    expect(updates.last['next'], isFalse);
    expect(updates.last['previous'], isFalse);
    await press('previous');
    await press('next');
    await press('unknown');
    await toolbar.stop();
    await press('pause');
    expect(callbacks.requests, isEmpty);
  });

  test('position ticks do not republish unchanged buttons', () async {
    for (var i = 0; i < 20; i++) {
      await toolbar.update(_state(position: i));
    }
    expect(updates, hasLength(1));
  });

  test('pending updates finish with the latest state', () async {
    pending = Completer<void>();
    final playing = toolbar.update(_state());
    await Future<void>.delayed(Duration.zero);
    final paused = toolbar.update(_state(playing: false));
    final stopped = toolbar.stop();
    pending!.complete();
    await Future.wait([playing, paused, stopped]);
    expect(updates, hasLength(2));
    expect(updates.last['visible'], isFalse);
  });

  test(
    'a failed native update is retried without losing playback state',
    () async {
      reject = true;
      await toolbar.update(_state());
      reject = false;
      await toolbar.update(_state());
      expect(updates, hasLength(1));
      await press('pause');
      expect(callbacks.requests.single, isA<PauseRequest>());
    },
  );
}
