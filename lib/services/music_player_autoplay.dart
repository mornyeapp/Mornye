part of 'music_player_service.dart';

typedef AutoplayLibraryLoader =
    Future<List<PlayableMedia>> Function(PlayableMedia seed);

Future<void> resetAutoplayLearning({MusicPlayerRuntime? runtime}) async {
  final target = runtime ?? musicPlayerRuntime;
  await target.personalization.reset();
  await target.taste.reset();
  final handler = target.handler;
  if (handler == null || handler.isDisposed) return;
  handler._configurePersonalization();
  handler._autoplay.updateMode();
}

AutoplayLearningTrack _learningTrack(PlayableMedia media) =>
    AutoplayLearningTrack(
      source: media.source,
      title: media.title,
      artist: media.artist,
      album: media.album,
      genre: media.genre ?? '',
      duration: media.duration,
    );

/// Bounded database pages keep recommendation work independent of Library
/// size. Both downloaded tracks and enabled scanned sources are local files.
/// A few songs by the seed's artist join small pages spread across the
/// Library: one large page in date-added order holds whole albums, so it
/// offered mostly one artist.
Future<List<PlayableMedia>> _loadAutoplayLibrary(
  PlayableMedia seed,
  MusicPlayerRuntime runtime,
) async {
  const pages = 8, pageSize = 48;
  final database = runtime.dependencies.libraryDatabase;
  final includeLocal = runtime.settings.localLibraryEnabled;
  final query = QueueLibraryDbQuery(includeLocal: includeLocal);
  final count = (await database.getQueueCounts(query)).allTrackCount;
  final random = Random();
  final whole = count <= pages * pageSize;
  final rows = [
    if (seed.artist.trim().isNotEmpty)
      ...await database.getQueueTrackPage(
        QueueLibraryDbQuery(
          includeLocal: includeLocal,
          searchQuery: seed.artist,
          limit: 32,
        ),
      ),
    for (var page = 0; page < (whole ? 1 : pages); page++)
      ...await database.getQueueTrackPage(
        QueueLibraryDbQuery(
          includeLocal: includeLocal,
          // One page from each eighth of the Library.
          offset: whole
              ? 0
              : min(
                  count - pageSize,
                  count * page ~/ pages + random.nextInt(count ~/ pages),
                ),
          limit: whole ? pages * pageSize : pageSize,
        ),
      ),
  ];
  final result = <PlayableMedia>[];
  final seen = <String>{};
  for (final row in rows) {
    final data = (row['item'] as Map).cast<String, dynamic>();
    if (!seen.add(data['id'] as String)) continue;
    final source = data['filePath'] as String? ?? '';
    if (source.isEmpty) continue;
    // Do not interpret remote URLs as streamable Library items.
    if (source.startsWith('http://') || source.startsWith('https://')) continue;
    if (!source.startsWith('content://') && !await File(source).exists()) {
      continue;
    }
    final cover = data['coverPath'] as String? ?? data['coverUrl'] as String?;
    final seconds = readPositiveInt(data['duration']);
    result.add(
      PlayableMedia(
        id: data['id'] as String,
        source: source,
        title: data['trackName'] as String? ?? '',
        artist: data['artistName'] as String? ?? '',
        album: data['albumName'] as String? ?? '',
        genre: data['genre'] as String?,
        artUri: cover == null || cover.isEmpty
            ? null
            : cover.startsWith('/')
            ? Uri.file(cover).toString()
            : cover,
        duration: seconds == null ? null : Duration(seconds: seconds),
        bitDepth: readPositiveInt(data['bitDepth']),
        sampleRate: readPositiveInt(data['sampleRate']),
        bitrate: readPositiveInt(data['bitrate']),
        format: data['format'] as String?,
      ),
    );
  }
  return result;
}

/// The genres of a tag such as `Pop; Dance/Electronic`, normalized.
Set<String> _autoplayGenres(String? value) => {
  for (final part in (value ?? '').split(RegExp(r'[,;/|&]')))
    if (normalizeLookupText(part) case final genre when genre.isNotEmpty) genre,
};

/// Songs that play between two by one artist, while other artists fit.
const _autoplayArtistGap = 4;

/// The latest songs, newest weighing most, that set the session's genres.
const _autoplaySessionWindow = 12;

