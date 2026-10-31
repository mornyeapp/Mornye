import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/desktop_platform.dart';

const _extensionMasterKeyName = 'extension_storage_master_key_v2';
const _localMasterKeyFileName = '.master_key_unsecured';

enum ExtensionStorageModeFailure { keyringRequired, conflictingKeys }

class ExtensionStorageModeException implements Exception {
  const ExtensionStorageModeException(this.reason);

  final ExtensionStorageModeFailure reason;

  @override
  String toString() => switch (reason) {
    ExtensionStorageModeFailure.keyringRequired =>
      'Unlock the keyring once to move existing encrypted extension data.',
    ExtensionStorageModeFailure.conflictingKeys =>
      'The local and keyring extension keys differ. Both have been preserved.',
  };
}

class ExtensionStoragePaths {
  const ExtensionStoragePaths({
    required this.extensionsDir,
    required this.dataDir,
    required this.masterKey,
  });

  final String extensionsDir;
  final String dataDir;
  final String masterKey;
}

class ExtensionStorageService {
  ExtensionStorageService._();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );
  static Future<ExtensionStoragePaths>? _preparing;
  static Future<void>? _changingMode;

  static bool get supportsUnsecuredStorage =>
      isDesktopPlatform && defaultTargetPlatform == TargetPlatform.linux;

  @visibleForTesting
  static void resetForTesting() {
    _preparing = null;
    _changingMode = null;
  }

  static Future<bool> isUnsecuredStorageEnabled() async {
    if (!supportsUnsecuredStorage) return false;
    await _changingMode;
    final support = await getApplicationSupportDirectory();
    return await _readLocalMasterKey(
          Directory(p.join(support.path, 'extension_data')),
        ) !=
        null;
  }

  /// The local key file is the durable opt-in. No keyring fallback is automatic.
  static Future<void> setUnsecuredStorage(bool enabled) {
    if (!supportsUnsecuredStorage) {
      return Future.error(
        UnsupportedError('Unsecured extension storage is Linux-only'),
      );
    }
    final previous = _changingMode;
    late final Future<void> changing;
    changing =
        (() async {
          if (previous != null) {
            try {
              await previous;
            } catch (_) {}
          }
          ExtensionStoragePaths? prepared;
          try {
            prepared = await _preparing;
          } catch (_) {
            // A failed keyring read must not block an explicit local-storage choice.
          }
          _preparing = null;
          final support = await getApplicationSupportDirectory();
          final dataDir = Directory(p.join(support.path, 'extension_data'));
          await dataDir.create(recursive: true);
          final local = await _readLocalMasterKey(dataDir);
          if (enabled) {
            if (local != null) return;
            String? key = prepared?.masterKey;
            if (key == null) {
              try {
                key = await _secureStorage.read(key: _extensionMasterKeyName);
              } catch (_) {
                if (await _hasEncryptedData(dataDir)) {
                  throw const ExtensionStorageModeException(
                    ExtensionStorageModeFailure.keyringRequired,
                  );
                }
              }
            }
            if (key == null && await _hasEncryptedData(dataDir)) {
              throw const ExtensionStorageModeException(
                ExtensionStorageModeFailure.keyringRequired,
              );
            }
            key = key == null ? _generateMasterKey() : _validateMasterKey(key);
            await _writeLocalMasterKey(dataDir, key);
          } else if (local != null) {
            final secured = await _secureStorage.read(
              key: _extensionMasterKeyName,
            );
            if (secured != null && _validateMasterKey(secured) != local) {
              throw const ExtensionStorageModeException(
                ExtensionStorageModeFailure.conflictingKeys,
              );
            }
            if (secured == null) {
              await _secureStorage.write(
                key: _extensionMasterKeyName,
                value: local,
              );
            }
            if (await _secureStorage.read(key: _extensionMasterKeyName) !=
                local) {
              throw StateError(
                'Could not verify the extension key in the keyring',
              );
            }
            await File(p.join(dataDir.path, _localMasterKeyFileName)).delete();
          }
        })().whenComplete(() {
          _preparing = null;
          if (identical(_changingMode, changing)) _changingMode = null;
        });
    _changingMode = changing;
    return changing;
  }

  static Future<ExtensionStoragePaths> prepare() {
    final changing = _changingMode;
    if (changing != null) return changing.then((_) => prepare());
    return _preparing ??= _prepare().catchError((
      Object error,
      StackTrace stack,
    ) {
      // A transient filesystem/keystore failure must not poison every retry
      // until the process is restarted.
      _preparing = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  static Future<ExtensionStoragePaths> _prepare() async {
    final supportDir = await getApplicationSupportDirectory();
    final extensionsDir = Directory(p.join(supportDir.path, 'extensions'));
    final dataDir = Directory(p.join(supportDir.path, 'extension_data'));

    // Mobile builds once kept extensions in the app's private Documents
    // folder. On desktop that folder is the user's own Documents, which never
    // held app storage, so nothing there may be moved.
    if (!isDesktopPlatform) {
      final documentsDir = await getApplicationDocumentsDirectory();
      await _migrateDirectory(
        Directory(p.join(documentsDir.path, 'extensions')),
        extensionsDir,
      );
      await _migrateDirectory(
        Directory(p.join(documentsDir.path, 'extension_data')),
        dataDir,
      );
    }
    await extensionsDir.create(recursive: true);
    await dataDir.create(recursive: true);

    return ExtensionStoragePaths(
      extensionsDir: extensionsDir.path,
      dataDir: dataDir.path,
      masterKey: await _loadOrCreateMasterKey(dataDir),
    );
  }

  static Future<String> _loadOrCreateMasterKey(Directory dataDir) async {
    if (supportsUnsecuredStorage) {
      final local = await _readLocalMasterKey(dataDir);
      if (local != null) return local;
    }
    final existing = await _secureStorage.read(key: _extensionMasterKeyName);
    if (existing != null) {
      return _validateMasterKey(existing);
    }

    // Plaintext settings and salt-based legacy credentials can be migrated with
    // a new key. Encrypted settings require the original key; generating another
    // one would leave every installed extension permanently unreadable.
    if (await _hasEncryptedData(dataDir)) {
      throw StateError(
        'The extension storage key is missing. Existing encrypted extension '
        'data has been preserved.',
      );
    }

    final encoded = _generateMasterKey();
    await _secureStorage.write(key: _extensionMasterKeyName, value: encoded);
    return encoded;
  }

  static Future<bool> _hasEncryptedData(Directory dataDir) async {
    if (await FileSystemEntity.type(
          p.join(dataDir.path, '.pending-auth.enc'),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      return true;
    }
    await for (final entry in dataDir.list(followLinks: false)) {
      if (entry is Directory) {
        for (final name in ['settings.enc', '.credentials.enc']) {
          if (await FileSystemEntity.type(
                p.join(entry.path, name),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
            return true;
          }
        }
      }
    }

    return false;
  }

  static String _generateMasterKey() {
    final random = Random.secure();
    return base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  static String _validateMasterKey(String value) {
    try {
      if (base64Decode(value).length == 32) return value;
    } on FormatException {
      // Preserve invalid keys for recovery rather than silently rotating them.
    }
    throw StateError(
      'The extension storage key is invalid. Existing extension data has been preserved.',
    );
  }

  static Future<String?> _readLocalMasterKey(Directory dataDir) async {
    final file = File(p.join(dataDir.path, _localMasterKeyFileName));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Refusing a non-file extension key', file.path);
    }
    return _validateMasterKey(await file.readAsString());
  }

  static Future<void> _writeLocalMasterKey(
    Directory dataDir,
    String key,
  ) async {
    final file = File(p.join(dataDir.path, _localMasterKeyFileName));
    await file.create(exclusive: true);
    try {
      // Set owner-only access before writing any key bytes.
      final permission = await Process.run('chmod', ['600', file.path]);
      if (permission.exitCode != 0) {
        throw FileSystemException(
          'Could not protect the local extension key',
          file.path,
        );
      }
      await file.writeAsString(key, flush: true);
    } catch (_) {
      await file.delete();
      rethrow;
    }
  }

  static Future<void> _migrateDirectory(
    Directory source,
    Directory destination,
  ) async {
    if (p.equals(source.path, destination.path)) {
      return;
    }
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) return;
    if (sourceType == FileSystemEntityType.link) {
      await Link(source.path).delete();
      return;
    }
    if (sourceType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Extension storage path is not a directory',
        source.path,
      );
    }
    if (await FileSystemEntity.type(destination.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Refusing extension storage symlink',
        destination.path,
      );
    }

    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _migrateDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        final target = File(targetPath);
        await target.parent.create(recursive: true);
        if (await target.exists()) {
          final sourceModified = await entity.lastModified();
          final targetModified = await target.lastModified();
          if (!sourceModified.isAfter(targetModified)) {
            await entity.delete();
            continue;
          }
        }
        await _copyFileAtomically(entity, target);
        await entity.delete();
      } else if (entity is Link) {
        // Extension storage must never preserve links into another sandbox.
        await entity.delete();
      }
    }
    if (await source.exists() && await source.list().isEmpty) {
      await source.delete();
    }
  }

  static Future<void> _copyFileAtomically(File source, File target) async {
    final nonce = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final temporary = File('${target.path}.migration-$nonce.tmp');
    try {
      await source.openRead().pipe(temporary.openWrite());
      final sourceLength = await source.length();
      if (await temporary.length() != sourceLength) {
        throw const FileSystemException('Incomplete extension storage copy');
      }
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        // Windows cannot atomically replace an existing file. Mobile platforms
        // take the first branch; this fallback keeps development migrations
        // functional while retaining the source until replacement succeeds.
        if (!await target.exists()) rethrow;
        await target.delete();
        await temporary.rename(target.path);
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
