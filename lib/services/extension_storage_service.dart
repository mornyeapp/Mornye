import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

const _extensionMasterKeyName = 'extension_storage_master_key_v2';
const _localMasterKeyFileName = '.master_key_unsecured';
const _keyRecordFileName = '.key_record';
const _lostSuffix = '.lost';

final _log = AppLogger('ExtensionStorage');

/// What is known about the key in the secure store: whether one was put
/// there, how often it then went missing, and whether the user still has to
/// be told that settings and sign-ins were set aside.
typedef _KeyRecord = ({bool issued, int lost, bool notice});

const _KeyRecord _noKeyRecord = (issued: false, lost: 0, notice: false);

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

  static Future<Directory> _dataDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'extension_data'));
  }

  /// Whether the key is kept in a local file: the choice made on Linux, or
  /// on any platform the fallback for a secure store that does not keep it.
  static Future<bool> isUnsecuredStorageEnabled() async {
    await _changingMode;
    return await _readLocalMasterKey(await _dataDirectory()) != null;
  }

  /// Whether extension settings and sign-ins were set aside because their
  /// key was lost, and the user has not been told yet.
  static Future<bool> hasRecoveryNotice() async =>
      (await _readKeyRecord(await _dataDirectory())).notice;

  static Future<void> dismissRecoveryNotice() async {
    final dataDir = await _dataDirectory();
    final record = await _readKeyRecord(dataDir);
    if (!record.notice) return;
    await _writeKeyRecord(dataDir, (
      issued: record.issued,
      lost: record.lost,
      notice: false,
    ));
  }

  /// The local key file is the durable choice, and the switch for it is
  /// Linux-only: Linux may have no keyring at all. A keyring that cannot be
  /// reached may still hold the key of existing data, so that data is only
  /// set aside when [startOver] says the user chose to.
  static Future<void> setUnsecuredStorage(
    bool enabled, {
    bool startOver = false,
  }) {
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
            var reachable = true;
            if (key == null) {
              try {
                key = await _secureStorage.read(key: _extensionMasterKeyName);
              } catch (_) {
                reachable = false;
              }
            }
            if (key == null && await _hasEncryptedData(dataDir)) {
              if (!reachable && !startOver) {
                throw const ExtensionStorageModeException(
                  ExtensionStorageModeFailure.keyringRequired,
                );
              }
              await _recordLoss(dataDir, await _readKeyRecord(dataDir));
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
            // The keyring has earned a fresh start.
            await _writeKeyRecord(dataDir, (
              issued: true,
              lost: 0,
              notice: (await _readKeyRecord(dataDir)).notice,
            ));
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
    final local = await _readLocalMasterKey(dataDir);
    if (local != null) return local;
    // A read that fails (a locked keyring, a keystore that is not ready)
    // says nothing about the key: it propagates and nothing is touched.
    final existing = await _secureStorage.read(key: _extensionMasterKeyName);
    if (existing != null) {
      return _validateMasterKey(existing);
    }

    // The store answered and has no key. Encrypted files cannot be read
    // without it, ever, and refusing to start left every extension dead on
    // each launch. Set them aside and start over with a new key: extensions
    // stay installed and ask to sign in again. Plaintext settings and
    // salt-based legacy credentials migrate with any key.
    var record = await _readKeyRecord(dataDir);
    if (record.issued || await _hasEncryptedData(dataDir)) {
      record = await _recordLoss(dataDir, record);
    }

    final encoded = _generateMasterKey();
    if (record.lost < _lossLimit && await _storeSecurely(encoded)) {
      await _writeKeyRecord(dataDir, (
        issued: true,
        lost: record.lost,
        notice: record.notice,
      ));
      return encoded;
    }
    _log.w('Extension storage key kept in a local file from now on');
    await _writeLocalMasterKey(dataDir, encoded);
    return encoded;
  }

  /// How many lost keys end trust in the secure store. A phone keeps app
  /// files private to the app and Android backs none of them up, so there a
  /// local key costs little and one loss is enough. Elsewhere one loss can be
  /// a restored backup or a changed keyring, so the store gets a second key.
  static int get _lossLimit =>
      defaultTargetPlatform == TargetPlatform.android ? 1 : 2;

  /// Sets aside what the lost key encrypted and counts the loss.
  static Future<_KeyRecord> _recordLoss(
    Directory dataDir,
    _KeyRecord record,
  ) async {
    final setAside = await _setAsideEncryptedData(dataDir);
    final _KeyRecord next = (
      issued: false,
      lost: record.lost + 1,
      notice: record.notice || setAside > 0,
    );
    await _writeKeyRecord(dataDir, next);
    _log.w(
      'Extension storage key is missing (loss ${next.lost}); '
      '$setAside encrypted files set aside',
    );
    return next;
  }

  /// Whether the secure store took [key] and gives it back. A store that
  /// accepts a key it does not keep would lose it again on the next launch.
  static Future<bool> _storeSecurely(String key) async {
    try {
      await _secureStorage.write(key: _extensionMasterKeyName, value: key);
      return await _secureStorage.read(key: _extensionMasterKeyName) == key;
    } catch (_) {
      // Linux reports a missing or locked keyring, and the user starts it or
      // turns on unsecured storage. Elsewhere there is nothing to turn on.
      if (supportsUnsecuredStorage) rethrow;
      return false;
    }
  }

  static Future<_KeyRecord> _readKeyRecord(Directory dataDir) async {
    try {
      final file = File(p.join(dataDir.path, _keyRecordFileName));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return _noKeyRecord;
      }
      final json = jsonDecode(await file.readAsString());
      if (json case {
        'issued': final bool issued,
        'lost': final int lost,
        'notice': final bool notice,
      } when lost >= 0) {
        return (issued: issued, lost: lost, notice: notice);
      }
    } on FormatException {
      // An unreadable record counts as none.
    } on FileSystemException {
      // The same.
    }
    return _noKeyRecord;
  }

  static Future<void> _writeKeyRecord(Directory dataDir, _KeyRecord record) =>
      File(p.join(dataDir.path, _keyRecordFileName)).writeAsString(
        jsonEncode({
          'issued': record.issued,
          'lost': record.lost,
          'notice': record.notice,
        }),
        flush: true,
      );

  /// Renames every encrypted file to `<name>.lost`, replacing the one from an
  /// earlier loss, and returns how many. Nothing reads those files; they are
  /// kept, not deleted.
  static Future<int> _setAsideEncryptedData(Directory dataDir) async {
    var count = 0;
    if (await _setAside(p.join(dataDir.path, '.pending-auth.enc'))) count++;
    final extensions = await dataDir.list(followLinks: false).toList();
    for (final entry in extensions) {
      if (entry is! Directory) continue;
      for (final name in ['settings.enc', '.credentials.enc']) {
        if (await _setAside(p.join(entry.path, name))) count++;
      }
    }
    return count;
  }

  static Future<bool> _setAside(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    final lost = '$path$_lostSuffix';
    switch (await FileSystemEntity.type(lost, followLinks: false)) {
      case FileSystemEntityType.notFound:
        break;
      case FileSystemEntityType.directory:
        await Directory(lost).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(lost).delete();
      default:
        await File(lost).delete();
    }
    await switch (type) {
      FileSystemEntityType.directory => Directory(path).rename(lost),
      FileSystemEntityType.link => Link(path).rename(lost),
      _ => File(path).rename(lost),
    };
    return true;
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
      // Set owner-only access before writing any key bytes. Phones keep app
      // files private to the app, and Windows to the user's profile.
      if (Platform.isLinux || Platform.isMacOS) {
        final permission = await Process.run('chmod', ['600', file.path]);
        if (permission.exitCode != 0) {
          throw FileSystemException(
            'Could not protect the local extension key',
            file.path,
          );
        }
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
