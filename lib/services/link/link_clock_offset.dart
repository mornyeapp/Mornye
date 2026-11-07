/// How far a paired device's clock runs from this one, worked out from
/// requests that read it.
///
/// A reply the other device stamped at `remoteMs` on its own clock, to a
/// request sent at `sentMs` and answered at `receivedMs` here, was stamped
/// about halfway between the two. The sample with the shortest round trip
/// is the most exact: the way there and back can differ by no more than it.
class LinkClockOffset {
  LinkClockOffset({
    this.keep = 8,
    this.maxRoundTripMs = 2000,
    this.minimumSamples = 3,
    this.resampleAfterMs = 60000,
  });

  /// The most recent samples kept, so a changed network path ages out.
  final int keep;

  /// A slower round trip says too little about either way to keep.
  final int maxRoundTripMs;

  /// Samples wanted before the offset settles.
  final int minimumSamples;

  /// How long the newest sample stays fresh.
  final int resampleAfterMs;

  final _samples = <({int offsetMs, int roundTripMs, int atMs})>[];

  /// Adds a reply stamped [remoteMs] on the other clock, to a request sent
  /// at [sentMs] and answered at [receivedMs] on this one.
  void add({
    required int sentMs,
    required int receivedMs,
    required int remoteMs,
  }) {
    final roundTrip = receivedMs - sentMs;
    if (roundTrip < 0 || roundTrip > maxRoundTripMs || remoteMs <= 0) return;
    _samples.add((
      offsetMs: remoteMs - (sentMs + (roundTrip ~/ 2)),
      roundTripMs: roundTrip,
      atMs: receivedMs,
    ));
    if (_samples.length > keep) _samples.removeAt(0);
  }

  /// The other clock minus this one, from the sample with the shortest
  /// round trip, or null before any.
  int? get offsetMs {
    if (_samples.isEmpty) return null;
    var best = _samples.first;
    for (final sample in _samples.skip(1)) {
      if (sample.roundTripMs < best.roundTripMs) best = sample;
    }
    return best.offsetMs;
  }

  /// Whether another sample would help at [nowMs]: too few yet, or the
  /// newest is old.
  bool wantsSample(int nowMs) =>
      _samples.length < minimumSamples ||
      nowMs - _samples.last.atMs >= resampleAfterMs;

  /// Forgets every sample, as after reconnecting over another path.
  void clear() => _samples.clear();
}
