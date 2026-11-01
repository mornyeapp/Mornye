// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_session/audio_session.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:rxdart/rxdart.dart';

import 'src/android_queue_window.dart';

AudioServicePlatform _platform = AudioServicePlatform.instance;

/// The buttons on a headset.
enum MediaButton {
  /// The "media" button on Android, or the play/pause button on iOS.
  media,

  /// The "skip to next" button.
  next,

  /// The "skip to previous" button.
  previous,
}

/// The actions associated with playing audio.
enum MediaAction {
  /// Stop playing audio.
  stop,

  /// Pause audio.
  pause,

  /// Play or resume audio.
  play,

  /// Rewind.
  rewind,

  /// Skip to the previous media item.
  skipToPrevious,

  /// Skip to the next media item.
  skipToNext,

  /// Fast forward.
  fastForward,

  /// Set a rating for the current media item.
  setRating,

  /// Seek within the current media item.
  seek,

  /// Toggle between playing and paused.
  playPause,

  /// Play a given media item by ID.
  playFromMediaId,

  /// Play media from a search.
  playFromSearch,

  /// Skip to a queue item.
  skipToQueueItem,

  /// Play media from a URI.
  playFromUri,

  /// Prepare media for playback.
  prepare,

  /// Prepare media for playback by ID.
  prepareFromMediaId,

  /// Prepare media for playback from a search.
  prepareFromSearch,

  /// Prepare media for playback from a URI.
  prepareFromUri,

  /// Set the repeat mode.
  setRepeatMode,

  /// Was depreceated in Android.
  // ignore: unused_field
  _setShuffleModeEnabled,

  /// Set captioning enabled.
  setCaptioningEnabled,

  /// Set the shuffle mode.
  setShuffleMode,

  /// Seek backwards continuously.
  seekBackward,

  /// Seek forwards continuously.
  seekForward,

  /// Set speed.
  setSpeed,

  /// Custom MediaAction.
  custom,
}

/// The states of audio processing.
enum AudioProcessingState {
  /// There hasn't been any resource loaded yet.
  idle,

  /// Resource is being loaded.
  loading,

  /// Resource is being buffered.
  buffering,

  /// Resource is buffered enough and available for playback.
  ready,

  /// The end of resource was reached.
  completed,

  /// There was an error loading resource.
  ///
  /// [PlaybackState.errorCode] and [PlaybackState.errorMessage] will be not null
  /// in this state.
  error,
}

/// The playback state which includes a [playing] boolean state, a processing
/// state such as [AudioProcessingState.buffering], the playback position and
/// the currently enabled actions to be shown in the Android notification or the
/// iOS control center.
class PlaybackState {
  /// The audio processing state e.g. [AudioProcessingState.buffering].
  final AudioProcessingState processingState;

  /// Whether audio is either playing, or will play as soon as [processingState]
  /// is [AudioProcessingState.ready]. A true value should be broadcast whenever
  /// it would be appropriate for UIs to display a pause or stop button.
  ///
  /// Since [playing] and [processingState] can vary independently, it is
  /// possible distinguish a particular audio processing state while audio is
  /// playing vs paused. For example, when buffering occurs during a seek, the
  /// [processingState] can be [AudioProcessingState.buffering], but alongside
  /// that [playing] can be true to indicate that the seek was performed while
  /// playing, or false to indicate that the seek was performed while paused.
  final bool playing;

  /// The list of currently enabled controls which should be shown in the media
  /// notification. Each control represents a clickable button with a
  /// [MediaAction] that must be one of:
  ///
  /// * [MediaAction.stop]
  /// * [MediaAction.pause]
  /// * [MediaAction.play]
  /// * [MediaAction.rewind]
  /// * [MediaAction.skipToPrevious]
  /// * [MediaAction.skipToNext]
  /// * [MediaAction.fastForward]
  /// * [MediaAction.playPause]
  final List<MediaControl> controls;

  /// Up to 3 indices of the [controls] that should appear in Android's compact
  /// media notification view. When the notification is expanded, all [controls]
  /// will be shown.
  final List<int>? androidCompactActionIndices;

  /// The set of system actions currently enabled. This is for specifying any
  /// other [MediaAction]s that are not supported by [controls], because they do
  /// not represent clickable buttons. For example:
  ///
  /// * [MediaAction.seek] (enable a seek bar)
  /// * [MediaAction.seekForward] (enable press-and-hold fast-forward control)
  /// * [MediaAction.seekBackward] (enable press-and-hold rewind control)
  ///
  /// Note that specifying [MediaAction.seek] in [systemActions] will enable a
  /// seek bar in both the Android notification and the iOS control center, but
  /// on Android, it will show only if the media item's duration has been set.
  /// [MediaAction.seekForward] and [MediaAction.seekBackward] have a special
  /// behaviour on iOS in which if you have already enabled the
  /// [MediaAction.skipToNext] and [MediaAction.skipToPrevious] buttons, these
  /// additional actions will allow the user to press and hold the buttons to
  /// activate the continuous seeking behaviour.
  ///
  /// When enabling the seek bar, also note that some Android devices will not
  /// render the seek bar correctly unless your [AudioServiceConfig.androidNotificationIcon]
  /// is a monochrome white icon on a transparent background, and your
  /// [AudioServiceConfig.notificationColor] is a non-transparent color.
  final Set<MediaAction> systemActions;

  /// The playback position at [updateTime].
  ///
  /// For efficiency, the [updatePosition] should NOT be updated continuously in
  /// real time. Instead, it should be updated only when the normal continuity
  /// of time is disrupted, such as during a seek, buffering and seeking. When
  /// broadcasting such a position change, the [updateTime] specifies the time
  /// of that change, allowing clients to project the realtime value of the
  /// position as `position + (DateTime.now() - updateTime)`. As a convenience,
  /// this calculation is provided by the [position] getter.
  final Duration updatePosition;

  /// The buffered position.
  final Duration bufferedPosition;

  /// The current playback speed where 1.0 means normal speed.
  final double speed;

  /// The time at which the playback position was last updated.
  final DateTime updateTime;

  /// The error code when [processingState] is [AudioProcessingState.error].
  final int? errorCode;

  /// The error message when [processingState] is [AudioProcessingState.error].
  final String? errorMessage;

  /// The current repeat mode.
  final AudioServiceRepeatMode repeatMode;

  /// The current shuffle mode.
  final AudioServiceShuffleMode shuffleMode;

  /// Whether captioning is enabled.
  final bool captioningEnabled;

  /// The index of the current item in the queue, if any.
  final int? queueIndex;

  /// Creates a [PlaybackState] with given field values, and with [updateTime]
  /// defaulting to [DateTime.now].
  PlaybackState({
    this.processingState = AudioProcessingState.idle,
    this.playing = false,
    this.controls = const [],
    this.androidCompactActionIndices,
    this.systemActions = const {},
    this.updatePosition = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.speed = 1.0,
    DateTime? updateTime,
    this.errorCode,
    this.errorMessage,
    this.repeatMode = AudioServiceRepeatMode.none,
    this.shuffleMode = AudioServiceShuffleMode.none,
    this.captioningEnabled = false,
    this.queueIndex,
  })  : assert(androidCompactActionIndices == null ||
            androidCompactActionIndices.length <= 3),
        updateTime = updateTime ?? clock.now();

  /// Creates a copy of this state with given fields replaced by new values,
  /// with [updateTime] set to [DateTime.now], and unless otherwise replaced,
  /// with [updatePosition] set to [position].
  ///
  /// The [errorCode] and [errorMessage] will be set to null unless [processingState] is
  /// [AudioProcessingState.error].
  PlaybackStateCopyWith get copyWith => _PlaybackStateCopyWith(this);

  /// The current playback position.
  Duration get position {
    if (playing && processingState == AudioProcessingState.ready) {
      return Duration(
        milliseconds: (updatePosition.inMilliseconds +
                speed *
                    (clock.now().millisecondsSinceEpoch -
                        updateTime.millisecondsSinceEpoch))
            .toInt(),
      );
    } else {
      return updatePosition;
    }
  }

  PlaybackStateMessage _toMessage() => PlaybackStateMessage(
        processingState:
            AudioProcessingStateMessage.values[processingState.index],
        playing: playing,
        controls: controls.map((control) => control._toMessage()).toList(),
        androidCompactActionIndices: androidCompactActionIndices,
        systemActions: systemActions
            .map((action) => MediaActionMessage.values[action.index])
            .toSet(),
        updatePosition: updatePosition,
        bufferedPosition: bufferedPosition,
        speed: speed,
        updateTime: updateTime,
        errorCode: errorCode,
        errorMessage: errorMessage,
        repeatMode: AudioServiceRepeatModeMessage.values[repeatMode.index],
        shuffleMode: AudioServiceShuffleModeMessage.values[shuffleMode.index],
        captioningEnabled: captioningEnabled,
        queueIndex: queueIndex,
      );

  @override
  String toString() => '${_toMessage().toMap()}';

  @override
  int get hashCode => Object.hash(
        processingState,
        playing,
        Object.hashAll(controls),
        androidCompactActionIndices != null
            ? Object.hashAll(androidCompactActionIndices!)
            : 0,
        Object.hashAll(systemActions),
        updatePosition,
        bufferedPosition,
        speed,
        updateTime,
        errorCode,
        errorMessage,
        repeatMode,
        shuffleMode,
        captioningEnabled,
        queueIndex,
      );

  @override
  bool operator ==(Object other) =>
      identical(other, this) ||
      other.runtimeType == runtimeType &&
          other is PlaybackState &&
          processingState == other.processingState &&
          playing == other.playing &&
          listEquals(controls, other.controls) &&
          listEquals(
              androidCompactActionIndices, other.androidCompactActionIndices) &&
          setEquals(systemActions, other.systemActions) &&
          updatePosition == other.updatePosition &&
          bufferedPosition == other.bufferedPosition &&
          speed == other.speed &&
          updateTime == other.updateTime &&
          errorCode == other.errorCode &&
          errorMessage == other.errorMessage &&
          repeatMode == other.repeatMode &&
          shuffleMode == other.shuffleMode &&
          captioningEnabled == other.captioningEnabled &&
          queueIndex == other.queueIndex;
}

/// The `copyWith` function type for [PlaybackState].
abstract class PlaybackStateCopyWith {
  /// Calls this function.
  PlaybackState call({
    AudioProcessingState processingState,
    bool playing,
    List<MediaControl> controls,
    List<int>? androidCompactActionIndices,
    Set<MediaAction> systemActions,
    Duration updatePosition,
    Duration bufferedPosition,
    double speed,
    int? errorCode,
    String? errorMessage,
    AudioServiceRepeatMode repeatMode,
    AudioServiceShuffleMode shuffleMode,
    bool captioningEnabled,
    int? queueIndex,
  });
}

/// The implementation of [PlaybackState]'s `copyWith` function allowing
/// parameters to be explicitly set to null.
class _PlaybackStateCopyWith extends PlaybackStateCopyWith {
  static const _fakeNull = Object();

  /// The [PlaybackState] object this function applies to.
  final PlaybackState value;

  _PlaybackStateCopyWith(this.value);

  @override
  PlaybackState call({
    Object? processingState = _fakeNull,
    Object? playing = _fakeNull,
    Object? controls = _fakeNull,
    Object? androidCompactActionIndices = _fakeNull,
    Object? systemActions = _fakeNull,
    Object? updatePosition = _fakeNull,
    Object? bufferedPosition = _fakeNull,
    Object? speed = _fakeNull,
    Object? errorCode = _fakeNull,
    Object? errorMessage = _fakeNull,
    Object? repeatMode = _fakeNull,
    Object? shuffleMode = _fakeNull,
    Object? captioningEnabled = _fakeNull,
    Object? queueIndex = _fakeNull,
  }) =>
      PlaybackState(
        processingState: processingState == _fakeNull
            ? value.processingState
            : processingState as AudioProcessingState,
        playing: playing == _fakeNull ? value.playing : playing as bool,
        controls: controls == _fakeNull
            ? value.controls
            : controls as List<MediaControl>,
        androidCompactActionIndices: androidCompactActionIndices == _fakeNull
            ? value.androidCompactActionIndices
            : androidCompactActionIndices as List<int>?,
        systemActions: systemActions == _fakeNull
            ? value.systemActions
            : systemActions as Set<MediaAction>,
        updatePosition: updatePosition == _fakeNull
            ? value.updatePosition
            : updatePosition as Duration,
        bufferedPosition: bufferedPosition == _fakeNull
            ? value.bufferedPosition
            : bufferedPosition as Duration,
        speed: speed == _fakeNull ? value.speed : speed as double,
        errorCode: errorCode == _fakeNull ? value.errorCode : errorCode as int?,
        errorMessage: errorMessage == _fakeNull
            ? value.errorMessage
            : errorMessage as String?,
        repeatMode: repeatMode == _fakeNull
            ? value.repeatMode
            : repeatMode as AudioServiceRepeatMode,
        shuffleMode: shuffleMode == _fakeNull
            ? value.shuffleMode
            : shuffleMode as AudioServiceShuffleMode,
        captioningEnabled: captioningEnabled == _fakeNull
            ? value.captioningEnabled
            : captioningEnabled as bool,
        queueIndex:
            queueIndex == _fakeNull ? value.queueIndex : queueIndex as int?,
      );
}

/// The style of a [Rating].
enum RatingStyle {
  /// Indicates a rating style is not supported.
  ///
  /// A [Rating] will never have this type, but can be used by other classes
  /// to indicate they do not support [Rating].
  none,

  /// A rating style with a single degree of rating, "heart" vs "no heart".
  ///
  /// Can be used to indicate the content referred to is a favorite (or not).
  heart,

  /// A rating style for "thumb up" vs "thumb down".
  thumbUpDown,

  /// A rating style with 0 to 3 stars.
  range3stars,

  /// A rating style with 0 to 4 stars.
  range4stars,

  /// A rating style with 0 to 5 stars.
  range5stars,

  /// A rating style expressed as a percentage.
  percentage,
}

/// A rating to attach to a MediaItem.
class Rating {
  final RatingStyle _type;
  final Object? _value;

  const Rating._(this._type, this._value);

  /// Creates a new heart rating.
  const Rating.newHeartRating(bool hasHeart)
      : this._(RatingStyle.heart, hasHeart);

  /// Creates a new percentage rating.
  const Rating.newPercentageRating(double percent)
      : assert(
          percent >= 0 && percent <= 100,
          'Percentage must be in range from 0 to 100',
        ),
        _type = RatingStyle.percentage,
        _value = percent;

  /// Creates a new star rating.
  Rating.newStarRating(RatingStyle style, int rating)
      : assert(
          style == RatingStyle.range3stars ||
              style == RatingStyle.range4stars ||
              style == RatingStyle.range5stars,
          'Invalid rating style',
        ),
        assert(rating >= 0 && rating <= style.index),
        _type = style,
        _value = rating;

  /// Creates a new thumb rating.
  const Rating.newThumbRating(bool isThumbsUp)
      : this._(RatingStyle.thumbUpDown, isThumbsUp);

  /// Creates a new unrated rating.
  const Rating.newUnratedRating(RatingStyle ratingStyle)
      : this._(ratingStyle, null);

  /// Return the rating style.
  RatingStyle getRatingStyle() => _type;

  /// Returns a percentage rating value greater or equal to `0.0`, or a
  /// negative value if the rating style is not percentage-based, or
  /// if it is unrated.
  double getPercentRating() {
    if (_type != RatingStyle.percentage) return -1;
    final localValue = _value as double?;
    if (localValue == null || localValue < 0 || localValue > 100) return -1;
    return localValue;
  }

  /// Returns a rating value greater or equal to `0.0`, or a negative
  /// value if the rating style is not star-based, or if it is
  /// unrated.
  int getStarRating() {
    if (_type != RatingStyle.range3stars &&
        _type != RatingStyle.range4stars &&
        _type != RatingStyle.range5stars) {
      return -1;
    }
    return _value as int? ?? -1;
  }

