import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/desktop_updater.dart';
import 'package:mornye/services/update_checker.dart';

const _version = 'v5.3.0';

const _desktopAssetNames = [
  'Mornye-$_version-arm64.apk',
  'Mornye-$_version-macos-universal.dmg',
  'Mornye-$_version-windows-x64-setup.exe',
  'Mornye-$_version-windows-x64-portable.zip',
  'Mornye-$_version-windows-arm64-setup.exe',
  'Mornye-$_version-linux-x86_64.AppImage',
  'Mornye-$_version-linux-aarch64.AppImage',
  'Mornye-$_version-linux-amd64.deb',
  'Mornye-$_version-linux-arm64.deb',
  'SHA256SUMS.txt',
];

List<ReleaseAsset> _assets(Iterable<String> names) => [
  for (final name in names)
    ReleaseAsset(name: name, url: 'https://example.test/$name'),
];

const _appImageHost = UpdateHost(
  os: 'linux',
  arch: 'x64',
  linuxPackage: LinuxPackageKind.appImage,
  appImagePath: '/home/user/Applications/Mornye.AppImage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selectDesktopAsset', () {
    final all = _assets(_desktopAssetNames);

    for (final (host, expected) in [
      (
        const UpdateHost(os: 'macos', arch: 'arm64'),
        'Mornye-$_version-macos-universal.dmg',
      ),
      (
        const UpdateHost(os: 'macos', arch: 'x64'),
        'Mornye-$_version-macos-universal.dmg',
      ),
      (
        const UpdateHost(os: 'windows', arch: 'x64'),
        'Mornye-$_version-windows-x64-setup.exe',
      ),
      (
        const UpdateHost(os: 'windows', arch: 'arm64'),
        'Mornye-$_version-windows-arm64-setup.exe',
      ),
      (_appImageHost, 'Mornye-$_version-linux-x86_64.AppImage'),
      (
        const UpdateHost(
          os: 'linux',
          arch: 'arm64',
          linuxPackage: LinuxPackageKind.appImage,
          appImagePath: '/opt/apps/Mornye.AppImage',
        ),
        'Mornye-$_version-linux-aarch64.AppImage',
      ),
    ]) {
      test('${host.os} ${host.arch} picks $expected', () {
        expect(UpdateChecker.selectDesktopAsset(all, host)?.name, expected);
      });
    }

    test('Windows on Arm falls back to the x64 installer', () {
      final withoutArm = _assets(
        _desktopAssetNames.where((name) => !name.contains('windows-arm64')),
      );
      expect(
        UpdateChecker.selectDesktopAsset(
          withoutArm,
          const UpdateHost(os: 'windows', arch: 'arm64'),
        )?.name,
        'Mornye-$_version-windows-x64-setup.exe',
      );
    });

    test('an x64 host never gets an arm64 package', () {
      final armOnly = _assets([
        'Mornye-$_version-windows-arm64-setup.exe',
        'Mornye-$_version-linux-aarch64.AppImage',
      ]);
      expect(
        UpdateChecker.selectDesktopAsset(
          armOnly,
          const UpdateHost(os: 'windows', arch: 'x64'),
        ),
        isNull,
      );
      expect(UpdateChecker.selectDesktopAsset(armOnly, _appImageHost), isNull);
    });

    for (final package in [
      LinuxPackageKind.deb,
      LinuxPackageKind.flatpak,
      LinuxPackageKind.bundle,
    ]) {
      test('Linux ${package.name} installs do not self-update', () {
        final host = UpdateHost(
          os: 'linux',
          arch: 'x64',
          linuxPackage: package,
        );
        expect(host.installKind, UpdateInstallKind.releasePage);
        expect(UpdateChecker.selectDesktopAsset(all, host), isNull);
      });
    }
  });

  group('detectLinuxPackage', () {
    test('APPIMAGE marks an AppImage', () {
      expect(
        UpdateHost.detectLinuxPackage(
          environment: {'APPIMAGE': '/home/user/Mornye.AppImage'},
          resolvedExecutable: '/tmp/.mount_MornyeAbc/usr/lib/mornye/mornye',
        ),
        LinuxPackageKind.appImage,
      );
    });

    test('a system path without APPIMAGE is the deb', () {
      expect(
        UpdateHost.detectLinuxPackage(
          environment: const {},
          resolvedExecutable: '/usr/lib/mornye/mornye',
        ),
        LinuxPackageKind.deb,
      );
    });

    test('Flatpak wins over everything else', () {
      expect(
        UpdateHost.detectLinuxPackage(
          environment: {'FLATPAK_ID': 'com.zarz.mornye'},
          resolvedExecutable: '/app/lib/mornye/mornye',
        ),
        LinuxPackageKind.flatpak,
      );
      expect(
        UpdateHost.detectLinuxPackage(
          environment: const {},
          resolvedExecutable: '/app/lib/mornye/mornye',
          flatpakInfoExists: true,
        ),
        LinuxPackageKind.flatpak,
      );
    });

    test('an extracted bundle elsewhere is a plain bundle', () {
      expect(
        UpdateHost.detectLinuxPackage(
          environment: {'APPIMAGE': ''},
          resolvedExecutable: '/home/user/mornye/mornye',
        ),
        LinuxPackageKind.bundle,
      );
    });
  });

  test('sha256FromChecksums reads sha256sum and shasum output', () {
    final a = List.filled(64, 'a').join();
    final b = List.filled(64, 'B').join();
    final sums =
        '$a  Mornye-v5.3.0-linux-x86_64.AppImage\n'
        '$b *Mornye-v5.3.0-macos-universal.dmg\r\n'
        'not a checksum line\n';
    expect(
      UpdateChecker.sha256FromChecksums(
        sums,
        'Mornye-v5.3.0-linux-x86_64.AppImage',
      ),
      a,
    );
    expect(
      UpdateChecker.sha256FromChecksums(
        sums,
        'Mornye-v5.3.0-macos-universal.dmg',
      ),
      b.toLowerCase(),
    );
    expect(UpdateChecker.sha256FromChecksums(sums, 'missing.exe'), isNull);
  });

  group('checkForUpdate on desktop', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Map<String, Object?> release() => {
      'tag_name': _version,
      'prerelease': false,
      'body': '- Desktop builds',
      'published_at': '2026-10-20T00:00:00Z',
      'html_url': 'https://example.test/releases/$_version',
      'assets': [
        for (final name in _desktopAssetNames)
          {'name': name, 'browser_download_url': 'https://example.test/$name'},
      ],
    };

    UpdateChecker checker(UpdateHost host) => UpdateChecker(
      installedVersion: '5.2.1',
      host: host,
      client: MockClient(
        (_) async => http.Response(jsonEncode([release()]), 200),
      ),
    );

    test(
      'desktop reads the desktop repository, Android the main one',
      () async {
        final requested = <Uri>[];
        UpdateChecker recording(UpdateHost host) => UpdateChecker(
          installedVersion: '5.2.1',
          host: host,
          client: MockClient((request) async {
            requested.add(request.url);
            return http.Response('[]', 200);
          }),
        );
        await recording(_appImageHost).checkForUpdate();
        await recording(UpdateHost.android).checkForUpdate();
        expect(requested.map((url) => url.path), [
          '/repos/mornyeapp/Mornye-Desktop/releases',
          '/repos/mornyeapp/Mornye/releases',
        ]);
      },
    );

    test(
      'a main repository list saved before the split is not reused',
      () async {
        // Saved by an earlier desktop build, which read the main repository.
        SharedPreferences.setMockInitialValues({
          'update_checker_releases_json': jsonEncode([release()]),
          'update_checker_releases_etag': '"main"',
        });
        final headers = <Map<String, String>>[];
        final offline = UpdateChecker(
          installedVersion: '5.2.1',
          host: _appImageHost,
          client: MockClient((request) async {
            headers.add(request.headers);
            throw http.ClientException('Offline');
          }),
        );
        expect(await offline.checkForUpdate(), isNull);
        expect(headers.single.containsKey('If-None-Match'), isFalse);

        // A list fetched from the desktop repository is reused offline.
        await checker(_appImageHost).checkForUpdate();
        expect(
          (await offline.checkForUpdate())?.assetName,
          'Mornye-$_version-linux-x86_64.AppImage',
        );
      },
    );

    test('an AppImage gets its package, checksums and target path', () async {
      final update = await checker(_appImageHost).checkForUpdate();
      expect(update?.installKind, UpdateInstallKind.linuxAppImage);
      expect(update?.assetName, 'Mornye-$_version-linux-x86_64.AppImage');
      expect(update?.checksumsUrl, 'https://example.test/SHA256SUMS.txt');
      expect(update?.appImagePath, _appImageHost.appImagePath);
      expect(update?.apkDownloadUrl, isNull);
      expect(update?.hasDesktopPackage, isTrue);
    });

    test('a deb install gets the release page only', () async {
      final update = await checker(
        const UpdateHost(
          os: 'linux',
          arch: 'x64',
          linuxPackage: LinuxPackageKind.deb,
        ),
      ).checkForUpdate();
      expect(update?.installKind, UpdateInstallKind.releasePage);
      expect(update?.assetUrl, isNull);
      expect(update?.hasDesktopPackage, isFalse);
      expect(update?.downloadUrl, 'https://example.test/releases/$_version');
    });

    test('Windows gets the installer', () async {
      final update = await checker(
        const UpdateHost(os: 'windows', arch: 'x64'),
      ).checkForUpdate();
      expect(update?.installKind, UpdateInstallKind.windowsInstaller);
      expect(update?.assetName, 'Mornye-$_version-windows-x64-setup.exe');
    });
  });

  group('DesktopUpdater', () {
    late Directory temp;
    final payload = utf8.encode('verified package bytes');
    final payloadSha = sha256.convert(payload).toString();
    const assetName = 'Mornye-$_version-linux-x86_64.AppImage';

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mornye-updater-test');
    });
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    UpdateInfo info({String? digest, bool withChecksums = true}) => UpdateInfo(
      version: '5.3.0',
      changelog: '',
      downloadUrl: 'https://example.test/releases/$_version',
      installKind: UpdateInstallKind.linuxAppImage,
      assetName: assetName,
      assetUrl: 'https://example.test/$assetName',
      assetSha256: digest,
      checksumsUrl: withChecksums
          ? 'https://example.test/SHA256SUMS.txt'
          : null,
      appImagePath: '${temp.path}/Mornye.AppImage',
    );

    MockClient client(String checksums) => MockClient((request) async {
      if (request.url.path.endsWith('SHA256SUMS.txt')) {
        return http.Response(checksums, 200);
      }
      return http.Response.bytes(payload, 200);
    });

    test('downloads and verifies against SHA256SUMS.txt', () async {
      final updater = DesktopUpdater(
        client: client('$payloadSha  $assetName\n'),
        downloadDirectory: temp,
      );
      final file = await updater.download(info());
      expect(await file.readAsBytes(), payload);
      expect(File('${file.path}.part').existsSync(), isFalse);
    });

    test('rejects a package whose digest does not match', () async {
      final updater = DesktopUpdater(
        client: client('${List.filled(64, 'c').join()}  $assetName\n'),
        downloadDirectory: temp,
      );
      await expectLater(
        updater.download(info()),
        throwsA(isA<DesktopUpdateException>()),
      );
      expect(temp.listSync(), isEmpty);
    });

    test('rejects SHA256SUMS.txt and GitHub digests that disagree', () async {
      final updater = DesktopUpdater(
        client: client('$payloadSha  $assetName\n'),
        downloadDirectory: temp,
      );
      await expectLater(
        updater.download(info(digest: List.filled(64, 'd').join())),
        throwsA(isA<DesktopUpdateException>()),
      );
    });

    test('rejects a package SHA256SUMS.txt does not list', () async {
      final updater = DesktopUpdater(
        client: client('$payloadSha  other-file.exe\n'),
        downloadDirectory: temp,
      );
      await expectLater(
        updater.download(info()),
        throwsA(isA<DesktopUpdateException>()),
      );
    });

    test('falls back to the GitHub digest without SHA256SUMS.txt', () async {
      final updater = DesktopUpdater(
        client: client(''),
        downloadDirectory: temp,
      );
      final file = await updater.download(
        info(digest: payloadSha, withChecksums: false),
      );
      expect(await file.readAsBytes(), payload);
      await expectLater(
        updater.download(info(withChecksums: false)),
        throwsA(isA<DesktopUpdateException>()),
      );
    });

    test('replaces the AppImage in place', () async {
      final target = File('${temp.path}/Mornye.AppImage')
        ..writeAsStringSync('old');
      final downloaded = File('${temp.path}/download.AppImage')
        ..writeAsStringSync('new');
      await DesktopUpdater().replaceAppImage(downloaded, target.path);
      expect(target.readAsStringSync(), 'new');
      expect(downloaded.existsSync(), isFalse);
      expect(target.statSync().mode & 0x1ff, 0x1ed); // 0755
      expect(temp.listSync().map((entry) => entry.uri.pathSegments.last), [
        'Mornye.AppImage',
      ]);
    }, skip: Platform.isWindows ? 'POSIX permissions only' : false);
  });
}
