import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/windows_audio_device_service.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart'
    show desktopNowPlayingOpen;
import 'package:mornye/widgets/player_volume_control.dart';

/// Global state controlling whether the independent floating Live Audio Stream Monitor
/// surface is visible.
final ValueNotifier<bool> desktopLiveAudioMonitorOpen = ValueNotifier<bool>(
  false,
);

/// Global state controlling whether the Audio Quick Settings panel is visible
/// in the root desktop application overlay.
final ValueNotifier<bool> desktopAudioQuickSettingsOpen = ValueNotifier<bool>(
  false,
);

/// Shared TapRegion group identifier connecting the audio control center panels
/// and the player bar trigger so that outside dismissal behaves predictably.
const String kAudioControlCenterTapRegionGroup = 'audio_control_center_region';

/// Standard width for both Audio Quick Settings and Live Audio Stream Monitor.
const double kAudioPanelWidth = 400.0;

/// Coordinates the visibility and lifecycle of the Audio Control Center (ACC)
/// and the Live Audio Stream Monitor.
class DesktopAudioControlCenterController {
  DesktopAudioControlCenterController._();
  static final DesktopAudioControlCenterController instance =
      DesktopAudioControlCenterController._();

  /// Whether Audio Quick Settings is currently open.
  final ValueNotifier<bool> quickSettingsOpen = desktopAudioQuickSettingsOpen;

  /// Whether the Live Audio Stream Monitor is currently open.
  final ValueNotifier<bool> monitorOpen = desktopLiveAudioMonitorOpen;

  /// Whether either surface is currently active.
  bool get isOpen => quickSettingsOpen.value || monitorOpen.value;

  /// Opens Audio Quick Settings and automatically coordinates opening the
  /// Live Audio Stream Monitor as well.
  void open() {
    quickSettingsOpen.value = true;
    monitorOpen.value = true;
  }

  /// Closes both Audio Quick Settings and the Live Audio Stream Monitor.
  void close() {
    quickSettingsOpen.value = false;
    monitorOpen.value = false;
  }

  /// Toggles Audio Quick Settings from the player-bar trigger.
  void toggle() {
    if (quickSettingsOpen.value) {
      close();
    } else {
      open();
    }
  }

  /// Closes only the Live Audio Stream Monitor, keeping ACC open.
  void closeMonitorOnly() {
    monitorOpen.value = false;
  }

  /// Opens the Live Audio Stream Monitor.
  void openMonitor() {
    monitorOpen.value = true;
  }

  /// Toggles only the Live Audio Stream Monitor.
  void toggleMonitor() {
    monitorOpen.value = !monitorOpen.value;
  }
}

/// Toggles visibility of the independent floating Live Audio Stream Monitor surface.
void toggleDesktopLiveAudioMonitor() =>
    DesktopAudioControlCenterController.instance.toggleMonitor();

/// Opens the independent floating Live Audio Stream Monitor surface.
void openDesktopLiveAudioMonitor() =>
    DesktopAudioControlCenterController.instance.openMonitor();

/// Closes the independent floating Live Audio Stream Monitor surface.
void closeDesktopLiveAudioMonitor() =>
    DesktopAudioControlCenterController.instance.closeMonitorOnly();

/// Toggles visibility of the Audio Quick Settings panel.
void toggleDesktopAudioQuickSettings() =>
    DesktopAudioControlCenterController.instance.toggle();

/// Opens the Audio Quick Settings panel.
void openDesktopAudioQuickSettings() =>
    DesktopAudioControlCenterController.instance.open();

/// Closes the Audio Quick Settings panel.
void closeDesktopAudioQuickSettings() =>
    DesktopAudioControlCenterController.instance.close();

/// The live WASAPI readout card. It displays confirmed physical output stream
/// parameters and bit-perfect verification facts.
class WindowsLiveAudioMonitorCard extends StatelessWidget {
  const WindowsLiveAudioMonitorCard({
    super.key,
    this.onDismiss,
    this.isFloating = false,
  });

  /// Optional callback to dismiss the surface.
  final VoidCallback? onDismiss;

