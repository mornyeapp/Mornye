import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/utils/usb_output_status_label.dart';

void main() {
  for (final language in ['en', 'id']) {
    test('USB states remain distinct in $language', () async {
      final l10n = await AppLocalizations.delegate.load(Locale(language));
      final labels = [
        for (final reason in [
          'idle',
          'preparing',
          'ready',
          'cancelled',
          'unsupported',
          'format_unsupported',
          'dac_format_rejected',
          'dac_unsupported',
          'dac_open_failed',
          'timeout',
          'decode_failed',
          'android_version',
          'permission_denied',
          'permission_declined',
        ])
          usbOutputStatusLabel(l10n, UsbAudioStatus(reason: reason)),
      ];
      expect(labels.toSet(), hasLength(14));
      expect(
        usbOutputStatusLabel(l10n, const UsbAudioStatus(reason: 'active')),
        l10n.usbBitPerfectFallback,
      );
    });

    test('failure labels name the format in $language', () async {
      final l10n = await AppLocalizations.delegate.load(Locale(language));
      String label(UsbAudioStatus status) => usbOutputStatusLabel(l10n, status);
      expect(
        label(
          const UsbAudioStatus(
            reason: 'format_unsupported',
            codec: 'ALAC',
            sourceBitDepth: 32,
          ),
        ),
        l10n.usbFormatUnsupported('ALAC 32-bit'),
      );
      // A lossy codec has no depth of its own to name.
      expect(
        label(
          const UsbAudioStatus(
            reason: 'format_unsupported',
            codec: 'AC-3',
            lossy: true,
            sourceBitDepth: 16,
          ),
        ),
        l10n.usbFormatUnsupported('AC-3'),
      );
      expect(
        label(
          const UsbAudioStatus(reason: 'decoder_unavailable', codec: 'ALAC'),
        ),
        l10n.usbDecoderUnavailable('ALAC'),
      );
      expect(
        label(const UsbAudioStatus(reason: 'decoder_unavailable')),
        l10n.usbFormatUnsupportedGeneric,
      );
      expect(
        label(
          const UsbAudioStatus(reason: 'channels_unsupported', channels: 6),
        ),
        l10n.usbChannelsUnsupported(6),
      );
      expect(
        label(const UsbAudioStatus(reason: 'channels_unsupported')),
        l10n.usbBitPerfectFallback,
      );
      expect(
        label(
          const UsbAudioStatus(
            reason: 'dac_format_rejected',
            bitDepth: 32,
            sampleRate: 384000,
            channels: 2,
          ),
        ),
        l10n.usbDacFormatRejected('32-bit 384 kHz'),
      );
      expect(
        label(
          const UsbAudioStatus(
            reason: 'dac_format_rejected',
            sourceBitDepth: 16,
            sampleRate: 44100,
            channels: 1,
          ),
        ),
        l10n.usbDacFormatRejected(l10n.usbFormatMono('16-bit 44.1 kHz')),
      );
    });

    test(
      'an active lossy source is not shown as lossless in $language',
      () async {
        final l10n = await AppLocalizations.delegate.load(Locale(language));
        const lossless = UsbAudioStatus(
          reason: 'active',
          device: 'DAC',
          sampleRate: 44100,
          bitDepth: 24,
          codec: 'ALAC',
        );
        const lossy = UsbAudioStatus(
          reason: 'active',
          device: 'DAC',
          sampleRate: 44100,
          bitDepth: 24,
          codec: 'AAC',
          lossy: true,
        );
        expect(
          usbOutputStatusLabel(l10n, lossless),
          'DAC · 24-bit PCM · 44.1 kHz',
        );
        expect(
          usbOutputStatusLabel(l10n, lossy),
          'DAC · ${l10n.usbOutputLossySource('AAC')} · 24-bit PCM · 44.1 kHz',
        );
      },
    );
  }
}
