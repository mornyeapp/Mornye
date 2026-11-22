import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_windows/path_provider_windows.dart';

/// Runs an external command; [Process.run] in production.
typedef DesktopProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Folder created inside the OS Music folder for desktop downloads, matching
/// the mobile `Download/Mornye` and `Documents/Mornye` defaults.
const desktopOutputFolderName = 'Mornye';

/// Replaces the host Music folder in widget tests, which must not depend on
/// the test machine's OS or run `xdg-user-dir`.
@visibleForTesting
String? debugDesktopMusicDirectoryOverride;

/// Resolves the user's Music folder on Windows, Linux and macOS, or null when
/// the host gives no usable location. Parameters exist for tests.
///
/// - macOS: `~/Music`.
/// - Linux: `xdg-user-dir MUSIC`, falling back to `~/Music`.
/// - Windows: the Music known folder, falling back to `%USERPROFILE%\Music`.
Future<String?> resolveDesktopMusicDirectory({
  String? operatingSystem,
  Map<String, String>? environment,
  DesktopProcessRunner? runProcess,
  Future<String?> Function()? windowsMusicFolder,
}) async {
  if (operatingSystem == null && debugDesktopMusicDirectoryOverride != null) {
    return debugDesktopMusicDirectoryOverride;
  }
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  switch (os) {
    case 'macos':
      return _join(p.posix, env['HOME'], 'Music');
    case 'linux':
      final home = env['HOME'];
      try {
        final result = await (runProcess ?? Process.run)('xdg-user-dir', [
          'MUSIC',
        ]);
        final path = '${result.stdout}'.trim();
        // xdg-user-dir prints HOME when the Music entry is not configured.
        if (result.exitCode == 0 &&
            p.posix.isAbsolute(path) &&
            !p.posix.equals(path, home ?? '')) {
          return path;
        }
      } catch (_) {
        // xdg-user-dirs is optional; use the conventional folder instead.
      }
      return _join(p.posix, home, 'Music');
    case 'windows':
      try {
        final known = await (windowsMusicFolder ?? _windowsKnownMusicFolder)();
        if (known != null && known.isNotEmpty) return known;
      } catch (_) {
        // Fall back to the profile folder below.
      }
      return _join(p.windows, env['USERPROFILE'], 'Music');
  }
  return null;
}

/// The default download folder on desktop: `<Music>/Mornye`.
Future<String?> resolveDesktopDefaultOutputDirectory({
  String? operatingSystem,
  Map<String, String>? environment,
  DesktopProcessRunner? runProcess,
  Future<String?> Function()? windowsMusicFolder,
}) async {
  final music = await resolveDesktopMusicDirectory(
    operatingSystem: operatingSystem,
    environment: environment,
    runProcess: runProcess,
    windowsMusicFolder: windowsMusicFolder,
  );
  if (music == null) return null;
  final os = operatingSystem ?? Platform.operatingSystem;
  final context = os == 'windows' ? p.windows : p.posix;
  return context.join(music, desktopOutputFolderName);
}

/// Starts the native picker in an existing folder without creating the output.
/// Windows rejects a missing initial directory before showing the dialog.
Future<String?> resolveDesktopPickerInitialDirectory(String? preferred) async {
  final path = preferred == null || preferred.isEmpty
      ? await resolveDesktopMusicDirectory()
      : preferred;
  if (path == null || path.isEmpty || !p.isAbsolute(path)) return null;

  var directory = Directory(path);
  while (true) {
    try {
      if (await directory.exists()) return directory.path;
    } on FileSystemException {
      // An inaccessible folder can still have an accessible parent.
    }
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

/// Shows the system folder picker on desktop and returns the folder's path,
/// without the trailing separator of the picker's directory URI.
Future<String?> pickDesktopDirectoryPath({
  String? dialogTitle,
  String? initialDirectory,
}) async {
  final uri = await FilePicker.pickDirectory(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
  );
  if (uri == null || !uri.isScheme('file')) return null;
  return p.normalize(uri.toFilePath(windows: Platform.isWindows));
}

String? _join(p.Context context, String? root, String child) {
  if (root == null || root.isEmpty) return null;
  return context.join(root, child);
}

// FOLDERID_Music. The analyzer resolves path_provider_windows to its stub,
// which does not declare WindowsKnownFolder.Music.
const _windowsMusicFolderId = '{4BD8D571-6D19-48D3-BE97-422220080E43}';

Future<String?> _windowsKnownMusicFolder() => kMornyeMobileBuild
    ? Future<String?>.value()
    : PathProviderWindows().getPath(_windowsMusicFolderId);
