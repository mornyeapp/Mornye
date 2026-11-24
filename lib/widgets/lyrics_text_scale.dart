import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/theme_provider.dart';

/// Applies the lyric preference on top of the system's accessibility scaling.
class LyricsTextScale extends ConsumerWidget {
  const LyricsTextScale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor = ref.watch(
      themeProvider.select((theme) => theme.lyricsTextScale),
    );
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: LyricsTextScaler(media.textScaler, factor),
      ),
      child: child,
    );
  }
}

class LyricsTextScaler extends TextScaler {
  const LyricsTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is LyricsTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}