  /// Returns true if the rating is "heart selected" or false if the
  /// rating is "heart unselected", if the rating style is not [RatingStyle.heart]
  /// or if it is unrated.
  bool hasHeart() {
    if (_type != RatingStyle.heart) return false;
    return _value as bool? ?? false;
  }

  /// Returns true if the rating is "thumb up" or false if the rating
  /// is "thumb down", if the rating style is not [RatingStyle.thumbUpDown] or if
  /// it is unrated.
  bool isThumbUp() {
    if (_type != RatingStyle.thumbUpDown) return false;
    return _value as bool? ?? false;
  }

  /// Return whether there is a rating value available.
  bool isRated() => _value != null;

  RatingMessage _toMessage() => RatingMessage(
        type: RatingStyleMessage.values[_type.index],
        value: _value,
      );

  @override
  String toString() => '${_toMessage().toMap()}';

  @override
  int get hashCode => Object.hash(_value, _type);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is Rating &&
      _type == other._type &&
      _value == other._value;
}

/// Metadata of an audio item that can be played, or a folder containing
/// audio items.
class MediaItem {
  /// A unique id.
  final String id;

  /// The title of this media item.
  final String title;

  /// The album this media item belongs to.
  final String? album;

  /// The artist of this media item.
  final String? artist;

  /// The genre of this media item.
  final String? genre;

  /// The duration of this media item.
  final Duration? duration;

  /// The artwork URI for this media item.
  ///
  /// Supported types of URIs are:
  ///
  ///  * File - file://
  ///  * Network - http:// https:// etc.
  ///  * Android content URIs - content://
  ///
  /// ## Speeding up Android content URI loading
  ///
  /// For Android content:// URIs, the plugin by default uses
  /// `ContentResolver.openFileDescriptor`, which takes the direct URI of an
  /// image.
  ///
  /// On Android API >= 29 there is `ContentResolver.loadThumbnail` function
  /// which takes a URI of some content (for example, a song from `MediaStore`),
  /// and returns a thumbnail for it.
  ///
  /// It is noticeably faster to use this function. You can enable this by
  /// putting a `loadThumbnailUri` key into the [extras]. If `loadThumbnail` is
  /// not available, it will just fallback to using `openFileDescriptor`.
  final Uri? artUri;

  /// The HTTP headers to use when sending an HTTP request for [artUri].
  final Map<String, String>? artHeaders;

  /// Whether this is playable (i.e. not a folder).
  final bool? playable;

  /// Override the default title for display purposes.
  final String? displayTitle;

  /// Override the default subtitle for display purposes.
  final String? displaySubtitle;

  /// Override the default description for display purposes.
  final String? displayDescription;

  /// The rating of the media item.
  final Rating? rating;

  /// Whether this is a live stream.
  final bool? isLive;

  /// A map of additional metadata for the media item.
  ///
  /// The values must be of type `int`, `String`, `bool` or `double`.
  final Map<String, dynamic>? extras;

  /// Creates a [MediaItem].
  ///
  /// The [id] must be unique for each instance.
  const MediaItem({
    required this.id,
    required this.title,
    this.album,
    this.artist,
    this.genre,
    this.duration,
    this.artUri,
    this.artHeaders,
    this.playable = true,
    this.displayTitle,
    this.displaySubtitle,
    this.displayDescription,
    this.rating,
    this.isLive,
    this.extras,
  });

  /// Creates a copy of this [MediaItem] with with the given fields replaced by
  /// new values.
  MediaItemCopyWith get copyWith => _MediaItemCopyWith(this);

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && other is MediaItem && other.id == id;

  MediaItemMessage _toMessage() => MediaItemMessage(
        id: id,
        album: album,
        title: title,
        artist: artist,
        genre: genre,
        duration: duration,
        artUri: artUri,
        playable: playable,
        displayTitle: displayTitle,
        displaySubtitle: displaySubtitle,
        displayDescription: displayDescription,
        rating: rating?._toMessage(),
        isLive: isLive,
        extras: extras,
      );

  @override
  String toString() => '${_toMessage().toMap()}';
}

/// The `copyWith` function type for [MediaItem].
abstract class MediaItemCopyWith {
  /// Calls this function.
  MediaItem call({
    String id,
    String title,
    String? album,
    String? artist,
    String? genre,
    Duration? duration,
    Uri? artUri,
    bool? playable,
    String? displayTitle,
    String? displaySubtitle,
    String? displayDescription,
    Rating? rating,
    bool? isLive,
    Map<String, dynamic>? extras,
  });
}

/// The implementation of [MediaItem]'s `copyWith` function allowing
/// parameters to be explicitly set to null.
class _MediaItemCopyWith extends MediaItemCopyWith {
  static const _fakeNull = Object();

  /// The [MediaItem] object this function applies to.
  final MediaItem value;

  _MediaItemCopyWith(this.value);

  @override
  MediaItem call({
    Object? id = _fakeNull,
    Object? title = _fakeNull,
    Object? album = _fakeNull,
    Object? artist = _fakeNull,
    Object? genre = _fakeNull,
    Object? duration = _fakeNull,
    Object? artUri = _fakeNull,
    Object? playable = _fakeNull,
    Object? displayTitle = _fakeNull,
    Object? displaySubtitle = _fakeNull,
    Object? displayDescription = _fakeNull,
    Object? rating = _fakeNull,
    Object? isLive = _fakeNull,
    Object? extras = _fakeNull,
  }) =>
      MediaItem(
        id: id == _fakeNull ? value.id : id as String,
        title: title == _fakeNull ? value.title : title as String,
        album: album == _fakeNull ? value.album : album as String?,
        artist: artist == _fakeNull ? value.artist : artist as String?,
        genre: genre == _fakeNull ? value.genre : genre as String?,
        duration:
            duration == _fakeNull ? value.duration : duration as Duration?,
        artUri: artUri == _fakeNull ? value.artUri : artUri as Uri?,
        playable: playable == _fakeNull ? value.playable : playable as bool?,
        displayTitle: displayTitle == _fakeNull
            ? value.displayTitle
            : displayTitle as String?,
        displaySubtitle: displaySubtitle == _fakeNull
            ? value.displaySubtitle
            : displaySubtitle as String?,
        displayDescription: displayDescription == _fakeNull
            ? value.displayDescription
            : displayDescription as String?,
        rating: rating == _fakeNull ? value.rating : rating as Rating?,
        isLive: isLive == _fakeNull ? value.isLive : isLive as bool?,
        extras: extras == _fakeNull
            ? value.extras
            : extras as Map<String, dynamic>?,
      );
}

/// Custom action information used to define an action name and optional extras
/// that are sent to [AudioHandler.customAction] when the associated media control is used.
class CustomMediaAction {
  /// Custom action name
  final String name;

  /// A map of additional data for the custom action.
  ///
  /// The values must be integers or strings.
  final Map<String, dynamic>? extras;

  /// Creates a [CustomMediaAction].
  const CustomMediaAction({required this.name, this.extras});

  /// Convert to a Map.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'name': name,
        'extras': extras,
      };

  CustomMediaActionMessage _toMessage() => CustomMediaActionMessage(
        name: name,
        extras: extras,
      );

  @override
  int get hashCode => Object.hash(name, extras);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is CustomMediaAction &&
      name == other.name &&
      mapEquals<String, dynamic>(extras, other.extras);
}

/// A button to appear in the Android notification, lock screen, Android smart
/// watch, or Android Auto device. The set of buttons you would like to display
/// at any given moment should be streamed via [AudioHandler.playbackState].
///
/// Each [MediaControl] button controls a specified [MediaAction]. Only the
/// following actions can be represented as buttons:
///
/// * [MediaAction.stop]
/// * [MediaAction.pause]
/// * [MediaAction.play]
/// * [MediaAction.rewind]
/// * [MediaAction.skipToPrevious]
/// * [MediaAction.skipToNext]
/// * [MediaAction.fastForward]
/// * [MediaAction.playPause]
///
/// Predefined controls with default Android icons and labels are defined as
/// static fields of this class. If you wish to define your own custom Android
/// controls with your own icon resources, you will need to place the Android
/// resources in `android/app/src/main/res`. Here, you will find a subdirectory
/// for each different resolution:
///
/// ```
/// drawable-hdpi
/// drawable-mdpi
/// drawable-xhdpi
/// drawable-xxhdpi
/// drawable-xxxhdpi
/// ```
///
/// You can use [Android Asset
/// Studio](https://romannurik.github.io/AndroidAssetStudio/) to generate these
/// different subdirectories for any standard material design icon.
class MediaControl {
  /// A default control for [MediaAction.stop].
  static const stop = MediaControl(
    androidIcon: 'drawable/audio_service_stop',
    label: 'Stop',
    action: MediaAction.stop,
  );

  /// A default control for [MediaAction.pause].
  static const pause = MediaControl(
    androidIcon: 'drawable/audio_service_pause',
    label: 'Pause',
    action: MediaAction.pause,
  );

  /// A default control for [MediaAction.play].
  static const play = MediaControl(
    androidIcon: 'drawable/audio_service_play_arrow',
    label: 'Play',
    action: MediaAction.play,
  );

  /// A default control for [MediaAction.rewind].
  static const rewind = MediaControl(
    androidIcon: 'drawable/audio_service_fast_rewind',
    label: 'Rewind',
    action: MediaAction.rewind,
  );

  /// A default control for [MediaAction.skipToNext].
  static const skipToNext = MediaControl(
    androidIcon: 'drawable/audio_service_skip_next',
    label: 'Next',
    action: MediaAction.skipToNext,
  );

  /// A default control for [MediaAction.skipToPrevious].
  static const skipToPrevious = MediaControl(
    androidIcon: 'drawable/audio_service_skip_previous',
    label: 'Previous',
    action: MediaAction.skipToPrevious,
  );

  /// A default control for [MediaAction.fastForward].
  static const fastForward = MediaControl(
    androidIcon: 'drawable/audio_service_fast_forward',
    label: 'Fast Forward',
    action: MediaAction.fastForward,
  );

  /// A reference to an Android icon resource for the control (e.g.
  /// `"drawable/ic_action_pause"`)
  final String androidIcon;

  /// A label for the control
  final String label;

  /// The action to be executed by this control
  final MediaAction action;

  /// The custom action name and optional extras to receive in
  /// [AudioHandler.customAction]
  final CustomMediaAction? customAction;

  /// Creates a custom [MediaControl].
  MediaControl.custom({
    required this.androidIcon,
    required this.label,
    required String name,
    Map<String, dynamic>? extras,
  })  : action = MediaAction.custom,
        customAction = CustomMediaAction(name: name, extras: extras) {
    assert(action != MediaAction.custom || customAction != null);
  }

  /// Creates a custom [MediaControl].
  const MediaControl({
    required this.androidIcon,
    required this.label,
    required this.action,
    this.customAction,
  });

  /// Creates a copy of this control with given fields replaced by new values.
  MediaControl copyWith({
    String? androidIcon,
    String? label,
    MediaAction? action,
    CustomMediaAction? customAction,
  }) =>
      MediaControl(
        androidIcon: androidIcon ?? this.androidIcon,
        label: label ?? this.label,
        action: action ?? this.action,
        customAction: customAction ?? this.customAction,
      );

  MediaControlMessage _toMessage() => MediaControlMessage(
        androidIcon: androidIcon,
        label: label,
        action: MediaActionMessage.values[action.index],
        customAction: customAction?._toMessage(),
      );

  @override
  String toString() => '${_toMessage().toMap()}';

  @override
  int get hashCode => Object.hash(androidIcon, label, action);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is MediaControl &&
      androidIcon == other.androidIcon &&
      label == other.label &&
      action == other.action;
}

/// Provides an API to manage the app's [AudioHandler]. An app must call [init]
/// during initialisation to register the [AudioHandler] that will service all
/// requests to play audio.
class AudioService {
  /// The cache to use when loading artwork.
  /// Defaults to [DefaultCacheManager].
  static BaseCacheManager get cacheManager => _cacheManager!;
  static BaseCacheManager? _cacheManager;

  static late AudioServiceConfig _config;
  static late AudioHandler _handler;
  static PlaybackState? _synchronizedPlaybackState;
  static final _playbackStateWaiters =
      Map<PlaybackState, List<Completer<void>>>.identity();

  /// The current configuration.
  static AudioServiceConfig get config => _config;

  /// The root media ID for browsing media provided by the background
  /// task.
  static const String browsableRootId = 'root';

  /// The root media ID for browsing the most recently played item(s).
  static const String recentRootId = 'recent';

  static final BehaviorSubject<bool> _notificationClicked =
      BehaviorSubject.seeded(false);

  /// A stream that broadcasts the status of the notificationClick event.
  static ValueStream<bool> get notificationClicked => _notificationClicked;

  static final _asyncError = PublishSubject<Object>();

  /// A stream that broadcasts any exceptions that occur asynchronously.
  static Stream<Object> get asyncError => _asyncError;

  static final _compatibilitySwitcher = SwitchAudioHandler();

  /// Register the app's [AudioHandler] with configuration options. This must be
  /// called once during the app's initialisation so that it is prepared to
  /// handle audio requests immediately after a cold restart (e.g. if the user
  /// clicks on the play button in the media notification while your app is not
  /// running and your app needs to be woken up).
  ///
  /// You may optionally specify a [cacheManager] to use when loading artwork to
  /// display in the media notification and lock screen. This defaults to
  /// [DefaultCacheManager].
  ///
  /// This may throw a [PlatformException] on Android if you have not set the
  /// correct Service or Activity in your `AndroidManifest.xml` file or if your
  /// Activity does not provide the correct `FlutterEngine`.
  static Future<T> init<T extends AudioHandler>({
    required T Function() builder,
    AudioServiceConfig? config,
    BaseCacheManager? cacheManager,
  }) async {
    assert(_cacheManager == null);
    config ??= const AudioServiceConfig();
    assert(config.fastForwardInterval > Duration.zero);
    assert(config.rewindInterval > Duration.zero);
    WidgetsFlutterBinding.ensureInitialized();
    _cacheManager = (cacheManager ??= DefaultCacheManager());
    final callbacks = _HandlerCallbacks();
    _platform.setHandlerCallbacks(callbacks);
    await _platform.configure(ConfigureRequest(config: config._toMessage()));
    _config = config;
    final handler = builder();
    _handler = handler;
    callbacks.setHandler(handler);

    _observeMediaItem();
    _observeAndroidPlaybackInfo();
    _observeQueue();
    _observePlaybackState();

    return handler;
  }

  static Future<void> _observeMediaItem() async {
    Object? artFetchOperationId;
    _handler.mediaItem.listen((mediaItem) async {
      if (mediaItem == null) {
        return;
      }
      final operationId = Object();
      artFetchOperationId = operationId;
      final artUri = mediaItem.artUri;
      if (artUri == null || artUri.scheme == 'content') {
        _platform
            .setMediaItem(
                SetMediaItemRequest(mediaItem: mediaItem._toMessage()))
            .catchError(_asyncError.add);
      } else {
        /// Sends media item to the platform.
        /// We potentially need to fetch the art before that.
        Future<void> sendToPlatform(String? filePath) async {
          final extras = mediaItem.extras;
          final platformMediaItem = mediaItem.copyWith(
            extras: <String, dynamic>{
              if (extras != null) ...extras,
              'artCacheFile': filePath,
            },
          );
          await _platform.setMediaItem(
              SetMediaItemRequest(mediaItem: platformMediaItem._toMessage()));
        }

        if (artUri.scheme == 'file') {
          sendToPlatform(artUri.toFilePath()).catchError(_asyncError.add);
        } else {
          // Try to load a cached file from memory.
          final fileInfo =
              await cacheManager.getFileFromMemory(artUri.toString());
          final filePath = fileInfo?.file.path;
          if (operationId != artFetchOperationId) {
            return;
          }

          if (filePath != null) {
            // If we successfully downloaded the art call to platform.
            sendToPlatform(filePath).catchError(_asyncError.add);
          } else {
            // We haven't fetched the art yet, so show the metadata now, and again
            // after we load the art.
            try {
              await _platform.setMediaItem(
                  SetMediaItemRequest(mediaItem: mediaItem._toMessage()));
            } catch (e) {
              _asyncError.add(e);
              return;
            }
            if (operationId != artFetchOperationId) {
              return;
            }
            // Load the art.
            final loadedFilePath = await _loadArtwork(mediaItem);
            if (operationId != artFetchOperationId) {
              return;
            }
            // If we successfully downloaded the art, call to platform.
            if (loadedFilePath != null) {
              sendToPlatform(loadedFilePath).catchError(_asyncError.add);
            }
          }
        }
      }
    });
  }

