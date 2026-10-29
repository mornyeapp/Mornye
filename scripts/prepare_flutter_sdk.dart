import 'dart:convert';
import 'dart:io';

const _patchedVersion = '3.47.8';

/// Backport for https://github.com/flutter/flutter/pull/192724.
/// Reviewed against 3.47.8, which still lacks the ancestor-cache refresh.
/// Retire or review this patch when upgrading the pinned SDK.
Future<bool> prepareFlutterSdk({
  required Directory sdk,
  required Directory project,
  bool checkOnly = false,
}) async {
  final pin =
      jsonDecode(File('${project.path}/.fvmrc').readAsStringSync())
          as Map<String, dynamic>;
  if (pin['flutter'] != _patchedVersion) {
    throw StateError('Review the semantics patch for the new Flutter pin.');
  }
  final versionFile = File('${sdk.path}/bin/cache/flutter.version.json');
  if (!versionFile.existsSync()) {
    throw StateError('Initialize the pinned SDK with flutter --version first.');
  }
  final version =
      jsonDecode(versionFile.readAsStringSync()) as Map<String, dynamic>;
  if (version['frameworkVersion'] != _patchedVersion) {
    throw StateError('Flutter $_patchedVersion is required for this patch.');
  }
  final patch = File(
    '${project.path}/patches/flutter/$_patchedVersion-semantics-geometry.patch',
  ).absolute.path;

  Future<ProcessResult> apply(List<String> flags) => Process.run('git', [
    '-C',
    sdk.absolute.path,
    'apply',
    '--ignore-space-change',
    ...flags,
    patch,
  ]);

  if ((await apply(['--reverse', '--check'])).exitCode == 0) return false;
  final validation = await apply(['--check']);
  if (validation.exitCode != 0) {
    throw StateError(
      'Flutter semantics patch does not match this SDK: '
      '${validation.stderr}',
    );
  }
  if (checkOnly) {
    throw StateError(
      'Flutter semantics patch is missing. Run '
      'dart scripts/prepare_flutter_sdk.dart before testing or building.',
    );
  }
  final result = await apply([]);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not apply Flutter semantics patch: ${result.stderr}',
    );
  }
  if ((await apply(['--reverse', '--check'])).exitCode != 0) {
    throw StateError('Flutter semantics patch verification failed.');
  }
  return true;
}

/// The bundled Dart executable is `<Flutter>/bin/cache/dart-sdk/bin/dart`.
Directory sdkFromDartExecutable(String executable) =>
    File(executable).parent.parent.parent.parent.parent;

Future<void> main(List<String> arguments) async {
  Directory? sdk;
  var checkOnly = false;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--check') {
      checkOnly = true;
    } else if (arguments[i] == '--sdk' && i + 1 < arguments.length) {
      sdk = Directory(arguments[++i]);
    } else {
      stderr.writeln(
        'Usage: dart scripts/prepare_flutter_sdk.dart '
        '[--sdk <Flutter SDK>] [--check]',
      );
      exitCode = 64;
      return;
    }
  }
  try {
    final changed = await prepareFlutterSdk(
      sdk: sdk ?? sdkFromDartExecutable(Platform.resolvedExecutable),
      project: File.fromUri(Platform.script).parent.parent,
      checkOnly: checkOnly,
    );
    stdout.writeln(
      'Flutter $_patchedVersion: semantics geometry patch '
      '${changed ? 'applied' : 'verified'}.',
    );
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
