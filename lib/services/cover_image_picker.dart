import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/metadata_cover_resources.dart';

/// An image picked on the device, copied into [MetadataCoverResources], with
/// the picked file's name.
typedef PickedCoverImage = ({MetadataCoverPreview preview, String name});

typedef CoverImagePicker =
    Future<PickedCoverImage?> Function(MetadataCoverResources covers);

/// Lets the person pick an image and copies it into [covers]; null when
/// nothing was picked.
Future<PickedCoverImage?> pickCoverImage(MetadataCoverResources covers) async {
  final picked = await FilePicker.pickFile(type: FileType.image);
  if (picked == null) return null;
  final sourcePath = picked.path;
  final hasPath = sourcePath != null && sourcePath.trim().isNotEmpty;
  final bytes = hasPath ? null : await picked.readAsBytes();
  final extension = coverImageExtension(
    p.extension(picked.name).replaceFirst('.', ''),
    bytes,
  );
  final preview = await covers.copyPicked(
    extension: extension,
    sourcePath: sourcePath,
    bytes: bytes,
  );
  return (preview: preview, name: picked.name);
}

/// The file extension for a picked image, from its name or its first bytes.
String coverImageExtension(String? ext, Uint8List? bytes) {
  final normalized = (ext ?? '').toLowerCase();
  if (normalized == 'png' ||
      normalized == 'jpg' ||
      normalized == 'jpeg' ||
      normalized == 'webp') {
    return normalized == 'jpeg' ? 'jpg' : normalized;
  }
  if (bytes != null && bytes.length >= 8) {
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
  }
  return 'jpg';
}
