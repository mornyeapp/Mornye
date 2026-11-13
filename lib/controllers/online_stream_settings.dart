import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The selected stream quality is a global preference, not a download option.
/// Highest Qobuz FLAC is the default for fresh installations.
class OnlineStreamSettings {
  static const _key = 'online_stream_quality_v1';
  static const best = 'HI_RES_LOSSLESS';
  // A universal chooser: source capabilities differ. Qobuz may offer FLAC;
  // SoundCloud serves AAC, while Jellyfin can serve original or transcode.
  static const qualities = <String, String>{
    best: 'Best available · source-dependent',
    'HI_RES': 'Prefer Hi-Res when offered',
    'LOSSLESS': 'Prefer lossless when offered',
    'ORIGINAL': 'Jellyfin · original file',
    'MP3_320': 'Jellyfin · MP3 320 kbps',
    'MP3_192': 'Jellyfin · MP3 192 kbps',
    'OPUS_128': 'Jellyfin · Opus 128 kbps',
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
                'Applied to the next stream. Actual formats depend on the provider.',
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
