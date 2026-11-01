import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_replaygain.dart';

void main() {
  test('missing decoder reports unsupported and rejects a default summary', () {
    var unsupported = false;
    final result = FFmpegReplayGain.parseScan(
      FFmpegResult(
        success: false,
        returnCode: 1,
        output:
            'Decoder (codec ac4) not found for input stream #0:0\n'
            'I: -70.0 LUFS\nPeak: -120.0 dBFS',
      ),
      onUnsupportedDecoder: () => unsupported = true,
    );
    expect(result, isNull);
    expect(unsupported, isTrue);
  });

  test('failed decoding cannot use a partial loudness measurement', () {
    var unsupported = false;
    final result = FFmpegReplayGain.parseScan(
      FFmpegResult(
        success: false,
        returnCode: 1,
        output:
            'Error while decoding stream #0:0: Invalid data\n'
            'I: -12.0 LUFS\nPeak: -1.0 dBFS',
      ),
      onUnsupportedDecoder: () => unsupported = true,
    );
    expect(result, isNull);
    expect(unsupported, isFalse);
  });

  test('completed analysis uses the final summary and highest peak', () {
    final result = FFmpegReplayGain.parseScan(
      FFmpegResult(
        success: true,
        returnCode: 0,
        output:
            'I: -70.0 LUFS\nI: -12.0 LUFS\n'
            'Peak: -2.0 dBFS\nPeak: -1.0 dBFS',
      ),
    );
    expect(result, isNotNull);
    expect(result!.trackGain, '-6.00 dB');
    expect(result.truePeakLinear, closeTo(0.891251, 0.000001));
  });
}