  /// Whether the card is presented as a floating surface.
  final bool isFloating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ValueListenableBuilder<WindowsAudioStatus>(
      valueListenable: windowsAudioStatus,
      builder: (context, status, _) {
        final bitPerfect = status.isBitPerfect;
        final exclusive = status.mode.startsWith('exclusive');
        final isPush = status.mode == 'exclusive_push';
        final accent = bitPerfect
            ? Colors.green
            : exclusive
                ? colors.primary
                : Colors.amber;

        String formatStream(int? rate, int? depth, String? sampleFormat) {
          if (rate == null) return 'Awaiting playback…';
          final detail = sampleFormat == null || sampleFormat.isEmpty
              ? ''
              : ' ($sampleFormat)';
          return '$rate Hz · ${depth ?? '—'}-bit$detail';
        }

        final glassColor = Color.alphaBlend(
          colors.primary.withValues(alpha: 0.08),
          const Color(0xD6151222),
        );

        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              color: glassColor,
              elevation: isFloating ? 8 : 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: accent.withValues(alpha: bitPerfect ? 0.65 : 0.28),
                  width: bitPerfect ? 1.5 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: isFloating
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : null,
                ),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          exclusive ? Icons.lock_outline : Icons.graphic_eq,
                          color: accent,
                          size: 19,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'LIVE AUDIO STREAM MONITOR',
                            maxLines: 1,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        if (onDismiss != null) ...[
                          const SizedBox(width: 6),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            tooltip: 'Close Monitor',
                            icon: Icon(Icons.close, color: colors.onSurfaceVariant),
                            onPressed: onDismiss,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.35),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            bitPerfect
                                ? 'BIT-PERFECT'
                                : exclusive
                                    ? (isPush ? 'EXCLUSIVE PUSH' : 'EXCLUSIVE EVENT')
                                    : 'SHARED',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: accent,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.35,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            bitPerfect
                                ? 'Lossless bit-perfect direct stream'
                                : exclusive
                                    ? 'WASAPI exclusive stream'
                                    : 'WASAPI shared mixer stream',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11.5,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 18),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _MonitorValue(
                            label: 'DAC HARDWARE OUTPUT',
                            value: formatStream(
                              status.sampleRate,
                              status.bitDepth,
                              status.format,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MonitorValue(
                            label: 'SOURCE TRACK FORMAT',
                            value: formatStream(
                              status.sourceSampleRate,
                              status.sourceBitDepth,
                              status.sourceFormat,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Active Endpoint: ${status.activeDevice ?? 'Default'}'
                      '${status.selectedDevice != null && status.selectedDevice != status.activeDevice ? ' (Selected: ${status.selectedDevice})' : ''} · '
                      '${status.driver.toUpperCase()} · '
                      'State: ${status.reason.toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest.withValues(
                          alpha: 0.65,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            bitPerfect
                                ? Icons.check_circle_outline
                                : Icons.info_outline,
                            size: 16,
                            color: accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              status.bitPerfectReason ??
                                  (status.sampleRate == null
                                      ? 'Start playback to inspect the negotiated output stream.'
                                      : 'Playback is active; bit-perfect output is not currently verified.'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12.5,
                                color: bitPerfect
                                    ? Colors.green
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MonitorValue extends StatelessWidget {
  const _MonitorValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.35,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Compact flyout settings panel allowing the user to select the Windows audio
/// endpoint, choose the output engine mode, and inspect probed format capabilities.
class WindowsAudioQuickSettingsPanel extends ConsumerStatefulWidget {
  const WindowsAudioQuickSettingsPanel({
    super.key,
    this.onClose,
    this.showCloseButton = true,
  });

  final VoidCallback? onClose;
  final bool showCloseButton;

  @override
  ConsumerState<WindowsAudioQuickSettingsPanel> createState() =>
      _WindowsAudioQuickSettingsPanelState();
}

class _WindowsAudioQuickSettingsPanelState
    extends ConsumerState<WindowsAudioQuickSettingsPanel> {
  final WindowsAudioDeviceService _devices = WindowsAudioDeviceService.instance;
  WindowsDeviceCapabilities? _capabilities;
  bool _loadingCapabilities = false;
  String? _requestedDevice;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _devices.addListener(_onDevicesChanged);
  }

  @override
  void dispose() {
    _devices.removeListener(_onDevicesChanged);
    super.dispose();
  }

  void _onDevicesChanged() {
    if (mounted) setState(() {});
  }

  void _loadCapabilitiesFor(String deviceId) {
    if (_requestedDevice == deviceId) return;
    _requestedDevice = deviceId;
    final generation = ++_requestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _loadingCapabilities = true);
      final capabilities = await _devices.getDeviceCapabilities(deviceId);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _capabilities = capabilities;
        _loadingCapabilities = false;
      });
    });
  }

  String _rateLabel(int rate) => switch (rate) {
        0 => 'Auto',
        44100 => '44.1k',
        48000 => '48k',
        88200 => '88.2k',
        96000 => '96k',
        176400 => '176.4k',
        192000 => '192k',
        352800 => '352.8k',
        384000 => '384k',
        _ => '${(rate / 1000).toStringAsFixed(1)}k',
      };

  String _formatLabel(String format) => switch (format) {
        'auto' => 'Auto',
        's16' => '16-bit',
        's24' => '24-bit',
        's32' => '32-bit',
        'float' => '32f',
        _ => format,
      };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final colors = Theme.of(context).colorScheme;
    _loadCapabilitiesFor(settings.windowsOutputDevice);

    final exclusive = settings.windowsOutputMode.startsWith('exclusive');
    final probedRates = _capabilities == null
        ? const <int>[]
        : exclusive
            ? _capabilities!.exclusiveRates
            : _capabilities!.sharedRates;

    const standardRates = <int>[
      0,
      44100,
      48000,
      88200,
      96000,
      176400,
      192000,
      352800,
      384000,
    ];
    final Set<int> rates = probedRates.isNotEmpty
        ? {0, ...probedRates}
        : Set<int>.from(standardRates);
    rates.add(settings.windowsOutputSampleRate);
    final sortedRates = rates.toList()..sort();

    final rateKey = settings.windowsOutputSampleRate == 0
        ? ''
        : settings.windowsOutputSampleRate.toString();
    final probedFormats = _capabilities == null
        ? const <String>[]
        : (_capabilities!.formatsByRate[rateKey] ??
            (exclusive
                ? _capabilities!.exclusiveFormats
                : _capabilities!.sampleFormats));
    const standardFormats = <String>['auto', 's16', 's24', 's32', 'float'];
    final Set<String> formatsSet = probedFormats.isNotEmpty
        ? {'auto', ...probedFormats}
        : Set<String>.from(standardFormats);
    formatsSet.add(settings.windowsOutputSampleFormat);
    final formats = formatsSet.toList();

    final devices = _devices.endpoints;
    final selectedDevice = settings.windowsOutputDevice;
    var deviceValue = '';
    if (selectedDevice.isNotEmpty) {
      for (final device in devices) {
        if (device.mpvDeviceId == selectedDevice ||
            device.endpointId == selectedDevice ||
            device.guid == selectedDevice ||
            device.id == selectedDevice) {
          deviceValue = device.mpvDeviceId;
          break;
        }
      }
    }

    final glassColor = Color.alphaBlend(
      colors.primary.withValues(alpha: 0.08),
      const Color(0xD6151222),
    );
    final borderColor = Colors.white.withValues(alpha: 0.12);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: glassColor,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: borderColor, width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'AUDIO QUICK SETTINGS',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: desktopLiveAudioMonitorOpen,
                      builder: (context, open, _) => IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        tooltip: open
                            ? 'Hide Stream Monitor'
                            : 'Show Stream Monitor',
                        icon: Icon(
                          open ? Icons.graphic_eq : Icons.graphic_eq_outlined,
                          color: open ? colors.primary : colors.onSurfaceVariant,
                        ),
                        onPressed: toggleDesktopLiveAudioMonitor,
                      ),
                    ),
                    if (widget.showCloseButton) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        tooltip: 'Close Quick Settings',
                        icon: Icon(Icons.close, color: colors.onSurfaceVariant),
                        onPressed: widget.onClose ?? closeDesktopAudioQuickSettings,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Text('VOLUME', style: _sectionLabel(context)),
                const SizedBox(height: 2),
                PlayerVolumeControl(foreground: colors.onSurface),
                const Divider(height: 18),
                Text('AUDIO ENGINE', style: _sectionLabel(context)),
                const SizedBox(height: 7),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    ),
                    textStyle: WidgetStatePropertyAll(
                      Theme.of(context).textTheme.labelMedium?.copyWith(
                            fontSize: 13.0,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(value: 'shared', label: Text('Shared')),
                    ButtonSegment(
                      value: 'exclusive_event',
                      label: Text('Exclusive Event'),
                    ),
                    ButtonSegment(
                      value: 'exclusive_push',
                      label: Text('Exclusive Push'),
                    ),
                  ],
                  selected: {
                    switch (settings.windowsOutputMode) {
                      'exclusive_push' => 'exclusive_push',
                      'exclusive' || 'exclusive_event' => 'exclusive_event',
                      _ => 'shared',
                    },
                  },
                  onSelectionChanged: (selected) {
                    ref
                        .read(settingsProvider.notifier)
                        .setWindowsOutputMode(selected.first);
                  },
                ),
                if (settings.windowsOutputMode == 'exclusive_push')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        'Exclusive Push is unavailable on the current libmpv backend (which operates exclusively in event-driven mode via AUDCLNT_STREAMFLAGS_EVENTCALLBACK). Output operates in Exclusive Event mode.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontSize: 11.5,
                              color: Colors.amber[200],
                            ),
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Automatic fallback to Shared',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontSize: 12.5),
                      ),
                    ),
                    Switch.adaptive(
                      value: settings.windowsExclusiveFallback,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setWindowsExclusiveFallback(value),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ),
                const Divider(height: 18),
                Text('OUTPUT FORMAT', style: _sectionLabel(context)),
                const SizedBox(height: 7),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _FormatDropdown<int>(
                        label: 'Sample Rate',
                        value: settings.windowsOutputSampleRate,
                        items: [
                          for (final rate in sortedRates)
                            DropdownMenuItem(
                              value: rate,
                              child: Text(_rateLabel(rate)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setWindowsOutputSampleRate(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: _FormatDropdown<String>(
                        label: 'Sample Format',
                        value: formats.contains(settings.windowsOutputSampleFormat)
                            ? settings.windowsOutputSampleFormat
                            : 'auto',
                        items: [
                          for (final format in formats)
                            DropdownMenuItem(
                              value: format,
                              child: Text(_formatLabel(format)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setWindowsOutputSampleFormat(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: _FormatDropdown<String>(
                        label: 'Channels',
                        value: settings.windowsOutputChannels,
                        items: const [
                          DropdownMenuItem(value: 'auto', child: Text('Auto')),
                          DropdownMenuItem(value: 'stereo', child: Text('Stereo')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setWindowsOutputChannels(value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (_loadingCapabilities)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Checking device capabilities…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  )
                else if (_capabilities != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Hardware: ${_capabilities!.exclusiveRates.length} exclusive rates · '
                      '${_capabilities!.exclusiveFormats.length} formats probed',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ),
                const Divider(height: 18),
                Text('OUTPUT DEVICE', style: _sectionLabel(context)),
                const SizedBox(height: 4),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: deviceValue,
                    isExpanded: true,
                    isDense: true,
                    iconSize: 18,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('System Default (Automatic)'),
                      ),
                      for (final device in devices)
                        DropdownMenuItem(
                          value: device.mpvDeviceId,
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        ref
                            .read(settingsProvider.notifier)
                            .setWindowsOutputDevice(value);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextStyle? _sectionLabel(BuildContext context) =>
      Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.45,
          );
}

class _FormatDropdown<T> extends StatelessWidget {
  const _FormatDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            isExpanded: true,
            items: items,
            onChanged: onChanged,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Overlay presenting the Audio Quick Settings and Live Audio Stream Monitor
/// on the root desktop shell.
class DesktopAudioControlCenterOverlay extends StatelessWidget {
  const DesktopAudioControlCenterOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: desktopNowPlayingOpen,
      builder: (context, nowPlayingOpen, _) {
        if (nowPlayingOpen) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: desktopLiveAudioMonitorOpen,
          builder: (context, monitorOpen, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: desktopAudioQuickSettingsOpen,
              builder: (context, quickSettingsOpen, _) {
                if (!quickSettingsOpen && !monitorOpen) {
                  return const SizedBox.shrink();
                }

                final mediaQuery = MediaQuery.of(context);
                final screenSize = mediaQuery.size;
                const rightSpacing = 18.0;
                const bottomSpacing = 88.0;
                const topMargin = 52.0;

                final panelWidth = math.min(
                  kAudioPanelWidth,
                  screenSize.width - (rightSpacing * 2),
                );
                final maxAvailableHeight = math.max(
                  120.0,
                  screenSize.height - bottomSpacing - topMargin,
                );

                return Positioned(
                  right: rightSpacing,
                  bottom: bottomSpacing,
                  width: panelWidth,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxAvailableHeight),
                    child: TapRegion(
                      groupId: kAudioControlCenterTapRegionGroup,
                      onTapOutside: (_) {
                        closeDesktopAudioQuickSettings();
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (monitorOpen) ...[
                            WindowsLiveAudioMonitorCard(
                              isFloating: true,
                              onDismiss: closeDesktopLiveAudioMonitor,
                            ),
                            if (quickSettingsOpen) const SizedBox(height: 10),
                          ],
                          if (quickSettingsOpen)
                            Flexible(
                              child: SingleChildScrollView(
                                child: const WindowsAudioQuickSettingsPanel(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

