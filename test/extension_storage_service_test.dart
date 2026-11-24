import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Map<String, String> values;
  late List<MethodCall> mutations;
  Object? readError;
  Object? writeError;
  bool ignoreWrites = false;
  late List<MethodCall> secureCalls;
  const keyName = 'extension_storage_master_key_v2';

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ExtensionStorageService.resetForTesting();
    root = await Directory.systemTemp.createTemp('extension-storage-');
    values = {};
    mutations = [];
    readError = null;
    writeError = null;
    ignoreWrites = false;
    secureCalls = [];
    messenger.setMockMethodCallHandler(
      paths,
      (call) async =>
          '${root.path}/${call.method == 'getApplicationSupportDirectory' ? 'support' : 'documents'}',
    );
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final options = Map<String, dynamic>.from(args['options'] as Map);
      secureCalls.add(call);
      if (defaultTargetPlatform == TargetPlatform.android) {
        expect(options['resetOnError'], 'false');
        expect(options['migrateOnAlgorithmChange'], 'true');
        expect(options['migrateWithBackup'], 'true');
        expect(
          options['keyCipherAlgorithm'],
          'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
        );
        expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
      }
      if (call.method == 'read') {
        if (readError != null) throw readError!;
        return values[args['key']];
      }
      mutations.add(call);
      if (call.method == 'write') {
        if (writeError != null) throw writeError!;
        if (!ignoreWrites) {
          values[args['key'] as String] = args['value'] as String;
        }
      }
      return null;
    });
  });
  tearDown(() async {
    ExtensionStorageService.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secure, null);
    await root.delete(recursive: true);
  });

  Future<File> seed(String relative, List<int> bytes) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  void linux() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugDesktopPlatformOverride = true;
  }

  File localKey() =>
      File('${root.path}/support/extension_data/.master_key_unsecured');

  test('mode changes serialize with startup and waiting preparation', () async {
    linux();
    final reading = Completer<void>();
    final ready = Completer<String>();
    final key = base64Encode(List.filled(32, 5));
    messenger.setMockMethodCallHandler(secure, (call) async {
      expect(call.method, 'read');
      if (!reading.isCompleted) reading.complete();
      return ready.future;
    });
    final startup = ExtensionStorageService.prepare();
    await reading.future;
    final changing = ExtensionStorageService.setUnsecuredStorage(true);
    final waiting = ExtensionStorageService.prepare();
    ready.complete(key);
    expect((await startup).masterKey, key);
    await changing;
    expect((await waiting).masterKey, key);
    expect(await localKey().readAsString(), key);
  });

  test(
    'Linux requires explicit opt-in and reuses its owner-only local key',
    () async {
      linux();
      readError = PlatformException(
        code: 'Libsecret error',
        message: 'secret_service_get_sync: The name is not activatable',
      );
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<PlatformException>()),
      );
      expect(await localKey().exists(), isFalse);
      await ExtensionStorageService.setUnsecuredStorage(true);
      expect(await ExtensionStorageService.isUnsecuredStorageEnabled(), isTrue);
      final key = await localKey().readAsString();
      expect(base64Decode(key), hasLength(32));
      expect((await localKey().stat()).mode & 0x1ff, 0x180);
      secureCalls.clear();
      ExtensionStorageService.resetForTesting();
      expect((await ExtensionStorageService.prepare()).masterKey, key);
      expect(secureCalls, isEmpty);
    },
  );

  test(
    'switching modes preserves the original key and encrypted data',
    () async {
      linux();
      final key = base64Encode(List.filled(32, 9));
      values[keyName] = key;
      final data = await seed('support/extension_data/example/settings.enc', [
        4,
        5,
        6,
      ]);
      await ExtensionStorageService.prepare();
      readError = PlatformException(code: 'keyring_locked');
      await ExtensionStorageService.setUnsecuredStorage(true);
      expect(await localKey().readAsString(), key);
      readError = null;
      values.clear();
      await ExtensionStorageService.setUnsecuredStorage(false);
      expect(values[keyName], key);
      expect(await localKey().exists(), isFalse);
      expect((await ExtensionStorageService.prepare()).masterKey, key);
      expect(await data.readAsBytes(), [4, 5, 6]);
    },
  );

  for (final name in [
    'example/settings.enc',
    'example/.credentials.enc',
    '.pending-auth.enc',
  ]) {
    test('unavailable keyring never replaces the key for $name', () async {
      linux();
      final data = await seed('support/extension_data/$name', [7, 8, 9]);
      readError = PlatformException(code: 'Libsecret error');
      await expectLater(
        ExtensionStorageService.setUnsecuredStorage(true),
        throwsA(
          isA<ExtensionStorageModeException>().having(
            (e) => e.reason,
            'reason',
            ExtensionStorageModeFailure.keyringRequired,
          ),
        ),
      );
      expect(await localKey().exists(), isFalse);
      expect(await data.readAsBytes(), [7, 8, 9]);
      expect(mutations, isEmpty);
    });
  }

  for (final failure in ['read', 'write', 'verification', 'conflict']) {
    test('failed secure migration keeps the local key ($failure)', () async {
      linux();
      await ExtensionStorageService.setUnsecuredStorage(true);
      final key = await localKey().readAsString();
      switch (failure) {
        case 'read':
          readError = PlatformException(code: 'Libsecret error');
        case 'write':
          writeError = PlatformException(code: 'keyring_locked');
        case 'verification':
          ignoreWrites = true;
        case 'conflict':
          values[keyName] = base64Encode(List.filled(32, 6));
      }
      await expectLater(
        ExtensionStorageService.setUnsecuredStorage(false),
        throwsA(anything),
      );
      expect(await localKey().readAsString(), key);
      expect(await ExtensionStorageService.isUnsecuredStorageEnabled(), isTrue);
      expect((await ExtensionStorageService.prepare()).masterKey, key);
    });
  }

  test(
    'invalid and symlinked local keys are preserved without keyring fallback',
    () async {
      linux();
      await seed(
        'support/extension_data/.master_key_unsecured',
        utf8.encode('invalid'),
      );
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<StateError>()),
      );
      expect(await localKey().readAsString(), 'invalid');
      await localKey().delete();
      final target = await seed(
        'outside',
        utf8.encode(base64Encode(List.filled(32, 3))),
      );
      await Link(localKey().path).create(target.path);
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await FileSystemEntity.isLink(localKey().path), isTrue);
      expect(secureCalls, isEmpty);
    },
  );

  test('other platforms have no switch for the local key', () async {
    values[keyName] = base64Encode(List.filled(32, 1));
    for (final enabled in [true, false]) {
      await expectLater(
        ExtensionStorageService.setUnsecuredStorage(enabled),
        throwsUnsupportedError,
      );
    }
    expect(await ExtensionStorageService.isUnsecuredStorageEnabled(), isFalse);
    expect(
      (await ExtensionStorageService.prepare()).masterKey,
      values[keyName],
    );
    expect(await localKey().exists(), isFalse);
  });

  test('Android moves to a local key when the keystore loses it', () async {
    final first = (await ExtensionStorageService.prepare()).masterKey;
    final lostFiles = [
      await seed('support/extension_data/example/settings.enc', [1]),
      await seed('support/extension_data/example/.credentials.enc', [2]),
      await seed('support/extension_data/.pending-auth.enc', [3]),
    ];
    final kept = await seed('support/extension_data/example/storage.json', [4]);
    values.clear();
    ExtensionStorageService.resetForTesting();

    final recovered = (await ExtensionStorageService.prepare()).masterKey;
    expect(recovered, isNot(first));
    expect(await localKey().readAsString(), recovered);
    expect(values, isEmpty);
    for (final (index, file) in lostFiles.indexed) {
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.lost').readAsBytes(), [index + 1]);
    }
    expect(await kept.readAsBytes(), [4]);
    expect(await ExtensionStorageService.hasRecoveryNotice(), isTrue);

    // From now on the keystore is not asked, so nothing can be lost again.
    await seed('support/extension_data/example/settings.enc', [5]);
    secureCalls.clear();
    ExtensionStorageService.resetForTesting();
    expect((await ExtensionStorageService.prepare()).masterKey, recovered);
    expect(secureCalls, isEmpty);
    expect(
      await File(
        '${root.path}/support/extension_data/example/settings.enc',
      ).readAsBytes(),
      [5],
    );

    await ExtensionStorageService.dismissRecoveryNotice();
    expect(await ExtensionStorageService.hasRecoveryNotice(), isFalse);
  });

  test('a lost key with nothing encrypted yet costs no data', () async {
    await ExtensionStorageService.prepare();
    values.clear();
    ExtensionStorageService.resetForTesting();
    final key = (await ExtensionStorageService.prepare()).masterKey;
    expect(await localKey().readAsString(), key);
    expect(await ExtensionStorageService.hasRecoveryNotice(), isFalse);
  });

  test('other platforms give the secure store a second key', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final settings = File(
      '${root.path}/support/extension_data/example/settings.enc',
    );
    await seed('support/extension_data/example/settings.enc', [1]);

    final second = (await ExtensionStorageService.prepare()).masterKey;
    expect(values[keyName], second);
    expect(await localKey().exists(), isFalse);
    expect(await File('${settings.path}.lost').readAsBytes(), [1]);
    expect(await ExtensionStorageService.hasRecoveryNotice(), isTrue);

    await seed('support/extension_data/example/settings.enc', [2]);
    values.clear();
    ExtensionStorageService.resetForTesting();
    final third = (await ExtensionStorageService.prepare()).masterKey;
    expect(third, isNot(second));
    expect(await localKey().readAsString(), third);
    expect(values, isEmpty);
    // Only the latest unreadable copy is kept.
    expect(await File('${settings.path}.lost').readAsBytes(), [2]);
    expect(await settings.exists(), isFalse);
  });

  for (final failure in ['unkept', 'refused']) {
    test(
      'a secure store that cannot keep a key is not used ($failure)',
      () async {
        if (failure == 'unkept') {
          ignoreWrites = true;
        } else {
          writeError = PlatformException(code: 'keystore_unavailable');
        }
        final key = (await ExtensionStorageService.prepare()).masterKey;
        expect(await localKey().readAsString(), key);
        expect(await ExtensionStorageService.hasRecoveryNotice(), isFalse);
        ExtensionStorageService.resetForTesting();
        expect((await ExtensionStorageService.prepare()).masterKey, key);
      },
    );
  }

  test('Linux starts over only when asked while the keyring is away', () async {
    linux();
    final data = await seed('support/extension_data/example/settings.enc', [7]);
    readError = PlatformException(code: 'Libsecret error');
    await expectLater(
      ExtensionStorageService.setUnsecuredStorage(true),
      throwsA(isA<ExtensionStorageModeException>()),
    );
    expect(await data.readAsBytes(), [7]);

    await ExtensionStorageService.setUnsecuredStorage(true, startOver: true);
    expect(await data.exists(), isFalse);
    expect(await File('${data.path}.lost').readAsBytes(), [7]);
    expect(await ExtensionStorageService.hasRecoveryNotice(), isTrue);
    expect(
      (await ExtensionStorageService.prepare()).masterKey,
      await localKey().readAsString(),
    );
    expect(mutations, isEmpty);
  });

  test(
    'Linux recovers by itself when the keyring answers without the key',
    () async {
      linux();
      final data = await seed('support/extension_data/example/settings.enc', [
        7,
      ]);
      final key = (await ExtensionStorageService.prepare()).masterKey;
      expect(values[keyName], key);
      expect(await localKey().exists(), isFalse);
      expect(await File('${data.path}.lost').readAsBytes(), [7]);
      expect(await ExtensionStorageService.hasRecoveryNotice(), isTrue);
    },
  );

  test(
    'upgrade retains the same key and migrates encrypted files intact',
    () async {
      final key = base64Encode(List.filled(32, 7));
      values[keyName] = key;
      for (final name in ['settings.enc', '.credentials.enc', '.cred_salt']) {
        await seed('documents/extension_data/example.provider/$name', [
          1,
          2,
          3,
          4,
        ]);
      }
      final storage = await ExtensionStorageService.prepare();
      expect(storage.masterKey, key);
      expect(mutations, isEmpty);
      for (final name in ['settings.enc', '.credentials.enc', '.cred_salt']) {
        expect(
          await File('${storage.dataDir}/example.provider/$name').readAsBytes(),
          [1, 2, 3, 4],
        );
      }
    },
  );

  test('desktop never moves folders out of the user Documents', () async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final userFile = await seed('documents/extensions/notes.txt', [1, 2]);
    final userData = await seed('documents/extension_data/a/b.json', [3]);
    final storage = await ExtensionStorageService.prepare();
    expect(await userFile.readAsBytes(), [1, 2]);
    expect(await userData.readAsBytes(), [3]);
    expect(await Directory(storage.extensionsDir).list().toList(), isEmpty);
    expect(
      await Directory(
        storage.dataDir,
      ).list().map((entry) => entry.uri.pathSegments.last).toList(),
      ['.key_record'],
    );
  });

  test('a missing key no longer stops extensions from starting', () async {
    final file = await seed(
      'support/extension_data/example.provider/settings.enc',
      [5, 6, 7],
    );
    final storage = await ExtensionStorageService.prepare();
    expect(base64Decode(storage.masterKey), hasLength(32));
    expect(await file.exists(), isFalse);
    expect(await File('${file.path}.lost').readAsBytes(), [5, 6, 7]);
    ExtensionStorageService.resetForTesting();
    expect(
      (await ExtensionStorageService.prepare()).masterKey,
      storage.masterKey,
    );
  });

  for (final invalid in [
    'not-base64',
    base64Encode([1, 2, 3]),
  ]) {
    test('malformed key is preserved ($invalid)', () async {
      values[keyName] = invalid;
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<StateError>()),
      );
      expect(mutations, isEmpty);
      expect(values[keyName], invalid);
    });
  }

  test(
    'keystore failure propagates without deleting data and is retryable',
    () async {
      readError = PlatformException(code: 'keystore_unavailable');
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<PlatformException>()),
      );
      expect(mutations, isEmpty);
      readError = null;
      values[keyName] = base64Encode(List.filled(32, 3));
      expect(
        (await ExtensionStorageService.prepare()).masterKey,
        values[keyName],
      );
      expect(mutations, isEmpty);
    },
  );

  test(
    'failed cipher migration preserves encrypted files and the key',
    () async {
      final key = base64Encode(List.filled(32, 4));
      values[keyName] = key;
      final file = await seed(
        'support/extension_data/example.provider/settings.enc',
        [8, 9, 10],
      );
      readError = PlatformException(
        code: 'Exception encountered',
        message:
            'Migration failed after algorithm change '
            '(Invalid key, key type incompatible with cipher). '
            'Enable resetOnError=true or call deleteAll().',
      );
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<PlatformException>()),
      );
      expect(mutations, isEmpty);
      expect(values[keyName], key);
      expect(await file.readAsBytes(), [8, 9, 10]);

      readError = null;
      expect((await ExtensionStorageService.prepare()).masterKey, key);
      expect(mutations, isEmpty);
    },
  );

  for (final legacy in [false, true]) {
    test(
      'fresh installs and plaintext legacy settings can create a key (legacy=$legacy)',
      () async {
        if (legacy) {
          await seed(
            'documents/extension_data/example.provider/settings.json',
            utf8.encode('{"region":"example"}'),
          );
          await seed(
            'documents/extension_data/example.provider/.cred_salt',
            List.filled(32, 1),
          );
        }
        final first = ExtensionStorageService.prepare();
        expect(identical(first, ExtensionStorageService.prepare()), isTrue);
        final storage = await first;
        expect(base64Decode(storage.masterKey), hasLength(32));
        expect(values[keyName], storage.masterKey);
        expect(mutations.map((call) => call.method), ['write']);
        if (legacy) {
          expect(
            await File(
              '${storage.dataDir}/example.provider/settings.json',
            ).readAsString(),
            '{"region":"example"}',
          );
        }
      },
    );
  }
}
