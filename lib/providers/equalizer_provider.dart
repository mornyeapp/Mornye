import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/playback_equalizer.dart';

class EqualizerState {
  const EqualizerState({
    this.settings = const EqualizerSettings(),
    this.presets = const [],
    this.error,
  });
  final EqualizerSettings settings;
  final List<EqualizerPreset> presets;
  final String? error;
}

final equalizerProvider = NotifierProvider<EqualizerController, EqualizerState>(
  EqualizerController.new,
);

class EqualizerController extends Notifier<EqualizerState> {
  static const storageKey = 'playback_equalizer_v1';
  int _revision = 0;
  bool _disposed = false;
  EqualizerState? _pending;
  bool _saving = false;
  Timer? _saveTimer;
  late Future<void> _loading;
  final _deletedPresets = <String>{};

  @override
  EqualizerState build() {
    ref.onDispose(() {
      _disposed = true;
      _saveTimer?.cancel();
      if (!_saving && _pending != null) unawaited(_save());
    });
    _loading = _load();
    return const EqualizerState();
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (_disposed || raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final settings = EqualizerSettings.fromJson(
        Map<String, dynamic>.from(data['settings'] as Map),
      );
      final presets = (data['presets'] as List? ?? const [])
          .take(100)
          .map(
            (v) =>
                EqualizerPreset.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList(growable: false);
      if (revision == _revision) {
        state = EqualizerState(settings: settings, presets: presets);
      } else {
        final merged = {
          for (final preset in presets) preset.name: preset,
          for (final preset in state.presets) preset.name: preset,
        };
        for (final name in _deletedPresets) {
          merged.remove(name);
        }
        state = EqualizerState(
          settings: state.settings,
          presets: merged.values.take(100).toList(),
        );
        _pending = state;
      }
      playbackEqualizer.value = state.settings;
    } catch (_) {
      if (!_disposed && revision == _revision) {
        state = const EqualizerState(
          error: 'Could not read saved equalizer settings.',
        );
      }
    }
  }

  void update(EqualizerSettings settings) => _commit(settings, state.presets);

  void applyPreset(EqualizerPreset preset) =>
      update(state.settings.withToneOf(preset.settings));

  void savePreset(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      throw const FormatException('Preset name must contain 1–80 characters.');
    }
    final next = state.presets.where((v) => v.name != trimmed).toList();
    if (next.length >= 100) {
      throw const FormatException('Maximum 100 custom presets.');
    }
    _deletedPresets.remove(trimmed);
    _commit(state.settings, [
      ...next,
      EqualizerPreset(trimmed, state.settings),
    ]);
  }

  void deletePreset(String name) {
    _deletedPresets.add(name);
    _commit(
      state.settings,
      state.presets.where((v) => v.name != name).toList(),
    );
  }

  String exportPreset(String name) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': 'mornye-equalizer',
        'version': 1,
        ...EqualizerPreset(name, state.settings).toJson(),
      });

  void importPreset(String source) {
    if (source.length > 65536) {
      throw const FormatException('Preset file is too large.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        (decoded['format'] != 'mornye-equalizer' &&
            decoded['format'] != 'spotiflac-equalizer') ||
        decoded['version'] != 1) {
      throw const FormatException('Unsupported equalizer preset.');
    }
    final preset = EqualizerPreset.fromJson(Map<String, dynamic>.from(decoded));
    final others = state.presets.where((v) => v.name != preset.name).toList();
    if (others.length >= 100) {
      throw const FormatException('Maximum 100 custom presets.');
    }
    _deletedPresets.remove(preset.name);
    _commit(preset.settings.copyWith(enabled: state.settings.enabled), [
      ...others,
      preset,
    ]);
  }

  void _commit(EqualizerSettings settings, List<EqualizerPreset> presets) {
    _revision++;
    state = EqualizerState(
      settings: settings,
      presets: identical(presets, state.presets)
          ? presets
          : List.unmodifiable(presets),
    );
    playbackEqualizer.value = settings;
    _pending = state;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      if (!_saving) unawaited(_save());
    });
  }

  Future<void> _save() async {
    _saving = true;
    try {
      await _loading;
      final prefs = await SharedPreferences.getInstance();
      while (_pending != null) {
        final value = _serialize(_pending!);
        _pending = null;
        if (!await prefs.setString(storageKey, value)) {
          throw StateError('Write failed');
        }
      }
    } catch (_) {
      if (!_disposed) {
        state = EqualizerState(
          settings: state.settings,
          presets: state.presets,
          error: 'Could not save equalizer settings.',
        );
      }
    } finally {
      _saving = false;
    }
  }

  String _serialize(EqualizerState snapshot) => jsonEncode({
    'settings': snapshot.settings.toJson(),
    'presets': snapshot.presets.map((v) => v.toJson()).toList(),
  });
}
