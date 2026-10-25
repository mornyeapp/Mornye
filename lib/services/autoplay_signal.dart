import 'package:mornye/services/playable_media.dart';

/// A relevance signal one autoplay refill uses beside the songs' metadata,
/// such as how songs sound or what the listener plays them with. Ranking may
/// run on another isolate, so a signal holds plain data and no services.
abstract class AutoplaySignal {
  const AutoplaySignal();

  /// Called once per refill before scoring. [session] holds the songs heard
  /// and queued in playback order, newest last; [candidates] the songs that
  /// may be picked.
  void prepare(List<PlayableMedia> session, List<PlayableMedia> candidates) {}

  /// Added once to [candidate]'s score. A song the signal knows nothing
  /// about should score about what an average known song does, so partly
  /// known Libraries do not favor the known songs.
  double score(PlayableMedia candidate) => 0;

  /// Added when choosing the song after [previous], the song it would
  /// follow in the queue.
  double follow(PlayableMedia previous, PlayableMedia candidate) => 0;
}
