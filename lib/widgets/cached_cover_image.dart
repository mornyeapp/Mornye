import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/utils/image_cache_utils.dart';

class CachedCoverImage extends StatelessWidget {
  static const int _defaultMinCacheExtent = 64;
  static const int _defaultMaxCacheExtent = 512;

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final Widget Function(BuildContext, String)? placeholder;
  final BorderRadius? borderRadius;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;

  const CachedCoverImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.memCacheWidth,
    this.memCacheHeight,
    this.errorWidget,
    this.placeholder,
    this.borderRadius,
    this.fadeInDuration = Duration.zero,
    this.fadeOutDuration = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    if (width != null ||
        height != null ||
        memCacheWidth != null ||
        memCacheHeight != null) {
      return _buildImage(context, const BoxConstraints());
    }
    // Grid cells size their children through constraints rather than explicit
    // width/height. Use those bounds for decoding as well as explicit sizes.
    return LayoutBuilder(
      builder: (context, constraints) => _buildImage(context, constraints),
    );
  }

  Widget _buildImage(BuildContext context, BoxConstraints constraints) {
    var autoMemCacheWidth =
        memCacheWidth ??
        (memCacheHeight == null
            ? _cacheExtentForLogicalSize(context, width)
            : null);
    // ResizeImage stretches the decoded bitmap when both axes are supplied.
    // Keep one decode axis so BoxFit can crop the original proportions.
    var autoMemCacheHeight = autoMemCacheWidth == null
        ? memCacheHeight ?? _cacheExtentForLogicalSize(context, height)
        : null;
    if (autoMemCacheWidth == null && autoMemCacheHeight == null) {
      // Infer one axis to preserve the source aspect ratio and respect any
      // explicit decode override used by large artwork/header consumers.
      autoMemCacheWidth = _cacheExtentForLogicalSize(
        context,
        constraints.maxWidth,
      );
      if (autoMemCacheWidth == null) {
        autoMemCacheHeight = _cacheExtentForLogicalSize(
          context,
          constraints.maxHeight,
        );
      }
    }
    final image = CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      memCacheWidth: autoMemCacheWidth,
      memCacheHeight: autoMemCacheHeight,
      cacheManager: CoverCacheManager.instance,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      useOldImageOnUrlChange: true,
      filterQuality: FilterQuality.low,
      errorWidget: errorWidget,
      placeholder: placeholder,
    );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: image);
    }

    return image;
  }

  static int? _cacheExtentForLogicalSize(BuildContext context, double? size) {
    if (size == null || !size.isFinite || size <= 0) return null;
    final dpr = MediaQuery.devicePixelRatioOf(
      context,
    ).clamp(1.0, 3.0).toDouble();
    return (size * dpr)
        .round()
        .clamp(_defaultMinCacheExtent, _defaultMaxCacheExtent)
        .toInt();
  }
}

