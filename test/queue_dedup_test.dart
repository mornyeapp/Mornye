import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/queue_dedup.dart';
import 'package:mornye/services/playable_media.dart';

PlayableMedia _song(String source, {String? id}) => PlayableMedia(
  id: id ?? source,
  source: source,
  title: source,
  artist: 'Artist',
);

List<String> _sources(List<PlayableMedia> media) => [
  for (final item in media) item.source,
];

void main() {
  group('queueIdentityKey', () {
    test('matches one file whatever id it was queued with', () {
      expect(
        queueIdentityKey(_song('/music/a.flac', id: 'library-7')),
        queueIdentityKey(_song('/music/a.flac', id: 'history-3')),
      );
    });

    test('a file URI counts as its path', () {
      expect(
        queueIdentityKey(_song('file:///music/a%20b.flac')),
        '/music/a b.flac',
      );
    });

    test('a SAF document matches through a folder tree', () {
      const document =
          'content://com.android.externalstorage.documents/document/'
          'primary%3AMusic%2Fa.flac';
      const tree =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic/document/primary%3AMusic%2Fa.flac';
      expect(queueIdentityKey(_song(tree)), queueIdentityKey(_song(document)));
      expect(
        queueIdentityKey(_song(document)),
        isNot(
          queueIdentityKey(
            _song(
              'content://com.android.externalstorage.documents/document/'
              'primary%3AMusic%2Fb.flac',
            ),
          ),
        ),
      );
    });

    test('other providers and sources keep their own identity', () {
      expect(
        queueIdentityKey(_song('content://media/external/audio/media/42')),
        'content://media/external/audio/media/42',
      );
      expect(
        queueIdentityKey(_song('network://nas/Album/a.flac')),
        'network://nas/Album/a.flac',
      );
      expect(
        queueIdentityKey(_song('https://example.com/a.flac?token=1')),
        isNot(queueIdentityKey(_song('https://example.com/a.flac?token=2'))),
      );
      expect(
        queueIdentityKey(_song('/music/album.cue#track01')),
        isNot(queueIdentityKey(_song('/music/album.cue#track02'))),
      );
    });

    test('a different file with the same tags is a different song', () {
      expect(
        queueIdentityKey(_song('/music/a.flac')),
        isNot(queueIdentityKey(_song('/music/a.mp3'))),
      );
    });
  });

  group('planQueueWithoutDuplicates', () {
    final queue = [
      _song('/played.flac'),
      _song('/current.flac'),
      _song('/next.flac'),
      _song('/later.flac'),
    ];

    test('replaces upcoming copies, highest index first', () {
      final plan = planQueueWithoutDuplicates(
        queue: queue,
        current: 1,
        incoming: [_song('/next.flac'), _song('/later.flac')],
      );
      expect(plan.remove, [3, 2]);
      expect(_sources(plan.insert), ['/next.flac', '/later.flac']);
    });

    test('never touches the current or played songs', () {
      final plan = planQueueWithoutDuplicates(
        queue: queue,
        current: 1,
        incoming: [_song('/current.flac'), _song('/played.flac')],
      );
      expect(plan.remove, isEmpty);
      expect(_sources(plan.insert), ['/current.flac', '/played.flac']);
    });

    test('adds each song of a batch once, in order', () {
      final plan = planQueueWithoutDuplicates(
        queue: queue,
        current: 1,
        incoming: [
          _song('/new.flac'),
          _song('/later.flac'),
          _song('/new.flac', id: 'again'),
        ],
      );
      expect(plan.remove, [3]);
      expect(_sources(plan.insert), ['/new.flac', '/later.flac']);
    });

    test('an empty queue only drops repeats within the batch', () {
      final plan = planQueueWithoutDuplicates(
        queue: const [],
        current: -1,
        incoming: [_song('/a.flac'), _song('/a.flac')],
      );
      expect(plan.remove, isEmpty);
      expect(_sources(plan.insert), ['/a.flac']);
    });
  });

  test('the setting defaults to off and round-trips through JSON', () {
    expect(const AppSettings().queueNoDuplicates, isFalse);
    expect(AppSettings.fromJson(const {}).queueNoDuplicates, isFalse);
    final on = const AppSettings().copyWith(queueNoDuplicates: true);
    expect(on.toJson()['queueNoDuplicates'], isTrue);
    expect(AppSettings.fromJson(on.toJson()).queueNoDuplicates, isTrue);
  });
}
