import 'dart:async';

import 'package:mornye/services/platform_bridge.dart';

typedef SafSibling = ({String uri, int size, int modified});

typedef SafSiblingList = ({
  Map<String, SafSibling> sidecars,
  Map<String, SafSibling> files,
});

typedef SafSiblingFinder =
    Future<SafSiblingList?> Function(
      String song, {
      required List<String> extensions,
      required List<String> names,
    });

/// The files a song start looks for beside an Android document: its `.mlrc`
/// and `.lrc` sidecars and its folder's `cover.mp4`. One listing of the
/// song's folder answers all of them. Lookups of one song shortly after each
/// other share that listing, so a file added or removed later is seen when
/// the song starts again.
class SafSiblings {
  SafSiblings({SafSiblingFinder? find, DateTime Function()? now})
    : _find = find ?? PlatformBridge.findSafSiblings,
      _now = now ?? DateTime.now;

  static final instance = SafSiblings();

  /// The sidecar extensions and file names one listing answers.
  static const extensions = ['mlrc', 'lrc'];
  static const names = ['cover.mp4'];

  /// Long enough for the lookups of one song start, which wait on the
  /// song's own tags, and short enough that a replay asks the folder again.
  static const _keepFor = Duration(seconds: 10);

  final SafSiblingFinder _find;
  final DateTime Function() _now;
  final _found = <String, (DateTime, Future<SafSiblingList?>)>{};

  /// The sidecar of [song] with [extension], one of [extensions], or null
  /// when its folder has none.
  Future<SafSibling?> sidecar(String song, String extension) async =>
      (await _lookup(song))?.sidecars[extension];

  /// The file [name], one of [names], in the folder of [song], or null when
  /// the folder has none.
  Future<SafSibling?> file(String song, String name) async =>
      (await _lookup(song))?.files[name];

  /// Forgets what was found beside [song], or beside every song, after a
  /// change to its folder.
  void forget([String? song]) {
    if (song == null) {
      _found.clear();
    } else {
      _found.remove(song);
    }
  }

  Future<SafSiblingList?> _lookup(String song) {
    final now = _now();
    final found = _found[song];
    if (found != null && now.difference(found.$1) < _keepFor) return found.$2;
    _found.removeWhere((_, entry) => now.difference(entry.$1) >= _keepFor);
    final lookup = _find(song, extensions: extensions, names: names);
    _found[song] = (now, lookup);
    // A failed lookup is asked again by the next caller.
    unawaited(
      lookup.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_found[song]?.$2, lookup)) _found.remove(song);
        },
      ),
    );
    return lookup;
  }
}