/// Renders a stored cover string in any form: an http(s) URL as a cached
/// network image, an absolute path or `file://` URI from disk, and other
/// forms as the shared [placeholder], which also serves the local error
/// state, the local not-ready frame, and the network placeholder/error
/// states alike.
class LocalOrNetworkCoverImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final int? localCacheWidth;
  final int? networkCacheWidth;
  final Duration? fadeInDuration;
  final Duration fadeOutDuration;
  final String Function(String)? urlTransform;
  final Widget Function(BuildContext) placeholder;

  const LocalOrNetworkCoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.localCacheWidth,
    this.networkCacheWidth,
    this.fadeInDuration,
    this.fadeOutDuration = Duration.zero,
    this.urlTransform,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    if (isHttpCoverUrl(url)) {
      return CachedCoverImage(
        imageUrl: urlTransform?.call(url) ?? url,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: networkCacheWidth,
        borderRadius: borderRadius,
        fadeInDuration: fadeInDuration ?? Duration.zero,
        fadeOutDuration: fadeOutDuration,
        placeholder: (_, _) => placeholder(context),
        errorWidget: (_, _, _) => placeholder(context),
      );
    }

    final path = coverFilePath(url);
    if (path == null) return _clip(placeholder(context));
    final file = File(path);
    if (localCacheWidth != null) {
      return _buildLocalImage(context, file, const BoxConstraints());
    }
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildLocalImage(context, file, constraints),
    );
  }

  Widget _clip(Widget child) => borderRadius == null
      ? child
      : ClipRRect(borderRadius: borderRadius!, child: child);

  Widget _buildLocalImage(
    BuildContext context,
    File file,
    BoxConstraints constraints,
  ) {
    final ImageProvider provider;
    if (localCacheWidth != null) {
      provider = ResizeImage(FileImage(file), width: localCacheWidth);
    } else {
      final decodeWidth = _localDecodeExtent(
        context,
        constraints.constrainWidth(width ?? double.infinity),
      );
      final decodeHeight = _localDecodeExtent(
        context,
        constraints.constrainHeight(height ?? double.infinity),
      );
      provider = decodeWidth == null && decodeHeight == null
          ? FileImage(file)
          : _FittedLocalFileImage(
              file,
              width: decodeWidth,
              height: decodeHeight,
              fit: fit,
            );
    }
    final image = Image(
      image: provider,
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
      frameBuilder: fadeInDuration == null
          ? null
          : (context, child, frame, wasSynchronouslyLoaded) {
              final ready = wasSynchronouslyLoaded || frame != null;
              if (fadeInDuration == Duration.zero) {
                return ready ? child : placeholder(context);
              }
              // The image defines the cover's size even when a track row
              // gives its leading widget unbounded constraints.
              return Stack(
                fit: StackFit.passthrough,
                children: [
                  Positioned.fill(child: placeholder(context)),
                  AnimatedOpacity(
                    opacity: ready ? 1.0 : 0.0,
                    duration: fadeInDuration!,
                    curve: Curves.easeOutCubic,
                    child: child,
                  ),
                ],
              );
            },
      errorBuilder: (_, _, _) => placeholder(context),
    );
    return _clip(image);
  }

  static int? _localDecodeExtent(BuildContext context, double? size) {
    if (size == null || !size.isFinite || size <= 0) return null;
    return (size * MediaQuery.devicePixelRatioOf(context)).ceil();
  }
}

/// Lets Flutter read intrinsic dimensions before choosing the decode size.
/// FileImage still owns file loading, codec creation and image lifecycle.
class _FittedLocalFileImage extends FileImage {
  final int? width;
  final int? height;
  final BoxFit fit;

  const _FittedLocalFileImage(
    super.file, {
    required this.width,
    required this.height,
    required this.fit,
  });

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    return super.loadImage(key, (buffer, {getTargetSize}) {
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final double ratio;
          if (width != null && height != null) {
            final fitted = applyBoxFit(
              fit,
              Size(intrinsicWidth.toDouble(), intrinsicHeight.toDouble()),
              Size(width!.toDouble(), height!.toDouble()),
            );
            ratio = math.max(
              fitted.destination.width / fitted.source.width,
              fitted.destination.height / fitted.source.height,
            );
          } else if (fit == BoxFit.none) {
            ratio = 1;
          } else {
            ratio = width != null
                ? width! / intrinsicWidth
                : height! / intrinsicHeight;
          }
          // Never enlarge the decoded source. Cover uses the cropped source
          // dimensions above, retaining enough pixels along both display axes.
          final scale = ratio.clamp(0.0, 1.0);
          return ui.TargetImageSize(
            width: (intrinsicWidth * scale).ceil().clamp(1, intrinsicWidth),
            height: (intrinsicHeight * scale).ceil().clamp(1, intrinsicHeight),
          );
        },
      );
    });
  }

  @override
  bool operator ==(Object other) =>
      other is _FittedLocalFileImage &&
      super == other &&
      width == other.width &&
      height == other.height &&
      fit == other.fit;

  @override
  int get hashCode => Object.hash(super.hashCode, width, height, fit);
}

