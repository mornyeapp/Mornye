import 'dart:typed_data';
import 'dart:ui' as ui;

/// The longer side of a shrunk cover, as the Library's own thumbnails.
const linkShrunkCoverSize = 800;

/// A smaller copy of a cover's image; null when it cannot be made.
typedef LinkCoverShrinker = Future<Uint8List?> Function(Uint8List image);

/// [image] as a PNG at most [linkShrunkCoverSize] pixels on its longer
/// side, keeping its shape; null when it cannot be decoded. Stores and
/// embedded art are often 3000 to 6000 pixels and several megabytes.
Future<Uint8List?> shrinkLinkCover(Uint8List image) async {
  const size = linkShrunkCoverSize;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    // The codec takes the buffer and disposes of it.
    codec = await ui.instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromUint8List(image),
      getTargetSize: (width, height) {
        if (width <= size && height <= size) return ui.TargetImageSize();
        return width >= height
            ? ui.TargetImageSize(width: size)
            : ui.TargetImageSize(height: size);
      },
    );
    frame = (await codec.getNextFrame()).image;
    final png = await frame.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } on Object {
    return null;
  } finally {
    frame?.dispose();
    codec?.dispose();
  }
}
