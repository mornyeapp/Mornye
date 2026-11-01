import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Preserves enough source pixels for a square cover crop of [extent] pixels.
class ExtensionIconImage extends ImageProvider<(Type, Object, int)> {
  const ExtensionIconImage(this.imageProvider, {required this.extent})
    : assert(extent > 0);

  final ImageProvider<Object> imageProvider;
  final int extent;

  @override
  Future<(Type, Object, int)> obtainKey(ImageConfiguration configuration) =>
      imageProvider
          .obtainKey(configuration)
          .then((key) => (ExtensionIconImage, key, extent));

  @override
  ImageStreamCompleter loadImage(
    (Type, Object, int) key,
    ImageDecoderCallback decode,
  ) {
    final completer = imageProvider.loadImage(key.$2, (
      buffer, {
      getTargetSize,
    }) {
      assert(getTargetSize == null);
      return decode(
        buffer,
        getTargetSize: (width, height) {
          final scale = (extent / math.min(width, height)).clamp(0.0, 1.0);
          return ui.TargetImageSize(
            width: (width * scale).ceil().clamp(1, width),
            height: (height * scale).ceil().clamp(1, height),
          );
        },
      );
    });
    completer.addEphemeralErrorListener((error, stackTrace) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is ExtensionIconImage &&
      imageProvider == other.imageProvider &&
      extent == other.extent;

  @override
  int get hashCode => Object.hash(imageProvider, extent);
}
