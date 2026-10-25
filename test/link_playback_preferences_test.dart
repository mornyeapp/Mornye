import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_playback_preferences.dart';
import 'package:mornye/services/link/link_protocol.dart';

void main() {
  late bool autoplay;
  late bool autoMix;
  late List<String> commands;
  late LinkPlaybackPreferencesSync sync;

  setUp(() {
    autoplay = false;
    autoMix = false;
    commands = [];
    sync = LinkPlaybackPreferencesSync(
      readAutoplay: () => autoplay,
      readAutoMix: () => autoMix,
      writeAutoplay: (value) {
        autoplay = value;
        unawaited(sync.updateLocal());
      },
      writeAutoMix: (value) {
        autoMix = value;
        unawaited(sync.updateLocal());
      },
      sendAutoplay: (value) async => commands.add('autoplay $value'),
      sendAutoMix: (value) async => commands.add('autoMix $value'),
    );
  });

  LinkPlayerState state({bool? autoplay, bool? autoMix}) =>
      LinkPlayerState(updatedMs: 1, autoplay: autoplay, autoMix: autoMix);

  test(
    'desktop changes update both preferences without echoing a command',
    () async {
      sync.updateRemote(state(autoplay: true, autoMix: true));
      await sync.updateLocal();
      expect(autoplay, isTrue);
      expect(autoMix, isTrue);
      expect(commands, isEmpty);
    },
  );

  test('phone changes are sent once to the playing desktop', () async {
    sync.updateRemote(state(autoplay: false, autoMix: false));
    autoplay = autoMix = true;
    await sync.updateLocal();
    await sync.updateLocal();
    expect(commands, ['autoplay true', 'autoMix true']);
    sync.updateRemote(state(autoplay: true, autoMix: true));
    await sync.updateLocal();
    expect(commands, hasLength(2));
  });

  test(
    'a failed command rollback restores the phone without a retry loop',
    () async {
      sync.updateRemote(state(autoplay: false, autoMix: false));
      autoplay = true;
      await sync.updateLocal();
      sync.updateRemote(state(autoplay: false, autoMix: false));
      await sync.updateLocal();
      expect(autoplay, isFalse);
      expect(commands, ['autoplay true']);
    },
  );

  test('older peers leave local preferences intact', () async {
    autoplay = autoMix = true;
    sync.updateRemote(state());
    await sync.updateLocal();
    expect(autoplay, isTrue);
    expect(autoMix, isTrue);
    expect(commands, isEmpty);
    sync.updateRemote(null);
    autoplay = false;
    await sync.updateLocal();
    expect(commands, isEmpty);
  });

  test('player state round-trips optional automation flags', () {
    final decoded = LinkPlayerState.fromJson(
      state(autoplay: true, autoMix: false).toJson(),
    )!;
    expect(decoded.autoplay, isTrue);
    expect(decoded.autoMix, isFalse);
    expect(LinkPlayerState.fromJson({'updatedMs': 1})!.autoplay, isNull);
  });
}
