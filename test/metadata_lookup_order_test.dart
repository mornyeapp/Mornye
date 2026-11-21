import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/cross_extension_share_service.dart';
import 'package:mornye/widgets/cross_extension_share_sheet.dart';

Extension _extension(String id, {bool search = true, bool enabled = true}) =>
    Extension(
      id: id,
      name: id,
      displayName: id,
      version: '1.0.0',
      description: '',
      enabled: enabled,
      status: 'loaded',
      searchBehavior: SearchBehavior(enabled: search),
    );

CrossExtensionShareResult _result(String id, {bool found = true}) =>
    CrossExtensionShareResult(extensionId: id, displayName: id, found: found);

void main() {
  final state = ExtensionState(
    extensions: [
      _extension('example.one'),
      _extension('example.two'),
      _extension('example.three'),
      _extension('example.silent', search: false),
      _extension('example.off', enabled: false),
    ],
    metadataProviderPriority: const [
      'example.off',
      'example.silent',
      'example.three',
      'example.one',
    ],
  );

  List<String> order({String? source, String? searchProvider}) =>
      metadataLookupOrder(
        extensionState: state,
        allMetadataProviders: const ['example.one', 'example.three'],
        sourceProviderId: source,
        searchProvider: searchProvider,
      );

  test('a lookup follows the Metadata Priority before the search provider', () {
    expect(order(searchProvider: 'example.two'), [
      'example.three',
      'example.one',
      'example.two',
    ]);
  });

  test('an item keeps the provider it came from', () {
    expect(order(source: 'example.two', searchProvider: 'example.one'), [
      'example.two',
      'example.three',
      'example.one',
    ]);
  });

  test('extensions that are off or cannot search are not asked', () {
    expect(order(source: 'example.off', searchProvider: 'example.silent'), [
      'example.three',
      'example.one',
      'example.two',
    ]);
  });

  test('other services list by found, then Metadata Priority, then name', () {
    final sorted = sortCrossExtensionResults(
      [
        _result('example.b'),
        _result('example.three', found: false),
        _result('example.a'),
        _result('example.one'),
        _result('example.three.found'),
        _result('example.three'),
      ],
      const ['example.three', 'example.one'],
    );
    expect(
      [for (final result in sorted) '${result.extensionId}:${result.found}'],
      [
        'example.three:true',
        'example.one:true',
        'example.a:true',
        'example.b:true',
        'example.three.found:true',
        'example.three:false',
      ],
    );
  });
}
