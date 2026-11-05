part of 'network_storage_service.dart';

extension NetworkStorageEdit on NetworkStorageService {
  /// Protocol capability only. Share permissions are checked by the server.
  Future<bool> canEditFile(String source) => canDeleteFile(source);

  Future<bool> editableFileExists(String source) async {
    final location = await _deletionLocation(source);
    if (location == null) {
      throw const FormatException('File editing requires SMB or WebDAV');
    }
    final parent = location.path.substring(
      0,
      location.path.lastIndexOf('/') + 1,
    );
    return (await list(
      location.connection,
      parent,
    )).any((entry) => entry.path == location.path && !entry.directory);
  }

  Future<void> _moveEditedFile(
    NetworkConnection connection,
    String from,
    String to,
  ) async {
    if (connection.protocol == NetworkProtocol.webdav) {
      await _uploadCommand(
        connection,
        'MOVE',
        from,
        headers: {
          'Destination': networkTarget(connection, to).toString(),
          'Overwrite': 'F',
        },
      );
      return;
    }
    final smb = await _smb(connection, networkTarget(connection, from));
    try {
      final destination = networkTarget(
        connection,
        to,
      ).pathSegments.where((segment) => segment.isNotEmpty).skip(1).join('/');
      await smb.rename(smb.path, destination);
    } finally {
      await smb.close();
    }
  }

  /// Uploads completely before moving the original aside. A failed replacement
  /// restores the original; an uncertain rollback keeps its recovery copy.
  /// The original must still match the file downloaded before editing.
  Future<void> replaceFile(
    String source,
    File edited, {
    required File original,
  }) async {
    final location = await _deletionLocation(source);
    if (location == null) {
      throw const FormatException('File editing requires SMB or WebDAV');
    }
    final (:connection, :path) = location;
    final parent = path.substring(0, path.lastIndexOf('/') + 1);
    final entry = (await list(
      connection,
      parent,
    )).where((entry) => entry.path == path && !entry.directory).firstOrNull;
    if (entry == null) throw const FileSystemException('File is unavailable');
    final token = NetworkStorageService.newId();
    final staging = '$parent.mornye-edit-$token.part';
    final backup = '$parent.mornye-original-$token.part';
    final stagingSource = NetworkStorageService.source(connection.id, staging);
    final backupSource = NetworkStorageService.source(connection.id, backup);
    final editedLength = await edited.length();
    if (editedLength <= 0) throw StateError('Edited audio file is empty');
    bool movedOriginal = false;
    bool committed = false;

    Future<bool> exists(String name) async => (await list(
      connection,
      parent,
    )).any((entry) => entry.path == name && !entry.directory);

    Future<void> discard(String name) async {
      await deleteFile(NetworkStorageService.source(connection.id, name));
    }

    try {
      await publishUpload(
        stagingSource,
        edited,
        token,
        checkpoint: () {},
        progress: (_, _) {},
      );
      if (!await _matchesUpload(
        source,
        original,
        await original.length(),
        () {},
      )) {
        throw StateError('The network file changed while it was being edited');
      }
      try {
        await _moveEditedFile(connection, path, backup);
        movedOriginal = true;
      } catch (_) {
        // A server can finish a rename before its connection drops.
        movedOriginal = await exists(backup) && !await exists(path);
        if (!movedOriginal) rethrow;
      }
      // Verify what the rename actually moved, since another editor can write
      // after the source check. Roll back instead of deleting that new version.
      if (!await _matchesUpload(
        backupSource,
        original,
        await original.length(),
        () {},
      )) {
        throw StateError('The network file changed while it was being edited');
      }
      try {
        await _moveEditedFile(connection, staging, path);
        committed = true;
      } catch (_) {
        committed = await _matchesUpload(source, edited, editedLength, () {});
        if (!committed) rethrow;
      }
    } finally {
      if (movedOriginal && !committed) {
        try {
          if (!await exists(path)) {
            await _moveEditedFile(connection, backup, path);
          }
        } catch (error) {
          NetworkStorageService._log.w(
            'Could not restore network file; recovery copy: $backup: $error',
          );
        }
      }
      for (final name in [staging, if (committed) backup]) {
        try {
          await discard(name);
        } catch (error) {
          NetworkStorageService._log.w(
            'Could not clean up a network edit temporary file: $error',
          );
        }
      }
    }
  }
}
