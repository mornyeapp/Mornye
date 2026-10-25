part of 'desktop_player_bar.dart';

/// Whether the window shows the mini player ([DesktopMiniPlayer]) in place
/// of the shell.
final desktopMiniPlayerOpen = ValueNotifier<bool>(false);

/// Whether the mini player shows the current lyric lines under the track.
final desktopMiniPlayerLyrics = ValueNotifier<bool>(false);

const double _miniPlayerWidth = 360;
const double _miniPlayerHeight = 140;
const double _miniPlayerLyricsHeight = 108;

Size _miniPlayerSize({required bool lyrics}) => Size(
  _miniPlayerWidth,
  _miniPlayerHeight + (lyrics ? _miniPlayerLyricsHeight : 0),
);

/// The content size requested from the native mini player window.
Size get desktopMiniPlayerSize =>
    _miniPlayerSize(lyrics: desktopMiniPlayerLyrics.value);

bool _miniPlayerBusy = false;

/// Turns the window into the mini player, or back into the full window.
Future<void> toggleDesktopMiniPlayer() =>
    setDesktopMiniPlayer(open: !desktopMiniPlayerOpen.value);

/// Shrinks the window into a small panel that floats above other windows,
/// like Music's MiniPlayer, or returns it to its full size and place.
Future<void> setDesktopMiniPlayer({required bool open}) async {
  if (!desktopMiniPlayerSupported ||
      _miniPlayerBusy ||
      open == desktopMiniPlayerOpen.value) {
    return;
  }
  _miniPlayerBusy = true;
  try {
    if (open) {
      desktopMiniPlayerOpen.value = true;
      final opened = await openDesktopMiniPlayerWindow(desktopMiniPlayerSize);
      if (!opened) desktopMiniPlayerOpen.value = false;
    } else {
      // The shell fades back with the window's actual size. Keep both
      // surfaces mounted until AppKit finishes restoring the frame.
      await closeDesktopMiniPlayerWindow();
      desktopMiniPlayerOpen.value = false;
    }
  } finally {
    _miniPlayerBusy = false;
  }
}

/// Shows or hides the lyric lines, growing or shrinking the panel from its
/// top edge.
Future<void> _toggleMiniPlayerLyrics() async {
  if (_miniPlayerBusy) return;
  _miniPlayerBusy = true;
  try {
    final show = !desktopMiniPlayerLyrics.value;
    if (show) desktopMiniPlayerLyrics.value = true;
    final resized = await openDesktopMiniPlayerWindow(
      _miniPlayerSize(lyrics: show),
    );
    desktopMiniPlayerLyrics.value = resized ? show : !show;
  } finally {
    _miniPlayerBusy = false;
  }
}

/// The mini player: the track, the transport and a thin progress bar, with
/// the current and next lyric lines below when they are on. The window
/// floats above other apps while it shows; dragging anywhere but a control
/// moves it.
///
/// Material takes the track's artwork scheme on `surfaceContainer`; Mornye
/// uses the dark Now Playing background.
class DesktopMiniPlayer extends ConsumerStatefulWidget {
  const DesktopMiniPlayer({super.key, this.metadataControllerFactory});

  final PlayerMetadataController Function()? metadataControllerFactory;

  @override
  ConsumerState<DesktopMiniPlayer> createState() => _DesktopMiniPlayerState();
}

class _DesktopMiniPlayerState extends ConsumerState<DesktopMiniPlayer> {
  late final _metadata =
      widget.metadataControllerFactory?.call() ?? PlayerMetadataController();
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;

