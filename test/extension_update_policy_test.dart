import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/extension_update_policy.dart';

void main() {
  const official = 'https://github.com/mornyeapp/Mornye-Extension';
  const resolved =
      'https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/main/registry.json';
  const custom = 'https://raw.githubusercontent.com/famous37/Mornye-Online/main/registry.json';

  group('official extension repository identification', () {
    test('recognizes GitHub and Mornye-resolved raw registry URLs', () {
      expect(isOfficialMornyeExtensionRegistry(official), isTrue);
      expect(isOfficialMornyeExtensionRegistry(resolved), isTrue);
      expect(
        isOfficialMornyeExtensionRegistry(
          'https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/feature/online/registry.json',
        ),
        isTrue,
      );
    });

    test('does not confuse clone, unrelated or unsafe URLs', () {
      expect(isOfficialMornyeExtensionRegistry(custom), isFalse);
      expect(
        isOfficialMornyeExtensionRegistry(
          'https://github.com/mornyeapp/Mornye-Extension-fake',
        ),
        isFalse,
      );
      expect(
        isOfficialMornyeExtensionRegistry(
          'https://evil.example/mornyeapp/Mornye-Extension/main/registry.json',
        ),
        isFalse,
      );
      expect(
        isOfficialMornyeExtensionRegistry(
          'http://github.com/mornyeapp/Mornye-Extension',
        ),
        isFalse,
      );
    });
  });

  group('protecting manually installed streaming mods', () {
    const online = <String, dynamic>{'fullTrackStreaming': true};
    const standard = <String, dynamic>{'fullTrackStreaming': false};

    test('blocks official updates to all three custom online .sflx IDs', () {
      for (final id in ['qobuz-web', 'jellyfin', 'soundcloud']) {
        expect(
          isOfficialRepoUpdateBlocked(
            registryUrl: resolved,
            extensionId: id,
            installedCapabilities: online,
          ),
          isTrue,
          reason: '$id must keep its manually installed online resolver',
        );
      }
    });

    test('does not block regular extensions or unmodified upstream builds', () {
      for (final id in ['tidal-web', 'deezer', 'spotify-web']) {
        expect(
          isOfficialRepoUpdateBlocked(
            registryUrl: resolved,
            extensionId: id,
            installedCapabilities: online,
          ),
          isFalse,
        );
      }
      expect(
        isOfficialRepoUpdateBlocked(
          registryUrl: resolved,
          extensionId: 'soundcloud',
          installedCapabilities: standard,
        ),
        isFalse,
      );
      expect(
        isOfficialRepoUpdateBlocked(
          registryUrl: resolved,
          extensionId: 'jellyfin',
          installedCapabilities: null,
        ),
        isFalse,
      );
    });

    test('allows custom extension registry updates for manually installed mods', () {
      expect(
        isOfficialRepoUpdateBlocked(
          registryUrl: custom,
          extensionId: 'qobuz-web',
          installedCapabilities: online,
        ),
        isFalse,
      );
    });
  });
}
