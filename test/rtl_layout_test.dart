import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_icons.dart';

void main() {
  test('Mornye directional icons mirror in right-to-left layouts', () {
    for (final icon in [
      mornyeIconFor(Icons.arrow_back),
      mornyeIconFor(Icons.chevron_left),
      mornyeArrowForward,
      CupertinoIcons.back,
      CupertinoIcons.forward,
      CupertinoIcons.right_chevron,
    ]) {
      expect(icon.matchTextDirection, isTrue, reason: '$icon');
    }
    // The mirrored glyphs are the same shapes as the SF-style names.
    expect(
      CupertinoIcons.back.codePoint,
      CupertinoIcons.chevron_back.codePoint,
    );
    expect(
      CupertinoIcons.forward.codePoint,
      CupertinoIcons.chevron_forward.codePoint,
    );
    expect(mornyeArrowForward.codePoint, CupertinoIcons.arrow_right.codePoint);
  });
}
