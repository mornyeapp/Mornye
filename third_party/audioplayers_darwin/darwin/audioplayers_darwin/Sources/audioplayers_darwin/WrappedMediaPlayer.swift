import AVKit

private let defaultPlaybackRate: Double = 1.0

private let defaultVolume: Double = 1.0

private let defaultReleaseMode: ReleaseMode = ReleaseMode.release

typealias Completer = () -> Void

typealias CompleterError = (Error?) -> Void

enum ReleaseMode: String {
  case stop
  case release
  case loop
}

@MainActor class WrappedMediaPlayer {
  /// The URL fragment the app adds to a file still arriving
  /// (`darwinArrivingUrl` in lib/services/music_playback_deck.dart).
  static let arrivingFragment = "mornye-arriving"

  private(set) var eventHandler: AudioPlayersStreamHandler
  private(set) var isPlaying: Bool
  var releaseMode: ReleaseMode

  /// Started the moment this player's item ends, without a gap. Cleared
  /// with the item.
  weak var next: WrappedMediaPlayer? {
    didSet { next?.prerollForStart() }
  }

  private var reference: AudioplayersDarwinPlugin
  private var player: AVPlayer
  private var equalizer = EqualizerAudioTap()
  private var equalizerConfiguration: [String: Any] = [:]
  /// The current item carries `equalizer`'s tap. It stays attached (and
  /// passes audio through) when neither the equalizer nor a pitch shift
  /// needs it any more; the next item gets one only when needed.
  private var tapAttached = false
  private var tapAttaching: (item: AVPlayerItem, task: Task<Void, Error>)?

  func setEqualizer(_ configuration: [String: Any]) async throws {
    equalizerConfiguration = configuration
    equalizer.dsp.configure(configuration)
    if configuration["enabled"] as? Bool == true {
      try await attachTap(feature: "Equalizer")
    }
  }

  /// Pitch shift in semitones (inside the tap, duration kept), and whether
  /// the pitch follows the playback rate (varispeed) or stays (spectral).
  /// Applies to the current item and every new one.
  private var semitones = 0.0
  private var pitchFollowsRate = false

  func setPitch(semitones: Double, followsRate: Bool) async throws {
    self.semitones = semitones
    pitchFollowsRate = followsRate
    equalizer.pitch.setSemitones(semitones)
    updateTimePitch()
    if semitones != 0 {
      try await attachTap(feature: "Pitch shift")
    }
  }

  /// Attaches the tap to the current item once, also when the equalizer and
  /// the pitch shift ask for it at the same time.
  private func attachTap(feature: String) async throws {
    guard !tapAttached, let item = player.currentItem else { return }
    if let pending = tapAttaching, pending.item === item {
      if (try? await pending.task.value) != nil { return }
      // Attach again so the error names this feature.
      guard !tapAttached, player.currentItem === item else { return }
    }
    let processor = equalizer
    let task = Task { @MainActor in
      try await EqualizerAudioTap.attach(to: item, processor: processor, feature: feature)
    }
    tapAttaching = (item, task)
    defer { if tapAttaching?.item === item { tapAttaching = nil } }
    try await task.value
    if player.currentItem === item, equalizer === processor { tapAttached = true }
  }

  /// Both algorithms sound the same at rate 1, and a change rebuilds the
  /// playing item's audio chain (a short stall), so the current item gets a
  /// new algorithm only at a rate that needs it. New items get it at once.
  private func updateTimePitch() {
    guard playbackRate != 1, let item = player.currentItem else { return }
    Self.applyTimePitch(followsRate: pitchFollowsRate, to: item)
  }

  /// Varispeed lets the pitch follow the rate like a record; spectral keeps
  /// it at any rate, with the best quality for music.
  static func applyTimePitch(followsRate: Bool, to item: AVPlayerItem) {
    let algorithm: AVAudioTimePitchAlgorithm = followsRate ? .varispeed : .spectral
    if item.audioTimePitchAlgorithm != algorithm { item.audioTimePitchAlgorithm = algorithm }
  }

  /// Whether the system may spatialize this player's audio: mono, stereo
  /// and multichannel when true, nothing when false. Applies to the current
  /// item and every new one.
  private var spatialAudio = true