  static Future<void> _observeAndroidPlaybackInfo() async {
    await for (var playbackInfo in _handler.androidPlaybackInfo) {
      try {
        await _platform.setAndroidPlaybackInfo(SetAndroidPlaybackInfoRequest(
          playbackInfo: playbackInfo._toMessage(),
        ));
      } catch (e) {
        _asyncError.add(e);
      }
    }
  }

  static Future<void> _observeQueue() async {
    const queueIndexKey = 'com.ryanheise.audio_service.queueIndex';
    final window = AndroidQueueWindow<MediaItem>();
    var pendingQueue = false;
    var sendingQueue = false;

    Future<void> sendQueue() async {
      pendingQueue = true;
      if (sendingQueue) return;
      sendingQueue = true;
      while (pendingQueue) {
        pendingQueue = false;
        final start = window.start;
        try {
          final items = window.items;
          await _platform.setQueue(SetQueueRequest(queue: [
            for (var i = 0; i < items.length; i++)
              if (start == 0 &&
                  !(items[i].extras?.containsKey(queueIndexKey) ?? false))
                items[i]._toMessage()
              else
                items[i].copyWith(extras: {
                  ...?items[i].extras,
                  queueIndexKey: start + i,
                })._toMessage(),
          ]));
        } catch (e) {
          _asyncError.add(e);
        }
      }
      sendingQueue = false;
    }

    _handler.queue.listen((queue) {
      if (_config.preloadArtwork) {
        _loadAllArtwork(queue);
      }
      // Only the Android plugin reads the queue; the darwin and web plugins
      // and the desktop sessions ignore it.
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
      window.updateQueue(queue, _handler.playbackState.value.queueIndex);
      sendQueue();
    });
    _handler.playbackState.listen((state) {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
      if (window.moveTo(state.queueIndex)) sendQueue();
    });
  }

  static Future<void> _observePlaybackState() async {
    var previousState = _handler.playbackState.nvalue;
    await for (var playbackState in _handler.playbackState) {
      try {
        await _platform
            .setState(SetStateRequest(state: playbackState._toMessage()));
        _synchronizedPlaybackState = playbackState;
        for (final waiter in _playbackStateWaiters.remove(playbackState) ??
            <Completer<void>>[]) {
          waiter.complete();
        }
        if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
        previousState = playbackState;
      } catch (e, stackTrace) {
        for (final waiter in _playbackStateWaiters.remove(playbackState) ??
            <Completer<void>>[]) {
          waiter.completeError(e, stackTrace);
        }
        _asyncError.add(e);
      }
    }
  }

  /// Waits until the native service acknowledges the current playback state.
  /// On Android, use this after publishing a playing state and before requesting
  /// audio focus from the background, so foreground promotion has completed.
  static Future<void> synchronizePlaybackState() async {
    final state = _handler.playbackState.value;
    if (identical(state, _synchronizedPlaybackState)) return;
    final waiter = Completer<void>();
    final waiters = _playbackStateWaiters.putIfAbsent(state, () => []);
    waiters.add(waiter);
    try {
      await waiter.future.timeout(const Duration(seconds: 5));
    } finally {
      waiters.remove(waiter);
      if (waiters.isEmpty && identical(_playbackStateWaiters[state], waiters)) {
        _playbackStateWaiters.remove(state);
      }
    }
  }

  /// A stream tracking the current position, suitable for animating a seek bar.
  /// To ensure a smooth animation, this stream emits values more frequently on
  /// short media items where the seek bar moves more quickly, and less
  /// frequenly on long media items where the seek bar moves more slowly. The
  /// interval between each update will be no quicker than once every 16ms and
  /// no slower than once every 200ms.
  ///
  /// See [createPositionStream] for more control over the stream parameters.
  static final Stream<Duration> position = createPositionStream(
      steps: 800,
      minPeriod: const Duration(milliseconds: 16),
      maxPeriod: const Duration(milliseconds: 200));

  /// Creates a new stream periodically tracking the current position. The
  /// stream will aim to emit [steps] position updates at intervals of
  /// current [MediaItem.duration] / [steps]. This interval will be clipped between [minPeriod]
  /// and [maxPeriod]. This stream will not emit values while audio playback is
  /// paused or stalled.
  ///
  /// Note: each time this method is called, a new stream is created. If you
  /// intend to use this stream multiple times, you should hold a reference to
  /// the returned stream.
  static Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    assert(minPeriod <= maxPeriod);
    assert(minPeriod > Duration.zero);
    Duration? last;
    late StreamController<Duration> controller;
    late StreamSubscription<MediaItem?> mediaItemSubscription;
    late StreamSubscription<PlaybackState> playbackStateSubscription;
    Timer? currentTimer;
    Duration duration() => _handler.mediaItem.nvalue?.duration ?? Duration.zero;
    Duration step() {
      var s = duration() ~/ steps;
      if (s < minPeriod) s = minPeriod;
      if (s > maxPeriod) s = maxPeriod;
      return s;
    }

    void yieldPosition(Timer? timer) {
      if (last != _handler.playbackState.nvalue?.position) {
        controller.add((last = _handler.playbackState.nvalue?.position)!);
      }
    }

    controller = StreamController.broadcast(
      sync: true,
      onListen: () {
        mediaItemSubscription =
            _handler.mediaItem.listen((MediaItem? mediaItem) {
          // Potentially a new duration
          currentTimer?.cancel();
          currentTimer = Timer.periodic(step(), yieldPosition);
        });
        playbackStateSubscription =
            _handler.playbackState.listen((PlaybackState state) {
          // Potentially a time discontinuity
          yieldPosition(currentTimer);
        });
      },
      onCancel: () {
        mediaItemSubscription.cancel();
        playbackStateSubscription.cancel();
      },
    );

    return controller.stream;
  }

  /// In Android, forces media button events to be routed to your active media
  /// session.
  ///
  /// This is necessary if you want to play TextToSpeech in the background and
  /// still respond to media button events. You should call it just before
  /// playing TextToSpeech.
  ///
  /// This is not necessary if you are playing normal audio in the background
  /// such as music because this kind of "normal" audio playback will
  /// automatically qualify your app to receive media button events.
  static Future<void> androidForceEnableMediaButtons() async {
    await _platform.androidForceEnableMediaButtons(
      const AndroidForceEnableMediaButtonsRequest(),
    );
  }

  /// Re-publishes the retained iOS metadata after the audio session is restored.
  /// Does not reload artwork or change playback. Call only on iOS.
  static Future<void> refreshNowPlayingInfo() async {
    await const MethodChannel('com.ryanheise.audio_service.client.methods')
        .invokeMethod<void>('refreshNowPlayingInfo');
  }

  /// Stops the service.
  static Future<void> _stop() async {
    await _platform.stopService(const StopServiceRequest());
  }

  static Future<void> _loadAllArtwork(List<MediaItem> queue) async {
    for (var mediaItem in queue) {
      await _loadArtwork(mediaItem);
    }
  }

  static Future<String?> _loadArtwork(MediaItem mediaItem) async {
    try {
      final artUri = mediaItem.artUri;
      if (artUri != null) {
        if (artUri.scheme == 'file') {
          return artUri.toFilePath();
        } else {
          final headers = mediaItem.artHeaders;
          final file = headers != null
              ? await cacheManager.getSingleFile(mediaItem.artUri!.toString(),
                  headers: headers)
              : await cacheManager.getSingleFile(mediaItem.artUri!.toString());
          return file.path;
        }
      }
    } catch (e, st) {
      // TODO: handle this somehow?
      // ignore: avoid_print
      print('Error loading artUri: $e\n$st');
    }
    return null;
  }

  // DEPRECATED members

  /// Deprecated. Use [browsableRootId] instead.
  @Deprecated("Use browsableRootId instead.")
  // ignore: constant_identifier_names
  static const String MEDIA_ROOT_ID = browsableRootId;

  static final _browseMediaChildrenSubject = BehaviorSubject<List<MediaItem>>();

  /// Deprecated. Directly subscribe to a parent's children via
  /// [AudioHandler.subscribeToChildren].
  @Deprecated("Use AudioHandler.subscribeToChildren instead.")
  static Stream<List<MediaItem>> get browseMediaChildrenStream =>
      _browseMediaChildrenSubject.stream;

  /// Deprecated. Use [AudioHandler.getChildren] instead.
  @Deprecated("Use AudioHandler.getChildren instead")
  static List<MediaItem>? get browseMediaChildren =>
      _browseMediaChildrenSubject.nvalue;

  /// Deprecated. Use [AudioHandler.playbackState] instead.
  @Deprecated("Use AudioHandler.playbackState instead.")
  static ValueStream<PlaybackState> get playbackStateStream =>
      _compatibilitySwitcher.playbackState;

  /// Deprecated. Use [notificationClicked] instead.
  @Deprecated("Use notificationClicked instead.")
  static ValueStream<bool> get notificationClickEventStream =>
      notificationClicked;

  /// Deprecated. Use `value` of  [AudioHandler.playbackState] instead.
  @Deprecated("Use AudioHandler.playbackState.value instead.")
  static PlaybackState get playbackState =>
      _compatibilitySwitcher.playbackState.nvalue ?? PlaybackState();

  /// Deprecated. Use [AudioHandler.mediaItem] instead.
  @Deprecated("Use AudioHandler.mediaItem instead.")
  static ValueStream<MediaItem?> get currentMediaItemStream =>
      _compatibilitySwitcher.mediaItem;

  /// Deprecated. Use `value` of [AudioHandler.mediaItem] instead.
  @Deprecated("Use AudioHandler.mediaItem.value instead.")
  static MediaItem? get currentMediaItem =>
      _compatibilitySwitcher.mediaItem.nvalue;

  /// Deprecated. Use [AudioHandler.queue] instead.
  @Deprecated("Use AudioHandler.queue instead.")
  static ValueStream<List<MediaItem>?> get queueStream =>
      _compatibilitySwitcher.queue;

  /// Deprecated. Use `value` of [AudioHandler.queue] instead.
  @Deprecated("Use AudioHandler.queue.value instead.")
  static List<MediaItem>? get queue => _compatibilitySwitcher.queue.nvalue;

  /// Deprecated. Use [AudioHandler.customEvent] instead.
  @Deprecated("Use AudioHandler.customEvent instead.")
  static Stream<dynamic> get customEventStream =>
      _compatibilitySwitcher.customEvent;

  /// Deprecated. Use [AudioHandler.playbackState] instead.
  @Deprecated("Use AudioHandler.playbackState instead.")
  static ValueStream<bool> get runningStream => playbackStateStream
          .map((state) => state.processingState != AudioProcessingState.idle)
      as ValueStream<bool>;

  /// Deprecated. Use [PlaybackState.processingState] of [AudioHandler.playbackState] instead.
  @Deprecated("Use PlaybackState.processingState instead.")
  static bool get running => runningStream.nvalue ?? false;

  static StreamSubscription<Map<String, dynamic>>? _childrenSubscription;

  /// Deprecated. The new [AudioHandler] API now automatically starts the
  /// service when your implementation enters the playing state. Parameters can
  /// be passed via [AudioHandler.customAction].
  @Deprecated("Use init instead.")
  static Future<bool> start({
    required Function backgroundTaskEntrypoint,
    Map<String, dynamic>? params,
    String androidNotificationChannelName = "Notifications",
    String? androidNotificationChannelDescription,
    int? androidNotificationColor,
    String androidNotificationIcon = 'mipmap/ic_launcher',
    bool androidShowNotificationBadge = false,
    bool androidNotificationClickStartsActivity = true,
    bool androidNotificationOngoing = false,
    bool androidResumeOnClick = true,
    bool androidStopForegroundOnPause = false,
    bool androidEnableQueue = false,
    Size? androidArtDownscaleSize,
    Duration fastForwardInterval = const Duration(seconds: 10),
    Duration rewindInterval = const Duration(seconds: 10),
  }) async {
    if (!androidEnableQueue) {
      // ignore: avoid_print
      print('NOTE: androidEnableQueue is always true from 0.18.0 onwards.');
    }
    if (_cacheManager != null && _handler.playbackState.hasValue) {
      if (_handler.playbackState.nvalue!.processingState !=
          AudioProcessingState.idle) {
        return false;
      }
    }

    AudioServiceBackground._startCompleter = Completer<BackgroundAudioTask>();
    backgroundTaskEntrypoint();
    final task = await AudioServiceBackground._startCompleter!.future;
    task._handler = _BackgroundAudioHandler();
    task._handler._task = task;
    AudioServiceBackground._startCompleter = null;

    if (_cacheManager == null) {
      _compatibilitySwitcher.inner = task._handler;
      await init(
        builder: () => _compatibilitySwitcher,
        config: AudioServiceConfig(
          androidResumeOnClick: androidResumeOnClick,
          androidNotificationChannelName: androidNotificationChannelName,
          androidNotificationChannelDescription:
              androidNotificationChannelDescription,
          notificationColor: androidNotificationColor != null
              ? Color(androidNotificationColor)
              : null,
          androidNotificationIcon: androidNotificationIcon,
          androidShowNotificationBadge: androidShowNotificationBadge,
          androidNotificationClickStartsActivity:
              androidNotificationClickStartsActivity,
          androidNotificationOngoing: androidNotificationOngoing,
          androidStopForegroundOnPause: androidStopForegroundOnPause,
          artDownscaleWidth: androidArtDownscaleSize?.width.round(),
          artDownscaleHeight: androidArtDownscaleSize?.height.round(),
          fastForwardInterval: fastForwardInterval,
          rewindInterval: rewindInterval,
        ),
      );
    } else {
      _compatibilitySwitcher.inner = task._handler;
    }
    await task.onStart(params);
    return true;
  }

  /// Deprecated. Instead, subscribe directly to a parent's children via
  /// [AudioHandler.subscribeToChildren].
  @Deprecated("Use AudioHandler.subscribeToChildren instead.")
  static Future<void> setBrowseMediaParent(
      [String parentMediaId = browsableRootId]) async {
    _childrenSubscription?.cancel();
    _childrenSubscription = _compatibilitySwitcher
        .subscribeToChildren(parentMediaId)
        .listen((Map<String, dynamic>? options) async {
      _browseMediaChildrenSubject
          .add(await _compatibilitySwitcher.getChildren(parentMediaId));
    });
  }

  /// Deprecated. Use [AudioHandler.addQueueItem] instead.
  @Deprecated("Use AudioHandler.addQueueItem instead.")
  static final addQueueItem = _compatibilitySwitcher.addQueueItem;

  /// Deprecated. Use [AudioHandler.insertQueueItem] instead.
  @Deprecated("Use AudioHandler.insertQueueItem instead.")
  static Future<void> addQueueItemAt(MediaItem mediaItem, int index) async {
    await _compatibilitySwitcher.insertQueueItem(index, mediaItem);
  }

  /// Deprecated. Use [AudioHandler.removeQueueItem] instead.
  @Deprecated("Use AudioHandler.removeQueueItem instead.")
  static final removeQueueItem = _compatibilitySwitcher.removeQueueItem;

  /// Deprecated. Use [AudioHandler.addQueueItems] instead.
  @Deprecated("Use AudioHandler.addQueueItems instead.")
  static Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    for (var mediaItem in mediaItems) {
      await addQueueItem(mediaItem);
    }
  }

  /// Deprecated. Use [AudioHandler.updateQueue] instead.
  @Deprecated("Use AudioHandler.updateQueue instead.")
  static final updateQueue = _compatibilitySwitcher.updateQueue;

  /// Deprecated. Use [AudioHandler.updateMediaItem] instead.
  @Deprecated("Use AudioHandler.updateMediaItem instead.")
  static final updateMediaItem = _compatibilitySwitcher.updateMediaItem;

  /// Deprecated. Use [AudioHandler.click] instead.
  @Deprecated("Use AudioHandler.click instead.")
  static final Future<void> Function([MediaButton]) click =
      _compatibilitySwitcher.click;

  /// Deprecated. Use [AudioHandler.prepare] instead.
  @Deprecated("Use AudioHandler.prepare instead.")
  static final prepare = _compatibilitySwitcher.prepare;

  /// Deprecated. Use [AudioHandler.prepareFromMediaId] instead.
  @Deprecated("Use AudioHandler.prepareFromMediaId instead.")
  static final Future<void> Function(String, [Map<String, dynamic>])
      prepareFromMediaId = _compatibilitySwitcher.prepareFromMediaId;

  /// Deprecated. Use [AudioHandler.play] instead.
  @Deprecated("Use AudioHandler.play instead.")
  static final play = _compatibilitySwitcher.play;

  /// Deprecated. Use [AudioHandler.playFromMediaId] instead.
  @Deprecated("Use AudioHandler.playFromMediaId instead.")
  static final Future<void> Function(String, [Map<String, dynamic>])
      playFromMediaId = _compatibilitySwitcher.playFromMediaId;

  /// Deprecated. Use [AudioHandler.playMediaItem] instead.
  @Deprecated("Use AudioHandler.playMediaItem instead.")
  static final playMediaItem = _compatibilitySwitcher.playMediaItem;

  /// Deprecated. Use [AudioHandler.skipToQueueItem] instead.
  @Deprecated("Use AudioHandler.skipToQueueItem instead.")
  static Future<void> skipToQueueItem(String mediaId) async {
    final queue = _compatibilitySwitcher.queue.nvalue!;
    final index = queue.indexWhere((item) => item.id == mediaId);
    await _compatibilitySwitcher.skipToQueueItem(index);
  }

  /// Deprecated. Use [AudioHandler.pause] instead.
  @Deprecated("Use AudioHandler.pause instead.")
  static final pause = _compatibilitySwitcher.pause;

  /// Deprecated. Use [AudioHandler.stop] instead.
  @Deprecated("Use AudioHandler.stop instead.")
  static final stop = _compatibilitySwitcher.stop;

  /// Deprecated. Use [AudioHandler.seek] instead.
  @Deprecated("Use AudioHandler.seek instead.")
  static final seekTo = _compatibilitySwitcher.seek;

  /// Deprecated. Use [AudioHandler.skipToNext] instead.
  @Deprecated("Use AudioHandler.skipToNext instead.")
  static final skipToNext = _compatibilitySwitcher.skipToNext;

  /// Deprecated. Use [AudioHandler.skipToPrevious] instead.
  @Deprecated("Use AudioHandler.skipToPrevious instead.")
  static final skipToPrevious = _compatibilitySwitcher.skipToPrevious;

  /// Deprecated. Use [AudioHandler.fastForward] instead.
  @Deprecated("Use AudioHandler.fastForward instead.")
  static final Future<void> Function() fastForward =
      _compatibilitySwitcher.fastForward;

  /// Deprecated. Use [AudioHandler.rewind] instead.
  @Deprecated("Use AudioHandler.rewind instead.")
  static final Future<void> Function() rewind = _compatibilitySwitcher.rewind;

  /// Deprecated. Use [AudioHandler.setRepeatMode] instead.
  @Deprecated("Use AudioHandler.setRepeatMode instead.")
  static final setRepeatMode = _compatibilitySwitcher.setRepeatMode;

  /// Deprecated. Use [AudioHandler.setShuffleMode] instead.
  @Deprecated("Use AudioHandler.setShuffleMode instead.")
  static final setShuffleMode = _compatibilitySwitcher.setShuffleMode;

  /// Deprecated. Use [AudioHandler.setRating] instead.
  @Deprecated("Use AudioHandler.setRating instead.")
  static Future<void> setRating(Rating rating, Map<dynamic, dynamic> extras) =>
      _compatibilitySwitcher.setRating(rating, extras.cast<String, dynamic>());

  /// Deprecated. Use [AudioHandler.setSpeed] instead.
  @Deprecated("Use AudioHandler.setSpeed instead.")
  static final setSpeed = _compatibilitySwitcher.setSpeed;

  /// Deprecated. Use [AudioHandler.seekBackward] instead.
  @Deprecated("Use audioHandler.seekBackward instead.")
  static final seekBackward = _compatibilitySwitcher.seekBackward;

  /// Deprecated. Use [AudioHandler.seekForward] instead.
  @Deprecated("Use AudioHandler.seekForward instead.")
  static final seekForward = _compatibilitySwitcher.seekForward;

  /// Deprecated. Use [AudioHandler.customAction] instead.
  @Deprecated("Use AudioHandler.customAction instead.")
  static final Future<dynamic> Function(String, Map<String, dynamic>)
      customAction = _compatibilitySwitcher.customAction;

  /// Deprecated. Use [position] instead.
  @Deprecated("Use position instead.")
  static final ValueStream<Duration> positionStream =
      BehaviorSubject.seeded(Duration.zero, sync: true)
        ..addStream(position)
        ..stream;
}

