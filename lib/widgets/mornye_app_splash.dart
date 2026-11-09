import 'package:flutter/material.dart';

/// Modern fluid splash animation with the high-definition Mornye badge and neon glow.
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
  late final Animation<double> _glowAnimation;
  late final Animation<double> _fadeAnimation;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.82, end: 1.04)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 65,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.04, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 35,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.65),
      ),
    );

    _glowAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.15, 0.75, curve: Curves.easeInOut),
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.72, 1.0, curve: Curves.easeOutCubic),
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

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final opacity = _fadeAnimation.value;
            if (opacity <= 0.0) return const SizedBox.shrink();

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
                              Container(
                                width: 150,
                                height: 150,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(
                                            alpha: 0.55 * _glowAnimation.value,
                                          ),
                                      Theme.of(context)
                                          .colorScheme
                                          .secondary
                                          .withValues(
                                            alpha: 0.25 * _glowAnimation.value,
                                          ),
                                      Colors.transparent,
                                    ],
                                    stops: const [0.0, 0.5, 1.0],
                                  ),
                                ),
                              ),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: Image.asset(
                                  'assets/brand/logo/png/mornye-badge@4x.png',
                                  width: 96,
                                  height: 96,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Opacity(
                          opacity: _glowAnimation.value.clamp(0.0, 1.0),
                          child: const Text(
                            'M O R N Y E',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 6.0,
                            ),
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
