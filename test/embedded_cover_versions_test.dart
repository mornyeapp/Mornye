import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/embedded_cover_versions.dart';

void main() {
  test('a new cover reaches only the rows of its file', () {
    final versions = EmbeddedCoverVersions();
    var first = 0;
    var second = 0;
    void onFirst() => first++;
    void onSecond() => second++;
    versions.of('/music/a.flac').addListener(onFirst);
    versions.of('/music/b.flac').addListener(onSecond);

    versions.bump(['/music/a.flac']);
    expect((first, second), (1, 0));

    versions.bump();
    expect((first, second), (2, 1));

    versions.of('/music/a.flac').removeListener(onFirst);
    versions.bump(['/music/a.flac']);
    expect((first, second), (2, 1));
  });

  test('the value changes with every bump', () {
    final versions = EmbeddedCoverVersions();
    final version = versions.of('/music/a.flac');
    final before = version.value;
    versions.bump(['/music/b.flac']);
    expect(version.value, isNot(before));
  });

  test('a file keeps one callback, and old ones are dropped', () {
    final versions = EmbeddedCoverVersions(maxCallbacks: 2);
    final changed = <String>[];
    final a = versions.callbackFor('a', changed.add);
    expect(identical(versions.callbackFor('a', changed.add), a), isTrue);

    versions.callbackFor('b', changed.add);
    versions.callbackFor('c', changed.add);
    expect(identical(versions.callbackFor('a', changed.add), a), isFalse);

    a();
    expect(changed, ['a']);
  });

  testWidgets('a row rebuilt for the same file keeps listening', (
    tester,
  ) async {
    final versions = EmbeddedCoverVersions();
    var builds = 0;
    Widget row() => ValueListenableBuilder<int>(
      valueListenable: versions.of('/music/a.flac'),
      builder: (context, _, _) {
        builds++;
        return const SizedBox();
      },
    );

    await tester.pumpWidget(row());
    await tester.pumpWidget(row());
    final settled = builds;

    versions.bump(['/music/a.flac']);
    await tester.pump();
    expect(builds, settled + 1);

    // More rows than any cap: a row still on screen is never cut off.
    for (var i = 0; i < 2000; i++) {
      versions.of('/music/other-$i.flac');
    }
    versions.bump(['/music/a.flac']);
    await tester.pump();
    expect(builds, settled + 2);

    await tester.pumpWidget(const SizedBox());
    versions.bump(['/music/a.flac']);
    await tester.pump();
    expect(builds, settled + 2);
  });
}
