import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';

void main() {
  group('bitrate display', () {
    test('uses metadata precision for fractional Opus kbps', () {
      expect(formatAudioAnalysisBitrate(238900), '238 kbps');
      expect(formatAudioAnalysisBitrate(239000), '239 kbps');
      expect(formatAudioAnalysisBitrate(320000), '320 kbps');
      expect(formatAudioAnalysisBitrate(1411200), '1.41 Mbps');
    });

    test('keeps audio stream bitrate distinct from whole file bitrate', () {
      final bitrate = AudioAnalysisBitrate.fromProbe(
        streamBitrate: 238900,
        containerBitrate: 260100,
        fileSize: 6502500,
        duration: 200,
      );
      expect(bitrate.bitsPerSecond, 238900);
      expect(bitrate.fileAverage, isFalse);
    });

    test('missing or invalid stream values use the labeled file average', () {
      for (final stream in [null, 0, -1]) {
        final bitrate = AudioAnalysisBitrate.fromProbe(
          streamBitrate: stream,
          containerBitrate: 238900,
          fileSize: 5972500,
          duration: 200,
        );
        expect(bitrate.bitsPerSecond, 238900);
        expect(bitrate.fileAverage, isTrue);
      }
    });

    test('estimates from bytes only with a usable duration', () {
      final bitrate = AudioAnalysisBitrate.fromProbe(
        streamBitrate: 0,
        containerBitrate: 0,
        fileSize: 5972500,
        duration: 200,
      );
      expect(bitrate.bitsPerSecond, 238900);
      expect(bitrate.fileAverage, isTrue);
      for (final duration in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          AudioAnalysisBitrate.fromProbe(
            fileSize: 5972500,
            duration: duration,
          ).bitsPerSecond,
          0,
        );
      }
    });

    test('cached analysis retains the meaning of its bitrate', () {
      const data = AudioAnalysisData(
        filePath: '/music/song.opus',
        fileSize: 5972500,
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 0,
        duration: 200,
        bitrate: 238900,
        bitrateIsFileAverage: true,
        bitDepth: 'N/A',
        dynamicRange: 12,
        peakAmplitude: -1,
        rmsLevel: -13,
        totalSamples: 9600000,
      );
      final restored = AudioAnalysisData.fromJson(data.toJson());
      expect(restored.bitrate, 238900);
      expect(restored.bitrateIsFileAverage, isTrue);
    });
  });

  group('spectral cutoff formatting', () {
    test('formats a detected cutoff frequency', () {
      expect(
        formatAudioAnalysisSpectralCutoff(
          22605,
          notDetectedLabel: 'Not detected',
        ),
        '22.6 kHz',
      );
    });

    test('keeps the metric visible when no cutoff is detected', () {
      expect(
        formatAudioAnalysisSpectralCutoff(
          null,
          notDetectedLabel: 'Not detected',
        ),
        'Not detected',
      );
    });
  });
}
