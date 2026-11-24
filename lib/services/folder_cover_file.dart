import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/download_metadata_embedding.dart';
import 'package:mornye/services/song_folder_file.dart';
import 'package:mornye/utils/file_access.dart';

/// The names an album cover saved to its folder can have, in lower case.
const folderCoverFileNames = {'folder.jpg', 'folder.png'};

/// An album's cover kept as `folder.jpg` in the album's own folder, where
/// players that do not read the cover inside a song look for it. Downloads
/// write it there when the settings ask.
class FolderCoverFile {
  FolderCoverFile({
    SongFolderFile? folder,
    Future<String?> Function(String url, int maxDimension)? download,
  }) : _folder = folder ?? SongFolderFile(),
       _download = download ?? DownloadMetadataEmbedding.downloadCoverFile;

  final SongFolderFile _folder;
  final Future<String?> Function(String url, int maxDimension) _download;

  /// Saves the cover at [url], no larger than [maxDimension] when that is
  /// positive, into the folder holding [song]: a local path, an Android
  /// document in [treeUri]/[relativeDir], or a network song. A cover
  /// already there stays. True when one was written.
  ///
  /// The file is named after what the image is: `folder.jpg`, or
  /// `folder.png` for a PNG cover. Any other image is not saved.
  Future<bool> save(
    String url, {
    required int maxDimension,
    required String song,
    String? treeUri,
    String? relativeDir,
  }) async {
    File? downloaded;
    try {
      return await _folder.save(
        song: song,
        treeUri: treeUri,
        relativeDir: relativeDir,
        content: () async {
          final path = await _download(url, maxDimension);
          if (path == null) return null;
          final file = downloaded = File(path);
          final format = await _format(file);
          if (format == null) return null;
          return (
            file: file,
            name: 'folder.${format.extension}',
            mimeType: format.mimeType,
          );
        },
      );
    } finally {
      if (downloaded != null) await deleteFileQuietly(downloaded!);
    }
  }

  static Future<({String extension, String mimeType})?> _format(
    File file,
  ) async {
    if (!await file.exists()) return null;
    final reader = await file.open();
    try {
      final bytes = await reader.read(4);
      if (bytes.length < 4) return null;
      if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
        return (extension: 'jpg', mimeType: 'image/jpeg');
      }
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47) {
        return (extension: 'png', mimeType: 'image/png');
      }
      return null;
    } finally {
      await reader.close();
    }
  }
}

final folderCoverFileProvider = Provider((ref) => FolderCoverFile());
