import 'dart:typed_data';

/// Represents a remote or local file entry returned by [SyncStorageDriver].
class SyncFileEntry {
  const SyncFileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedTime,
    this.etag,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int? size;
  final int? modifiedTime;
  final String? etag;

  @override
  String toString() =>
      'SyncFileEntry(name: $name, isDir: $isDirectory, size: $size, etag: $etag)';
}

/// Abstract storage driver for reading and writing sync partitions across
/// local directories and WebDAV endpoints.
abstract class SyncStorageDriver {
  /// Checks whether the storage backend is reachable, mounted, or authenticated.
  Future<bool> isAvailable();

  /// Enumerates files and subdirectories in a directory path.
  Future<List<SyncFileEntry>> listFiles(String path);

  /// Fetches metadata (etag, size, modifiedTime) for a single file or directory.
  Future<SyncFileEntry?> stat(String path);

  /// Reads full file contents as raw bytes.
  Future<Uint8List> readFile(String path);

  /// Reads full file contents as a UTF-8 string.
  Future<String> readText(String path);

  /// Writes file contents atomically. If [overwrite] is true, replaces existing target.
  Future<void> writeFile(String path, Uint8List data, {bool overwrite = true});

  /// Writes string contents atomically.
  Future<void> writeText(String path, String text, {bool overwrite = true});

  /// Deletes a file.
  Future<void> deleteFile(String path);

  /// Deletes a directory and its contents recursively.
  Future<void> deleteDirectory(String path);

  /// Creates a directory hierarchy if not already present.
  Future<void> createDirectory(String path);
}
