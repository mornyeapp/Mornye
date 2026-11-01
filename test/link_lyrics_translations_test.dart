import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_lyrics_translations.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';
import 'package:mornye/services/lyrics_translation_sharing.dart';

SharedLyricsTranslation update({int version = 1}) => SharedLyricsTranslation(
  sourceHash: List.filled(64, 'a').join(),
  language: 'id',
  updatedMs: version,
  result: LyricsTranslationResult(
    ['Terjemahan $version'],
    romanizations: const ['Reading'],
    alignments: [
      [LyricsTranslationChunk('Terjemahan $version', 0)],
    ],
  ),
);

Future<void> flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late LyricsTranslationSharing desktop;
  late LyricsTranslationSharing phone;
  late LinkLyricsTranslations host;
  late LinkLyricsTranslations client;
  late List<Map<String, dynamic>> messages;

  setUp(() {
    desktop = LyricsTranslationSharing();
    phone = LyricsTranslationSharing();
    messages = [];
    host = LinkLyricsTranslations(
      sharing: desktop,
      send: (message, _) {
        messages.add(message);
        client.handle(message);
      },
    )..start();
    client = LinkLyricsTranslations(
      sharing: phone,
      send: (message, _) {
        messages.add(message);
        host.handle(message, deviceId: 'phone');
      },
    )..start();
  });
  tearDown(() {
    host.dispose();
    client.dispose();
    desktop.dispose();
    phone.dispose();
  });

  test(
    'AI translations and romanizations arrive in both directions without echoes',
    () async {
      desktop.publish(update());
      await flush();
      expect(phone.receivedFor(update().sourceHash)?.result.romanizations, [
        'Reading',
      ]);
      expect(
        phone
            .receivedFor(update().sourceHash)
            ?.result
            .alignments
            .single
            .single
            .source,
        0,
      );
      expect(messages, hasLength(1));
      phone.publish(update(version: 2));
      await flush();
      expect(desktop.receivedFor(update().sourceHash)?.result.translations, [
        'Terjemahan 2',
      ]);
      expect(
        desktop.receivedFor(update().sourceHash)?.result.wordSynced,
        isTrue,
      );
      expect(messages, hasLength(2));
    },
  );

  test('opening lyrics requests a completed result from the peer', () async {
    host.dispose();
    desktop.publish(update());
    await flush();
    host = LinkLyricsTranslations(
      sharing: desktop,
      send: (message, _) {
        messages.add(message);
        client.handle(message);
      },
    )..start();
    phone.request(update().sourceHash);
    await flush();
    expect(messages.first['type'], LinkMessageTypes.lyricsTranslationRequest);
    expect(phone.receivedFor(update().sourceHash)?.result.translations, [
      'Terjemahan 1',
    ]);
  });

  test('reconnect recovers a translation made while disconnected', () async {
    host.dispose();
    phone.request(update().sourceHash);
    desktop.publish(update(version: 3));
    await flush();
    host = LinkLyricsTranslations(
      sharing: desktop,
      send: (message, _) {
        client.handle(message);
      },
    )..start();
    client.connected();
    await flush();
    expect(phone.receivedFor(update().sourceHash)?.result.translations, [
      'Terjemahan 3',
    ]);
  });

  test('late older replies cannot overwrite a newer translation', () async {
    phone.receive(update(version: 2));
    expect(phone.receive(update()), isFalse);
    expect(phone.lookup(update().sourceHash)?.updatedMs, 2);
    expect(phone.receive(update(version: 2)), isFalse);
    await flush();
    expect(messages, isEmpty);
  });

  test('malformed and oversized payloads are ignored', () {
    for (final payload in <Map<String, dynamic>>[
      {...update().toJson(), 'sourceHash': 'other'},
      {
        ...update().toJson(),
        'translations': [42],
      },
      {
        ...update().toJson(),
        'romanizations': ['a', 'b'],
      },
      {
        ...update().toJson(),
        'translations': List.filled(100, List.filled(2000, '字').join()),
        'romanizations': <String?>[],
      },
    ]) {
      expect(SharedLyricsTranslation.fromJson(payload), isNull);
      expect(
        client.handle({
          'type': LinkMessageTypes.lyricsTranslation,
          'translation': payload,
        }),
        isTrue,
      );
    }
    expect(phone.lookup(update().sourceHash), isNull);
  });
}
