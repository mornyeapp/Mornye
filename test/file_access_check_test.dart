import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/file_access_check.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';

void main() {
  test('a computer treats a phone content URI as absent', () async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    expect(await fileExists('content://provider/music/track.flac'), isFalse);
  });

  test('found files retain their size and modification time', () async {
    final stat = FileAccessStat(size: 123, modified: DateTime(2026));
    final result = await checkFileAccess(
      '/music/track.flac',
      readStat: (_) async => stat,
    );
    expect(result, isA<FileAccessFound>());
    expect((result as FileAccessFound).stat, same(stat));
  });

  test('only a confirmed absent file is missing', () async {
    final result = await checkFileAccess(
      '/music/removed.flac',
      readStat: (_) async => null,
    );
    expect(result, isA<FileAccessMissing>());
  });

  for (final code in ['permission_denied', 'provider_unavailable']) {
    test('$code is unavailable and retains its diagnostic', () async {
      final error = PlatformException(code: code);
      final result = await checkFileAccess(
        'content://provider/music/track.flac',
        readStat: (_) async => throw error,
      );
      expect(result, isA<FileAccessUnavailable>());
      expect((result as FileAccessUnavailable).error, same(error));
      expect(result.stack.toString(), isNotEmpty);
    });
  }
}
