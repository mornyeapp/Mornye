import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/motion_artwork_folder.dart';
import 'package:mornye/services/saf_siblings.dart';

const _song = 'content://tree/a/document/song';
const _lrc = (uri: 'content://tree/a/document/lrc', size: 4, modified: 1);
const _cover = (uri: 'content://tree/a/document/cover', size: 9, modified: 2);

void main() {
  var now = DateTime(2026);
  final asked = <(String, List<String>, List<String>)>[];
  SafSiblingList? found;
  Object? error;

  SafSiblings siblings() => SafSiblings(
    now: () => now,
    find: (song, {required extensions, required names}) async {
      asked.add((song, extensions, names));
      if (error != null) throw error!;
      return found;
    },
  );

  setUp(() {
    now = DateTime(2026);
    asked.clear();
    found = (sidecars: {'lrc': _lrc}, files: {motionArtworkFileName: _cover});
    error = null;
  });

  test('asks for the lyrics files and the animated cover together', () {
    expect(SafSiblings.extensions, [mlrcExtension, lrcExtension]);
    expect(SafSiblings.names, [motionArtworkFileName]);
  });

  test('lookups of one song start share one listing', () async {
    final lookup = siblings();
    final (mlrc, lrc, cover) = await (
      lookup.sidecar(_song, mlrcExtension),
      lookup.sidecar(_song, lrcExtension),
      lookup.file(_song, motionArtworkFileName),
    ).wait;
    now = now.add(const Duration(seconds: 5));
    expect(await lookup.sidecar(_song, lrcExtension), _lrc);
    expect(asked, [(_song, SafSiblings.extensions, SafSiblings.names)]);
    expect(mlrc, isNull);
    expect(lrc, _lrc);
    expect(cover, _cover);
  });

  test('a later start lists the folder again', () async {
    final lookup = siblings();
    expect(await lookup.sidecar(_song, lrcExtension), _lrc);
    found = (sidecars: {}, files: {});
    now = now.add(const Duration(seconds: 10));
    expect(await lookup.sidecar(_song, lrcExtension), isNull);
    expect(asked, hasLength(2));
  });

  test('another song lists its own folder', () async {
    final lookup = siblings();
    await lookup.sidecar(_song, lrcExtension);
    await lookup.sidecar('${_song}2', lrcExtension);
    expect(asked.map((entry) => entry.$1), [_song, '${_song}2']);
  });

  test('a forgotten song lists its folder again', () async {
    final lookup = siblings();
    await lookup.sidecar(_song, lrcExtension);
    lookup.forget(_song);
    await lookup.sidecar(_song, lrcExtension);
    lookup.forget();
    await lookup.file(_song, motionArtworkFileName);
    expect(asked, hasLength(3));
  });

  test('a folder that cannot be read has nothing beside the song', () async {
    found = null;
    final lookup = siblings();
    expect(await lookup.sidecar(_song, lrcExtension), isNull);
    expect(await lookup.file(_song, motionArtworkFileName), isNull);
    expect(asked, hasLength(1));
  });

  test('a failed listing is asked again', () async {
    error = StateError('provider');
    final lookup = siblings();
    await expectLater(lookup.sidecar(_song, lrcExtension), throwsStateError);
    error = null;
    expect(await lookup.sidecar(_song, lrcExtension), _lrc);
    expect(asked, hasLength(2));
  });
}
