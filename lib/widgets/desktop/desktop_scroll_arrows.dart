import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_glass_press.dart';

/// Builds a horizontal list that scrolls with [controller].
typedef DesktopScrollArrowsBuilder =
    Widget Function(BuildContext context, ScrollController controller);

/// Back and forward buttons over a horizontal list on desktop, shown while
/// the pointer is over it and more content lies in that direction.
///
/// A mouse wheel only scrolls vertically and mouse drags do not scroll, so
/// without them a mouse user cannot reach the rest of a shelf. Phones and
/// tablets get the list unchanged.
class DesktopScrollArrows extends StatefulWidget {
  const DesktopScrollArrows({super.key, required this.builder});

  final DesktopScrollArrowsBuilder builder;

  @override
  State<DesktopScrollArrows> createState() => _DesktopScrollArrowsState();
}

class _DesktopScrollArrowsState extends State<DesktopScrollArrows> {
  final _controller = ScrollController();
  // Hovering shows the arrows alone; the list and its cards keep their build.
  final _hovered = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hovered.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target =
        (position.pixels + direction * position.viewportDimension * 0.8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.builder(context, _controller);
    if (!isDesktopPlatform) return list;
    return MouseRegion(
      onEnter: (_) => _hovered.value = true,
      onExit: (_) => _hovered.value = false,
      child: Stack(
        children: [
          list,
          // A zero-size child paints and hits nothing, as no child did.
          ValueListenableBuilder<bool>(
            valueListenable: _hovered,
            builder: (context, hovered, _) {
              if (context.isMornye) {
                return _ArrowsFade(hovered: hovered, child: _arrows(context));
              }
              return hovered ? _arrows(context) : const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Widget _arrows(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final position = _controller.hasClients ? _controller.position : null;
      final ready = position != null && position.hasContentDimensions;
      return Stack(
        children: [
          if (ready && position.extentBefore > 0)
            _arrow(context, forward: false),
          if (ready && position.extentAfter > 0) _arrow(context, forward: true),
        ],
      );
    },
  );

  Widget _arrow(BuildContext context, {required bool forward}) {
    final l10n = context.l10n;
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = forward
        ? (mornye ? CupertinoIcons.forward : Icons.chevron_right)
        : (mornye ? CupertinoIcons.back : Icons.chevron_left);
    if (mornye) {
      // Music's tall glass paddle, close to the edge of the shelf.
      return PositionedDirectional(
        start: forward ? null : 6,
        end: forward ? 6 : null,
        top: 0,
        bottom: 0,
        child: Center(
          child: Tooltip(
            message: forward
                ? l10n.desktopScrollForward
                : l10n.desktopScrollBack,
            child: SizedBox(
              width: 28,
              height: 52,
              child: MornyeGlassPress(
                radius: 14,
                child: MornyeGlassPanel(
                  radius: 14,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: () => _page(forward ? 1 : -1),
                      splashFactory: NoSplash.splashFactory,
                      hoverColor: colorScheme.onSurface.withValues(alpha: 0.06),
                      highlightColor: colorScheme.onSurface.withValues(
                        alpha: 0.12,
                      ),
                      child: Center(
                        child: Icon(
                          icon,
                          size: 16,
                          color: colorScheme.onSurface,
                        ),
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
    return PositionedDirectional(
      start: forward ? null : 8,
      end: forward ? 8 : null,
      top: 0,
      bottom: 0,
      child: Center(
        child: Tooltip(
          message: forward ? l10n.desktopScrollForward : l10n.desktopScrollBack,
          child: Material(
            color: colorScheme.secondaryContainer,
            shape: const CircleBorder(),
            elevation: 2,
            shadowColor: Colors.black38,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _page(forward ? 1 : -1),
              child: SizedBox.square(
                dimension: 40,
                child: Icon(
                  icon,
                  size: 24,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades Mornye's arrows in and out with the pointer, building them only
/// while they show so a shelf at rest stays free of scroll listeners.
class _ArrowsFade extends StatefulWidget {
  const _ArrowsFade({required this.hovered, required this.child});

  final bool hovered;
  final Widget child;

  @override
  State<_ArrowsFade> createState() => _ArrowsFadeState();
}

class _ArrowsFadeState extends State<_ArrowsFade> {
  late bool _shown = widget.hovered;

  @override
  void didUpdateWidget(_ArrowsFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hovered) _shown = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !widget.hovered,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: widget.hovered ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 250),
        onEnd: () {
          if (!widget.hovered) setState(() => _shown = false);
        },
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity, child: child),
        child: widget.child,
      ),
    );
  }
}
