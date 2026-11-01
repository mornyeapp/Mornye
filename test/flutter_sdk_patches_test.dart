import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/prepare_flutter_sdk.dart' as preparation;

const _original = '''
              if (!parentInSemanticsTree.geometryDirty) {
                targets.add(parentInSemanticsTree);
              } else {
                final _RenderObjectSemantics? firstAncestorNodeWithCleanGeometry =
                    parentInSemanticsTree.firstAncestorNodeWithCleanGeometry;
                // firstAncestorNodeWithCleanGeometry can be null if this is a blocked branch.
''';

void main() {
  late Directory sdk;
  late File source;
  late File version;

  setUp(() async {
    sdk = await Directory.systemTemp.createTemp('flutter-patch-');
    source = File('${sdk.path}/packages/flutter/lib/src/rendering/object.dart');
    await source.parent.create(recursive: true);
    await source.writeAsString(_original);
    version = File('${sdk.path}/bin/cache/flutter.version.json');
    await version.parent.create(recursive: true);
    await version.writeAsString(jsonEncode({'frameworkVersion': '3.47.8'}));
    final result = await Process.run('git', ['init', '--quiet', sdk.path]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
  });
  tearDown(() => sdk.delete(recursive: true));

  Future<bool> prepare({bool checkOnly = false}) =>
      preparation.prepareFlutterSdk(
        sdk: sdk,
        project: Directory.current,
        checkOnly: checkOnly,
      );

  for (final crlf in [false, true]) {
    test('patches once and verifies cached SDKs (CRLF: $crlf)', () async {
      if (crlf) await source.writeAsString(_original.replaceAll('\n', '\r\n'));
      expect(await prepare(), isTrue);
      final patched = await source.readAsBytes();
      final text = utf8.decode(patched).replaceAll('\r\n', '\n');
      expect(
        text,
        contains(
          'parentInSemanticsTree.computeAncestorInfo(treeShapeToken);\n'
          '                final _RenderObjectSemantics?',
        ),
      );
      expect(await prepare(), isFalse);
      expect(await prepare(checkOnly: true), isFalse);
      expect(await source.readAsBytes(), patched);
    });
  }

  test('check-only detects an unprepared SDK without changing it', () async {
    await expectLater(prepare(checkOnly: true), throwsStateError);
    expect(await source.readAsString(), _original);
  });

  test('a different Flutter version fails before applying the patch', () async {
    await version.writeAsString(jsonEncode({'frameworkVersion': '3.47.5'}));
    await expectLater(prepare(), throwsStateError);
    expect(await source.readAsString(), _original);
  });

  test('a new project pin requires review before touching the SDK', () async {
    final project = await Directory.systemTemp.createTemp('flutter-new-pin-');
    addTearDown(() => project.delete(recursive: true));
    await File(
      '${project.path}/.fvmrc',
    ).writeAsString(jsonEncode({'flutter': '3.47.9'}));
    await expectLater(
      preparation.prepareFlutterSdk(sdk: sdk, project: project),
      throwsStateError,
    );
    expect(await source.readAsString(), _original);
  });

  test('an uninitialized SDK fails without modifying source', () async {
    await version.delete();
    await expectLater(prepare(), throwsStateError);
    expect(await source.readAsString(), _original);
  });

  test('unexpected source fails without making a partial change', () async {
    await source.writeAsString('different SDK source');
    await expectLater(prepare(), throwsStateError);
    expect(await source.readAsString(), 'different SDK source');
  });

  test('uses the SDK belonging to the executing Dart binary', () {
    final root = preparation.sdkFromDartExecutable(
      '${sdk.path}/bin/cache/dart-sdk/bin/dart',
    );
    expect(root.path, sdk.path);
  });
}