class _BackgroundAudioHandler extends BaseAudioHandler {
  // ignore: deprecated_member_use_from_same_package
  late BackgroundAudioTask _task;

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> prepare() => _task.onPrepare();

  @override
  Future<void> prepareFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onPrepareFromMediaId(mediaId);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> play() => _task.onPlay();

  @override
  Future<void> playFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onPlayFromMediaId(mediaId);

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onPlayMediaItem(mediaItem);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> pause() => _task.onPause();

  @override
  Future<void> click([MediaButton button = MediaButton.media]) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onClick(button);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> stop() => _task.onStop();

  @override
  Future<void> addQueueItem(MediaItem mediaItem) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onAddQueueItem(mediaItem);

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    for (var mediaItem in mediaItems) {
      // ignore: deprecated_member_use_from_same_package
      await _task.onAddQueueItem(mediaItem);
    }
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onAddQueueItemAt(mediaItem, index);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> updateQueue(List<MediaItem> queue) => _task.onUpdateQueue(queue);

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onUpdateMediaItem(mediaItem);

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onRemoveQueueItem(mediaItem);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> skipToNext() => _task.onSkipToNext();

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> skipToPrevious() => _task.onSkipToPrevious();

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> fastForward() => _task.onFastForward();

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> rewind() => _task.onRewind();

  @override
  Future<void> skipToQueueItem(int index) async {
    final queue = this.queue.nvalue ?? <MediaItem>[];
    if (index < 0 || index >= queue.length) return;
    final mediaItem = queue[index];
    // ignore: deprecated_member_use_from_same_package
    await _task.onSkipToQueueItem(mediaItem.id);
  }

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> seek(Duration position) => _task.onSeekTo(position);

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onSetRating(rating, extras);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onSetRepeatMode(repeatMode);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onSetShuffleMode(shuffleMode);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> seekBackward(bool begin) => _task.onSeekBackward(begin);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> seekForward(bool begin) => _task.onSeekForward(begin);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> setSpeed(double speed) => _task.onSetSpeed(speed);

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onCustomAction(name, extras);

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> onNotificationDeleted() => _task.onClose();

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
          [Map<String, dynamic>? options]) =>
      // ignore: deprecated_member_use_from_same_package
      _task.onLoadChildren(parentMediaId);
}

/// This class is deprecated. Use [BaseAudioHandler] instead.
@Deprecated("Use AudioHandler instead.")
abstract class BackgroundAudioTask {
  late _BackgroundAudioHandler _handler;

  /// Deprecated. Use [AudioServiceConfig.fastForwardInterval] from [AudioService.config] instead.
  @Deprecated(
      "Use [AudioServiceConfig.fastForwardInterval] from [AudioService.config] instead.")
  Duration get fastForwardInterval => AudioService.config.fastForwardInterval;

  /// Deprecated. Use [AudioServiceConfig.rewindInterval] from [AudioService.config] instead.
  @Deprecated(
      "Use [AudioServiceConfig.rewindInterval] from [AudioService.config] instead.")
  Duration get rewindInterval => AudioService.config.rewindInterval;

  /// Deprecated. The new [AudioHandler] API now automatically starts the
  /// service when your implementation enters the playing state. Parameters can
  /// be passed via [AudioHandler.customAction].
  @Deprecated("Use AudioService.init instead.")
  Future<void> onStart(Map<String, dynamic>? params) async {}

  /// Deprecated. Replaced by [AudioHandler.stop].
  @mustCallSuper
  @Deprecated("Use AudioHandler.stop instead.")
  Future<void> onStop() async {
    final audioSession = await AudioSession.instance;
    try {
      await audioSession.setActive(false);
    } catch (e) {
      // ignore: avoid_print
      print("While deactivating audio session: $e");
    }
  }

  /// Deprecated. Replaced by [AudioHandler.getChildren].
  @Deprecated("Use AudioHandler.getChildren instead.")
  Future<List<MediaItem>> onLoadChildren(String parentMediaId) async => [];

  /// Deprecated. Replaced by [AudioHandler.click].
  @Deprecated("Use AudioHandler.click instead.")
  Future<void> onClick(MediaButton? button) async {
    switch (button!) {
      case MediaButton.media:
        if (_handler.playbackState.nvalue!.playing) {
          await onPause();
        } else {
          await onPlay();
        }
        break;
      case MediaButton.next:
        await onSkipToNext();
        break;
      case MediaButton.previous:
        await onSkipToPrevious();
        break;
    }
  }

  /// Deprecated. Replaced by [AudioHandler.pause].
  @Deprecated("Use AudioHandler.pause instead.")
  Future<void> onPause() async {}

  /// Deprecated. Replaced by [AudioHandler.prepare].
  @Deprecated("Use AudioHandler.prepare instead.")
  Future<void> onPrepare() async {}

  /// Deprecated. Replaced by [AudioHandler.prepareFromMediaId].
  @Deprecated("Use AudioHandler.prepareFromMediaId instead.")
  Future<void> onPrepareFromMediaId(String mediaId) async {}

  /// Deprecated. Replaced by [AudioHandler.play].
  @Deprecated("Use AudioHandler.play instead.")
  Future<void> onPlay() async {}

  /// Deprecated. Replaced by [AudioHandler.playFromMediaId].
  @Deprecated("Use AudioHandler.playFromMediaId instead.")
  Future<void> onPlayFromMediaId(String mediaId) async {}

  /// Deprecated. Replaced by [AudioHandler.playMediaItem].
  @Deprecated("Use AudioHandler.playMediaItem instead.")
  Future<void> onPlayMediaItem(MediaItem mediaItem) async {}

  /// Deprecated. Replaced by [AudioHandler.addQueueItem].
  @Deprecated("Use AudioHandler.addQueueItem instead.")
  Future<void> onAddQueueItem(MediaItem mediaItem) async {}

  /// Deprecated. Replaced by [AudioHandler.updateQueue].
  @Deprecated("Use AudioHandler.updateQueue instead.")
  Future<void> onUpdateQueue(List<MediaItem> queue) async {}

  /// Deprecated. Replaced by [AudioHandler.updateMediaItem].
  @Deprecated("Use AudioHandler.updateMediaItem instead.")
  Future<void> onUpdateMediaItem(MediaItem mediaItem) async {}

  /// Deprecated. Replaced by [AudioHandler.insertQueueItem].
  @Deprecated("Use AudioHandler.insertQueueItem instead.")
  Future<void> onAddQueueItemAt(MediaItem mediaItem, int index) async {}

  /// Deprecated. Replaced by [AudioHandler.removeQueueItem].
  @Deprecated("Use AudioHandler.removeQueueItem instead.")
  Future<void> onRemoveQueueItem(MediaItem mediaItem) async {}

  /// Deprecated. Replaced by [AudioHandler.skipToNext].
  @Deprecated("Use AudioHandler.skipToNext instead.")
  Future<void> onSkipToNext() => _skip(1);

  /// Deprecated. Replaced by [AudioHandler.skipToPrevious].
  @Deprecated("Use AudioHandler.skipToPrevious instead.")
  Future<void> onSkipToPrevious() => _skip(-1);

  /// Deprecated. Replaced by [AudioHandler.fastForward].
  @Deprecated("Use AudioHandler.fastForward instead.")
  Future<void> onFastForward() async {}

  /// Deprecated. Replaced by [AudioHandler.rewind].
  @Deprecated("Use AudioHandler.rewind instead.")
  Future<void> onRewind() async {}

  /// Deprecated. Replaced by [AudioHandler.skipToQueueItem].
  @Deprecated("Use AudioHandler.skipToQueueItem instead.")
  Future<void> onSkipToQueueItem(String mediaId) async {}

  /// Deprecated. Replaced by [AudioHandler.seek].
  @Deprecated("Use AudioHandler.seek instead.")
  Future<void> onSeekTo(Duration position) async {}

  /// Deprecated. Replaced by [AudioHandler.setRating].
  @Deprecated("Use AudioHandler.setRating instead.")
  Future<void> onSetRating(Rating rating, Map<String, dynamic>? extras) async {}

  /// Deprecated. Replaced by [AudioHandler.setRepeatMode].
  @Deprecated("Use AudioHandler.setRepeatMode instead.")
  Future<void> onSetRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  /// Deprecated. Replaced by [AudioHandler.setShuffleMode].
  @Deprecated("Use AudioHandler.setShuffleMode instead.")
  Future<void> onSetShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  /// Deprecated. Replaced by [AudioHandler.seekBackward].
  @Deprecated("Use AudioHandler.seekBackward instead.")
  Future<void> onSeekBackward(bool begin) async {}

  /// Deprecated. Replaced by [AudioHandler.seekForward].
  @Deprecated("Use AudioHandler.seekForward instead.")
  Future<void> onSeekForward(bool begin) async {}

  /// Deprecated. Replaced by [AudioHandler.setSpeed].
  @Deprecated("Use AudioHandler.setSpeed instead.")
  Future<void> onSetSpeed(double speed) async {}

  /// Deprecated. Replaced by [AudioHandler.customAction].
  @Deprecated("Use AudioHandler.customAction instead.")
  Future<dynamic> onCustomAction(String name, dynamic arguments) async {}

  /// Deprecated. Replaced by [AudioHandler.onTaskRemoved].
  @Deprecated("Use AudioHandler.onTaskRemoved instead.")
  Future<void> onTaskRemoved() async {}

  /// Deprecated. Replaced by [AudioHandler.onNotificationDeleted].
  @Deprecated("Use AudioHandler.onNotificationDeleted instead.")
  Future<void> onClose() => onStop();

  Future<void> _skip(int offset) async {
    final mediaItem = _handler.mediaItem.nvalue;
    if (mediaItem == null) return;
    final queue = _handler.queue.nvalue ?? <MediaItem>[];
    final i = queue.indexOf(mediaItem);
    if (i == -1) return;
    final newIndex = i + offset;
    if (newIndex >= 0 && newIndex < queue.length) {
      await onSkipToQueueItem(queue[newIndex].id);
    }
  }
}

/// An [AudioHandler] plays audio, provides state updates and query results to
/// clients. It implements standard protocols that allow it to be remotely
/// controlled by the lock screen, media notifications, the iOS control center,
/// headsets, smart watches, car audio systems, and other compatible agents.
///
/// This class cannot be subclassed directly. Implementations should subclass
/// [BaseAudioHandler], and composite behaviours should be defined as subclasses
/// of [CompositeAudioHandler].
abstract class AudioHandler {
  AudioHandler._();

