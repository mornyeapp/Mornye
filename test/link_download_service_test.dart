import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';

Extension _extension(
  String id, {
  bool enabled = true,
  bool download = false,
  bool metadata = false,
  List<String> replaces = const [],
}) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1.0.0',
  description: 'Example provider',
  enabled: enabled,
  status: 'loaded',
  hasDownloadProvider: download,
  hasMetadataProvider: metadata,
  capabilities: {if (replaces.isNotEmpty) 'replacesBuiltInProviders': replaces},
);

void main() {
  final extensions = ExtensionState(
    extensions: [
      _extension('example.catalog', metadata: true),
      _extension('example.store', download: true),
      _extension('example.backup', download: true),
      _extension('example.off', download: true, enabled: false),
      _extension('example.mirror', download: true, replaces: ['legacy']),
    ],
  );

  String resolve(
    String? requested, {
    String defaultService = 'example.store',
  }) => linkDownloadServiceFor(
    requested,
    defaultService: defaultService,
    extensions: extensions,
  );

  test('a hint that downloads here is used', () {
    expect(resolve('example.backup'), 'example.backup');
    expect(resolve(' EXAMPLE.BACKUP '), 'example.backup');
  });

  test('a metadata-only hint falls back to the default download service', () {
    expect(resolve('example.catalog'), 'example.store');
    expect(
      resolve('example.catalog', defaultService: 'example.backup'),
      'example.backup',
    );
  });

  test('a disabled or unknown hint falls back to the default', () {
    expect(resolve('example.off'), 'example.store');
    expect(resolve('example.unknown'), 'example.store');
  });

  test('a hint naming a replaced built-in provider uses its replacement', () {
    expect(resolve('legacy'), 'example.mirror');
  });

  test('no hint uses the default, and an unusable default the first one', () {
    expect(resolve(null), 'example.store');
    expect(resolve('  '), 'example.store');
    expect(resolve(null, defaultService: 'example.catalog'), 'example.store');
  });

  test('nothing to download with gives an empty service', () {
    expect(
      linkDownloadServiceFor(
        'example.catalog',
        defaultService: 'example.catalog',
        extensions: ExtensionState(
          extensions: [_extension('example.catalog', metadata: true)],
        ),
      ),
      isEmpty,
    );
  });
}