/// Rank once per refill, so the visible queue is the actual playback order.
/// Songs score by how well their genres fit the listening session (the
/// seed, the songs before it and the queued ones, newest weighing most),
/// with optional local learning on top. Artists heard or queued lately lose
/// priority, an artist does not return within [_autoplayArtistGap] songs or
/// twice in one refill while others fit, and songs of a picked album lose
/// priority, so a favorite artist cannot take over the queue. [signals] add
/// what metadata cannot tell, such as how well a song follows the one before.
List<PlayableMedia> selectAutoplayTracks({
  required PlayableMedia seed,
  required List<PlayableMedia> candidates,
  required List<PlayableMedia> upcoming,
  required List<PlayableMedia> recent,
  required Set<String> dismissedSources,
  required Random random,
  int limit = 6,
  double Function(PlayableMedia)? preferenceAdjustment,
  List<AutoplaySignal> signals = const [],
}) {
  String normalized(String? value) => normalizeLookupText(value);
  String songKey(PlayableMedia item) =>
      '${normalized(item.artist)}|${normalized(item.title)}';
  final sources = {
    seed.source,
    ...upcoming.map((item) => item.source),
    ...dismissedSources,
  };
  final songs = {songKey(seed), ...upcoming.map(songKey)};
  final seedArtist = normalized(seed.artist);
  final seedAlbum = normalized(seed.album);
  final recentSources = <String, int>{};
  final recentSongs = <String, int>{};
  for (var i = 0; i < recent.length; i++) {
    recentSources[recent[i].source] = i;
    recentSongs[songKey(recent[i])] = i;
  }

  // The session in playback order: history, the seed (often its last entry
  // already), then the queued songs the picks follow.
  final session = <PlayableMedia>[];
  for (final item in [...recent, seed, ...upcoming]) {
    if (session.isEmpty || session.last.source != item.source) {
      session.add(item);
    }
  }
  final genreWeights = <String, double>{};
  var genreTotal = 0.0;
  // Songs back from the session's end, and plays, of each artist.
  final artistDistance = <String, int>{};
  final artistPlays = <String, int>{};
  for (var back = 0; back < session.length; back++) {
    final item = session[session.length - 1 - back];
    final artist = normalized(item.artist);
    if (artist.isNotEmpty) {
      artistDistance.putIfAbsent(artist, () => back);
      artistPlays[artist] = (artistPlays[artist] ?? 0) + 1;
    }
    if (back >= _autoplaySessionWindow) continue;
    final genres = _autoplayGenres(item.genre);
    if (genres.isEmpty) continue;
    final weight = pow(0.75, back).toDouble();
    genreTotal += weight;
    for (final genre in genres) {
      genreWeights[genre] = (genreWeights[genre] ?? 0) + weight / genres.length;
    }
  }

  final eligible = <PlayableMedia>[];
  for (final item in candidates) {
    if (item.source.trim().isEmpty ||
        item.source.startsWith('http://') ||
        item.source.startsWith('https://') ||
        !sources.add(item.source) ||
        !songs.add(songKey(item))) {
      continue;
    }
    eligible.add(item);
  }
  for (final signal in signals) {
    signal.prepare(session, eligible);
  }

  final scored =
      <({PlayableMedia item, double score, String artist, String album})>[];
  for (final item in eligible) {
    final key = songKey(item);
    final artist = normalized(item.artist);
    final album = normalized(item.album);
    var score = random.nextDouble() * 1.5;
    if (genreTotal > 0) {
      var fit = 0.0;
      for (final genre in _autoplayGenres(item.genre)) {
        fit += genreWeights[genre] ?? 0;
      }
      score += 6 * min(1.0, fit / genreTotal);
    }
    if (seedArtist.isNotEmpty && seedArtist == artist) score += 2;
    if (seedAlbum.isNotEmpty && seedAlbum == album) score += 1;
    if (preferenceAdjustment != null) score += preferenceAdjustment(item);
    for (final signal in signals) {
      score += signal.score(item);
    }
    // Match the latest source OR normalized song occurrence without walking
    // the entire listening history again for every candidate.
    final played = max(
      recentSources[item.source] ?? -1,
      recentSongs[key] ?? -1,
    );
    if (played >= 0) {
      // Heard already: recency alone orders these.
      score -= 20 + played.toDouble();
    } else if (artist.isNotEmpty) {
      final distance = artistDistance[artist];
      if (distance == null) {
        // An artist the session has not reached yet.
        score += 1;
      } else {
        score -= 6 * pow(0.7, distance) + 1.5 * min(4, artistPlays[artist]!);
      }
    }
    scored.add((item: item, score: score, artist: artist, album: album));
  }

  final selected = <PlayableMedia>[];
  // The artists that played last, newest at the end.
  final latest = [for (final item in session) normalized(item.artist)];
  final picked = <String>{};
  // The song the next pick follows.
  PlayableMedia? before = session.isEmpty ? null : session.last;
  while (selected.length < limit && scored.isNotEmpty) {
    final previous = latest.isEmpty ? '' : latest.last;
    final spaced = {
      ...latest.skip(max(0, latest.length - (_autoplayArtistGap - 1))),
      ...picked,
    };
    final follows = before;
    final totals = [for (final entry in scored) entry.score];
    if (follows != null) {
      for (final signal in signals) {
        for (var i = 0; i < scored.length; i++) {
          totals[i] += signal.follow(follows, scored[i].item);
        }
      }
    }
    int? best;
    // Artists spaced apart first, then only not twice in a row, then the
    // best of what is left.
    for (final rule in [
      spaced,
      {previous},
      const <String>{},
    ]) {
      for (var i = 0; i < scored.length; i++) {
        final entry = scored[i];
        if (entry.artist.isNotEmpty && rule.contains(entry.artist)) continue;
        if (best == null || totals[i] > totals[best]) best = i;
      }
      if (best != null) break;
    }
    final next = scored.removeAt(best!);
    selected.add(next.item);
    before = next.item;
    latest.add(next.artist);
    if (next.artist.isNotEmpty) picked.add(next.artist);
    if (next.album.isEmpty) continue;
    // Songs of one album, such as a compilation's, stay apart too.
    for (var i = 0; i < scored.length; i++) {
      final entry = scored[i];
      if (entry.album == next.album) {
        scored[i] = (
          item: entry.item,
          score: entry.score - 3,
          artist: entry.artist,
          album: entry.album,
        );
      }
    }
  }
  return selected;
}