  /// Prepare media items for playback.
  Future<void> prepare();

  /// Prepare a specific media item for playback.
  Future<void> prepareFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]);

  /// Prepare playback from a search query.
  Future<void> prepareFromSearch(String query, [Map<String, dynamic>? extras]);

  /// Prepare a media item represented by a Uri for playback.
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]);

  /// Start or resume playback.
  Future<void> play();

  /// Play a specific media item.
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]);

  /// Begin playback from a search query.
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]);

  /// Play a media item represented by a Uri.
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]);

  /// Play a specific media item.
  Future<void> playMediaItem(MediaItem mediaItem);

  /// Pause playback.
  Future<void> pause();

  /// Process a headset button click, where [button] defaults to
  /// [MediaButton.media].
  Future<void> click([MediaButton button = MediaButton.media]);

  /// Stop playback and release resources.
  Future<void> stop();

  /// Add [mediaItem] to the queue.
  Future<void> addQueueItem(MediaItem mediaItem);

  /// Add [mediaItems] to the queue.
  Future<void> addQueueItems(List<MediaItem> mediaItems);

  /// Insert [mediaItem] into the queue at position [index].
  Future<void> insertQueueItem(int index, MediaItem mediaItem);

  /// Update to the queue to [queue].
  Future<void> updateQueue(List<MediaItem> queue);

  /// Update the properties of [mediaItem].
  Future<void> updateMediaItem(MediaItem mediaItem);

  /// Remove [mediaItem] from the queue.
  Future<void> removeQueueItem(MediaItem mediaItem);

  /// Remove media item from the queue at the specified [index].
  Future<void> removeQueueItemAt(int index);

  /// Skip to the next item in the queue.
  Future<void> skipToNext();

  /// Skip to the previous item in the queue.
  Future<void> skipToPrevious();

  /// Jump forward by [AudioServiceConfig.fastForwardInterval].
  Future<void> fastForward();

  /// Jump backward by [AudioServiceConfig.rewindInterval]. Note: this value
  /// must be positive.
  Future<void> rewind();

  /// Skip to a queue item.
  Future<void> skipToQueueItem(int index);

  /// Seek to [position].
  Future<void> seek(Duration position);

  /// Set the rating.
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]);

  /// Set whether captioning is enabled.
  Future<void> setCaptioningEnabled(bool enabled);

  /// Set the repeat mode.
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode);

  /// Set the shuffle mode.
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode);

  /// Begin or end seeking backward continuously.
  Future<void> seekBackward(bool begin);

  /// Begin or end seeking forward continuously.
  Future<void> seekForward(bool begin);

  /// Set the playback speed.
  Future<void> setSpeed(double speed);

  /// A mechanism to support app-specific actions.
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]);

  /// Handle the task being swiped away in the task manager (Android).
  Future<void> onTaskRemoved();

  /// Handle the notification being swiped away (Android).
  Future<void> onNotificationDeleted();

  /// Get the children of a parent media item.
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]);

  /// Get a value stream that emits service-specific options to send to the
  /// client whenever the children under the specified parent change. The
  /// emitted options may contain information about what changed. A client that
  /// is subscribed to this stream should call [getChildren] to obtain the
  /// changed children.
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId);

  /// Get a particular media item.
  Future<MediaItem?> getMediaItem(String mediaId);

  /// Search for media items.
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]);

  /// Set the remote volume on Android. This works only when using
  /// [RemoteAndroidPlaybackInfo].
  Future<void> androidSetRemoteVolume(int volumeIndex);

  /// Adjust the remote volume on Android. This works only when using
  /// [RemoteAndroidPlaybackInfo].
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction);

  /// A value stream of playback states.
  ValueStream<PlaybackState> get playbackState;

  /// A value stream of the current queue.
  ValueStream<List<MediaItem>> get queue;

  /// A value stream of the current queueTitle.
  ValueStream<String> get queueTitle;

  /// A value stream of the current media item.
  ValueStream<MediaItem?> get mediaItem;

  /// A value stream of the current rating style.
  ValueStream<RatingStyle> get ratingStyle;

  /// A value stream of the current [AndroidPlaybackInfo].
  ValueStream<AndroidPlaybackInfo> get androidPlaybackInfo;

  /// A stream of custom events.
  Stream<dynamic> get customEvent;

  /// A stream of custom states.
  ValueStream<dynamic> get customState;
}

/// A [SwitchAudioHandler] wraps another [AudioHandler] that may be switched for
/// another at any time by setting [inner].
class SwitchAudioHandler extends CompositeAudioHandler {
  final BehaviorSubject<PlaybackState> _playbackState = BehaviorSubject();
  final BehaviorSubject<List<MediaItem>> _queue = BehaviorSubject();
  final BehaviorSubject<String> _queueTitle = BehaviorSubject();
  final BehaviorSubject<MediaItem?> _mediaItem = BehaviorSubject();
  final BehaviorSubject<AndroidPlaybackInfo> _androidPlaybackInfo =
      BehaviorSubject();
  final BehaviorSubject<RatingStyle> _ratingStyle = BehaviorSubject();
  final PublishSubject<dynamic> _customEvent = PublishSubject<dynamic>();
  final BehaviorSubject<dynamic> _customState = BehaviorSubject<dynamic>();

  @override
  ValueStream<PlaybackState> get playbackState => _playbackState;

  @override
  ValueStream<List<MediaItem>> get queue => _queue;

  @override
  ValueStream<String> get queueTitle => _queueTitle;

  @override
  ValueStream<MediaItem?> get mediaItem => _mediaItem;

  @override
  ValueStream<AndroidPlaybackInfo> get androidPlaybackInfo =>
      _androidPlaybackInfo;

  @override
  ValueStream<RatingStyle> get ratingStyle => _ratingStyle;

  @override
  Stream<dynamic> get customEvent => _customEvent;

  @override
  ValueStream<dynamic> get customState => _customState;

  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  StreamSubscription<List<MediaItem>>? _queueSubscription;
  StreamSubscription<String>? _queueTitleSubscription;
  StreamSubscription<MediaItem?>? _mediaItemSubscription;
  StreamSubscription<AndroidPlaybackInfo>? _androidPlaybackInfoSubscription;
  StreamSubscription<RatingStyle>? _ratingStyleSubscription;
  StreamSubscription<dynamic>? _customEventSubscription;
  StreamSubscription<dynamic>? _customStateSubscription;

  /// Creates a [SwitchAudioHandler] with an initial [inner] handler, which
  /// defaults to a no-op handler.
  SwitchAudioHandler([AudioHandler? inner])
      : this._(inner ?? BaseAudioHandler());

  SwitchAudioHandler._(AudioHandler inner) : super(inner) {
    this.inner = inner;
  }

  /// The current inner [AudioHandler] that this [SwitchAudioHandler] will
  /// delegate to.
  AudioHandler get inner => _inner;

  set inner(AudioHandler newInner) {
    // Should disallow all ancestors...
    assert(newInner != this);
    _playbackStateSubscription?.cancel();
    _queueSubscription?.cancel();
    _queueTitleSubscription?.cancel();
    _mediaItemSubscription?.cancel();
    _androidPlaybackInfoSubscription?.cancel();
    _ratingStyleSubscription?.cancel();
    _customEventSubscription?.cancel();
    _customStateSubscription?.cancel();
    _inner = newInner;
    _playbackStateSubscription = inner.playbackState.listen(_playbackState.add);
    _queueSubscription = inner.queue.listen(_queue.add);
    _queueTitleSubscription = inner.queueTitle.listen(_queueTitle.add);
    // XXX: This only works in one direction.
    _mediaItemSubscription = inner.mediaItem.listen(_mediaItem.add);
    _androidPlaybackInfoSubscription =
        inner.androidPlaybackInfo.listen(_androidPlaybackInfo.add);
    _ratingStyleSubscription = inner.ratingStyle.listen(_ratingStyle.add);
    _customEventSubscription = inner.customEvent.listen(_customEvent.add);
    _customStateSubscription = inner.customState.listen(_customState.add);
  }
}

/// A [CompositeAudioHandler] wraps another [AudioHandler] and adds additional
/// behaviour to it. Each method will by default pass through to the
/// corresponding method of the wrapped handler. If you override a method, it
/// must call super in addition to any "additional" functionality you add.
class CompositeAudioHandler extends AudioHandler {
  AudioHandler _inner;

  /// Create the [CompositeAudioHandler] with the given wrapped handler.
  CompositeAudioHandler(AudioHandler inner)
      : _inner = inner,
        super._();

  @override
  @mustCallSuper
  Future<void> prepare() => _inner.prepare();

  @override
  @mustCallSuper
  Future<void> prepareFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      _inner.prepareFromMediaId(mediaId, extras);

  @override
  @mustCallSuper
  Future<void> prepareFromSearch(String query,
          [Map<String, dynamic>? extras]) =>
      _inner.prepareFromSearch(query, extras);

  @override
  @mustCallSuper
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) =>
      _inner.prepareFromUri(uri, extras);

  @override
  @mustCallSuper
  Future<void> play() => _inner.play();

  @override
  @mustCallSuper
  Future<void> playFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      _inner.playFromMediaId(mediaId, extras);

  @override
  @mustCallSuper
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) =>
      _inner.playFromSearch(query, extras);

  @override
  @mustCallSuper
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) =>
      _inner.playFromUri(uri, extras);

  @override
  @mustCallSuper
  Future<void> playMediaItem(MediaItem mediaItem) =>
      _inner.playMediaItem(mediaItem);

  @override
  @mustCallSuper
  Future<void> pause() => _inner.pause();

  @override
  @mustCallSuper
  Future<void> click([MediaButton button = MediaButton.media]) =>
      _inner.click(button);

  @override
  @mustCallSuper
  Future<void> stop() => _inner.stop();

  @override
  @mustCallSuper
  Future<void> addQueueItem(MediaItem mediaItem) =>
      _inner.addQueueItem(mediaItem);

  @override
  @mustCallSuper
  Future<void> addQueueItems(List<MediaItem> mediaItems) =>
      _inner.addQueueItems(mediaItems);

  @override
  @mustCallSuper
  Future<void> insertQueueItem(int index, MediaItem mediaItem) =>
      _inner.insertQueueItem(index, mediaItem);

  @override
  @mustCallSuper
  Future<void> updateQueue(List<MediaItem> queue) => _inner.updateQueue(queue);

  @override
  @mustCallSuper
  Future<void> updateMediaItem(MediaItem mediaItem) =>
      _inner.updateMediaItem(mediaItem);

  @override
  @mustCallSuper
  Future<void> removeQueueItem(MediaItem mediaItem) =>
      _inner.removeQueueItem(mediaItem);

  @override
  @mustCallSuper
  Future<void> removeQueueItemAt(int index) => _inner.removeQueueItemAt(index);

  @override
  @mustCallSuper
  Future<void> skipToNext() => _inner.skipToNext();

  @override
  @mustCallSuper
  Future<void> skipToPrevious() => _inner.skipToPrevious();

  @override
  @mustCallSuper
  Future<void> fastForward() => _inner.fastForward();

  @override
  @mustCallSuper
  Future<void> rewind() => _inner.rewind();

  @override
  @mustCallSuper
  Future<void> skipToQueueItem(int index) => _inner.skipToQueueItem(index);

  @override
  @mustCallSuper
  Future<void> seek(Duration position) => _inner.seek(position);

  @override
  @mustCallSuper
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) =>
      _inner.setRating(rating, extras);

  @override
  @mustCallSuper
  Future<void> setCaptioningEnabled(bool enabled) =>
      _inner.setCaptioningEnabled(enabled);

  @override
  @mustCallSuper
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _inner.setRepeatMode(repeatMode);

  @override
  @mustCallSuper
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _inner.setShuffleMode(shuffleMode);

  @override
  @mustCallSuper
  Future<void> seekBackward(bool begin) => _inner.seekBackward(begin);

  @override
  @mustCallSuper
  Future<void> seekForward(bool begin) => _inner.seekForward(begin);

  @override
  @mustCallSuper
  Future<void> setSpeed(double speed) => _inner.setSpeed(speed);

  @override
  @mustCallSuper
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) =>
      _inner.customAction(name, extras);

  @override
  @mustCallSuper
  Future<void> onTaskRemoved() => _inner.onTaskRemoved();

  @override
  @mustCallSuper
  Future<void> onNotificationDeleted() => _inner.onNotificationDeleted();

  @override
  @mustCallSuper
  Future<List<MediaItem>> getChildren(String parentMediaId,
          [Map<String, dynamic>? options]) =>
      _inner.getChildren(parentMediaId, options);

  @override
  @mustCallSuper
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) =>
      _inner.subscribeToChildren(parentMediaId);

  @override
  @mustCallSuper
  Future<MediaItem?> getMediaItem(String mediaId) =>
      _inner.getMediaItem(mediaId);

  @override
  @mustCallSuper
  Future<List<MediaItem>> search(String query,
          [Map<String, dynamic>? extras]) =>
      _inner.search(query, extras);

  @override
  @mustCallSuper
  Future<void> androidSetRemoteVolume(int volumeIndex) =>
      _inner.androidSetRemoteVolume(volumeIndex);

  @override
  @mustCallSuper
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) =>
      _inner.androidAdjustRemoteVolume(direction);

  @override
  ValueStream<PlaybackState> get playbackState => _inner.playbackState;

  @override
  ValueStream<List<MediaItem>> get queue => _inner.queue;

  @override
  ValueStream<String> get queueTitle => _inner.queueTitle;

  @override
  ValueStream<MediaItem?> get mediaItem => _inner.mediaItem;

  @override
  ValueStream<RatingStyle> get ratingStyle => _inner.ratingStyle;

  @override
  ValueStream<AndroidPlaybackInfo> get androidPlaybackInfo =>
      _inner.androidPlaybackInfo;

  @override
  Stream<dynamic> get customEvent => _inner.customEvent;

  @override
  ValueStream<dynamic> get customState => _inner.customState;
}

class _IsolateRequest {
  /// The send port for sending the response of this request.
  final SendPort sendPort;
  final String method;
  final List<dynamic>? arguments;

  _IsolateRequest(this.sendPort, this.method, [this.arguments]);
}

/// A [CompositeAudioHandler] that can be accessed from other isolates via
/// [lookup].
///
/// This handler recognises the custom action 'unregister' so that
/// `customAction('unregister')` can be called from a client to unregister this
/// handler, or it can be unregistered by a direct invocation of [unregister].
class IsolatedAudioHandler extends CompositeAudioHandler {
  /// The default port name by which this isolated audio handler can be looked
  /// up.
  static const defaultPortName = 'com.ryanheise.audioservice.port';

  /// Connect to an [IsolatedAudioHandler] from another isolate having the name
  /// [portName] (defaulting to [defaultPortName]).
  static Future<AudioHandler> lookup(
      {String portName = defaultPortName}) async {
    assert(!kIsWeb, "Isolates are not supported on web");
    final handler = _ClientIsolatedAudioHandler(portName: portName);
    await handler._init();
    return handler;
  }

  /// The port name to use when looking up this handler.
  final String portName;

  final _receivePort = ReceivePort();