  func setSpatialAudio(_ enabled: Bool) {
    spatialAudio = enabled
    if let item = player.currentItem { Self.applySpatialAudio(enabled, to: item) }
  }

  /// Audio-only items otherwise default to multichannel only.
  static func applySpatialAudio(_ enabled: Bool, to item: AVPlayerItem) {
    if #available(iOS 14.0, macOS 11.0, *) {
      item.allowedAudioSpatializationFormats = enabled ? .monoStereoAndMultichannel : []
    }
  }

  private var playbackRate: Double
  private var volume: Double
  private var url: String?

  private var completionObserver: TimeObserver?
  private var playerItemStatusObservation: NSKeyValueObservation?
  private var playerItemStatusContinuation: CheckedContinuation<Void, Error>?

  init(
    reference: AudioplayersDarwinPlugin,
    eventHandler: AudioPlayersStreamHandler,
    player: AVPlayer = AVPlayer.init(),
    playbackRate: Double = defaultPlaybackRate,
    volume: Double = defaultVolume,
    releaseMode: ReleaseMode = defaultReleaseMode,
    url: String? = nil
  ) {
    self.reference = reference
    self.eventHandler = eventHandler
    self.player = player
    // Audio follows the system route (AirPlay audio, like Music). External
    // playback would hand the item to the receiver, which opens a full-screen
    // player on a Mac, bypasses the equalizer tap and stops when closed.
    player.allowsExternalPlayback = false
    self.completionObserver = nil
    self.playerItemStatusObservation = nil

    self.isPlaying = false
    self.playbackRate = playbackRate
    self.volume = volume
    self.releaseMode = releaseMode
    self.url = url
  }

  func setSourceUrl(
    url: String,
    isLocal: Bool,
    mimeType: String? = nil
  ) async throws {
    let playbackStatus = player.currentItem?.status

    if self.url != url || playbackStatus == .failed || playbackStatus == nil {
      reset()
      self.url = url
      let playerItem = try createPlayerItem(url: url, isLocal: isLocal, mimeType: mimeType)
      // An outgoing item's render callbacks must not share filter history
      // or format storage with the next item.
      equalizer = EqualizerAudioTap()
      equalizer.dsp.configure(equalizerConfiguration)
      equalizer.pitch.setSemitones(semitones)
      tapAttached = false
      tapAttaching = nil
      // Need to observe item status immediately after creating:
      try await setUpPlayerItemStatusObservation(playerItem)
      guard player.currentItem === playerItem else { throw CancellationError() }
      // The app sends the shift once; every later source keeps it. The
      // equalizer is attached by the app's setEqualizer after the source.
      if semitones != 0 {
        do {
          try await attachTap(feature: "Pitch shift")
        } catch {
          eventHandler.onLog(message: "Pitch shift unavailable for this source: \(error)")
        }
        guard player.currentItem === playerItem else { throw CancellationError() }
      }
      // Needs to be called after the preparation has completed.
      self.updateDuration()

      self.setUpSoundCompletedObserver(self.player, playerItem)
      self.eventHandler.onPrepared(isPrepared: true)
    } else {
      if playbackStatus == .readyToPlay {
        self.eventHandler.onPrepared(isPrepared: true)
      }
    }
  }

  func getDuration() -> Int? {
    guard let duration = getDurationCMTime() else {
      return nil
    }
    return fromCMTime(time: duration)
  }

  func getCurrentPosition() -> Int? {
    guard let time = getCurrentCMTime() else {
      return nil
    }
    return fromCMTime(time: time)
  }

  func pause() {
    isPlaying = false
    player.pause()
  }

  func resume() {
    isPlaying = true
    configParameters(player: player)
    if #available(iOS 10.0, macOS 10.12, *) {
      player.playImmediately(atRate: Float(playbackRate))
    } else {
      player.play()
    }
    updateDuration()
  }

  /// Fills the render pipeline of a paused, loaded item so a later
  /// [resume] starts at once.
  func prerollForStart() {
    // preroll raises an exception unless the player itself is ready.
    guard !isPlaying, player.rate == 0, player.status == .readyToPlay,
      player.currentItem?.status == .readyToPlay
    else {
      return
    }
    player.preroll(atRate: Float(playbackRate)) { _ in }
  }

  func setVolume(volume: Double) {
    self.volume = volume
    player.volume = Float(volume)
  }

  func setPlaybackRate(playbackRate: Double) {
    self.playbackRate = playbackRate
    // Before the rate, so the item never plays it with the old algorithm.
    // Paused items stay paused.
    updateTimePitch()
    if isPlaying {
      // Setting the rate causes the player to resume playing. So setting it only, when already playing.
      setRateKeepingTime(Float(playbackRate))
    }
  }

  /// A plain `rate` change holds the item's clock while the audio restarts
  /// at the new rate, so every change leaves the song 21 to 26 ms further
  /// behind (measured on macOS with every time pitch algorithm, also
  /// between two rates other than 1). Small repeated changes, as Mornye
  /// Link Play together makes, then never close a gap. Pinning the item
  /// time at this host instant keeps the clock continuous. A player that
  /// waits for data or is not moving changes its rate the plain way, and so
  /// does an item with the tap (equalizer or pitch shift): there both ways
  /// moved the clock by tens of milliseconds per change, the pinned one up
  /// to 200 ms when leaving a rate.
  private func setRateKeepingTime(_ rate: Float) {
    let clock = CMClockGetHostTimeClock()
    var current: Float64 = 0
    var anchorItem = CMTime.zero
    var anchorHost = CMTime.zero
    guard !tapAttached, tapAttaching == nil,
      player.timeControlStatus == .playing, player.rate != 0,
      let item = player.currentItem, item.status == .readyToPlay,
      let timebase = item.timebase,
      CMSyncGetRelativeRateAndAnchorTime(
        timebase, relativeTo: clock, relativeRateOut: &current,
        anchorTimeOut: &anchorItem, relativeToAnchorTimeOut: &anchorHost) == noErr,
      current > 0
    else {
      player.rate = rate
      return
    }
    let host = CMClockGetTime(clock)
    let itemTime = CMTimeAdd(
      anchorItem, CMTimeMultiplyByFloat64(CMTimeSubtract(host, anchorHost), multiplier: current))
    // The anchored call raises unless the player is told not to wait; the
    // setting comes back at once, so later stalls are handled as before.
    let waits = player.automaticallyWaitsToMinimizeStalling
    player.automaticallyWaitsToMinimizeStalling = false
    player.setRate(rate, time: itemTime, atHostTime: host)
    player.automaticallyWaitsToMinimizeStalling = waits
  }

  func seek(time: CMTime) async {
    guard let currentItem = player.currentItem else {
      return
    }
    let finished = await currentItem.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    // Replacing or disposing the source can finish an outstanding seek.
    // Its completion must not pause the new item or publish an old event.
    guard finished, player.currentItem === currentItem else { return }
    if !self.isPlaying {
      self.player.pause()
    }
    self.eventHandler.onSeekComplete()
  }

  func stop() async {
    pause()
    if releaseMode == ReleaseMode.release {
      await release()
    } else if (getCurrentPosition() ?? 0) != 0 {
      await seek(time: toCMTime(millis: 0))
    }
  }

  func release() async {
    if self.isPlaying {
      pause()
    }
    self.reset()
  }

  func dispose() async {
    await release()
    self.eventHandler.dispose()
  }

  private func getDurationCMTime() -> CMTime? {
    return player.currentItem?.duration
  }

  private func getCurrentCMTime() -> CMTime? {
    return player.currentItem?.currentTime()
  }

  private func createPlayerItem(
    url: String,
    isLocal: Bool,
    mimeType: String? = nil
  ) throws -> AVPlayerItem {
    guard
      let parsedUrl = isLocal
        ? URL(fileURLWithPath: url.deletingPrefix("file://")) : URL(string: url)
    else {
      throw AudioPlayerError.error("Url not valid: \(url)")
    }

    // A file still being written (the app marks its URL) cannot be indexed:
    // that reads to its end, which stalls until the upload ends and times out.
    var assetUrl = parsedUrl
    var arriving = false
    if !isLocal, parsedUrl.fragment == Self.arrivingFragment,
      var components = URLComponents(url: parsedUrl, resolvingAgainstBaseURL: false)
    {
      components.fragment = nil
      if let unmarked = components.url {
        assetUrl = unmarked
        arriving = true
      }
    }

    // FLAC can otherwise seek to different audio while reporting the requested
    // time. Exact seek tolerances alone do not fix an approximate asset index.
    var options: [String: Any] =
      arriving ? [:] : [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    if let unwrappedMimeType = mimeType {
      if #available(iOS 17, macOS 14.0, *) {
        options[AVURLAssetOverrideMIMETypeKey] = unwrappedMimeType
      } else {
        options["AVURLAssetOutOfBandMIMETypeKey"] = unwrappedMimeType
      }
    }
    let playerItem = AVPlayerItem(asset: AVURLAsset(url: assetUrl, options: options))
    Self.applyTimePitch(followsRate: pitchFollowsRate, to: playerItem)
    Self.applySpatialAudio(spatialAudio, to: playerItem)
    return playerItem
  }

  private func setUpPlayerItemStatusObservation(
    _ playerItem: AVPlayerItem
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      playerItemStatusContinuation = continuation
      playerItemStatusObservation = playerItem.observe(\AVPlayerItem.status) {
        [weak self] (playerItem, change) in
        let status = playerItem.status
        let message = "player status: \(status), change: \(change)"
        Task { @MainActor [weak self, weak playerItem] in
          guard let self, let playerItem, self.player.currentItem === playerItem else { return }
          self.eventHandler.onLog(message: message)
          switch status {
          case .readyToPlay:
            self.finishPlayerItemPreparation(.success(()))
          case .failed:
            let failure = Self.sourceError(playerItem.error)
            self.eventHandler.onLog(message: "AVPlayer preparation failed: \(failure)")
            self.finishPlayerItemPreparation(.failure(failure))
            self.reset()
          default:
            // Do not resume continuation yet.
            break
          }
        }
      }
      // Replacing the player item triggers continuation of the observation.
      self.player.replaceCurrentItem(with: playerItem)
    }
  }

  /// Preserve the native cause without exposing URLs, headers or credentials
  /// from NSError.userInfo in the player error or exported logs.
  static func sourceError(_ error: Error?) -> AudioPlayerError {
    var causes: [String] = []
    var current = error as NSError?
    for _ in 0..<5 {
      guard let cause = current else { break }
      causes.append("\(cause.domain) (\(cause.code))")
      current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    let detail = causes.isEmpty ? "" : " [\(causes.joined(separator: "; "))]"
    return .error("Failed to set playerItem\(detail)")
  }

  private func finishPlayerItemPreparation(_ result: Result<Void, Error>) {
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
    let continuation = playerItemStatusContinuation
    playerItemStatusContinuation = nil
    continuation?.resume(with: result)
  }

  private func setUpSoundCompletedObserver(_ player: AVPlayer, _ playerItem: AVPlayerItem) {
    let observer = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: nil
    ) { [weak self, weak playerItem] _ in
      Task { @MainActor [weak self, weak playerItem] in
        guard let self, let playerItem, self.player.currentItem === playerItem else {
          return
        }
        await self.onSoundComplete(playerItem)
      }
    }
    self.completionObserver = TimeObserver(player: player, observer: observer)
  }

  private func configParameters(player: AVPlayer) {
    if isPlaying {
      player.volume = Float(volume)
      player.rate = Float(playbackRate)
    }
  }

  private func reset() {
    next = nil
    finishPlayerItemPreparation(.failure(CancellationError()))
    if let cObserver = completionObserver {
      NotificationCenter.default.removeObserver(cObserver.observer)
      completionObserver = nil
    }
    player.replaceCurrentItem(with: nil)
    self.url = nil
  }

  private func updateDuration() {
    guard let duration = getDurationCMTime() else {
      return
    }
    if CMTimeGetSeconds(duration) > 0 {
      let millis = fromCMTime(time: duration)
      eventHandler.onDuration(millis: millis)
    }
  }

  private func onSoundComplete(_ playerItem: AVPlayerItem) async {
    guard isPlaying, player.currentItem === playerItem else { return }

    // Start the next song before anything else, so it follows without a gap.
    if let following = next {
      next = nil
      if !following.isPlaying { following.resume() }
    }
    reference.controlAudioSession()
    eventHandler.onComplete()

    await seek(time: toCMTime(millis: 0))
    guard player.currentItem === playerItem else { return }
    if self.releaseMode == ReleaseMode.loop {
      self.resume()
    } else if self.releaseMode == ReleaseMode.release {
      await self.release()
    } else {
      self.isPlaying = false
    }
  }
}
