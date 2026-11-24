import 'dart:math' as math;

/// Symmetric list padding that lets the first and last lyric lines reach the
/// vertical center instead of getting pinned to a viewport edge.
double syncedLyricsCenterPadding({
  required double viewportDimension,
  required double estimatedLineExtent,
  double minimumPadding = 24,
}) {
  return math.max(
    minimumPadding,
    (viewportDimension - estimatedLineExtent) / 2,
  );
}

/// Estimated scroll offset when symmetric center padding is applied.
double syncedLyricsEstimatedOffset({
  required int index,
  required double estimatedLineExtent,
}) {
  if (index <= 0) return 0;
  return index * estimatedLineExtent;
}

/// Advances to the final lyric line whose timestamp is already due.
int syncedLyricsDueLineIndex({
  required List<Duration> lineStarts,
  required int currentIndex,
  required Duration position,
}) {
  if (lineStarts.isEmpty) return -1;
  var dueIndex = currentIndex;
  if (dueIndex < -1) dueIndex = -1;
  if (dueIndex >= lineStarts.length) dueIndex = lineStarts.length - 1;
  while (dueIndex + 1 < lineStarts.length &&
      lineStarts[dueIndex + 1] <= position) {
    dueIndex++;
  }
  return dueIndex;
}

/// The line to show at [position] while playback advances, given the line
/// [shown] already, which starts at [shownStart]. A [position] only a little
/// behind [shownStart], as a late position report is, keeps [shown] instead
/// of stepping back to the line before for a moment. A seek back of
/// [seekThreshold] or more moves to [index] at once.
int steadySyncedLyricsIndex({
  required int index,
  required int shown,
  required Duration shownStart,
  required Duration position,
  Duration seekThreshold = const Duration(milliseconds: 750),
}) => index < shown && shownStart - position < seekThreshold ? shown : index;

/// How far ahead of the audio clock playing lyrics are drawn. A frame reaches
/// the screen about two refresh intervals after it is drawn, so lyrics drawn
/// for the position at that moment always showed that much behind the sound.
Duration lyricsDisplayLead(double? refreshRate) {
  final rate = refreshRate != null && refreshRate.isFinite && refreshRate >= 30
      ? refreshRate
      : 60.0;
  return Duration(microseconds: (2e6 / rate).round().clamp(8000, 40000));
}

/// Extrapolates the latest player position for the lyrics animation only.
///
/// The global playback state intentionally updates at a lower frequency to
/// avoid rebuilding unrelated UI on every frame. The active lyric line uses
/// this value to animate between those updates.
Duration interpolatedSyncedLyricsPosition({
  required Duration anchorPosition,
  required Duration elapsedSinceAnchor,
  required bool isPlaying,
}) {
  if (!isPlaying || elapsedSinceAnchor.isNegative) return anchorPosition;
  return anchorPosition + elapsedSinceAnchor;
}

/// How long the lyric clock takes to close the gap to a reported position.
const syncedLyricsCatchUpWindow = Duration(seconds: 2);

/// How fast the lyric clock runs, relative to playback, to close the gap to
/// a reported position over [window]: a little slow when the report is
/// behind, a little fast when it is ahead. The highlight keeps moving
/// forward from where it is, where stepping to the report moved it back a
/// few letters whenever one was behind. Null for a seek or another large
/// change, which is applied at once.
double? syncedLyricsCatchUpRate({
  required Duration predictedPosition,
  required Duration reportedPosition,
  Duration seekThreshold = const Duration(milliseconds: 750),
  Duration window = syncedLyricsCatchUpWindow,
}) {
  final drift = reportedPosition - predictedPosition;
  if (drift.abs() >= seekThreshold) return null;
  return (1 + drift.inMicroseconds / window.inMicroseconds).clamp(0.5, 1.5);
}

/// Continuous progress for one timed TTML or enhanced LRC segment.
double syncedLyricSegmentProgress({
  required Duration position,
  required Duration start,
  required Duration end,
}) {
  if (position <= start) return 0;
  if (position >= end || end <= start) return 1;
  return (position - start).inMicroseconds / (end - start).inMicroseconds;
}

/// Subtle vertical emphasis relative to the normal highlighted position.
/// Long timed segments rise further while held, then settle back to 1. This
/// follows lyric duration, not pitch, and is deterministic on pause or seek.
double syncedLyricSegmentLift({
  required Duration position,
  required Duration start,
  required Duration end,
}) {
  if (end <= start) return 0;
  final elapsed = (position - start).inMicroseconds / 1000;
  final duration = (end - start).inMicroseconds / 1000;
  double ease(double value) {
    final t = value.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  // Start gently before the color sweep and let the movement trail it. Keep
  // this envelope independent of word length: fast syllables must not snap
  // upwards just because their highlight finishes in a few frames.
  // The whole timed word shares this movement, independent of the color sweep.
  final normalLift = ease((elapsed + 180) / 720);
  final heldStrength = ((duration - 1000) / 1500).clamp(0.0, 1.0);
  if (heldStrength == 0) return normalLift;
  final rise = ease((elapsed - 400) / math.min(1200, (duration - 400) * 0.6));
  final settle = ease((duration - elapsed) / 600);
  return normalLift + 1.3 * heldStrength * rise * settle;
}

/// Glow strength from 0 to 1 for a word held for a long time. Short words
/// never glow; a held word brightens while it is sung, then fades shortly
/// after its end instead of switching off with the sweep.
double syncedLyricSegmentGlow({
  required Duration position,
  required Duration start,
  required Duration end,
}) {
  final duration = (end - start).inMicroseconds / 1000;
  final strength = ((duration - 900) / 1100).clamp(0.0, 1.0);
  if (strength == 0) return 0;
  final elapsed = (position - start).inMicroseconds / 1000;
  double ease(double value) {
    final t = value.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  final rise = ease((elapsed - 250) / math.min(900, duration * 0.5));
  final fade = ease((duration + 500 - elapsed) / 500);
  return strength * rise * fade;
}
