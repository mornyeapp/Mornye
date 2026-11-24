import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_clock_offset.dart';

void main() {
  test('takes the offset of the shortest round trip', () {
    final clock = LinkClockOffset();
    expect(clock.offsetMs, isNull);

    // The other clock runs 5 s ahead. A slow reply, stamped early on its
    // way, says less than a quick one.
    clock.add(sentMs: 1000, receivedMs: 1400, remoteMs: 6050);
    expect(clock.offsetMs, 4850);
    clock.add(sentMs: 2000, receivedMs: 2020, remoteMs: 7010);
    expect(clock.offsetMs, 5000);
    clock.add(sentMs: 3000, receivedMs: 3300, remoteMs: 8290);
    expect(clock.offsetMs, 5000);
  });

  test('drops replies that say nothing useful', () {
    final clock = LinkClockOffset(maxRoundTripMs: 2000);
    clock.add(sentMs: 1000, receivedMs: 900, remoteMs: 6000);
    clock.add(sentMs: 1000, receivedMs: 3500, remoteMs: 6000);
    clock.add(sentMs: 1000, receivedMs: 1010, remoteMs: 0);
    expect(clock.offsetMs, isNull);
  });

  test('keeps only recent samples and asks for more while few or old', () {
    final clock = LinkClockOffset(keep: 2, minimumSamples: 2);
    expect(clock.wantsSample(0), isTrue);
    clock.add(sentMs: 0, receivedMs: 10, remoteMs: 100);
    expect(clock.wantsSample(10), isTrue);
    clock.add(sentMs: 20, receivedMs: 60, remoteMs: 140);
    expect(clock.wantsSample(60), isFalse);
    expect(clock.wantsSample(60060), isTrue);

    // The quick first sample ages out with a third.
    clock.add(sentMs: 100, receivedMs: 140, remoteMs: 230);
    expect(clock.offsetMs, 100);

    clock.clear();
    expect(clock.offsetMs, isNull);
    expect(clock.wantsSample(200), isTrue);
  });
}
