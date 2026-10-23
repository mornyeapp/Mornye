import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/update_progress_notifications.dart';

void main() {
  test(
    'slow notifications retain only the latest progress and finish before the result',
    () async {
      final writes = <int>[];
      final completions = <Completer<void>>[];
      final notifications = UpdateProgressNotifications((received, total) {
        writes.add(received);
        final completion = Completer<void>();
        completions.add(completion);
        return completion.future;
      });
      notifications.update(0, 1000);
      for (var received = 1; received <= 1000; received++) {
        notifications.update(received, 1000);
      }
      expect(writes, [0]);
      var finished = false;
      final finish = notifications.finish().then((_) => finished = true);
      notifications.update(2000, 2000);
      completions.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(writes, [0, 1000]);
      expect(finished, isFalse);
      completions.last.complete();
      await finish;
      expect(finished, isTrue);
      notifications.update(3000, 3000);
      expect(writes, [0, 1000]);
    },
  );

  test(
    'a failed progress write cannot drop the latest value or prevent cleanup',
    () async {
      final first = Completer<void>();
      final writes = <int>[];
      final notifications = UpdateProgressNotifications((received, total) {
        writes.add(received);
        return received == 0 ? first.future : Future<void>.value();
      });
      notifications.update(0, 100);
      notifications.update(10, 100);
      notifications.update(100, 100);
      first.completeError(StateError('notification service unavailable'));
      await notifications.finish();
      expect(writes, [0, 100]);
    },
  );

  test('finishing an unused notifier prevents all later progress', () async {
    final writes = <int>[];
    final notifications = UpdateProgressNotifications((received, total) async {
      writes.add(received);
    });
    await notifications.finish();
    notifications.update(1, 2);
    await notifications.finish();
    expect(writes, isEmpty);
  });
}
