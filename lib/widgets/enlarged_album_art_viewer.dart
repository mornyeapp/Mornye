import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/routes/now_playing_route.dart'
    show kNowPlayingArtworkHeroTag;
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

/// Shows an enlarged inspection viewer for song/album artwork with
/// interactive 3D parallax tilt, pinch-to-zoom, and smooth hero transitions.
Future<void> showEnlargedAlbumArt(
  BuildContext context, {
  required String? artUri,
  String? title,
  String? artist,
  Object? heroTag = kNowPlayingArtworkHeroTag,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, secondaryAnimation) =>
          EnlargedAlbumArtViewer(
            artUri: artUri,
            title: title,
            artist: artist,
            heroTag: heroTag,
          ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class EnlargedAlbumArtViewer extends StatefulWidget {
  const EnlargedAlbumArtViewer({
    super.key,
    required this.artUri,
    this.title,
    this.artist,
    this.heroTag = kNowPlayingArtworkHeroTag,
  });

  final String? artUri;
  final String? title;
  final String? artist;
  final Object? heroTag;

  @override
  State<EnlargedAlbumArtViewer> createState() => _EnlargedAlbumArtViewerState();
}

class _EnlargedAlbumArtViewerState extends State<EnlargedAlbumArtViewer>
    with SingleTickerProviderStateMixin {
  static const double _maxTiltRadians = 0.22; // ~12.6 degrees

  late final AnimationController _springController;
  late Animation<Offset> _springAnimation;
  final TransformationController _transformController =
      TransformationController();

  Offset _tilt = Offset.zero;
  double _dismissDragOffsetY = 0.0;
  bool _isDragging = false;

  bool get _isZoomed => _transformController.value.getMaxScaleOnAxis() > 1.05;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _springAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(_springController);
    _springController.addListener(() {
      setState(() {
        _tilt = _springAnimation.value;
      });
    });
  }

  @override
  void dispose() {
    _springController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  void _springBackToCenter() {
    if (_springController.isAnimating) _springController.stop();
    _springAnimation = Tween<Offset>(begin: _tilt, end: Offset.zero).animate(
      CurvedAnimation(parent: _springController, curve: Curves.easeOutCubic),
    );
    _springController.forward(from: 0);
  }

  void _handleHover(PointerHoverEvent event) {
    if (_isZoomed || _isDragging) return;
    final size = MediaQuery.sizeOf(context);
    final normX = ((event.localPosition.dx - size.width / 2) / (size.width / 2))
        .clamp(-1.0, 1.0);
    final normY =
        ((event.localPosition.dy - size.height / 2) / (size.height / 2)).clamp(
          -1.0,
          1.0,
        );
    setState(() {
      _tilt = Offset(normX, normY);
    });
  }

  void _handleMouseExit(PointerExitEvent event) {
    if (_isZoomed) return;
    _springBackToCenter();
  }

  Widget _buildArtworkImage(double size) {
    final uri = widget.artUri;
    if (uri == null || uri.isEmpty) {
      return Container(
        width: size,
        height: size,
        color: const Color(0xFF222222),
        child: const Icon(Icons.album, size: 96, color: Colors.white54),
      );
    }

    if (uri.startsWith('file://')) {
      return Image.file(
        File(Uri.parse(uri).toFilePath()),
        fit: BoxFit.contain,
        width: size,
        height: size,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _fallbackPlaceholder(size),
      );
    }

    if (uri.startsWith('/') ||
        uri.startsWith(r'\\') ||
        (uri.length > 2 && uri[1] == ':')) {
      return Image.file(
        File(uri),
        fit: BoxFit.contain,
        width: size,
        height: size,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _fallbackPlaceholder(size),
      );
    }

    return LocalOrNetworkCoverImage(
      url: uri,
      fit: BoxFit.contain,
      width: size,
      height: size,
      placeholder: (_) => _fallbackPlaceholder(size),
    );
  }

  Widget _fallbackPlaceholder(double size) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFF222222),
      child: const Icon(Icons.music_note, size: 96, color: Colors.white54),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final artSize = (screenSize.shortestSide * 0.85).clamp(260.0, 480.0);

    // 3D Perspective Transformation Matrix
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.001) // perspective projection
      ..rotateX(-_tilt.dy * _maxTiltRadians) // tilt vertical
      ..rotateY(_tilt.dx * _maxTiltRadians); // tilt horizontal

    // Dynamic drop shadow offset reacts to 3D tilt
    final shadowOffset = Offset(-_tilt.dx * 30, 20 - _tilt.dy * 30);

    // Dynamic specular reflection follows the light source opposite to tilt
    final glareAlignment = Alignment(-_tilt.dx * 1.6, -_tilt.dy * 1.6);

    Widget artCard = Container(
      width: artSize,
      height: artSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 40,
            spreadRadius: 2,
            offset: shadowOffset,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildArtworkImage(artSize),
            // Interactive 3D specular highlight / glare layer
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: glareAlignment,
                      radius: 1.2,
                      colors: [
                        Colors.white.withValues(
                          alpha: (0.18 * (_tilt.distance.clamp(0.0, 1.0)))
                              .clamp(0.0, 0.25),
                        ),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.8],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.heroTag != null) {
      artCard = Hero(tag: widget.heroTag!, child: artCard);
    }

    final dismissProgress = (_dismissDragOffsetY / 300.0).clamp(0.0, 0.6);
    final backgroundOpacity = (0.85 - dismissProgress).clamp(0.0, 0.85);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: MouseRegion(
        onHover: _handleHover,
        onExit: _handleMouseExit,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          onPanStart: (_) {
            _isDragging = true;
            if (_springController.isAnimating) _springController.stop();
          },
          onPanUpdate: (details) {
            if (_isZoomed) return;
            final normX =
                ((details.localPosition.dx - screenSize.width / 2) /
                        (screenSize.width / 2))
                    .clamp(-1.0, 1.0);
            final normY =
                ((details.localPosition.dy - screenSize.height / 2) /
                        (screenSize.height / 2))
                    .clamp(-1.0, 1.0);
            setState(() {
              _tilt = Offset(normX, normY);
              if (details.delta.dy > 0 || _dismissDragOffsetY > 0) {
                _dismissDragOffsetY = (_dismissDragOffsetY + details.delta.dy)
                    .clamp(0.0, 600.0);
              }
            });
          },
          onPanEnd: (details) {
            _isDragging = false;
            if (_dismissDragOffsetY > 100 ||
                details.velocity.pixelsPerSecond.dy > 600) {
              Navigator.of(context).pop();
            } else {
              setState(() {
                _dismissDragOffsetY = 0.0;
              });
              _springBackToCenter();
            }
          },
          onPanCancel: () {
            _isDragging = false;
            setState(() {
              _dismissDragOffsetY = 0.0;
            });
            _springBackToCenter();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Frosted dark background
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: backgroundOpacity),
                ),
              ),

              // Close button at top right
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: IconButton.filled(
                      key: const Key('close-enlarged-art'),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.15),
                        foregroundColor: Colors.white,
                      ),
                      icon: const AppIcon(Icons.close, size: 24),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),

              // Central interactive 3D Tilt Card with Pinch to Zoom
              Center(
                child: Transform.translate(
                  offset: Offset(0, _dismissDragOffsetY),
                  child: Transform(
                    alignment: FractionalOffset.center,
                    transform: matrix,
                    child: InteractiveViewer(
                      transformationController: _transformController,
                      minScale: 1.0,
                      maxScale: 4.0,
                      clipBehavior: Clip.none,
                      onInteractionEnd: (_) {
                        if (!_isZoomed) {
                          _springBackToCenter();
                        }
                      },
                      child: artCard,
                    ),
                  ),
                ),
              ),

              // Title and Artist header at the bottom
              if (widget.title != null || widget.artist != null)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        bottom: 24,
                        left: 24,
                        right: 24,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.title != null)
                                  Text(
                                    widget.title!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                if (widget.artist != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.artist!,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.75,
                                      ),
                                      fontSize: 14,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