class _MusicAutoplay {
  _MusicAutoplay(this.handler, this.loadLibrary);

  final MusicPlayerHandler handler;
  final AutoplayLibraryLoader loadLibrary;
  final Set<String> _dismissed = {};
  Future<void>? _pending;
  int _generation = 0;
  (String, int)? _attempt;

  bool get enabled =>
      handler._settings.autoplay &&
      handler._repeatMode == AudioServiceRepeatMode.none;

  int get manualInsertIndex {
    for (var i = handler._index + 1; i < handler._media.length; i++) {
      if (handler._media[i].autoplay) return i;
    }
    return handler._media.length;
  }

  void reset() {
    _generation++;
    _pending = null;
    _attempt = null;
    _dismissed.clear();
  }

  void dismiss(PlayableMedia item) => _dismissed.add(item.source);

  void updateMode() {
    reset();
    // Never remove the song already playing or a manually queued song.
    // Refresh suggestions when the enabled Library sources change too.
    for (var i = handler._media.length - 1; i > handler._index; i--) {
      if (handler._media[i].autoplay) {
        handler.removeQueuedItem(handler._queueItems[i]);
      }
    }
    _dismissed.clear();
    if (enabled) unawaited(fill());
  }

  Future<void> fill() async {
    if (!enabled ||
        handler._disposed ||
        handler._index < 0 ||
        handler._index >= handler._media.length) {
      return;
    }
    if (handler._media.length - handler._index - 1 >= 3) return;
    final pending = _pending;
    if (pending != null) return pending;
    final seed = handler._media[handler._index];
    final attempt = (seed.source, handler._sessionQueueRevision);
    if (_attempt == attempt) return;
    _attempt = attempt;
    final operation = _fill(seed, _generation);
    _pending = operation;
    try {
      await operation;
    } finally {
      if (identical(_pending, operation)) _pending = null;
    }
  }

  /// What the refill knows beyond metadata, loaded beside its candidates.
  Future<List<AutoplaySignal>> _loadSignals(
    List<PlayableMedia> candidates,
  ) async {
    // The songs ranking takes as the session: history, then the current
    // song and the queued ones.
    final media = handler._media;
    final session = [
      for (final i in [...handler._playHistory, handler._index])
        if (i >= 0 && i < media.length) media[i],
      if (handler._index >= 0) ...media.skip(handler._index + 1),
    ];
    final runtime = handler._runtime;
    final (sound, taste) = await (
      // Only the latest songs set the session's sound.
      runtime.songAnalysis.loadSignal(
        session: session.skip(max(0, session.length - 16)),
        candidates: candidates,
      ),
      // What the listener plays with the session's songs, while learning
      // is on.
      runtime.personalization.enabled
          ? runtime.taste.signal(session, candidates)
          : Future<AutoplaySignal?>.value(),
    ).wait;
    return [?sound, ?taste];
  }

