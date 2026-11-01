import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_directory_index.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:mornye/utils/windows_path_identity.dart';

void main() {
  test('extended drive and UNC paths share physical and folder identities', () {
    for (final pair in [
      (r'C:\Music\song.flac', r'\\?\C:\Music\song.flac'),
      (r'\\server\share\song.flac', r'\\?\UNC\server\share\song.flac'),
    ]) {
      expect(windowsPathIdentity(pair.$1), windowsPathIdentity(pair.$2));
      expect(physicalFilePathsMatch(pair.$1, pair.$2), isTrue);
      final plain = libraryFileLocation(pair.$1)!;
      final extended = libraryFileLocation(pair.$2)!;
      expect(extended.root, plain.root);
      expect(extended.folders, plain.folders);
      expect(extended.fileName, plain.fileName);
      expect(
        buildPathMatchKeys(pair.$2),
        contains('windows-file:${windowsPathIdentity(pair.$1)}'),
      );
    }
    expect(
      physicalFilePathsMatch(r'C:\Music\song.flac', r'\\?\C:\Music\song.opus'),
      isFalse,
    );
    expect(
      buildPathMatchKeys(r'\\?\C:\Music\song.flac'),
      isNot(contains('windows-file:C:/Music/song')),
    );
  });

  test('device namespaces and verbatim-only names have no ordinary alias', () {
    for (final path in [
      r'\\.\PhysicalDrive0',
      r'\\?\Volume{123}\a',
      r'\\?\C:\a.\b',
      r'\\?\C:\a \b',
      '/music/a.flac',
      'network://id/a',
    ]) {
      expect(windowsPathIdentity(path), isNull, reason: path);
    }
  });
}
