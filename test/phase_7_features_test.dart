import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/services/autoeq_database.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 7: Lyrics from Description Extraction', () {
    test('extractLyricsFromDescription extracts timestamped LRC from description', () {
      const description = '''
Uploaded by Artist Official.
Check out our tour dates at example.com!

[00:10.50]First line of the song
[00:15.20]Second line of the song
[00:20.00]Third line of the song

Follow us on Instagram: @artist
''';

      final extracted = extractLyricsFromDescription(description);
      expect(extracted, contains('[00:10.50]First line of the song'));
      expect(extracted, contains('[00:15.20]Second line of the song'));
      expect(extracted, contains('[00:20.00]Third line of the song'));
      expect(extracted.contains('Check out our tour dates'), isFalse);
      expect(extracted.contains('Follow us on Instagram'), isFalse);
    });

    test('extractLyricsFromDescription extracts lyrics from section header', () {
      const description = '''
Produced by Metro Boomin
Recorded in Los Angeles, CA

Lyrics:
I hear the sound of the rain
Falling down on my window pane
Every time you call my name
Nothing ever stays the same

Connect with us:
Instagram: https://instagram.com/artist
''';

      final extracted = extractLyricsFromDescription(description);
      expect(extracted, contains('I hear the sound of the rain'));
      expect(extracted, contains('Falling down on my window pane'));
      expect(extracted, contains('Nothing ever stays the same'));
      expect(extracted.contains('Produced by Metro Boomin'), isFalse);
      expect(extracted.contains('Connect with us:'), isFalse);
      expect(extracted.contains('https://instagram.com'), isFalse);
    });

    test('extractLyricsFromDescription extracts plain verse lyrics', () {
      const description = '''
In the middle of the night
When the stars are shining bright
I can see a distant light
Guiding me through the fight
''';

      final extracted = extractLyricsFromDescription(description);
      expect(extracted, contains('In the middle of the night'));
      expect(extracted, contains('Guiding me through the fight'));
    });

    test('PlayerMetadataController falls back to description when lyrics are empty', () async {
      final controller = PlayerMetadataController(
        readMetadata: (_) async => {
          'title': 'Test Song',
          'artist': 'Test Artist',
          'description': '''
Lyrics:
[00:05.00]Line one of song
[00:10.00]Line two of song
[00:15.00]Line three of song
''',
        },
      );

      final item = MediaItem(
        id: '123',
        title: 'Test Song',
        artist: 'Test Artist',
        extras: {'source': '/path/to/test.flac'},
      );

      await controller.load(item);

      expect(controller.lyrics.isEmpty, isFalse);
      expect(controller.lyrics.lines.length, equals(3));
      expect(controller.lyrics.lines[0].text, equals('Line one of song'));
      expect(controller.lyrics.lines[1].text, equals('Line two of song'));
      expect(controller.lyrics.lines[2].text, equals('Line three of song'));
    });
  });

  group('Phase 7: AutoEq Database & Wavelet Parser', () {
    test('AutoEqDatabase contains popular headphone profiles', () {
      expect(AutoEqDatabase.profiles.length, greaterThan(50));

      final airpods = AutoEqDatabase.search('AirPods');
      expect(airpods.length, greaterThanOrEqualTo(4));
      expect(airpods.any((p) => p.model.contains('AirPods Pro 2')), isTrue);

      final sony = AutoEqDatabase.search('Sony');
      expect(sony.any((p) => p.model.contains('WH-1000XM4')), isTrue);
      expect(sony.any((p) => p.model.contains('WH-1000XM5')), isTrue);

      final senn = AutoEqDatabase.search('HD 600');
      expect(senn.isNotEmpty, isTrue);
      expect(senn.first.brand, equals('Sennheiser'));

      final galaxy = AutoEqDatabase.search('Galaxy Buds');
      expect(galaxy.isNotEmpty, isTrue);
      expect(galaxy.any((p) => p.model.contains('Buds 2 Pro')), isTrue);
    });

    test('parseWaveletGraphicEq parses GraphicEQ format and interpolates 10 bands', () {
      const sampleWavelet = '''
GraphicEQ: 20 0.0; 25 1.0; 31.5 2.0; 63 3.0; 125 1.5; 250 0.5; 500 -1.0; 1000 -0.5; 2000 1.0; 4000 2.5; 8000 1.0; 16000 0.0; 20000 -1.0
''';

      final profile = AutoEqDatabase.parseWaveletGraphicEq('MyCustomHeadphones.txt', sampleWavelet);
      expect(profile, isNotNull);
      expect(profile!.model, equals('MyCustomHeadphones'));
      expect(profile.gains.length, equals(10));
      // Preamp should protect against maximum gain
      expect(profile.preamp, lessThan(0.0));

      final preset = profile.toEqualizerPreset();
      expect(preset.name, equals('Custom MyCustomHeadphones'));
      expect(preset.settings.gains.length, equals(10));
      expect(preset.settings.enabled, isTrue);
    });
  });
}
