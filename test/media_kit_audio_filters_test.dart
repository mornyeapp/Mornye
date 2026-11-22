import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/media_kit_audio_filters.dart';
import 'package:mornye/services/playback_deck.dart';

void main() {
  test('a disabled equalizer clears the chain', () {
    final chain = MpvAudioFilterChain.fromEqualizer(
      const EqualizerSettings(gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    );
    expect(chain.isEmpty, isTrue);
    expect(chain.spec, '');
  });

  test('the filters form one graph after a float conversion', () {
    final chain = MpvAudioFilterChain.fromEqualizer(
      const EqualizerSettings(enabled: true, limiter: false),
    );
    expect(
      chain.spec,
      startsWith(
        '@mornye_format:format=format=floatp,'
        '@mornye_dsp:lavfi=[volume@pre=precision=float:volume=0dB,'
        'equalizer@band0=f=31.25:t=q:w=1.4142:g=0,',
      ),
    );
    expect(chain.spec, endsWith('equalizer@band9=f=16000:t=q:w=1.4142:g=0]'));
  });

  test('every band becomes a peaking filter with the shared Q', () {
    final settings = const EqualizerSettings(
      enabled: true,
      autoHeadroom: false,
      limiter: false,
    ).copyWith(gains: [3, -2, 0, 0, 0, 0, 0, 0, 0, 1.5]);
    final chain = MpvAudioFilterChain.fromEqualizer(settings);
    final bands = chain.filters.where((f) => f.name == 'equalizer').toList();
    expect(bands, hasLength(10));
    expect(bands.first.spec, 'equalizer@band0=f=31.25:t=q:w=1.4142:g=3');
    expect(bands[1].options['g'], '-2');
    // Ten bands spaced an octave apart: Q = sqrt(2) / (2 - 1).
    expect(bands.map((f) => f.options['w']).toSet(), {'1.4142'});
    expect(bands.last.options['f'], '16000');
    expect(bands.last.options['g'], '1.5');
  });

  test('preamp and automatic headroom set the input gain', () {
    final boosted = const EqualizerSettings(
      enabled: true,
    ).copyWith(gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0], preamp: 2);
    final chain = MpvAudioFilterChain.fromEqualizer(boosted);
    // preamp 2 dB minus 6 dB headroom for the largest boost.
    expect(chain.filters.first.spec, 'volume@pre=precision=float:volume=-4dB');
    expect(chain.volumeGainDb, 0);

    final manual = MpvAudioFilterChain.fromEqualizer(
      boosted.copyWith(autoHeadroom: false),
    );
    expect(manual.filters.first.options['volume'], '2dB');
  });

  test('balance, compressor and limiter follow the bands in order', () {
    final settings = const EqualizerSettings(
      enabled: true,
    ).copyWith(balance: 0.25, compressor: true, threshold: -20, ratio: 4);
    final chain = MpvAudioFilterChain.fromEqualizer(settings);
    final names = chain.filters.map((f) => f.name);
    expect(names.first, 'volume');
    expect(names.skip(1).take(10), everyElement('equalizer'));
    expect(names.skip(11), ['stereotools', 'acompressor', 'alimiter']);

    expect(chain.filters[11].spec, 'stereotools@balance=balance_out=0.25');
    final compressor = chain.filters[12];
    expect(compressor.options, containsPair('threshold', '0.1'));
    expect(compressor.options, containsPair('ratio', '4'));
    expect(compressor.options['detection'], 'peak');
    final limiter = chain.filters[13];
    // -0.5 dBFS ceiling, without alimiter's automatic output level.
    expect(limiter.options, containsPair('limit', '0.9441'));
    expect(limiter.options, containsPair('level', '0'));

    final centered = MpvAudioFilterChain.fromEqualizer(
      settings.copyWith(balance: 0, compressor: false, limiter: false),
    );
    expect(centered.filters.map((f) => f.name).toSet(), {
      'volume',
      'equalizer',
    });
  });

  test('parametric filters replace the bands with their own sections', () {
    final settings = const EqualizerSettings(enabled: true).copyWith(
      parametric: true,
      gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      bass: 4,
      filters: const [
        EqualizerFilter(frequency: 105, gain: -2.1, q: 0.7),
        EqualizerFilter(
          type: EqualizerFilterType.lowShelf,
          frequency: 80,
          gain: 4,
          q: 0.71,
        ),
        EqualizerFilter(
          type: EqualizerFilterType.highShelf,
          frequency: 30000,
          gain: -3,
          q: 0.5,
        ),
        EqualizerFilter(frequency: 500, gain: 0),
        EqualizerFilter(frequency: 900, gain: 5, enabled: false),
      ],
    );
    final chain = MpvAudioFilterChain.fromEqualizer(
      settings,
      sampleRate: 48000,
    );
    final sections = chain.filters
        .where((f) => f.id.startsWith('filter'))
        .map((f) => f.spec)
        .toList();
    expect(sections, [
      'equalizer@filter0=f=105:t=q:w=0.7:g=-2.1',
      'lowshelf@filter1=f=80:t=q:w=0.71:g=4',
      // Kept below 45% of the sample rate, like a band.
      'highshelf@filter2=f=21600:t=q:w=0.5:g=-3',
    ]);
    expect(chain.filters.any((f) => f.id.startsWith('band')), isFalse);
    // The headroom is the filters' own peak, not the waiting bands': the
    // shelf's 4 dB less what the cut beside it takes off.
    expect(chain.filters.first.options['volume'], '-3.8297dB');

    final bare = MpvAudioFilterChain.fromEqualizer(
      settings,
      sampleRate: 48000,
      unavailable: const {'lowshelf', 'highshelf'},
    );
    expect(
      bare.filters.where((f) => f.id.startsWith('filter')).map((f) => f.name),
      ['equalizer'],
    );
  });

  test('filters missing from libmpv are left out', () {
    final settings = const EqualizerSettings(
      enabled: true,
    ).copyWith(gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0], balance: 0.5);
    final chain = MpvAudioFilterChain.fromEqualizer(
      settings,
      unavailable: MpvAudioFilterChain.optionalFilters,
    );
    expect(chain.filters.map((f) => f.name).toSet(), {'equalizer'});
    // The headroom moves to mpv's volume.
    expect(chain.volumeGainDb, -6);
  });

  test('tone controls fold into the band gains', () {
    final chain = MpvAudioFilterChain.fromEqualizer(
      const EqualizerSettings(enabled: true, bass: 6, limiter: false),
    );
    final gains = [
      for (final filter in chain.filters.skip(1))
        double.parse(filter.options['g']!),
    ];
    expect(gains.first, closeTo(5.82, 0.01));
    expect(gains.last, closeTo(0, 0.01));
  });

  test('bands stay below 45% of the sample rate', () {
    final settings = const EqualizerSettings(enabled: true).withBandCount(31);
    final defaultRate = MpvAudioFilterChain.fromEqualizer(settings);
    expect(defaultRate.filters[31].options['f'], '19845');
    final low = MpvAudioFilterChain.fromEqualizer(settings, sampleRate: 22050);
    expect(low.filters[31].options['f'], '9922.5');
    final high = MpvAudioFilterChain.fromEqualizer(settings, sampleRate: 96000);
    expect(high.filters[31].options['f'], '20000');
  });

  test('settings that do not change a filter leave the spec equal', () {
    final base = const EqualizerSettings(enabled: true);
    final spec = MpvAudioFilterChain.fromEqualizer(base).spec;
    expect(
      MpvAudioFilterChain.fromEqualizer(base, sampleRate: 48000).spec,
      spec,
    );
    expect(
      MpvAudioFilterChain.fromEqualizer(base.copyWith(preamp: -3)).spec,
      isNot(spec),
    );
  });

  test('compressor timing is clamped like the other platforms', () {
    final chain = MpvAudioFilterChain.fromEqualizer(
      const EqualizerSettings(
        enabled: true,
      ).copyWith(compressor: true, attack: 0, release: 5000, ratio: 40),
    );
    final compressor = chain.filters.firstWhere((f) => f.name == 'acompressor');
    expect(compressor.options, containsPair('attack', '1'));
    expect(compressor.options, containsPair('release', '1000'));
    expect(compressor.options, containsPair('ratio', '20'));
  });

  group('tempo', () {
    test('without a shift only speed and pitch correction change', () {
      final kept = MpvTempo.of(1.5, PlaybackPitch.none);
      expect(kept.speed, 1.5);
      expect(kept.pitchCorrection, isTrue);
      expect(kept.filters, isEmpty);
      expect(kept.tempoScale, isNull);
      final following = MpvTempo.of(
        0.8,
        const PlaybackPitch(followsRate: true),
      );
      expect(following.speed, 0.8);
      expect(following.pitchCorrection, isFalse);
      expect(MpvAudioFilterChain.empty.withTempo(following).spec, '');
    });

    test('a shift is a rubberband filter after the equalizer', () {
      final tempo = MpvTempo.of(1.25, const PlaybackPitch(semitones: 12));
      expect(tempo.speed, 1.25);
      expect(tempo.pitchCorrection, isTrue);
      final chain = MpvAudioFilterChain.fromEqualizer(
        const EqualizerSettings(enabled: true, limiter: false),
      ).withTempo(tempo);
      expect(
        chain.spec,
        endsWith(
          'equalizer@band9=f=16000:t=q:w=1.4142:g=0,'
          'rubberband@pitch=pitch=2:pitchq=quality]',
        ),
      );
      // Without the equalizer the shift still has its graph.
      expect(
        MpvAudioFilterChain.empty.withTempo(tempo).spec,
        '@mornye_format:format=format=floatp,'
        '@mornye_dsp:lavfi=[rubberband@pitch=pitch=2:pitchq=quality]',
      );
    });

    test('without rubberband mpv resamples and scaletempo restores', () {
      final kept = MpvTempo.of(
        1.5,
        const PlaybackPitch(semitones: 12),
        unavailable: {'rubberband'},
      );
      // Resampled by the frequency factor, stretched back to 1.5x.
      expect(kept.speed, 2);
      expect(kept.pitchCorrection, isFalse);
      expect(kept.filters, isEmpty);
      expect(kept.tempoScale, 0.75);
      final following = MpvTempo.of(
        1.5,
        const PlaybackPitch(semitones: -12, followsRate: true),
        unavailable: {'rubberband'},
      );
      expect(following.speed, 0.75);
      expect(following.tempoScale, 2);
      final chain = MpvAudioFilterChain.fromEqualizer(
        const EqualizerSettings(enabled: true),
      ).withTempo(kept);
      expect(chain.spec, endsWith('],@mornye_tempo:scaletempo=scale=0.75'));
      expect(
        MpvAudioFilterChain.empty.withTempo(kept).spec,
        '@mornye_tempo:scaletempo=scale=0.75',
      );
      expect(MpvAudioFilterChain.empty.withTempo(kept).isEmpty, isFalse);
    });
  });
}
