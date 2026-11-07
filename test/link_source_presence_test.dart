import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_source_presence.dart';

bool _isLink(String source) => source.startsWith('link-');

void main() {
  testWidgets('a device shows while connected and hides after the grace', (
    tester,
  ) async {
    var changes = 0;
    final presence = LinkSourcePresence(
      onChanged: () => changes++,
      now: () => tester.binding.clock.now(),
    );

    expect(presence.availability('link-a'), isNull, reason: 'not ready');
    expect(presence.availability('nas'), isNull, reason: 'not ready');

    presence.update(ready: true, isLink: _isLink, connected: {'link-a'});
    expect(changes, 1);
    expect(presence.availability('link-a'), isTrue);
    expect(presence.availability('nas'), isTrue);
    expect(presence.availability('link-b'), isNull, reason: 'in the grace');

    await tester.pump(linkSourceOfflineGrace);
    expect(presence.availability('link-b'), isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(changes, 2, reason: 'the Library hears when the grace ends');

    presence.update(ready: true, isLink: _isLink, connected: const {});
    expect(presence.availability('link-a'), isNull);
    await tester.pump(linkSourceOfflineGrace - const Duration(seconds: 1));
    expect(presence.availability('link-a'), isNull);
    await tester.pump(const Duration(seconds: 1, milliseconds: 50));
    expect(presence.availability('link-a'), isFalse);

    final before = changes;
    presence.update(ready: true, isLink: _isLink, connected: {'link-a'});
    expect(changes, before + 1);
    expect(presence.availability('link-a'), isTrue);
    presence.dispose();
  });

  testWidgets('turned off, every device shows', (tester) async {
    var changes = 0;
    final presence = LinkSourcePresence(
      onChanged: () => changes++,
      now: () => tester.binding.clock.now(),
    );
    presence.enabled = false;
    expect(changes, 1);
    expect(presence.availability('link-a'), isTrue, reason: 'even unready');

    presence.update(ready: true, isLink: _isLink, connected: const {});
    await tester.pump(linkSourceOfflineGrace + const Duration(seconds: 1));
    expect(presence.availability('link-a'), isTrue);

    presence.enabled = true;
    expect(presence.availability('link-a'), isFalse);
    presence.dispose();
  });

  testWidgets('in the background songs wait for a fresh grace', (tester) async {
    var changes = 0;
    final presence = LinkSourcePresence(
      onChanged: () => changes++,
      now: () => tester.binding.clock.now(),
    );
    presence.update(ready: true, isLink: _isLink, connected: {'link-a'});

    presence.pause();
    presence.update(ready: true, isLink: _isLink, connected: const {});
    final paused = changes;
    await tester.pump(const Duration(minutes: 1));
    expect(presence.availability('link-a'), isNull);
    expect(changes, paused, reason: 'no grace runs in the background');

    presence.resume();
    expect(presence.availability('link-a'), isNull);
    await tester.pump(
      linkSourceOfflineGrace + const Duration(milliseconds: 50),
    );
    expect(presence.availability('link-a'), isFalse);

    presence.pause();
    presence.update(ready: true, isLink: _isLink, connected: {'link-a'});
    expect(presence.availability('link-a'), isTrue, reason: 'shows at once');
    presence.dispose();
  });
}