  /// Creates an [IsolatedAudioHandler] that can be looked up by [portName]
  /// (defaulting to [defaultPortName]).
  ///
  /// This will throw a [StateError] if another [IsolatedAudioHandler] was
  /// already registered with the given port name. Setting [overridePortName] to
  /// `true` will unregister any existing port name first. However, this is
  /// inherently racy and may still throw the same [StateError] if another
  /// isolate is able to register another new handler with the same name before
  /// this isolate can.
  IsolatedAudioHandler(
    super.inner, {
    this.portName = defaultPortName,
    bool overridePortName = false,
  }) : assert(!kIsWeb) {
    _receivePort.listen((dynamic event) async {
      final request = event as _IsolateRequest;
      switch (request.method) {
        case 'playbackState':
          _syncStream(playbackState, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'queue':
          _syncStream(queue, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'queueTitle':
          _syncStream(queueTitle, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'mediaItem':
          _syncStream(mediaItem, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'androidPlaybackInfo':
          _syncStream(androidPlaybackInfo, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'ratingStyle':
          _syncStream(ratingStyle, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'customEvent':
          _syncStream<dynamic>(customEvent, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'customState':
          _syncStream<dynamic>(customState, request.arguments![0] as SendPort);
          request.sendPort.send(null);
          break;
        case 'prepare':
          await prepare();
          request.sendPort.send(null);
          break;
        case 'prepareFromMediaId':
          await prepareFromMediaId(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'prepareFromSearch':
          await prepareFromSearch(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'prepareFromUri':
          await prepareFromUri(
            request.arguments![0] as Uri,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'play':
          await play();
          request.sendPort.send(null);
          break;
        case 'playFromMediaId':
          await playFromMediaId(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'playFromSearch':
          await playFromSearch(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'playFromUri':
          await playFromUri(
            request.arguments![0] as Uri,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'playMediaItem':
          await playMediaItem(request.arguments![0] as MediaItem);
          request.sendPort.send(null);
          break;
        case 'pause':
          await pause();
          request.sendPort.send(null);
          break;
        case 'click':
          await click(request.arguments![0] as MediaButton);
          request.sendPort.send(null);
          break;
        case 'stop':
          await stop();
          request.sendPort.send(null);
          break;
        case 'addQueueItem':
          await addQueueItem(request.arguments![0] as MediaItem);
          request.sendPort.send(null);
          break;
        case 'addQueueItems':
          await addQueueItems(request.arguments![0] as List<MediaItem>);
          request.sendPort.send(null);
          break;
        case 'insertQueueItem':
          await insertQueueItem(
            request.arguments![0] as int,
            request.arguments![1] as MediaItem,
          );
          request.sendPort.send(null);
          break;
        case 'updateQueue':
          await updateQueue(request.arguments![0] as List<MediaItem>);
          request.sendPort.send(null);
          break;
        case 'updateMediaItem':
          await updateMediaItem(request.arguments![0] as MediaItem);
          request.sendPort.send(null);
          break;
        case 'removeQueueItem':
          await removeQueueItem(request.arguments![0] as MediaItem);
          request.sendPort.send(null);
          break;
        case 'removeQueueItemAt':
          await removeQueueItemAt(request.arguments![0] as int);
          request.sendPort.send(null);
          break;
        case 'skipToNext':
          await skipToNext();
          request.sendPort.send(null);
          break;
        case 'skipToPrevious':
          await skipToPrevious();
          request.sendPort.send(null);
          break;
        case 'fastForward':
          await fastForward();
          request.sendPort.send(null);
          break;
        case 'rewind':
          await rewind();
          request.sendPort.send(null);
          break;
        case 'skipToQueueItem':
          await skipToQueueItem(request.arguments![0] as int);
          request.sendPort.send(null);
          break;
        case 'seek':
          await seek(request.arguments![0] as Duration);
          request.sendPort.send(null);
          break;
        case 'setRating':
          await setRating(
            request.arguments![0] as Rating,
            request.arguments![1] as Map<String, dynamic>?,
          );
          request.sendPort.send(null);
          break;
        case 'setCaptioningEnabled':
          await setCaptioningEnabled(request.arguments![0] as bool);
          request.sendPort.send(null);
          break;
        case 'setRepeatMode':
          await setRepeatMode(request.arguments![0] as AudioServiceRepeatMode);
          request.sendPort.send(null);
          break;
        case 'setShuffleMode':
          await setShuffleMode(
              request.arguments![0] as AudioServiceShuffleMode);
          request.sendPort.send(null);
          break;
        case 'seekBackward':
          await seekBackward(request.arguments![0] as bool);
          request.sendPort.send(null);
          break;
        case 'seekForward':
          await seekForward(request.arguments![0] as bool);
          request.sendPort.send(null);
          break;
        case 'setSpeed':
          await setSpeed(request.arguments![0] as double);
          request.sendPort.send(null);
          break;
        case 'customAction':
          request.sendPort.send(await customAction(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          ));
          break;
        case 'onTaskRemoved':
          await onTaskRemoved();
          request.sendPort.send(null);
          break;
        case 'onNotificationDeleted':
          await onNotificationDeleted();
          request.sendPort.send(null);
          break;
        case 'getChildren':
          request.sendPort.send(await getChildren(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          ));
          break;
        case 'subscribeToChildren':
          final parentMediaId = request.arguments![0] as String;
          final sendPort = request.arguments![1] as SendPort?;
          subscribeToChildren(parentMediaId).listen(sendPort!.send);
          break;
        case 'getMediaItem':
          final result = await getMediaItem(request.arguments![0] as String);
          request.sendPort.send(result);
          break;
        case 'search':
          request.sendPort.send(await search(
            request.arguments![0] as String,
            request.arguments![1] as Map<String, dynamic>?,
          ));
          break;
        case 'androidAdjustRemoteVolume':
          await androidAdjustRemoteVolume(
              request.arguments![0] as AndroidVolumeDirection);
          request.sendPort.send(null);
          break;
        case 'androidSetRemoteVolume':
          await androidSetRemoteVolume(request.arguments![0] as int);
          request.sendPort.send(null);
          break;
      }
    });
    if (overridePortName) {
      IsolateNameServer.removePortNameMapping(portName);
    }
    final success =
        IsolateNameServer.registerPortWithName(_receivePort.sendPort, portName);
    if (!success) {
      throw StateError(
          'Port name $portName is already registered by another IsolatedAudioHandler.');
    }
  }

  /// Unregisters this handler so that it can no longer be looked up by
  /// [portName].
  void unregister() {
    IsolateNameServer.removePortNameMapping(portName);
  }

  /// Forwards events from `stream` to the requesting isolate via [sendPort].
  void _syncStream<T>(Stream<T> stream, SendPort sendPort) {
    stream.listen(sendPort.send);
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (name == 'unregister') {
      unregister();
    } else {
      return super.customAction(name, extras);
    }
  }
}

/// A proxy for an [IsolatedAudioHandler] running in another isolate.
///
/// All method invocations on this handler will be forwarded to the other
/// handler, and all stream events emitted by the other handler can be listened
/// to on this handler.
class _ClientIsolatedAudioHandler implements BaseAudioHandler {
  final _childrenSubjects = <String, BehaviorSubject<Map<String, dynamic>>>{};

  /// The port name of the [IsolatedAudioHandler] that this client handler
  /// connects to.
  final String portName;

  @override
  final BehaviorSubject<PlaybackState> playbackState = BehaviorSubject();

  @override
  final BehaviorSubject<List<MediaItem>> queue = BehaviorSubject();

  @override
  final BehaviorSubject<String> queueTitle = BehaviorSubject();

  @override
  final BehaviorSubject<MediaItem?> mediaItem = BehaviorSubject();

  @override
  final BehaviorSubject<AndroidPlaybackInfo> androidPlaybackInfo =
      BehaviorSubject();

  @override
  final BehaviorSubject<RatingStyle> ratingStyle = BehaviorSubject();

  @override
  final PublishSubject<dynamic> customEvent = PublishSubject<dynamic>();

  @override
  final BehaviorSubject<dynamic> customState = BehaviorSubject<dynamic>();

  _ClientIsolatedAudioHandler({
    this.portName = IsolatedAudioHandler.defaultPortName,
  });

  Future<void> _init() async {
    await _syncSubject(playbackState, 'playbackState');
    await _syncSubject(queue, 'queue');
    await _syncSubject(queueTitle, 'queueTitle');
    await _syncSubject(mediaItem, 'mediaItem');
    await _syncSubject(androidPlaybackInfo, 'androidPlaybackInfo');
    await _syncSubject(ratingStyle, 'ratingStyle');
    await _syncSubject<dynamic>(customEvent, 'customEvent');
    await _syncSubject<dynamic>(customState, 'customState');
  }

  /// Opens a channel to the [IsolatedAudioSource] through which this proxy can
  /// listen to events on a stream named [name] from that [IsolatedAudioSource]
  /// and forward them on to this proxy's corresponding stream subject to
  /// deliver to the client isolate.
  Future<void> _syncSubject<T>(Subject<T> subject, String name) async {
    final receivePort = ReceivePort();
    receivePort.cast<T>().listen(subject.add);
    await _send(name, <dynamic>[receivePort.sendPort]);
  }

  @override
  Future<void> prepare() => _send('prepare');

  @override
  Future<void> prepareFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      _send('prepareFromMediaId', <dynamic>[mediaId, extras]);

  @override
  Future<void> prepareFromSearch(String query,
          [Map<String, dynamic>? extras]) =>
      _send('prepareFromSearch', <dynamic>[query, extras]);

  @override
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) =>
      _send('prepareFromUri', <dynamic>[uri, extras]);

  @override
  Future<void> play() => _send('play');

  @override
  Future<void> playFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      _send('playFromMediaId', <dynamic>[mediaId, extras]);

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) =>
      _send('playFromSearch', <dynamic>[query, extras]);

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) =>
      _send('playFromUri', <dynamic>[uri, extras]);

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      _send('playMediaItem', <dynamic>[mediaItem]);

  @override
  Future<void> pause() => _send('pause');

  @override
  Future<void> click([MediaButton button = MediaButton.media]) =>
      _send('click', <dynamic>[button]);

  @override
  Future<void> stop() => _send('stop');

  @override
  Future<void> addQueueItem(MediaItem mediaItem) =>
      _send('addQueueItem', <dynamic>[mediaItem]);

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) =>
      _send('addQueueItems', <dynamic>[mediaItems]);

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) =>
      _send('insertQueueItem', <dynamic>[index, mediaItem]);

  @override
  Future<void> updateQueue(List<MediaItem> queue) =>
      _send('updateQueue', <dynamic>[queue]);

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) =>
      _send('updateMediaItem', <dynamic>[mediaItem]);

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) =>
      _send('removeQueueItem', <dynamic>[mediaItem]);

  @override
  Future<void> removeQueueItemAt(int index) =>
      _send('removeQueueItemAt', <dynamic>[index]);

  @override
  Future<void> skipToNext() => _send('skipToNext');

  @override
  Future<void> skipToPrevious() => _send('skipToPrevious');

  @override
  Future<void> fastForward() => _send('fastForward');

  @override
  Future<void> rewind() => _send('rewind');

  @override
  Future<void> skipToQueueItem(int index) =>
      _send('skipToQueueItem', <dynamic>[index]);

  @override
  Future<void> seek(Duration position) => _send('seek', <dynamic>[position]);

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) =>
      _send('setRating', <dynamic>[rating, extras]);

  @override
  Future<void> setCaptioningEnabled(bool enabled) =>
      _send('setCaptioningEnabled', <dynamic>[enabled]);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _send('setRepeatMode', <dynamic>[repeatMode]);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _send('setShuffleMode', <dynamic>[shuffleMode]);

  @override
  Future<void> seekBackward(bool begin) =>
      _send('seekBackward', <dynamic>[begin]);

  @override
  Future<void> seekForward(bool begin) =>
      _send('seekForward', <dynamic>[begin]);

  @override
  Future<void> setSpeed(double speed) => _send('setSpeed', <dynamic>[speed]);

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) =>
      _send('customAction', <dynamic>[name, extras]);

  @override
  Future<void> onTaskRemoved() => _send('onTaskRemoved');

  @override
  Future<void> onNotificationDeleted() => _send('onNotificationDeleted');

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
          [Map<String, dynamic>? options]) async =>
      (await _send('getChildren', <dynamic>[parentMediaId, options]))
          as List<MediaItem>;

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    var childrenSubject = _childrenSubjects[parentMediaId];
    if (childrenSubject == null) {
      childrenSubject = _childrenSubjects[parentMediaId] = BehaviorSubject();
      final receivePort = ReceivePort();
      receivePort.listen((dynamic options) {
        childrenSubject!.add(options as Map<String, dynamic>);
      });
      _send('subscribeToChildren',
          <dynamic>[parentMediaId, receivePort.sendPort]);
    }
    return childrenSubject;
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async =>
      (await _send('getMediaItem', <dynamic>[mediaId])) as MediaItem?;

  @override
  Future<List<MediaItem>> search(String query,
          [Map<String, dynamic>? extras]) async =>
      (await _send('search', <dynamic>[query, extras])) as List<MediaItem>;

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) =>
      _send('androidAdjustRemoteVolume', <dynamic>[direction]);

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) =>
      _send('androidSetRemoteVolume', <dynamic>[volumeIndex]);

  Future<dynamic> _send(String method, [List<dynamic>? arguments]) async {
    final sendPort = IsolateNameServer.lookupPortByName(portName);
    if (sendPort == null) {
      throw StateError('IsolatedAudioHandler $portName not available');
    }
    final receivePort = ReceivePort();
    sendPort.send(_IsolateRequest(receivePort.sendPort, method, arguments));
    final dynamic result = await receivePort.first;
    receivePort.close();
    return result;
  }
}

/// Base class for implementations of [AudioHandler]. It provides default
/// implementations of all methods and streams. Each stream in this class is
/// specialized as either a [BehaviorSubject] or [PublishSubject] providing an
/// additional `add` method for emitting values on those streams.
///
/// These are [BehaviorSubject]s provided by this class:
///
/// * [playbackState]
/// * [queue]
/// * [queueTitle]
/// * [androidPlaybackInfo]
/// * [ratingStyle]
///
/// Besides them, there's also [customEvent] which is a [PublishSubject].
///
/// You can choose to implement all methods yourself, or you may leverage some
/// mixins to provide default implementations of certain behaviours:
///
/// * [QueueHandler] provides default implementations of methods for updating
/// and navigating the queue.
/// * [SeekHandler] provides default implementations of methods for seeking
/// forwards and backwards.
///
/// ## Android service lifecycle and state transitions
///
/// On Android, the [AudioHandler] runs inside an Android service. This allows
/// the audio logic to continue running in the background, and also an app that
/// had previously been terminated to wake up and resume playing audio when the
/// user click on the play button in a media notification or headset.
///
/// ### Foreground/background transitions
///
/// The underlying Android service enters the `foreground` state whenever
/// [PlaybackState.playing] becomes `true`, and enters the `background` state
/// whenever [PlaybackState.playing] becomes `false`.
///
/// ### Start/stop transitions
///
/// The underlying Android service enters the `started` state whenever
/// [PlaybackState.playing] becomes `true`, and enters the `stopped` state
/// whenever [PlaybackState.processingState] becomes `idle`.
///
/// ### Create/destroy lifecycle
///
/// The underlying service is created either when a client binds to it, or when
/// it is started, and it is destroyed when no clients are bound to it AND it is
/// stopped. When the Flutter UI is attached to an Android Activity, this will
/// also bind to the service, and it will unbind from the service when the
/// Activity is destroyed. A media notification will also bind to the service.
///
/// If the service needs to be created when the app is not already running, your
/// app's `main` entrypoint will be called in the background which should
/// initialise your [AudioHandler].
class BaseAudioHandler extends AudioHandler {
  /// A controller for broadcasting the current [PlaybackState] to the app's UI,
  /// media notification and other clients. Example usage:
  ///
  /// ```dart
  /// playbackState.add(playbackState.value!.copyWith(playing: true));
  /// ```
  ///
  /// The state changes broadcast via this stream can be listened to via the
  /// Flutter app's UI
  @override
  final BehaviorSubject<PlaybackState> playbackState =
      BehaviorSubject.seeded(PlaybackState());

  /// A controller for broadcasting the current queue to the app's UI, media
  /// notification and other clients. Example usage:
  ///
  /// ```dart
  /// queue.add(queue.value! + [additionalItem]);
  /// ```
  @override
  final BehaviorSubject<List<MediaItem>> queue =
      BehaviorSubject.seeded(<MediaItem>[]);

