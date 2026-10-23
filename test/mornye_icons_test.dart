import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_icons.dart';

void main() {
  test('repeated lookups return the first glyph for each icon', () {
    final expected = {
      Icons.extension: CupertinoIcons.square_grid_2x2,
      Icons.grid_view_rounded: CupertinoIcons.square_grid_2x2,
      Icons.palette_outlined: CupertinoIcons.paintbrush,
      // The first pattern wins for an icon listed twice.
      Icons.library_music: CupertinoIcons.music_note_list,
      Icons.monitor_heart_outlined: CupertinoIcons.waveform_path_ecg,
      Icons.folder_open: CupertinoIcons.folder,
      Icons.computer: CupertinoIcons.desktopcomputer,
      Icons.campaign_outlined: CupertinoIcons.speaker_2,
      Icons.telegram: CupertinoIcons.paperplane,
      // Unmapped Material and Cupertino icons pass through.
      Icons.ac_unit: Icons.ac_unit,
      Icons.filter_9_plus: Icons.filter_9_plus,
      CupertinoIcons.heart: CupertinoIcons.heart,
    };
    for (final pass in [1, 2]) {
      for (final MapEntry(key: icon, value: glyph) in expected.entries) {
        expect(mornyeIconFor(icon), glyph, reason: 'pass $pass: $icon');
      }
    }
    final back = mornyeIconFor(Icons.arrow_back);
    expect(mornyeIconFor(Icons.arrow_back), same(back));
    expect(back.matchTextDirection, isTrue);
  });
}