CachedNetworkImageProvider cachedCoverImageProvider(String url) {
  return CachedNetworkImageProvider(
    url,
    cacheManager: CoverCacheManager.instance,
  );
}

/// Whether a stored cover string is an http(s) URL, which loads through
/// [CoverCacheManager].
bool isHttpCoverUrl(String? source) =>
    source != null &&
    (source.startsWith('http://') || source.startsWith('https://'));

/// The local file a stored cover string names: an absolute path or a
/// `file://` URI. Null for URLs, `content://` URIs and other forms.
String? coverFilePath(String? source) {
  if (source == null || source.isEmpty) return null;
  if (source.startsWith('file://')) {
    try {
      return Uri.parse(source).toFilePath();
    } on FormatException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }
  // The cover store's saved file for a `network://` cover plugs in here.
  // Widgets and palettes call this during build, so that lookup must read
  // only the store's in-memory index, without file IO.
  if (source.startsWith('network://')) return null;
  return p.isAbsolute(source) ? source : null;
}

/// What the cover widgets, precaching and palettes decode for a stored cover
/// string: an http(s) URL as it is, a local file as its path, so every form
/// of one cover shares its cache entries. Null when the form has no image.
String? coverImageSource(String? source) =>
    isHttpCoverUrl(source) ? source : coverFilePath(source);

/// The image of a stored cover string in any form, keyed like the cover
/// widgets' own decode and resized as `Image.file` does with [cacheWidth]
/// and [cacheHeight]. Null when the form has no image.
ImageProvider<Object>? coverImageProvider(
  String? source, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  final ImageProvider<Object> provider;
  if (isHttpCoverUrl(source)) {
    provider = cachedCoverImageProvider(source!);
  } else {
    final path = coverFilePath(source);
    if (path == null) return null;
    provider = FileImage(File(path));
  }
  return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, provider);
}

/// Chooses one artwork source for both the Metadata foreground cover and its
/// blurred backdrop. Embedded file artwork is authoritative for downloaded
/// tracks; local scan artwork is next, with remote metadata only as fallback.
String? resolveMetadataArtworkSource({
  String? embeddedCoverPath,
  String? localCoverPath,
  String? remoteCoverUrl,
}) {
  for (final candidate in [embeddedCoverPath, localCoverPath, remoteCoverUrl]) {
    final normalized = candidate?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  return null;
}

/// Decode size shared by Track Metadata's blurred backdrop and its prewarm.
/// The backdrop is heavily blurred, so a modest square bitmap is sufficient
/// and avoids allocating a second full-viewport image beside the Hero cover.
int metadataBackdropCacheExtent(BuildContext context) {
  final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
  final logicalWidth = MediaQuery.sizeOf(context).width;
  return (logicalWidth * dpr * 0.35).round().clamp(192, 384).toInt();
}

/// Warms the exact resized image used by Track Metadata's blurred backdrop.
/// Navigation waits for the common memory/disk-cache path, but a bounded budget
/// prevents a cold network request from delaying the route for too long.
Future<void> precacheMetadataBackdrop(
  BuildContext context,
  String? source,
) async {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) return;

  final extent = metadataBackdropCacheExtent(context);
  final provider = coverImageProvider(
    normalized,
    cacheWidth: extent,
    cacheHeight: isHttpCoverUrl(normalized) ? null : extent,
  );
  if (provider == null) return;
  try {
    await precacheImage(
      provider,
      context,
      onError: (_, _) {},
    ).timeout(const Duration(milliseconds: 200));
  } catch (_) {}
}

/// Pre-warms the cover cache at the metadata-screen display size so the hero
/// transition doesn't pop in a low-res frame.
void precacheCoverImage(BuildContext context, String? url) {
  if (url == null || url.isEmpty) return;
  final provider = coverImageProvider(
    url,
    cacheWidth: coverCacheWidthForViewport(context),
  );
  if (provider == null) return;
  // A stale local path is common and its placeholder already covers it; only
  // a failed download still reaches the app's error handler.
  precacheImage(
    provider,
    context,
    onError: isHttpCoverUrl(url) ? null : (_, _) {},
  );
}
