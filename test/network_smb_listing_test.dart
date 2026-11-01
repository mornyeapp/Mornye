import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/smb_listing_benchmark.dart';

void main() {
  for (final count in [0, 1, 32, 256, 4095, 4096, 10000]) {
    test(
      'SMB adapter retains original order and values for $count entries',
      () async {
        final input = smbListingFixture(count);
        final original = [...input.files];
        final expected = smbListingRows(legacySmbListing(input));
        final result = await NetworkStorageService.prepareSmbEntries(
          input.files,
          input.path,
        );
        expect(smbListingRows(result), expected);
        expect(input.files, original);
        expect(
          result.any((entry) => entry.name == '.' || entry.name == '..'),
          isFalse,
        );
      },
    );
  }

  test(
    'case ties, links, literal paths and large sizes retain their semantics',
    () async {
      final date = DateTime.utc(2026);
      final input = (
        path: '100% + #1/日本語/',
        files: [
          for (final (name, type, size) in [
            ('Same', Smb2FileType.file, 9007199254740991),
            ('SAME', Smb2FileType.directory, 1),
            ('same', Smb2FileType.file, 2),
            ('same', Smb2FileType.link, 3),
            ('İ.dot', Smb2FileType.file, 4),
            ('i.dot', Smb2FileType.file, 5),
            ('literal%20 #+.mp3', Smb2FileType.file, 6),
            ('..', Smb2FileType.directory, 0),
            ('.', Smb2FileType.directory, 0),
          ])
            Smb2DirEntry(
              name: name,
              stat: Smb2Stat(
                type: type,
                size: size,
                modified: date,
                created: date,
                accessed: date,
                changed: date,
              ),
            ),
        ],
      );
      final result = await NetworkStorageService.prepareSmbEntries(
        input.files,
        input.path,
      );
      expect(smbListingRows(result), smbListingRows(legacySmbListing(input)));
      expect(result.first.path, '100% + #1/日本語/SAME/');
      expect(result.where((entry) => entry.directory), hasLength(1));
      expect(result.singleWhere((entry) => entry.size == 3).directory, isFalse);
      expect(result.any((entry) => entry.size == 9007199254740991), isTrue);
      expect(
        result.every(
          (entry) => entry.modifiedTime == date.millisecondsSinceEpoch,
        ),
        isTrue,
      );
    },
  );
}
