import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_compare_dsp.dart';
import 'package:mornye/services/audio_compare_ffmpeg.dart';

String _graph(List<String> arguments) =>
    arguments[arguments.indexOf('-filter_complex') + 1];

void main() {
  group('excerpt arguments', () {
    test('decode both files once and write each excerpt as float PCM', () {
      final arguments = buildAudioCompareExcerptArguments(
        referencePath: '/music/a.flac',
        otherPath: '/music/b.mp3',
        sampleRate: 44100,
        channels: 2,
        excerpts: const [
          AudioCompareExcerpt(
            input: 0,
            startSample: 100,
            endSample: 200,
            outputPath: '/tmp/r.f32',
          ),
          AudioCompareExcerpt(
            input: 1,
            startSample: 50,
            endSample: 260,
            outputPath: '/tmp/o.f32',
          ),
        ],
      );
      expect(arguments.sublist(0, 7), [
        '-hide_banner',
        '-nostats',
        '-y',
        '-i',
        '/music/a.flac',
        '-i',
        '/music/b.mp3',
      ]);
      expect(
        _graph(arguments),
        '[0:a:0]aresample=44100,'
        'aformat=sample_fmts=flt:channel_layouts=stereo,'
        'atrim=start_sample=100:end_sample=200[cmp_x0];'
        '[1:a:0]aresample=44100,'
        'aformat=sample_fmts=flt:channel_layouts=stereo,'
        'atrim=start_sample=50:end_sample=260[cmp_x1]',
      );
      expect(arguments.sublist(9), [
        '-map',
        '[cmp_x0]',
        '-f',
        'f32le',
        '-c:a',
        'pcm_f32le',
        '/tmp/r.f32',
        '-map',
        '[cmp_x1]',
        '-f',
        'f32le',
        '-c:a',
        'pcm_f32le',
        '/tmp/o.f32',
      ]);
    });

    test('the wide search splits one mono decimated decode per file', () {
      final graph = _graph(
        buildAudioCompareExcerptArguments(
          referencePath: 'a',
          otherPath: 'b',
          sampleRate: 96000,
          channels: 2,
          decimatedRate: audioCompareCoarseRate,
          excerpts: const [
            AudioCompareExcerpt(
              input: 0,
              startSample: 0,
              endSample: 10,
              outputPath: 'r0',
            ),
            AudioCompareExcerpt(
              input: 1,
              startSample: 0,
              endSample: 20,
              outputPath: 'o0',
            ),
            AudioCompareExcerpt(
              input: 0,
              startSample: 30,
              endSample: 40,
              outputPath: 'r1',
            ),
            AudioCompareExcerpt(
              input: 1,
              startSample: 25,
              endSample: 45,
              outputPath: 'o1',
            ),
          ],
        ),
      );
      expect(
        graph,
        '[0:a:0]aresample=96000,'
        'aformat=sample_fmts=flt:channel_layouts=mono,aresample=4000,'
        'asplit=2[cmp_s0][cmp_s2];'
        '[cmp_s0]atrim=start_sample=0:end_sample=10[cmp_x0];'
        '[cmp_s2]atrim=start_sample=30:end_sample=40[cmp_x2];'
        '[1:a:0]aresample=96000,'
        'aformat=sample_fmts=flt:channel_layouts=mono,aresample=4000,'
        'asplit=2[cmp_s1][cmp_s3];'
        '[cmp_s1]atrim=start_sample=0:end_sample=20[cmp_x1];'
        '[cmp_s3]atrim=start_sample=25:end_sample=45[cmp_x3]',
      );
    });
  });

  group('merge graph', () {
    test('a later other file is trimmed, an earlier one delayed', () {
      String merge(int offset) => buildAudioCompareMergeGraph(
        sampleRate: 48000,
        channels: 2,
        offsetFrames: offset,
      );
      const chain =
          'aresample=48000,aformat=sample_fmts=flt:channel_layouts=stereo';
      expect(
        merge(1105),
        '[0:a:0]$chain,asetpts=N/SR/TB[cmp_ref];'
        '[1:a:0]$chain,atrim=start_sample=1105,asetpts=N/SR/TB,apad[cmp_oth];'
        '[cmp_ref][cmp_oth]amerge=inputs=2',
      );
      expect(
        merge(-2112),
        contains('[1:a:0]$chain,adelay=delays=2112S:all=1,asetpts=N/SR/TB'),
      );
      expect(merge(0), contains('[1:a:0]$chain,asetpts=N/SR/TB,apad'));
    });
  });

  group('stats arguments', () {
    test('stereo residual and reference levels per window, in two bands', () {
      final arguments = buildAudioCompareStatsArguments(
        referencePath: '/music/a.flac',
        otherPath: '/music/b.mp3',
        sampleRate: 44100,
        channels: 2,
        offsetFrames: 0,
        gain: 1.0512,
        windowFrames: 3969,
        metadataPath: r'C:\Temp\levels.txt',
      );
      final graph = _graph(arguments);
      expect(
        graph,
        contains(
          'pan=4c|c0=c0-1.051200000*c2|c1=c1-1.051200000*c3|c2=c0|c3=c1,'
          'asplit=2[cmp_full][cmp_hp];'
          '[cmp_hp]highpass=f=8000:poles=2,highpass=f=8000:poles=2[cmp_high];'
          '[cmp_full][cmp_high]amerge=inputs=2,'
          'asetnsamples=n=3969:p=0,'
          'astats=metadata=1:reset=1:measure_perchannel=RMS_level:'
          'measure_overall=none,',
        ),
      );
      expect(
        graph,
        endsWith(r"ametadata=print:file='C\:\\Temp\\levels.txt'[cmp_stats]"),
      );
      expect(arguments.sublist(arguments.length - 5), [
        '-map',
        '[cmp_stats]',
        '-f',
        'null',
        '-',
      ]);
    });

    test('mono and an inverted gain stay valid pan expressions', () {
      final graph = _graph(
        buildAudioCompareStatsArguments(
          referencePath: 'a',
          otherPath: 'b',
          sampleRate: 22050,
          channels: 1,
          offsetFrames: 0,
          gain: -0.5,
          windowFrames: 100,
          metadataPath: '/tmp/m.txt',
        ),
      );
      expect(graph, contains('pan=2c|c0=c0+0.500000000*c1|c1=c0,'));
      // The band split stays below Nyquist at low rates.
      expect(graph, contains('highpass=f=8000'));
      final low = _graph(
        buildAudioCompareStatsArguments(
          referencePath: 'a',
          otherPath: 'b',
          sampleRate: 16000,
          channels: 1,
          offsetFrames: 0,
          gain: 1,
          windowFrames: 100,
          metadataPath: '/tmp/m.txt',
        ),
      );
      expect(low, contains('highpass=f=7200'));
    });
  });

  test('the residual spectrogram reuses the spectrogram filter', () {
    final arguments = buildAudioCompareSpectrogramArguments(
      referencePath: 'a',
      otherPath: 'b',
      sampleRate: 44100,
      channels: 2,
      offsetFrames: -10,
      gain: 0.9,
      durationSeconds: 600,
      outputPath: '/tmp/s.rgba',
    );
    final graph = _graph(arguments);
    expect(
      graph,
      contains(
        'pan=stereo|c0=c0-0.900000000*c2|c1=c1-0.900000000*c3[cmp_residual];'
        '[cmp_residual]aselect=',
      ),
    );
    expect(graph, contains('showspectrumpic=s=1600x800'));
    expect(graph, endsWith('format=rgba[spectrum]'));
    expect(arguments.sublist(arguments.length - 9), [
      '-map',
      '[spectrum]',
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgba',
      '/tmp/s.rgba',
    ]);
  });

  group('metadata', () {
    const metadata = '''
frame:0    pts:0       pts_time:0
lavfi.astats.1.RMS_level=-43.777571
lavfi.astats.2.RMS_level=-inf
lavfi.astats.3.RMS_level=-10.000000
lavfi.astats.4.RMS_level=-13.467247
lavfi.astats.5.RMS_level=-64.218687
lavfi.astats.6.RMS_level=-64.342160
lavfi.astats.7.RMS_level=-62.779902
lavfi.astats.8.RMS_level=-63.032422
frame:1    pts:3969   pts_time:0.09
lavfi.astats.1.RMS_level=-20.000000
lavfi.astats.2.RMS_level=-20.000000
lavfi.astats.3.RMS_level=-10.000000
lavfi.astats.4.RMS_level=-10.000000
lavfi.astats.5.RMS_level=-inf
lavfi.astats.6.RMS_level=-inf
lavfi.astats.7.RMS_level=-30.000000
lavfi.astats.8.RMS_level=-30.000000
''';

    test('parses each window in channel order', () {
      final levels = parseAudioCompareMetadata(metadata, channels: 8);
      expect(levels, hasLength(2));
      expect(levels[0][0], closeTo(-43.777571, 1e-9));
      expect(levels[0][1], double.negativeInfinity);
      expect(levels[1][6], -30);
    });

    test('turns levels into timeline windows', () {
      final windows = audioCompareWindowsFromMetadata(
        parseAudioCompareMetadata(metadata, channels: 8),
        channels: 2,
        sampleRate: 44100,
        windowFrames: 3969,
        totalFrames: 3969 + 1000,
      );
      expect(windows, hasLength(2));
      expect(windows[1].startSeconds, closeTo(0.09, 1e-9));
      expect(windows[0].frames, 3969);
      expect(windows[1].frames, 1000);
      expect(windows[0].residual[1], 0);
      expect(windows[1].relativeDb(AudioCompareChannel.combined), -10);
      expect(
        windows[0].relativeDb(AudioCompareChannel.right),
        audioCompareFloorDb,
      );
      expect(windows[1].referenceHigh[0], closeTo(0.001, 1e-12));
      expect(windows[1].residualHigh[0], 0);
    });

    test('a truncated window keeps missing channels silent', () {
      final levels = parseAudioCompareMetadata(
        'frame:0 pts:0 pts_time:0\nlavfi.astats.1.RMS_level=-6\n',
        channels: 4,
      );
      final windows = audioCompareWindowsFromMetadata(
        levels,
        channels: 1,
        sampleRate: 48000,
        windowFrames: 480,
      );
      expect(windows.single.reference[0], 0);
      expect(windows.single.residual[0], greaterThan(0));
    });
  });
}
