part of 'network_library_scanner.dart';

extension on NetworkLibraryScanner {
  /// Writes the rows of a [NetworkVirtualSources] host from the songs it
  /// lists; nothing is read over the network.
  Future<LibraryScanNDJSONFile> _scanVirtual(
    NetworkVirtualSources sources,
    String id, {
    required Future<void> Function() checkpoint,
    required void Function(int, int, String) onProgress,
  }) async {
    await checkpoint();
    File? file;
    RandomAccessFile? output;
    var complete = false;
    try {
      final temp = await Directory(
        '${(await _temporaryDirectory()).path}/network_scans',
      ).create(recursive: true);
      file = File('${temp.path}/${NetworkStorageService.newId()}.ndjson');
      final writer = await _openOutput(file);
      output = writer;
      final buffer = StringBuffer();
      var count = 0;
      var buffered = 0;
      await for (final song in sources.songs(id)) {
        await checkpoint();
        final source = NetworkStorageService.source(id, song.path);
        final entry = NetworkEntry(
          song.path,
          song.path.split('/').last,
          size: song.size,
          modifiedTime: song.modifiedTime,
        );
        final row = networkLibraryRow(source, entry, song.tags);
        row['id'] = 'network_${sha256.convert(utf8.encode(source))}';
        if (song.coverPath != null) row['coverPath'] = song.coverPath;
        buffer.writeln(jsonEncode(row));
        count++;
        buffered++;
        if (buffered >= 64 || buffer.length >= 64 * 1024) {
          await writer.writeString(buffer.toString());
          buffer.clear();
          buffered = 0;
        }
        onProgress(count, 0, row['trackName'] as String);
      }
      if (buffer.isNotEmpty) await writer.writeString(buffer.toString());
      await writer.flush();
      await writer.close();
      output = null;
      await checkpoint();
      complete = true;
      return LibraryScanNDJSONFile(
        file: file,
        expectedCount: count,
        preserveMissingPaths: const [],
      );
    } finally {
      try {
        await output?.close();
      } finally {
        if (!complete && file != null && await file.exists()) {
          await file.delete();
        }
      }
    }
  }
}
