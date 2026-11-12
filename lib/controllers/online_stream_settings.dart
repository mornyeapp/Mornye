import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The selected stream quality is a global preference, not a download option.
/// Highest Qobuz FLAC is the default for fresh installations.
class OnlineStreamSettings {
  static const _key = 'online_stream_quality_v1';
  static const best = 'HI_RES_LOSSLESS';
  static const qualities = <String, String>{
    best: 'Best available · up to 24-bit / 192 kHz',
    'HI_RES': 'Hi-Res FLAC · prefer 24-bit',
    'LOSSLESS': 'Lossless FLAC · 16-bit',
  };

  static Future<String> current() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return qualities.containsKey(value) ? value! : best;
  }

  static Future<void> save(String quality) async {
    if (!qualities.containsKey(quality)) {
      throw ArgumentError.value(
        quality,
        'quality',
        'Unsupported stream quality',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, quality);
  }

  /// Long-press on the inline play control opens the global quality picker.
  static Future<String?> choose(BuildContext context) async {
    final selected = await current();
    if (!context.mounted) return null;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Online audio quality'),
              subtitle: Text(
                'Applied to the next stream. Best available is the default.',
              ),
            ),
            for (final option in qualities.entries)
              ListTile(
                title: Text(option.value),
                trailing: option.key == selected
                    ? const Icon(Icons.check_circle)
                    : const Icon(Icons.circle_outlined),
                onTap: () => Navigator.pop(sheetContext, option.key),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
