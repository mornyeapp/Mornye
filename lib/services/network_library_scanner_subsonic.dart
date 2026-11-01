part of 'network_library_scanner.dart';

extension on NetworkLibraryScanner {
  Future<LibraryScanNDJSONFile> _scanSubsonic(
    NetworkConnection connection, {
    required bool forceFullScan,
    required Future<void> Function() checkpoint,
    required void Function(int, int, String) onProgress,
  }) async {
    await checkpoint();
    final client = _storage.openSubsonic(connection);
    _activeSubsonic = client;
    File? file;
    RandomAccessFile? output;
    var complete = false;
    try {
      final temp = await Directory(
        '${(await _temporaryDirectory()).path}/network_scans',
      ).create(recursive: true);
      final covers = await Directory(
        '${(await _supportDirectory()).path}/library_covers',
      ).create(recursive: true);
      file = File('${temp.path}/${NetworkStorageService.newId()}.ndjson');
      final writer = await _openOutput(file);
      output = writer;
      final buffer = StringBuffer();
      final artwork = <String, String?>{};
      final started = DateTime.now();
      var count = 0;
      var buffered = 0;
      await for (final song in client.catalog(checkpoint: checkpoint)) {
        await checkpoint();
        String? cover;
        if (song.coverId.isNotEmpty) {
          if (!artwork.containsKey(song.coverId)) {
            // A search3 catalog keeps no album's songs together.
            if (artwork.length >= 20000) artwork.remove(artwork.keys.first);
            try {
              artwork[song.coverId] = await client.cachedCover(
                song,
                covers,
                refresh: forceFullScan,
              );
            } catch (_) {
              await checkpoint();
              artwork[song.coverId] = null;
              _log.w('Subsonic artwork unavailable during library sync');
            }
          }
          cover = artwork[song.coverId];
        }
        await checkpoint();
        final source = NetworkStorageService.source(connection.id, song.path);
        final row = networkLibraryRow(source, song.entry, song.metadata);
        row['id'] = 'network_${sha256.convert(utf8.encode(source))}';
        if (client.catalogNewestFirst) {
          // The Library sorts latest by scannedAt: keep the server's order.
          row['scannedAt'] = started
              .subtract(Duration(milliseconds: count))
              .toIso8601String();
        }
        if (cover != null) row['coverPath'] = cover;
        buffer.writeln(jsonEncode(row));
        count++;
        buffered++;
        if (buffered >= 64 || buffer.length >= 64 * 1024) {
          await writer.writeString(buffer.toString());
          buffer.clear();
          buffered = 0;
        }
        onProgress(count, 0, song.title);
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
      client.close();
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