  /// A controller for broadcasting the current queue title to the app's UI, media
  /// notification and other clients. Example usage:
  ///
  /// ```dart
  /// queueTitle.add(newTitle);
  /// ```
  @override
  final BehaviorSubject<String> queueTitle = BehaviorSubject.seeded('');

  /// A controller for broadcasting the current media item to the app's UI,
  /// media notification and other clients. Example usage:
  ///
  /// ```dart
  /// mediaItem.add(item);
  /// ```
  @override
  final BehaviorSubject<MediaItem?> mediaItem = BehaviorSubject.seeded(null);

  /// A controller for broadcasting the current [AndroidPlaybackInfo] to the app's UI,
  /// media notification and other clients. Example usage:
  ///
  /// ```dart
  /// androidPlaybackInfo.add(newPlaybackInfo);
  /// ```
  @override
  final BehaviorSubject<AndroidPlaybackInfo> androidPlaybackInfo =
      BehaviorSubject();

  /// A controller for broadcasting the current rating style to the app's UI,
  /// media notification and other clients. Example usage:
  ///
  /// ```dart
  /// ratingStyle.add(style);
  /// ```
  @override
  final BehaviorSubject<RatingStyle> ratingStyle = BehaviorSubject();

  /// A controller for broadcasting a custom event to the app's UI.
  /// A shorthand for the event stream is [customEvent].
  /// Example usage:
  ///
  /// ```dart
  /// customEventSubject.add(MyCustomEvent(arg: 3));
  /// ```
  @override
  final PublishSubject<dynamic> customEvent = PublishSubject<dynamic>();

  /// A controller for broadcasting the current custom state to the app's UI.
  /// Example usage:
  ///
  /// ```dart
  /// customState.add(MyCustomState(...));
  /// ```
  @override
  final BehaviorSubject<dynamic> customState = BehaviorSubject<dynamic>();

  /// Constructor. Normally this is called from subclasses via `super`.
  BaseAudioHandler() : super._();

  @override
  Future<void> prepare() async {}

  @override
  Future<void> prepareFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> prepareFromSearch(String query,
      [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.nvalue?.playing == true) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  /// Stop playback and release resources.
  ///
  /// The default implementation (which may be overridden) updates
  /// [playbackState] by setting the processing state to
  /// [AudioProcessingState.idle] which disables the system notification.
  @override
  Future<void> stop() async {
    playbackState.add(playbackState.nvalue!
        .copyWith(processingState: AudioProcessingState.idle));
    await playbackState.firstWhere(
        (state) => state.processingState == AudioProcessingState.idle);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {}

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {}

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {}

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {}

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {}

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {}

  @override
  Future<void> removeQueueItemAt(int index) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> fastForward() async {}

  @override
  Future<void> rewind() async {}

  @override
  Future<void> skipToQueueItem(int index) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> setCaptioningEnabled(bool enabled) async {}

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  @override
  Future<void> seekBackward(bool begin) async {}

  @override
  Future<void> seekForward(bool begin) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {}

  @override
  Future<void> onTaskRemoved() async {}

  @override
  Future<void> onNotificationDeleted() async {
    await stop();
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
          [Map<String, dynamic>? options]) async =>
      [];

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) =>
      BehaviorSubject.seeded(<String, dynamic>{});

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async => null;

  @override
  Future<List<MediaItem>> search(String query,
          [Map<String, dynamic>? extras]) async =>
      [];

  @override
  Future<void> androidAdjustRemoteVolume(
      AndroidVolumeDirection direction) async {}

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) async {}
}

/// This mixin provides default implementations of [fastForward], [rewind],
/// [seekForward] and [seekBackward] which are all defined in terms of your own
/// implementation of [seek].
mixin SeekHandler on BaseAudioHandler {
  _Seeker? _seeker;

  @override
  Future<void> fastForward() =>
      _seekRelative(AudioService.config.fastForwardInterval);

  @override
  Future<void> rewind() => _seekRelative(-AudioService.config.rewindInterval);

  @override
  Future<void> seekForward(bool begin) async => _seekContinuously(begin, 1);

  @override
  Future<void> seekBackward(bool begin) async => _seekContinuously(begin, -1);

  /// Jumps away from the current position by [offset].
  Future<void> _seekRelative(Duration offset) async {
    var newPosition = playbackState.nvalue!.position + offset;
    // Make sure we don't jump out of bounds.
    if (newPosition < Duration.zero) {
      newPosition = Duration.zero;
    }
    final duration = mediaItem.nvalue?.duration ?? Duration.zero;
    if (newPosition > duration) {
      newPosition = duration;
    }
    // Perform the jump via a seek.
    await seek(newPosition);
  }

  /// Begins or stops a continuous seek in [direction]. After it begins it will
  /// continue seeking forward or backward by 10 seconds within the audio, at
  /// intervals of 1 second in app time.
  void _seekContinuously(bool begin, int direction) {
    _seeker?.stop();
    if (begin && mediaItem.nvalue?.duration != null) {
      _seeker = _Seeker(this, Duration(seconds: 10 * direction),
          const Duration(seconds: 1), mediaItem.nvalue!.duration!)
        ..start();
    }
  }
}

class _Seeker {
  final AudioHandler handler;
  final Duration positionInterval;
  final Duration stepInterval;
  final Duration duration;
  bool _running = false;

  _Seeker(
    this.handler,
    this.positionInterval,
    this.stepInterval,
    this.duration,
  );

  Future<void> start() async {
    _running = true;
    while (_running) {
      var newPosition =
          handler.playbackState.nvalue!.position + positionInterval;
      if (newPosition < Duration.zero) newPosition = Duration.zero;
      if (newPosition > duration) newPosition = duration;
      handler.seek(newPosition);
      await Future<void>.delayed(stepInterval);
    }
  }

  void stop() {
    _running = false;
  }
}

/// This mixin provides default implementations of methods for updating and
/// navigating the queue. When using this mixin, you must add a list of
/// [MediaItem]s to [queue], override [skipToQueueItem] and initialise the queue
/// index (e.g. by calling [skipToQueueItem] with the initial queue index). The
/// [skipToNext] and [skipToPrevious] default implementations are defined by
/// this mixin in terms of your own implementation of [skipToQueueItem].
mixin QueueHandler on BaseAudioHandler {
  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    queue.add(queue.nvalue!..add(mediaItem));
    await super.addQueueItem(mediaItem);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    queue.add(queue.nvalue!..addAll(mediaItems));
    await super.addQueueItems(mediaItems);
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    queue.add(queue.nvalue!..insert(index, mediaItem));
    await super.insertQueueItem(index, mediaItem);
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(
        this.queue.nvalue!..replaceRange(0, this.queue.nvalue!.length, queue));
    await super.updateQueue(queue);
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    queue.add(queue.nvalue!..[queue.nvalue!.indexOf(mediaItem)] = mediaItem);
    await super.updateMediaItem(mediaItem);
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    queue.add(queue.nvalue!..remove(mediaItem));
    await super.removeQueueItem(mediaItem);
  }

  @override
  Future<void> skipToNext() async {
    await _skip(1);
    await super.skipToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    await _skip(-1);
    await super.skipToPrevious();
  }

  /// This should be overridden to skip to the queue item at [index].
  /// Implementations should broadcast the new queue index via [playbackState],
  /// broadcast the new media item via [mediaItem], and potentially issue
  /// instructions to start the new item playing. Some implementations may
  /// choose to automatically play when skipping to a queue item while others
  /// may prefer to play the new item only if the player was already playing
  /// another item beforehand.
  ///
  /// An example implementation may look like:
  ///
  /// ```dart
  /// playbackState.add(playbackState.value!.copyWith(queueIndex: index));
  /// mediaItem.add(queue.value![index]);
  /// player.playAtIndex(index); // use your player's respective API
  /// await super.skipToQueueItem(index);
  /// ```
  @override
  Future<void> skipToQueueItem(int index) async {
    await super.skipToQueueItem(index);
  }

  Future<void> _skip(int offset) async {
    final queue = this.queue.nvalue!;
    final index = playbackState.nvalue!.queueIndex!;
    if (index < 0 || index >= queue.length) return;
    return skipToQueueItem(index + offset);
  }
}

/// The available shuffle modes for the queue.
enum AudioServiceShuffleMode {
  /// The queue will not be shuffled.
  none,

  /// The whole queue will be shuffled.
  all,

  /// A group of items will be shuffled. This corresponds to Android's
  /// [SHUFFLE_MODE_GROUP](https://developer.android.com/reference/androidx/media2/common/SessionPlayer#SHUFFLE_MODE_GROUP).
  group,
}

/// The available repeat modes.
///
/// This defines how media items should repeat when the current one is finished.
enum AudioServiceRepeatMode {
  /// The current media item or queue will not repeat.
  none,

  /// The current media item will repeat.
  one,

  /// Playback will continue looping through all media items in the current list.
  all,

  /// UNIMPLEMENTED - see https://github.com/ryanheise/audio_service/issues/560
  ///
  /// This corresponds to Android's [REPEAT_MODE_GROUP](https://developer.android.com/reference/androidx/media2/common/SessionPlayer#REPEAT_MODE_GROUP).
  ///
  /// This could represent a playlist that is a smaller subset of all media items.
  group,
}

/// The configuration options to use when intializing the [AudioService].
class AudioServiceConfig {
  /// Whether on Android a media button click wakes up the media session and
  /// resumes playback.
  // TODO: either fix, or remove this https://github.com/ryanheise/audio_service/issues/638
  final bool androidResumeOnClick;

  /// The ID of the media notification channel. This will default to
  /// `<YOUR_PACKAGE_NAME>.channel` where `<YOUR_PACKAGE_NAME>` is your app's
  /// package name. e.g. `com.mycompany.myapp.channel`.
  ///
  /// If your app uses multiple notification channels, make sure each channel
  /// has a unique ID so that they don't clash. It is recommended to override
  /// the default ID.
  ///
  /// NOTE: After a user installs and runs your app, a channel will be created
  /// with this ID and will show up in the app's settings. If you subsequently
  /// change this channel ID here, it will result in a new channel being created
  /// under the new ID leaving the old channel still visible. Therefore, if your
  /// app has already been published, you might prefer to keep using the same
  /// channel ID that you are currently using.
  final String? androidNotificationChannelId;

  /// The name of the media notification channel, that is visible to user in
  /// settings of your app.
  final String androidNotificationChannelName;

  /// A description of the media notification channel, that is visible to user
  /// in settings of your app.
  final String? androidNotificationChannelDescription;

  /// The color to use on the background of the notification on Android. This
  /// should be a non-transparent color.
  final Color? notificationColor;

  /// The icon resource to be used in the Android media notification, specified
  /// like an XML resource reference. This should be a monochrome white icon on
  /// a transparent background. The default value is `"mipmap/ic_launcher"`.
  final String androidNotificationIcon;

  /// Whether notification badges (also known as notification dots) should
  /// appear on a launcher icon when the app has an active notification.
  final bool androidShowNotificationBadge;

  /// Whether the application activity will be opened on click on notification.
  final bool androidNotificationClickStartsActivity;

  /// Whether the notification can be swiped away.
  ///
  /// If you set this to true, [androidStopForegroundOnPause] must be true as well,
  /// otherwise this will not do anything, because when foreground service is active,
  /// it forces notification to be ongoing.
  final bool androidNotificationOngoing;

  /// Whether the Android service should switch to a lower priority state when
  /// playback is paused allowing the user to swipe away the notification. Note
  /// that while in this lower priority state, the operating system will also be
  /// able to kill your service at any time to reclaim resources.
  final bool androidStopForegroundOnPause;

  /// If not null, causes the artwork specified by [MediaItem.artUri] to be
  /// downscaled to this maximum pixel width. If the resolution of your artwork
  /// is particularly high, this can help to conserve memory. If specified,
  /// [artDownscaleHeight] must also be specified.
  final int? artDownscaleWidth;

  /// If not null, causes the artwork specified by [MediaItem.artUri] to be
  /// downscaled to this maximum pixel height. If the resolution of your artwork
  /// is particularly high, this can help to conserve memory. If specified,
  /// [artDownscaleWidth] must also be specified.
  final int? artDownscaleHeight;

  /// The interval to be used in [AudioHandler.fastForward]. This value will
  /// also be used on iOS to render the skip-forward button. This value must be
  /// positive.
  final Duration fastForwardInterval;

  /// The interval to be used in [AudioHandler.rewind]. This value will also be
  /// used on iOS to render the skip-backward button. This value must be
  /// positive.
  final Duration rewindInterval;

  /// By default artworks are loaded only when the item is fed into [AudioHandler.mediaItem].
  ///
  /// If set to `true`, artworks for items start loading as soon as they are added to
  /// [AudioHandler.queue].
  final bool preloadArtwork;

  /// Extras to report on Android in response to an `onGetRoot` request.
  final Map<String, dynamic>? androidBrowsableRootExtras;

  /// Creates a configuration object.
  const AudioServiceConfig({
    this.androidResumeOnClick = true,
    this.androidNotificationChannelId,
    this.androidNotificationChannelName = 'Notifications',
    this.androidNotificationChannelDescription,
    this.notificationColor,
    this.androidNotificationIcon = 'mipmap/ic_launcher',
    this.androidShowNotificationBadge = false,
    this.androidNotificationClickStartsActivity = true,
    this.androidNotificationOngoing = false,
    this.androidStopForegroundOnPause = true,
    this.artDownscaleWidth,
    this.artDownscaleHeight,
    this.fastForwardInterval = const Duration(seconds: 10),
    this.rewindInterval = const Duration(seconds: 10),
    this.preloadArtwork = false,
    this.androidBrowsableRootExtras,
  })  : assert((artDownscaleWidth != null) == (artDownscaleHeight != null)),
        assert(
          !androidNotificationOngoing || androidStopForegroundOnPause,
          'The androidNotificationOngoing will make no effect with androidStopForegroundOnPause set to false',
        );

  AudioServiceConfigMessage _toMessage() => AudioServiceConfigMessage(
        androidResumeOnClick: androidResumeOnClick,
        androidNotificationChannelId: androidNotificationChannelId,
        androidNotificationChannelName: androidNotificationChannelName,
        androidNotificationChannelDescription:
            androidNotificationChannelDescription,
        notificationColor: notificationColor,
        androidNotificationIcon: androidNotificationIcon,
        androidShowNotificationBadge: androidShowNotificationBadge,
        androidNotificationClickStartsActivity:
            androidNotificationClickStartsActivity,
        androidNotificationOngoing: androidNotificationOngoing,
        androidStopForegroundOnPause: androidStopForegroundOnPause,
        artDownscaleWidth: artDownscaleWidth,
        artDownscaleHeight: artDownscaleHeight,
        fastForwardInterval: fastForwardInterval,
        rewindInterval: rewindInterval,
        preloadArtwork: preloadArtwork,
        androidBrowsableRootExtras: androidBrowsableRootExtras,
      );

  @override
  String toString() => '${_toMessage().toMap()}';
}

/// Key/value codes for use in [MediaItem.extras] and
/// [AudioServiceConfig.androidBrowsableRootExtras] to influence how Android
/// Auto will style browsable and playable media items.
class AndroidContentStyle {
  /// Set this key to `true` in [AudioServiceConfig.androidBrowsableRootExtras]
  /// to declare that content style is supported.
  static const supportedKey = 'android.media.browse.CONTENT_STYLE_SUPPORTED';

  /// The key in [MediaItem.extras] and
  /// [AudioServiceConfig.androidBrowsableRootExtras] to configure the content
  /// style for playable items. The value can be any of the `*ItemHintValue`
  /// constants defined in this class.
  static const playableHintKey =
      'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';

  /// The key in [MediaItem.extras] and
  /// [AudioServiceConfig.androidBrowsableRootExtras] to configure the content
  /// style for browsable items. The value can be any of the `*ItemHintValue`
  /// constants defined in this class.
  static const browsableHintKey =
      'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';

  /// Specifies that items should be presented as lists.
  static const listItemHintValue = 1;