  @override
  void initState() {
    super.initState();
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id == next.value?.id && previous != null) return;
        unawaited(
          _metadata.load(next.value, inspectUnresolvedContentUri: true),
        );
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _mediaItemSub?.close();
    _metadata.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (context.isMornye) return _buildPanel(context, mediaItem);
    return PlayerArtworkTheme(
      artUri: mediaItem?.artUri?.toString(),
      child: Builder(builder: (context) => _buildPanel(context, mediaItem)),
    );
  }

  Widget _buildPanel(BuildContext context, MediaItem? mediaItem) {
    final mornye = context.isMornye;
    final theme = mornye
        ? MornyeTheme.fromContext(context, brightness: Brightness.dark)
        : Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Theme(
      data: theme,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (mornye)
              MornyePlayerBackground(artUri: mediaItem?.artUri)
            else
              ColoredBox(color: colorScheme.surfaceContainer),
            // Behind the content, so empty space and text drag the window
            // while the controls keep their clicks.
            const Positioned.fill(
              child: DesktopWindowDragArea(frameless: true),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: desktopMiniPlayerLyrics,
              builder: (context, lyrics, _) => ClipRect(
                child: OverflowBox(
                  alignment: AlignmentDirectional.topStart,
                  minWidth: _miniPlayerWidth,
                  maxWidth: _miniPlayerWidth,
                  minHeight: _miniPlayerSize(lyrics: lyrics).height,
                  maxHeight: _miniPlayerSize(lyrics: lyrics).height,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _content(context, mediaItem, lyrics: lyrics),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    MediaItem? mediaItem, {
    required bool lyrics,
  }) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final buttonStyle = IconButton.styleFrom(
      minimumSize: const Size.square(36),
      padding: const EdgeInsets.all(6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 88,
          child: Row(
            children: [
              _Artwork(mediaItem: mediaItem, size: 72, radius: mornye ? 8 : 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (mediaItem == null)
                      Text(
                        l10n.desktopPlayerIdle,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      _TitleAndArtist(mediaItem: mediaItem),
                    _Transport(enabled: mediaItem != null),
                  ],
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  AppIconButton(
                    key: const ValueKey('desktop-mini-player-expand'),
                    tooltip: desktopTooltip(
                      context,
                      l10n.desktopMiniPlayerExpand,
                      DesktopCommand.miniPlayer,
                    ),
                    iconSize: 20,
                    style: buttonStyle,
                    color: colorScheme.onSurfaceVariant,
                    icon: AppIcon(
                      mornye
                          ? CupertinoIcons.arrow_up_left_arrow_down_right
                          : Icons.open_in_full,
                    ),
                    onPressed: () => setDesktopMiniPlayer(open: false),
                  ),
                  AppIconButton(
                    key: const ValueKey('desktop-mini-player-lyrics'),
                    tooltip: l10n.nowPlayingTabLyrics,
                    iconSize: 20,
                    style: buttonStyle,
                    isSelected: lyrics,
                    color: lyrics
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    icon: AppIcon(
                      mornye
                          ? CupertinoIcons.quote_bubble
                          : Icons.lyrics_outlined,
                    ),
                    onPressed: _toggleMiniPlayerLyrics,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // The Material slider keeps its full height for dragging, centered
        // on a thin row.
        SizedBox(
          height: 16,
          child: OverflowBox(
            minHeight: 0,
            maxHeight: mornye ? 10 : 48,
            child: _SeekRow(mediaItem: mediaItem, dense: true),
          ),
        ),
        if (lyrics) Expanded(child: _MiniPlayerLyrics(metadata: _metadata)),
      ],
    );
  }
}

/// The lyric line being sung and the one after it. Plain lyrics scroll;
/// without lyrics it says so.
class _MiniPlayerLyrics extends ConsumerStatefulWidget {
  const _MiniPlayerLyrics({required this.metadata});

  final PlayerMetadataController metadata;

  @override
  ConsumerState<_MiniPlayerLyrics> createState() => _MiniPlayerLyricsState();
}

class _MiniPlayerLyricsState extends ConsumerState<_MiniPlayerLyrics>
    with WidgetsBindingObserver {
  Timer? _nextLine;
  final _seekPreview = ValueNotifier<Duration?>(null);
  bool _tickerEnabled = true;

  bool get _visible =>
      _tickerEnabled &&
      switch (WidgetsBinding.instance.lifecycleState) {
        null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        _ => false,
      };

  PlayerMetadataController get metadata => widget.metadata;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (!_visible) _nextLine?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_visible) _nextLine?.cancel();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nextLine?.cancel();
    _seekPreview.dispose();
    super.dispose();
  }

  /// The lead line playing now. Playback reports its position only when its
  /// state changes, so a timer rebuilds the view when the next line starts.
  int _followPlayback(WidgetRef ref, List<LyricLine> lines) {
    _nextLine?.cancel();
    final state =
        (_visible
                ? ref.watch(playbackStateProvider)
                : ref.read(playbackStateProvider))
            .value;
    final position = state?.position ?? Duration.zero;
    final current = _sungLineAt(lines, position);
    final next = _leadLineAfter(lines, current);
    if (_visible &&
        state != null &&
        state.playing &&
        state.processingState == AudioProcessingState.ready &&
        state.speed.isFinite &&
        state.speed > 0 &&
        next >= 0) {
      final wait = lines[next].time - position;
      _nextLine = Timer(
        Duration(microseconds: (wait.inMicroseconds / state.speed).ceil()),
        () {
          if (mounted) setState(() {});
        },
      );
    }
    return current;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: metadata,
    builder: (context, _) {
      final colorScheme = Theme.of(context).colorScheme;
      final textTheme = Theme.of(context).textTheme;
      if (metadata.loading || metadata.searchingOnline) {
        return const Center(child: AppLoadingIndicator(size: 20));
      }
      final lyrics = metadata.lyrics;
      if (lyrics.isEmpty) {
        return Center(
          child: Text(
            context.l10n.nowPlayingNoLyrics,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
      if (!lyrics.synced) {
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            lyrics.plainText,
            style: textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
      return Consumer(
        builder: (context, ref, _) {
          final lines = lyrics.lines;
          final current = _followPlayback(ref, lines);
          final next = _leadLineAfter(lines, current);
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SingleChildScrollView(
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.topStart,
                  children: [...previous, ?current],
                ),
                child: Column(
                  key: ValueKey(current),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (current >= 0)
                      if (lines[current].hasWordTiming)
                        WordTimedLyricLine(
                          line: lines[current],
                          initialPosition:
                              ref.read(playbackStateProvider).value?.position ??
                              Duration.zero,
                          seekPreview: _seekPreview,
                          style: textTheme.titleLarge!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                        )
                      else
                        Text(
                          lines[current].text,
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    if (next >= 0)
                      Text(
                        lines[next].text,
                        style: textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

bool _isLeadLine(LyricLine line) =>
    !line.isBackground && line.text.trim().isNotEmpty;

/// The last lead line that has started at [position], or -1 before the
/// first one.
int _sungLineAt(List<LyricLine> lines, Duration position) {
  var sung = -1;
  for (var index = 0; index < lines.length; index++) {
    if (lines[index].time > position) break;
    if (_isLeadLine(lines[index])) sung = index;
  }
  return sung;
}

/// The first lead line after [index], or -1 when none follows.
int _leadLineAfter(List<LyricLine> lines, int index) {
  for (var next = index + 1; next < lines.length; next++) {
    if (_isLeadLine(lines[next])) return next;
  }
  return -1;
}
