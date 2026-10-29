import 'dart:math';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:mornye/services/network_storage_service.dart';

typedef SmbListingInput = ({List<Smb2DirEntry> files, String path});

// Frozen adapter and comparator from NetworkStorageService.list/_sorted.
List<NetworkEntry> legacySmbListing(SmbListingInput input) =>
    [
      for (final file in input.files)
        if (file.name != '.' && file.name != '..')
          NetworkEntry(
            '${input.path}${file.name}${file.stat.isDirectory ? '/' : ''}',
            file.name,
            directory: file.stat.isDirectory,
            size: file.stat.size,
          ),
    ]..sort(
      (a, b) => a.directory != b.directory
          ? (a.directory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

SmbListingInput smbListingFixture(int count) {
  const names = [
    'Track',
    'track',
    'Ångström',
    'İstanbul',
    '音楽 🎵',
    'Κόσμος',
    'ß',
  ];
  final random = Random(8127);
  final files = List.generate(count, (index) {
    final directory = index % 7 == 0;
    return Smb2DirEntry(
      name: switch (index) {
        0 => '.',
        1 => '..',
        _ =>
          '${names[index % names.length]} — ${index % 400 == 3 ? 'SAME' : index.toString()} Album with spaces #1${directory ? '' : '.flac'}',
      },
      stat: Smb2Stat(
        type: directory ? Smb2FileType.directory : Smb2FileType.file,
        size: 1000000000 + index,
        modified: DateTime.fromMillisecondsSinceEpoch(
          1700000000000 + index,
          isUtc: true,
        ),
        created: DateTime.fromMillisecondsSinceEpoch(
          1600000000000 + index,
          isUtc: true,
        ),
        accessed: DateTime.fromMillisecondsSinceEpoch(
          1700000000000 + index,
          isUtc: true,
        ),
        changed: DateTime.fromMillisecondsSinceEpoch(
          1700000000000 + index,
          isUtc: true,
        ),
      ),
    );
  })..shuffle(random);
  return (files: files, path: 'Folder #1/');
}

List<Object?> smbListingRows(List<NetworkEntry> entries) => [
  for (final entry in entries)
    [entry.path, entry.name, entry.directory, entry.size],
];
