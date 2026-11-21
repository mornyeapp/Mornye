import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_tokens.dart';

class AudioQualityBadge extends StatelessWidget {
  final String label;
  final ColorScheme colorScheme;

  const AudioQualityBadge({
    super.key,
    required this.label,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: context.tokens.borderRadiusBadge,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.tokens.badgeFontSize,
          fontWeight: FontWeight.w600,
          color: colorScheme.onPrimaryContainer,
          height: 1.3,
        ),
      ),
    );
  }
}

class ExplicitBadge extends StatelessWidget {
  final ColorScheme colorScheme;

  const ExplicitBadge({super.key, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.metadataExplicitValue;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                borderRadius: context.tokens.borderRadiusBadge,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    'E',
                    style: TextStyle(
                      fontSize: context.tokens.badgeFontSize,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.surface,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ExplicitTrackTitle extends StatelessWidget {
  final String title;
  final bool explicit;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow overflow;
  final ColorScheme? colorScheme;

  const ExplicitTrackTitle({
    super.key,
    required this.title,
    required this.explicit,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title),
          if (explicit)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Transform.translate(
                offset: const Offset(0, -2),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6),
                  child: ExplicitBadge(
                    colorScheme: colorScheme ?? Theme.of(context).colorScheme,
                  ),
                ),
              ),
            ),
        ],
      ),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

class DolbyAtmosBadge extends StatelessWidget {
  final ColorScheme colorScheme;

  const DolbyAtmosBadge({super.key, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      // Sits beside the quality badge, which keeps the only accent role.
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: context.tokens.borderRadiusBadge,
      ),
      child: DolbyAtmosLogo(color: colorScheme.onSurfaceVariant),
    );
  }
}

class DolbyAtmosLogo extends StatelessWidget {
  const DolbyAtmosLogo({
    super.key,
    required this.color,
    this.size = const Size(14, 10),
  });

  final Color color;
  final Size size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Dolby Atmos',
    child: CustomPaint(
      size: size,
      painter: DolbyLogoPainter(color: color),
    ),
  );
}

class DolbyLogoPainter extends CustomPainter {
  final Color color;

  DolbyLogoPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final h = size.height;
    final w = size.width;
    final cy = h / 2;

    final leftPath = Path()
      ..moveTo(w * 0.08, 0)
      ..lineTo(w * 0.08, h)
      ..lineTo(w * 0.20, h)
      ..arcToPoint(
        Offset(w * 0.20, 0),
        radius: Radius.elliptical(w * 0.25, cy),
        clockwise: false,
      )
      ..close();
    canvas.drawPath(leftPath, paint);

    final rightPath = Path()
      ..moveTo(w * 0.92, 0)
      ..lineTo(w * 0.92, h)
      ..lineTo(w * 0.80, h)
      ..arcToPoint(
        Offset(w * 0.80, 0),
        radius: Radius.elliptical(w * 0.25, cy),
        clockwise: true,
      )
      ..close();
    canvas.drawPath(rightPath, paint);
  }

  @override
  bool shouldRepaint(DolbyLogoPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// Keeps artist text and optional track badges responsive on narrow rows.
///
/// A [Row] with a flexible artist still overflows when the badges themselves
/// need more room than remains. [Wrap] moves whole badges to another run while
/// keeping the artist constrained and ellipsized when it alone is too long.
class TrackMetadataBadgesLine extends StatelessWidget {
  const TrackMetadataBadgesLine({
    super.key,
    required this.primary,
    this.badges = const [],
  });

  final Widget primary;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) return primary;

    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: primary,
          ),
          ...badges,
        ],
      ),
    );
  }
}

/// Returns the quality-related badge widgets for a track. Spacing and wrapping
/// belong to [TrackMetadataBadgesLine] so the group stays responsive.
List<Widget> buildQualityBadges({
  required String? audioQuality,
  required String? audioModes,
  required ColorScheme colorScheme,
  bool explicit = false,
}) {
  final badges = <Widget>[];
  if (explicit) {
    badges.add(ExplicitBadge(colorScheme: colorScheme));
  }
  if (audioQuality != null && audioQuality.isNotEmpty) {
    badges.add(
      AudioQualityBadge(label: audioQuality, colorScheme: colorScheme),
    );
  }
  if (audioModes != null && audioModes.contains('DOLBY_ATMOS')) {
    badges.add(DolbyAtmosBadge(colorScheme: colorScheme));
  }
  return badges;
}