  /// Specifies that items should be presented as grids.
  static const gridItemHintValue = 2;

  /// Specifies that items should be presented as lists with vector icons.
  static const categoryListItemHintValue = 3;

  /// Specifies that items should be presented as grids with vector icons.
  static const categoryGridItemHintValue = 4;
}

/// (Maybe) temporary.
extension AudioServiceValueStream<T> on ValueStream<T> {
  /// Returns `this`.
  @Deprecated('Use "this" instead. Will be removed before the release')
  ValueStream<T> get stream => this;
}

extension _MediaItemMessageExtension on MediaItemMessage {
  MediaItem toPlugin() => MediaItem(
        id: id,
        album: album,
        title: title,
        artist: artist,
        genre: genre,
        duration: duration,
        artUri: artUri,
        playable: playable,
        displayTitle: displayTitle,
        displaySubtitle: displaySubtitle,
        displayDescription: displayDescription,
        rating: rating?.toPlugin(),
        isLive: isLive,
        extras: extras,
      );
}

extension _RatingMessageExtension on RatingMessage {
  Rating toPlugin() => Rating._(RatingStyle.values[type.index], value);
}

extension _AndroidVolumeDirectionMessageExtension
    on AndroidVolumeDirectionMessage {
  AndroidVolumeDirection toPlugin() => AndroidVolumeDirection.values[index]!;
}

extension _MediaButtonMessageExtension on MediaButtonMessage {
  MediaButton toPlugin() => MediaButton.values[index];
}

/// An enum of volume direction controls on Android.
class AndroidVolumeDirection {
  /// Lower the ringer volume.
  static final lower = AndroidVolumeDirection._(-1);

  /// Keep the previous ringer volume.
  static final same = AndroidVolumeDirection._(0);

  /// Raise the ringer volume.
  static final raise = AndroidVolumeDirection._(1);

  /// A map of indices to values.
  static final values = <int, AndroidVolumeDirection>{
    -1: lower,
    0: same,
    1: raise,
  };

  /// The index for this enum value.
  final int index;

  AndroidVolumeDirection._(this.index);

  @override
  String toString() => '$index';
}

/// An enumeration of different volume control types on Android.
enum AndroidVolumeControlType {
  /// The volume cannot be changed.
  fixed,

  /// The volume can be adjusted relatively.
  relative,

  /// The volume can be set using an absolute value.
  absolute,
}

/// Information about volume control for either local or remote playback
/// depending on the subclass.
abstract class AndroidPlaybackInfo {
  AndroidPlaybackInfoMessage _toMessage();

  @override
  String toString() => '${_toMessage().toMap()}';
}

/// Playback information for remote volume handling.
class RemoteAndroidPlaybackInfo extends AndroidPlaybackInfo {
  //final AndroidAudioAttributes audioAttributes;

  /// The type of volume control supported by the session.
  final AndroidVolumeControlType volumeControlType;

  /// The maximum volume supported.
  final int maxVolume;

  /// The current volume.
  final int volume;

  // ignore: public_member_api_docs
  RemoteAndroidPlaybackInfo({
    required this.volumeControlType,
    required this.maxVolume,
    required this.volume,
  });

  /// Creates a copy of this object with fields replaced.
  AndroidPlaybackInfo copyWith({
    AndroidVolumeControlType? volumeControlType,
    int? maxVolume,
    int? volume,
  }) =>
      RemoteAndroidPlaybackInfo(
        volumeControlType: volumeControlType ?? this.volumeControlType,
        maxVolume: maxVolume ?? this.maxVolume,
        volume: volume ?? this.volume,
      );

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is RemoteAndroidPlaybackInfo &&
      volumeControlType == other.volumeControlType &&
      maxVolume == other.maxVolume &&
      volume == other.volume;

  @override
  int get hashCode => Object.hash(volumeControlType, maxVolume, volume);

  @override
  RemoteAndroidPlaybackInfoMessage _toMessage() =>
      RemoteAndroidPlaybackInfoMessage(
        volumeControlType:
            AndroidVolumeControlTypeMessage.values[volumeControlType.index],
        maxVolume: maxVolume,
        volume: volume,
      );
}

/// Playback information for local volume handling.
class LocalAndroidPlaybackInfo extends AndroidPlaybackInfo {
  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType;

  @override
  int get hashCode => 0;

  @override
  LocalAndroidPlaybackInfoMessage _toMessage() =>
      const LocalAndroidPlaybackInfoMessage();
}

/// This class is deprecated. Use the stream subjects in [BaseAudioHandler]
/// instead.
@Deprecated("Use stream subjects in BaseAudioHandler instead.")
class AudioServiceBackground {
  static SwitchAudioHandler get _handler =>
      AudioService._handler as SwitchAudioHandler;
  static Completer<BackgroundAudioTask>? _startCompleter;

  /// Deprecated. Use [AudioHandler.playbackState] instead.
  @Deprecated("Use AudioHandler.playbackState instead.")
  static PlaybackState get state =>
      _handler.playbackState.nvalue ?? PlaybackState();

  /// Deprecated. Use [AudioHandler.queue] instead.
  @Deprecated("Use AudioHandler.queue instead.")
  static List<MediaItem>? get queue => _handler.queue.nvalue;

  /// Deprecated. Use [AudioService.init] instead.
  @Deprecated("Use AudioService.init instead")
  static Future<void> run(BackgroundAudioTask Function() taskBuilder) async {
    final task = taskBuilder();
    _startCompleter!.complete(task);
  }

  /// Deprecated. Use [BaseAudioHandler.playbackState] instead.
  @Deprecated("Use BaseAudioHandler.playbackState instead.")
  static Future<void> setState({
    List<MediaControl>? controls,
    List<MediaAction>? systemActions,
    AudioProcessingState? processingState,
    bool? playing,
    Duration? position,
    Duration? bufferedPosition,
    double? speed,
    DateTime? updateTime,
    List<int>? androidCompactActions,
    AudioServiceRepeatMode? repeatMode,
    AudioServiceShuffleMode? shuffleMode,
  }) async {
    final oldState = _handler.playbackState.nvalue!;
    _taskHandler.playbackState.add(PlaybackState(
      controls: controls ?? oldState.controls,
      systemActions: systemActions?.toSet() ?? oldState.systemActions,
      processingState: processingState ?? oldState.processingState,
      playing: playing ?? oldState.playing,
      updatePosition: position ?? oldState.position,
      bufferedPosition: bufferedPosition ?? oldState.bufferedPosition,
      speed: speed ?? oldState.speed,
      androidCompactActionIndices:
          androidCompactActions ?? oldState.androidCompactActionIndices,
      repeatMode: repeatMode ?? oldState.repeatMode,
      shuffleMode: shuffleMode ?? oldState.shuffleMode,
    ));
  }

  static _BackgroundAudioHandler get _taskHandler =>
      _handler.inner as _BackgroundAudioHandler;

  /// Deprecated. Use [BaseAudioHandler.queue] instead.
  @Deprecated("Use BaseAudioHandler.queue instead.")
  static Future<void> setQueue(List<MediaItem> queue,
      {bool preloadArtwork = false}) async {
    if (preloadArtwork) {
      // ignore: avoid_print
      print(
        'WARNING: preloadArtwork is not enabled! '
        'This is deprecated and must be set via AudioService.init()',
      );
    }
    _taskHandler.queue.add(queue);
  }

  /// Deprecated. Use [BaseAudioHandler.mediaItem] instead.
  @Deprecated("Use BaseAudioHandler.mediaItem instead.")
  static Future<void> setMediaItem(MediaItem mediaItem) async {
    _taskHandler.mediaItem.add(mediaItem);
  }

  /// Deprecated. Use [AudioHandler.subscribeToChildren] instead.
  @Deprecated("Use AudioHandler.subscribeToChildren instead.")
  static Future<void> notifyChildrenChanged(
      [String parentMediaId = AudioService.browsableRootId]) async {
    await _platform.notifyChildrenChanged(
        NotifyChildrenChangedRequest(parentMediaId: parentMediaId));
  }

  /// Deprecated. Use [AudioService.androidForceEnableMediaButtons] instead.
  @Deprecated("Use AudioService.androidForceEnableMediaButtons instead.")
  static Future<void> androidForceEnableMediaButtons() async {
    await AudioService.androidForceEnableMediaButtons();
  }

  /// Deprecated. Use [BaseAudioHandler.customEvent] instead.
  @Deprecated("Use BaseAudioHandler.customEvent instead.")
  static void sendCustomEvent(dynamic event) {
    _taskHandler.customEvent.add(event);
  }
}

class _HandlerCallbacks extends AudioHandlerCallbacks {
  final _handlerCompleter = Completer<AudioHandler>();

  Future<AudioHandler> get handlerFuture => _handlerCompleter.future;

  void setHandler(AudioHandler handler) => _handlerCompleter.complete(handler);

  @override
  Future<void> addQueueItem(AddQueueItemRequest request) async =>
      (await handlerFuture).addQueueItem(request.mediaItem.toPlugin());

  @override
  Future<void> androidAdjustRemoteVolume(
          AndroidAdjustRemoteVolumeRequest request) async =>
      (await handlerFuture)
          .androidAdjustRemoteVolume(request.direction.toPlugin());

  @override
  Future<void> androidSetRemoteVolume(
          AndroidSetRemoteVolumeRequest request) async =>
      (await handlerFuture).androidSetRemoteVolume(request.volumeIndex);

  @override
  Future<void> click(ClickRequest request) async {
    return (await handlerFuture).click(request.button.toPlugin());
  }

  @override
  Future<dynamic> customAction(CustomActionRequest request) async =>
      (await handlerFuture).customAction(request.name, request.extras);

  @override
  Future<void> fastForward(FastForwardRequest request) async =>
      (await handlerFuture).fastForward();

  @override
  Future<GetChildrenResponse> getChildren(GetChildrenRequest request) async {
    final mediaItems =
        await _onLoadChildren(request.parentMediaId, request.options);
    return GetChildrenResponse(
        children: mediaItems.map((item) => item._toMessage()).toList());
  }

  @override
  Future<GetMediaItemResponse> getMediaItem(GetMediaItemRequest request) async {
    return GetMediaItemResponse(
        mediaItem: (await (await handlerFuture).getMediaItem(request.mediaId))
            ?._toMessage());
  }

  @override
  Future<void> insertQueueItem(InsertQueueItemRequest request) async =>
      (await handlerFuture)
          .insertQueueItem(request.index, request.mediaItem.toPlugin());

  @override
  Future<void> onNotificationClicked(
      OnNotificationClickedRequest request) async {
    AudioService._notificationClicked.add(request.clicked);
  }

  @override
  Future<void> onNotificationDeleted(
          OnNotificationDeletedRequest request) async =>
      (await handlerFuture).onNotificationDeleted();

  @override
  Future<void> onTaskRemoved(OnTaskRemovedRequest request) async =>
      (await handlerFuture).onTaskRemoved();

  @override
  Future<void> pause(PauseRequest request) async =>
      (await handlerFuture).pause();

  @override
  Future<void> play(PlayRequest request) async => (await handlerFuture).play();

  @override
  Future<void> playFromMediaId(PlayFromMediaIdRequest request) async =>
      (await handlerFuture).playFromMediaId(request.mediaId, request.extras);

  @override
  Future<void> playFromSearch(PlayFromSearchRequest request) async =>
      (await handlerFuture).playFromSearch(request.query, request.extras);

  @override
  Future<void> playFromUri(PlayFromUriRequest request) async =>
      (await handlerFuture).playFromUri(request.uri, request.extras);

  @override
  Future<void> playMediaItem(PlayMediaItemRequest request) async =>
      (await handlerFuture).playMediaItem(request.mediaItem.toPlugin());

  @override
  Future<void> prepare(PrepareRequest request) async =>
      (await handlerFuture).prepare();

  @override
  Future<void> prepareFromMediaId(PrepareFromMediaIdRequest request) async =>
      (await handlerFuture).prepareFromMediaId(request.mediaId, request.extras);

  @override
  Future<void> prepareFromSearch(PrepareFromSearchRequest request) async =>
      (await handlerFuture).prepareFromSearch(request.query, request.extras);

  @override
  Future<void> prepareFromUri(PrepareFromUriRequest request) async =>
      (await handlerFuture).prepareFromUri(request.uri, request.extras);

  @override
  Future<void> removeQueueItem(RemoveQueueItemRequest request) async =>
      (await handlerFuture).removeQueueItem(request.mediaItem.toPlugin());

  @override
  Future<void> removeQueueItemAt(RemoveQueueItemAtRequest request) async =>
      (await handlerFuture).removeQueueItemAt(request.index);

  @override
  Future<void> rewind(RewindRequest request) async =>
      (await handlerFuture).rewind();

  @override
  Future<SearchResponse> search(SearchRequest request) async => SearchResponse(
      mediaItems:
          (await (await handlerFuture).search(request.query, request.extras))
              .map((item) => item._toMessage())
              .toList());

  @override
  Future<void> seek(SeekRequest request) async =>
      (await handlerFuture).seek(request.position);

  @override
  Future<void> seekBackward(SeekBackwardRequest request) async =>
      (await handlerFuture).seekBackward(request.begin);

  @override
  Future<void> seekForward(SeekForwardRequest request) async =>
      (await handlerFuture).seekForward(request.begin);

  @override
  Future<void> setCaptioningEnabled(
          SetCaptioningEnabledRequest request) async =>
      (await handlerFuture).setCaptioningEnabled(request.enabled);

  @override
  Future<void> setRating(SetRatingRequest request) async =>
      (await handlerFuture)
          .setRating(request.rating.toPlugin(), request.extras);

  @override
  Future<void> setRepeatMode(SetRepeatModeRequest request) async =>
      (await handlerFuture).setRepeatMode(
          AudioServiceRepeatMode.values[request.repeatMode.index]);

  @override
  Future<void> setShuffleMode(SetShuffleModeRequest request) async =>
      (await handlerFuture).setShuffleMode(
          AudioServiceShuffleMode.values[request.shuffleMode.index]);

  @override
  Future<void> setSpeed(SetSpeedRequest request) async =>
      (await handlerFuture).setSpeed(request.speed);

  @override
  Future<void> skipToNext(SkipToNextRequest request) async =>
      (await handlerFuture).skipToNext();

  @override
  Future<void> skipToPrevious(SkipToPreviousRequest request) async =>
      (await handlerFuture).skipToPrevious();

  @override
  Future<void> skipToQueueItem(SkipToQueueItemRequest request) async =>
      (await handlerFuture).skipToQueueItem(request.index);

  @override
  Future<void> stop(StopRequest request) async => (await handlerFuture).stop();

  final Map<String, ValueStream<Map<String, dynamic>>> _childrenSubscriptions =
      {};

  Future<List<MediaItem>> _onLoadChildren(
      String parentMediaId, Map<String, dynamic>? options) async {
    var childrenSubscription = _childrenSubscriptions[parentMediaId];
    if (childrenSubscription == null) {
      childrenSubscription = _childrenSubscriptions[parentMediaId] =
          (await handlerFuture).subscribeToChildren(parentMediaId);
      childrenSubscription.listen((Map<String, dynamic>? options) {
        // Notify clients that the children of [parentMediaId] have changed.
        _platform.notifyChildrenChanged(NotifyChildrenChangedRequest(
          parentMediaId: parentMediaId,
          options: options,
        ));
      });
    }
    return await (await handlerFuture).getChildren(parentMediaId, options);
  }
}

/// Backwards compatible extensions on rxdart's ValueStream
extension _ValueStreamExtension<T> on ValueStream<T> {
  /// Backwards compatible version of valueOrNull.
  T? get nvalue => hasValue ? value : null;
}

/// This widget is no longer required and has been deprecated.
@Deprecated("This widget is no longer required and can be safely removed.")
class AudioServiceWidget extends StatelessWidget {
  /// Deprecated.
  final Widget child;

  /// Deprecated.
  const AudioServiceWidget({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
