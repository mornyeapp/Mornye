import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/extension_update_policy.dart';

void main() {
  const modified = <String, dynamic>{'fullTrackStreaming': true};
  const unmodified = <String, dynamic>{'fullTrackStreaming': false};

  group('pin modified .sflx, not the original extension repository', () {
    test('blocks repository replacement of each modified online extension', () {
      for (final id in ['qobuz-web', 'jellyfin', 'soundcloud']) {
        expect(
          isModifiedSflxRepoUpdateBlocked(
            extensionId: id,
            installedCapabilities: modified,
          ),
          isTrue,
          reason: 'Our modified $id package must not be overwritten',
        );
      }
    });

    test('unmodified official packages with same IDs remain updatable', () {
      for (final id in ['qobuz-web', 'jellyfin', 'soundcloud']) {
        expect(
          isModifiedSflxRepoUpdateBlocked(
            extensionId: id,
            installedCapabilities: unmodified,
          ),
          isFalse,
        );
        expect(
          isModifiedSflxRepoUpdateBlocked(
            extensionId: id,
            installedCapabilities: null,
          ),
          isFalse,
        );
      }
    });

    test('all other official extensions remain updatable', () {
      for (final id in ['tidal-web', 'deezer', 'spotify-web', 'amazon']) {
        expect(
          isModifiedSflxRepoUpdateBlocked(
            extensionId: id,
            installedCapabilities: modified,
          ),
          isFalse,
        );
      }
    });

    test('pinning is independent of repo URL, version and enabled state', () {
      // The installed package's capabilities are sufficient. The update
      // guard intentionally does not consult an official/custom URL.
      expect(
        isModifiedSflxRepoUpdateBlocked(
          extensionId: 'SOUNDCLOUD',
          installedCapabilities: modified,
        ),
        isTrue,
      );
    });
  });
}
