import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';

Future<ui.Image> _plotImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 160, 80),
    Paint()..color = Colors.orange,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(160, 80);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('spectrogram export name', () {
    test('prefers the given name and strips characters files cannot hold', () {
      expect(
        audioSpectrogramExportBaseName(
          '/music/a.flac',
          exportName: 'Artist: A/B - Title?',
        ),
        'Artist_ A_B - Title_',
      );
    });

    test('falls back to the file name without its extension', () {
      expect(audioSpectrogramExportBaseName('/music/Song.flac'), 'Song');
      expect(
        audioSpectrogramExportBaseName(r'C:\Music\Song.flac', exportName: ' '),
        'Song',
      );
      expect(
        audioSpectrogramExportBaseName('smb://nas/share/Album/Song%201.m4a'),
        'Song 1',
      );
    });

    test('uses the document name of a content URI', () {
      expect(
        audioSpectrogramExportBaseName(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic/document/primary%3AMusic%2FAlbum%2FSong.flac',
        ),
        'Song',
      );
    });

    test('never returns an empty name', () {
      expect(audioSpectrogramExportBaseName('/music/'), 'audio');
      expect(audioSpectrogramExportBaseName('/music/...'), 'audio');
    });
  });

  test('renders the plot with axes and legend as a PNG', () async {
    final plot = await _plotImage();
    addTearDown(plot.dispose);

    final bytes = await renderAudioSpectrogramPng(
      image: plot,
      title: 'Artist - Title',
      sampleRate: 44100,
      duration: 200,
      details: const ['Sample Rate: 44100 Hz'],
    );

    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    addTearDown(frame.image.dispose);
    // 16 + 34 + 800 + 16 logical pixels across, at the default 2x scale.
    expect(frame.image.width, 1732);
    expect(frame.image.height, greaterThan(800 * 1.1));
  });
}
