import 'package:flutter/material.dart';
import 'package:mornye/theme/app_theme.dart';

/// Modern fluid splash animation with sonic ripple waves, high-definition
/// Mornye liquid badge, and modern geometric studio typography.
class MornyeAppSplash extends StatefulWidget {
  final Widget child;

  const MornyeAppSplash({super.key, required this.child});

  @override
  State<MornyeAppSplash> createState() => _MornyeAppSplashState();
}

class _MornyeAppSplashState extends State<MornyeAppSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _rippleAnimation;
  late final Animation<double> _fadeAnimation;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.84, end: 1.05)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.05, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 40,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.70),
      ),
    );

    _rippleAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.10, 0.85, curve: Curves.easeOutQuad),
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.75, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) {
          setState(() => _dismissed = true);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        setState(() => _dismissed = true);
      } else {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return widget.child;

    final primary = Theme.of(context).colorScheme.primary;
    final secondary = Theme.of(context).colorScheme.secondary;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final opacity = _fadeAnimation.value;
            if (opacity <= 0.0) return const SizedBox.shrink();

            final rippleVal = _rippleAnimation.value;

            return IgnorePointer(
              ignoring: opacity < 0.2,
              child: Opacity(
                opacity: opacity,
                child: ColoredBox(
                  color: const Color(0xFF000000), // OLED black
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Transform.scale(
                          scale: _scaleAnimation.value,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Sonic wave ripple rings
                              CustomPaint(
                                size: const Size(260, 260),
                                painter: _SonicRipplePainter(
                                  progress: rippleVal,
                                  primaryColor: primary,
                                  secondaryColor: secondary,
                                ),
                              ),
                              // Frosted liquid glass container for badge
                              Container(
                                width: 104,
                                height: 104,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(26),
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Colors.white.withValues(alpha: 0.16),
                                      Colors.white.withValues(alpha: 0.04),
                                    ],
                                  ),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.25),
                                    width: 1.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: primary.withValues(
                                        alpha: 0.35 * (1.0 - rippleVal * 0.4),
                                      ),
                                      blurRadius: 36,
                                      spreadRadius: 4,
                                    ),
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.5),
                                      blurRadius: 16,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
                                  child: Image.asset(
                                    'assets/brand/logo/png/mornye-badge@4x.png',
                                    width: 96,
                                    height: 96,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                        // Modern Studio Typography
                        Opacity(
                          opacity: rippleVal.clamp(0.0, 1.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'M O R N Y E',
                                style: TextStyle(
                                  fontFamily: AppTheme.bundledFontFamily,
                                  color: Colors.white,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 9.0,
                                  shadows: [
                                    Shadow(
                                      color: primary.withValues(alpha: 0.6),
                                      blurRadius: 20,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'S T U D I O   S O U N D',
                                style: TextStyle(
                                  fontFamily: AppTheme.bundledFontFamily,
                                  color: primary.withValues(alpha: 0.85),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 4.5,
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
        ),
      ],
    );
  }
}

class _SonicRipplePainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  const _SonicRipplePainter({
    required this.progress,
    required this.primaryColor,
    required this.secondaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Draw 3 expanding concentric harmonic wave rings
    for (var i = 0; i < 3; i++) {
      final ringProgress = (progress - (i * 0.18)).clamp(0.0, 1.0);
      if (ringProgress <= 0.0 || ringProgress >= 1.0) continue;

      final radius = 55.0 + (maxRadius - 55.0) * ringProgress;
      final opacity = (1.0 - ringProgress) * (0.45 - (i * 0.10));

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (2.4 - (ringProgress * 1.4)).clamp(0.8, 2.4)
        ..color = Color.lerp(primaryColor, secondaryColor, ringProgress)!
            .withValues(alpha: opacity.clamp(0.0, 1.0));

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SonicRipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.primaryColor != primaryColor ||
      oldDelegate.secondaryColor != secondaryColor;
}
