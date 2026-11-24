import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/switching_playback_deck.dart';

/// macOS: AVPlayer cannot play while the app holds the output in hog mode,
/// so exclusive output plays through a libmpv deck (`audio-exclusive`)
/// instead. This deck plays through the shared deck and moves to a libmpv
/// deck while [playbackExclusiveOutput] is on; a change mid-track reopens the
/// source on the other deck where it was. Leaving exclusive output disposes
/// the libmpv deck, which gives the device back.
class ExclusiveOutputDeck extends SwitchingPlaybackDeck {
  ExclusiveOutputDeck({
    required PlaybackDeck shared,
    required PlaybackDeck Function() createExclusive,
    required bool Function() exclusiveAvailable,
  }) : _exclusiveAvailable = exclusiveAvailable,
       super(
         primary: shared,
         createAlternate: createExclusive,
         trigger: playbackExclusiveOutput,
       );

  final bool Function() _exclusiveAvailable;

  @override
  String get switchName => 'Exclusive output';

  @override
  bool get reloadsOnChange => true;

  @override
  bool get routesEachSource => false;

  @override
  bool wantsAlternate(DeckSource? source) {
    if (!playbackExclusiveOutput.value) return false;
    if (_exclusiveAvailable()) return true;
    playbackExclusiveStatus.value = ExclusiveOutputStatus.unavailable;
    return false;
  }
}
