import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/windows_media_playback_deck.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Windows: the "Dolby Atmos through Windows" switch, with what this PC
/// offers it. Windows includes the Dolby Digital Plus (E-AC-3) decoder, the
/// AC-4 decoder comes only from PC makers, and Atmos needs a spatial sound
/// format in the Windows sound settings.
class WindowsDolbySettingItem extends ConsumerStatefulWidget {
  const WindowsDolbySettingItem({
    super.key,
    this.loadSupport = windowsDolbySupport,
  });

  /// Reads what the PC supports; replaced in tests.
  final Future<WindowsDolbySupport?> Function() loadSupport;

  @override
  ConsumerState<WindowsDolbySettingItem> createState() =>
      _WindowsDolbySettingItemState();
}

class _WindowsDolbySettingItemState
    extends ConsumerState<WindowsDolbySettingItem> {
  /// Read once per visit: decoders rarely change while the page is open.
  late final Future<WindowsDolbySupport?> _support = widget.loadSupport();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    return FutureBuilder<WindowsDolbySupport?>(
      future: _support,
      builder: (context, snapshot) {
        final support = snapshot.data;
        return SettingsSwitchItem(
          icon: Icons.surround_sound_outlined,
          title: l10n.windowsDolbyEngine,
          subtitle: [
            l10n.windowsDolbyEngineDescription,
            if (support != null)
              [
                support.dolbyDigitalPlus
                    ? l10n.windowsDolbyEac3Supported
                    : l10n.windowsDolbyEac3Missing,
                support.ac4
                    ? l10n.windowsDolbyAc4Supported
                    : l10n.windowsDolbyAc4Missing,
                support.spatialSound
                    ? l10n.windowsDolbySpatialOn
                    : l10n.windowsDolbySpatialOff,
              ].join('\n'),
            if (settings.exclusiveOutput) l10n.windowsDolbyEngineExclusive,
          ].join('\n\n'),
          value: settings.windowsDolbyEngine,
          onChanged: (value) =>
              ref.read(settingsProvider.notifier).setWindowsDolbyEngine(value),
        );
      },
    );
  }
}