  Future<void> _fill(PlayableMedia seed, int generation) async {
    try {
      final candidates = await loadLibrary(seed);
      final signals = await _loadSignals(candidates);
      if (!enabled ||
          handler._disposed ||
          generation != _generation ||
          handler._index < 0) {
        return;
      }
      // Re-check the live queue after I/O: quick skips and manual additions
      // must not duplicate entries or replace the user's selected track.
      final current = handler._media[handler._index];
      final upcoming = handler._media.skip(handler._index + 1).toList();
      if (upcoming.length >= 3) return;
      final recent = handler._playHistory
          .where((i) => i >= 0 && i < handler._media.length)
          .map((i) => handler._media[i])
          .toList();
      final model = handler._runtime.personalization.rankingSnapshot;
      final revision = handler._sessionQueueRevision;
      List<PlayableMedia> ordinaryRanking() => selectAutoplayTracks(
        seed: current,
        candidates: candidates,
        upcoming: upcoming,
        recent: recent,
        dismissedSources: _dismissed,
        random: handler._random,
        limit: 6 - upcoming.length,
      );
      List<PlayableMedia> selected;
      if (model == null && signals.isEmpty) {
        selected = ordinaryRanking();
      } else {
        try {
          selected = await compute(
            _rankPersonalizedAutoplay,
            _AutoplayRanking(
              seed: current,
              candidates: candidates,
              upcoming: upcoming,
              recent: recent,
              dismissed: Set<String>.of(_dismissed),
              model: model,
              signals: signals,
              randomSeed: handler._random.nextInt(1 << 31),
              at: DateTime.now(),
              limit: 6 - upcoming.length,
            ),
            debugLabel: 'autoplay-ranking',
          );
        } catch (error) {
          _log.w(
            'Personalized ranking unavailable; using ordinary autoplay: $error',
          );
          selected = ordinaryRanking();
        }
      }
      // The worker must not publish suggestions for an obsolete queue/seed.
      if (!enabled ||
          handler._disposed ||
          generation != _generation ||
          revision != handler._sessionQueueRevision ||
          handler._index < 0 ||
          handler._index >= handler._media.length ||
          handler._media[handler._index].source != current.source) {
        return;
      }
      if (selected.isEmpty) return;
      final additions = [
        for (final item in selected)
          PlayableMedia.fromJson({...item.toJson(), 'autoplay': true})!,
      ];
      final queueItems = additions.map(handler._toMediaItem).toList();
      handler._media.addAll(additions);
      handler._queueItems.addAll(queueItems);
      handler._originalQueueOrder?.addAll(queueItems);
      handler._markSessionQueueChanged();
      handler.queue.add(List.unmodifiable(handler._queueItems));
      unawaited(
        handler._persistSession(position: handler.playbackState.value.position),
      );
    } catch (error) {
      _log.w('Could not prepare Library Autoplay: $error');
    }
  }
}

/// Metadata, a frozen 64 KiB model and plain-data signals only, never the
/// player or runtime.
class _AutoplayRanking {
  const _AutoplayRanking({
    required this.seed,
    required this.candidates,
    required this.upcoming,
    required this.recent,
    required this.dismissed,
    required this.model,
    required this.signals,
    required this.randomSeed,
    required this.at,
    required this.limit,
  });

  final PlayableMedia seed;
  final List<PlayableMedia> candidates, upcoming, recent;
  final Set<String> dismissed;
  final AutoplayPreferenceModel? model;
  final List<AutoplaySignal> signals;
  final int randomSeed;
  final DateTime at;
  final int limit;
}

List<PlayableMedia> _rankPersonalizedAutoplay(_AutoplayRanking input) {
  final model = input.model;
  final learningSeed = _learningTrack(input.seed);
  final random = Random(input.randomSeed);
  final exploration = model?.explore(Random(random.nextInt(1 << 31)));
  return selectAutoplayTracks(
    seed: input.seed,
    candidates: input.candidates,
    upcoming: input.upcoming,
    recent: input.recent,
    dismissedSources: input.dismissed,
    random: random,
    limit: input.limit,
    preferenceAdjustment: model == null
        ? null
        : (track) {
            final learning = _learningTrack(track);
            return model.rankAdjustment(
                  learning,
                  previous: learningSeed,
                  at: input.at,
                ) +
                exploration!.adjustment(learning);
          },
    signals: input.signals,
  );
}
