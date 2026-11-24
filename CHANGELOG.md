# Changelog

Notes for the people who use the app: what was added, what works better and
what was fixed. A release puts the section named after its version (or
`Unreleased`) at the top of its notes, in the app's update dialog and in the
Telegram post, with the full commit list folded under it. Write list items
only, since the update dialog shows nothing else, and put what matters most
first: the dialog stops at 2000 characters in versions before 5.4.5 and at
8096 from 5.4.5 on, and the Telegram post at 2500. GitHub shows it whole.

Versions 4.9.7 to 5.4.0 have their notes on the
[releases page](https://github.com/mornyeapp/Mornye/releases).

## [5.4.5] - 2026-11-24

### Added

- **Parametric Equalizer**: Switch between Graphic and Parametric modes with up to 20 custom filters (peak, low shelf, and high shelf; 20 Hz to 20 kHz, +/-24 dB, Q 0.1 to 20), exact numeric entry, and import/export of plain-text AutoEQ-style filter lists (`Preamp` and `Filter` lines). Supported on Desktop, iOS, and Android (via the new playback engine DSP).
- **Personal Home & Dedicated Search Tab**: Home is now always your personal page in both Material and Mornye styles, while Search becomes its own tab/destination opening directly on the extension feed (*Search feed*). On Material Home, the old gray search prompt row was removed so the greeting leads straight into your sections, with a one-time tooltip for existing installs.
- **Recommended for You**: Added a daily cached *"Recommended for you"* shelf on Home suggesting tracks outside your Library based on your most played, recently added, and loved songs.
- **Expanded Home Mixes**: Added **Deep Cuts** and **Year Mix**, daily rotating Artist Mixes and extra genres, balanced variety across mix types, and up to 12 mixes on Home. *On repeat* falls back to Library albums when there is no listening history yet.
- **Home Shows Your Collection & Edit Home**: Home gains a status line under the greeting (songs added since your last visit, downloads in progress), *Finish your collection* (wishlist songs, albums missing songs, recognized songs not in your Library, failed downloads), a Hi-Res shelf while a DAC or exclusive output plays, and a row for a connected Link device. *Edit Home* at the end of the page reorders sections and shows or hides them; *Finish your collection* and *On repeat* start turned off.
- **Pin to Home & Your Own Shortcuts**: Pin albums, playlists, Loved, artists, genres, and folders to Home with a long press in the Library (up to 12), and remove any Home shortcut, the built-in ones included, so the grid can hold only what you picked.
- **Quick Play on Home**: A grid of nine songs from your Library sits under *Shortcuts* (under *Continue listening* in the Mornye style), and one tap plays a song with the other eight queued after it. It leads with the songs you play most and fills up with picks from your Library that change each day, and it can be moved or hidden in *Edit Home*.
- **Recommendations That Learn More**: With *Personalized autoplay* on, *Recommended for you* puts the songs that fit your taste first, Autoplay and mixes place songs you have not played yet through their album, credited artists, and genre, and learning now knows whether you listen on the speaker, wired headphones, Bluetooth, a DAC, a car, or another device. *Settings > Playback* shows how your mixes and recommendations are received once there is enough to measure. Everything stays on your device.
- **Cast to DLNA and FCast Devices**: Besides Google Cast, the app now finds DLNA / UPnP speakers and TVs and FCast receivers on your Wi-Fi network and plays your queue on them with play, pause, seek, and volume. On Android, *Audio Output* gains *Other TVs and speakers* under *Cast to TV*; on iOS and desktop they appear in the same list as Google Cast devices.
- **Update Metadata Over Mornye Link**: Songs you saved from a connected computer or phone can take the tag changes made there since. *Update metadata* on the Link page lists the saved songs that differ, shows each differing tag as the value on this phone and the value on the other device with its own switch, and changes nothing until you confirm.
- **Albums in Mornye Top Picks**: *Top Picks for You* on the Mornye Home now offers albums next to your mixes, each as a tall card whose cover runs on into a soft blur under the title, and the color backgrounds of mix banners now drift gently (they stay still when the system asks for reduced motion and on low-end devices).
- **Recommendations by Genre & Top Picks Page**: The arrow next to *Recommended for you* on Home opens a page with today's suggestions and a shelf for each of your Library's main genres. On the Mornye Home, the arrow next to *Top Picks for You* opens every pick sorted onto its own shelf: *Made for You*, *From your Library*, *New releases*, and the picks of your Home feed extension.
- **Full Profile Page**: Tapping your profile in Settings now opens a complete listener profile with *All time* totals and streaks, *Last 30 days* activity, *Last 12 months*, *Music taste* by genre with a color for each, *Listening habits*, *Time of day*, *Decades*, *Sound quality*, *Top artists/albums/tracks*, and collection counts (profile editing moved to *Edit profile*). *Now playing* shows how far the song has played, and *Listener type* describes you with up to five of 22 traits (such as *Night owl*, *Jazz at heart*, *Throwback lover*, or *Quick skipper*); the two leading ones also show under your name and on the Settings profile row.
- **Share Your Profile**: *Share profile* turns your profile into a story or square image with your photo, your leading listener type in large type, listening time, music taste, top artists and tracks, and sound quality. Choose what shows and the background, then save or share it.
- **Download Focus Mode (External Player)**: Selecting *External player* hides built-in-player-only UI across Home, Library, Profile, and Settings without deleting your queue, listening history, or preferences, focusing the app on downloading and file management.
- **Manual Lyrics Translation Editor & Readable Tags**: Add and edit lyrics translations by hand directly from the player. Saved translations and romanizations now write as readable plain-text tags (`[x-translated:...]`, `[x-romanized:...]`, `[x-translated-words:...]`) in `.mlrc` (`[x-mlrc:2]`) and embedded tags while staying backward-compatible with legacy base64 tags.
- **Customizable Share Lyrics Cards**: Added a *Style* pane with card shapes (**Story** 1080x1920, **Square** 1080x1080, **Wide** 1920x1080), text sizes (**Small / Auto / Large**), alignment options, and a **Save** button to export as PNG without storage permissions.
- **Share a Song's Name or Link**: *Share* on a song now offers **Share name** and **Share link**. Share link looks the song up on your installed extensions and shares its link on the service you pick.
- **Lock Screen Lyrics Title Option**: Added *"Keep the song title"* under *Lyrics on lock screen* so the active lyric line replaces the artist field while keeping the song title visible.
- **Full-Screen Cover Controls**: Added **Whole cover** (keeps full-screen artwork square at full width without side cropping) and **Cover fade** (**Short / Medium / Long**). On Mornye, still full-screen covers now end with a soft blur transitioning into a matching solid edge color.
- **Direct USB DAC Resampling & Rate Cap**: Automatically resamples tracks whose native sample rate a DAC rejects using a Kaiser windowed sinc polyphase filter (130 dB stopband, triangular dither for 16-bit output), reads UAC2 clock ranges, remembers working rates per DAC, and adds a **Highest sample rate** setting in Direct USB. A **Dither type** choice (**TPDF** or **TPDF HP**) picks the dither added to converted songs on a 16-bit output; TPDF HP moves the added noise to high frequencies where it is harder to hear.
- **AutoMix Beat Matching**: Added a *Beat matching* setting (**Standard**, **More often**, **Most often**) controlling how often AutoMix aligns beats between tracks, synced across devices via Link.
- **Simple Audio Quality Label**: Added a **Simple** audio quality badge mode (*Hi-Res*, *Lossless*, *Dolby*, or format name) for the Library and full player.
- **Multi-Track Authenticity Chart**: Batch Hi-Res / authenticity checks now overlay average spectra on one shared chart with color-blind-safe per-track colors.
- **Drag-to-Select Songs**: After a long press selects a song, slide your finger up or down to select or deselect multiple songs with automatic edge scrolling.
- **CSV Import with Track Links**: Supports `URL`, `Link`, `Track URL`, and `Track Link` columns (including album and playlist links) via matching extensions, with ISRC and stricter title/artist fallbacks.
- **Library, Queue & Desktop Actions**: Apply one cover image to all selected songs in *Set common values*; added *Re-download* and *Copy title* on track details; added copy/open-album actions for downloads and desktop library items, delete on the desktop album selection bar, desktop scroll arrows for Home shelves and Equalizer band faders, and extension names on verification prompts. *Up Next* gains a button that saves the whole queue, in its order, to a new or existing playlist.
- **Animation Speed Setting**: Added *Settings > Appearance > Animation speed* (0.5x to 2x) governing page transitions, player motion, sheets, snackbars, banners, and UI animations.
- **Turn Quiet Songs Up**: *Volume normalization* used to only turn loud songs down, so songs mastered quietly stayed quiet and the app sounded softer than other players. The new *Turn quiet songs up* switch under it raises those songs too, by up to 12 dB. On phones and Macs a limiter holds back their loudest moments; on Windows and Linux they may clip.

### Improved

- **Material 3 Motion & Scrolling**: Material pages now push solidly with distance-driven fade, pop as a receding card, follow the Android **predictive back gesture** live, and cache scaled transition frames as pictures to eliminate glyph-atlas jank. The Material full-screen player expands and collapses as one solid expressive spring surface, and Android Material lists use native Android fling physics while keeping bounce at both ends. A song's cover now flies back to its row on a back swipe, just as it does on a back press.
- **Mornye / Apple HIG Liquid Glass Alignment**: Removed Liquid Glass from content surfaces (reserving it for navigation and controls), adopted Cupertino buttons, menus, activity indicators, grouped settings lists, and expanded Cupertino icons, unified Liquid Glass springs, and removed staggered row delays on Mornye lists. Mornye's glass now follows the iOS 27 look on the tab bar, mini player, and controls at the default *Glass clarity*, and switch and slider thumbs turn to glass while you hold them.
- **Material 3 Expressive Consistency**: Connected option rows across song lists, search results, artists, albums, playlists, menus, loading skeletons, track details, and all bottom sheets; solid container colors without extra outlines; auto-widened menus and content-sized sheets; start-aligned plain lyrics and cleaner instant-apply search sorting; the desktop player bar gains shuffle and repeat beside the playback buttons, and its other buttons join one connected group in which Lyrics and Up Next fill while their panel is open.
- **Roomier Page Headers**: On phones, album, playlist, and folder pages show at most two buttons at the top and keep the other actions, such as saving songs to this phone or keeping them offline, in one menu, so the buttons no longer sit against each other.
- **Play From Search**: Tapping a song in Search that you already have now plays it, instead of only saying it is already in your Library.
- **Shorter Settings With an External Player**: With *External player* chosen, Settings leads with what shapes a download, hides the categories that only serve the built-in player, and offers the player choice as one row. Link stays listed once it is set up.
- **Accessibility & RTL**: Enforced an 11 pt minimum text floor, full touch targets, and proper RTL mirroring for navigation, sliders, and Rewind taps. Theme changes switch at once when the system asks for reduced motion. Album and artist headers show the still cover instead of the motion cover when the system asks for reduced motion.
- **Smaller Packages Across Platforms**: Icon tree-shaking, stripped unused font axes, compact binary pinyin data, trimmed concert timezone data, deduplicated LGPL license text, desktop code compiled out of mobile builds, Android resource/asset shrinking, dropped FFmpegKit plugin on macOS/Linux desktop, and size-optimized Rust builds (keeping FLAC decoding and the extension JS engine at full speed, without UniFFI on desktop, and with trimmed SQLite).
- **Runtime Performance**: Overlapped startup and deferred storage checks; fewer rebuilds, repaints, and preference writes; a lighter cover flight when opening track details from the Library; a lighter Mornye player when it opens and closes; cached squircle paths and lens shaders; stopped hidden controls from tracking playback position; indexed History/Library queries and partial Library updates; cheaper Rust cover resizing, MP3 tag reads, and scans; off-main-thread scan progress parsing; fewer Android SAF/Binder IPC queries and disk writes; and serialized writes to prevent `history.db` lock contention. Album, playlist and mix pages keep their header and its blur when it reaches the top, instead of drawing them again. Home no longer rebuilds after each finished download while *Recommended for you* stays the same. A song change redraws the player, the lock screen controls and the widget fewer times. With *Personalized autoplay* on, the app no longer reads its whole suggestion log again after every song. The wave of the Material mini player moves with less work. When the Mornye tab bar folds or unfolds as you scroll, its two round buttons are no longer made again on every frame, and switching tabs no longer builds the mini player above it again. The drifting banners of Mornye *Top Picks* also rest when a section above them changes and moves them out of sight, and switching tabs no longer builds the whole *Top Picks* shelf again just to stop or start them. The Mornye full player opens with its cover already decoded, and a song change no longer builds the whole player a second time once it finds the song has no motion cover, or the same motion cover as the song before, as within an album. Opening it on a motion cover no longer builds it again when the video reports a size it already knows, or several times over when the video cannot play. Sections you hide in *Edit Home*, and the ones that start turned off, no longer load their songs in the background. Autoplay saves and restores its long list of recently played songs, and Home its feed, away from the screen. *Storage & Cache* shows the size of the Home feed without reading the whole feed. The full player no longer builds itself again as it opens and closes, and the Material player fades in one pass while it grows or shrinks. Opening a menu or sheet over the player no longer redraws the whole player, and neither does finding a song's motion cover in the Material player. While the player is open, the next song's colours are worked out ahead, so they change together with its cover. When you close the Material player after the song changed, the mini player and the bar below it show the new song's colours at once instead of redrawing themselves on every frame of the close. After a download or a scan, your profile reads your listening record again only when something was played since. The day's Library mixes now count plays and weigh your taste away from the screen, and *Personalized autoplay* reads its logs there too when it learns. A Library album no longer builds its whole page a second time as it opens, once its found-artwork and animated cover lookups finish without finding anything. On desktop, the Material sidebar fades your playlists in and out as it opens and closes instead of building every playlist row again on each frame. Resizing the window no longer decodes the cover of the desktop Now Playing view again on every frame. Album, playlist and folder pages on desktop decode their header cover at the size it shows, once, instead of at the width of the window and again whenever that width changes. Covers in desktop grids keep their picture while the Lyrics or Up Next panel or the sidebar slides beside them, and decode again once, when the grid stops moving. Resizing the desktop window no longer builds the sidebar, the open Lyrics or Up Next panel and the player bar controls again on every frame; they only move into their new places. Opening and closing the Material sidebar builds its destinations about six times less often. Typing in the Library search no longer builds its filter chips again each time results for one kind of item arrive. On a song change, the Material mini player and the navigation bar under it take the new cover's colours at once and only fade their background, instead of building both again on every frame of the fade. The playing song's row in a Material list takes the new cover's colours at once too; its fill still fades, and the whole row is no longer built again on every frame. The Material desktop player bar and mini player do the same; the player bar builds about six times less per song change. While Mornye Link shares your Library (*Share with Mornye on your phone* on a computer, *Share with other phones* on a phone), a large Library no longer holds up the screen for as long when its shared list of songs is rebuilt at start and after the Library changes. Songs that Direct USB has to resample start sooner, since the filter for a pair of rates is worked out once. Lyrics the app has found before appear a little sooner. Searching for albums and artists in a large Library is faster. The Lyrics filter of the Library search goes through your songs faster and finds matches sooner. Removing missing downloads from History and sorting the Library by size are faster. While a NAS or server folder is scanned, its counter updates four times a second instead of for every file. Scanning a Subsonic server is faster, since the songs of four albums are asked for at once. With a large Library, Mornye Link also builds its shared list of songs faster on a computer. Starting a long download queue on Android no longer holds up the app for a moment. On phones, Mornye Link no longer starts when the app opens, only once you use it. The home screen player widget no longer holds up the app when the launcher refreshes it. On a Mac, resizing the borderless window by its edges is smoother. The equalizer curve redraws with less work while you drag a band or a filter, and editing one filter no longer rebuilds the whole list. On desktop, opening or closing the Lyrics or Up Next panel no longer builds the open page again, and sidebar playlists hold no animations until you select one. Moving the pointer over desktop album track lists takes less work. Dropping many files on the desktop window no longer stalls it while they are checked. Switching themes and working out the colours of a cover take less work. When the next song has the same background colour, the player no longer animates it. Artist pages, Explore and the wide Search decode their covers at the size they show, and resizing the window no longer decodes them again. Sliding a finger over Library songs to select them takes less work, and Library covers fade in at your *Animation speed*. The extension store filters its list a moment after you stop typing instead of on every letter. Resizing the window with Settings open no longer builds the open settings page again on every frame. Lyrics with word timing draw the sung part of a line with less work, and the blurred lines around the current one keep their picture while nothing in them changes. In the Material player, a song without a cover no longer runs a full-screen blur, and the Mornye cover glow stays smooth while the window resizes. Mornye labels over covers get their contrast right sooner after a page opens. Album cards in Mornye *Top Picks* stay smooth while a desktop window is resized. Extension icons are kept on the device, so they show at once the next time, with the letter tile in their place while one loads. Long download sessions keep a shorter list of finished downloads in memory, a finished download marks its song as downloaded without checking every song on the page again, and removing a song from a long queue no longer copies the whole queue. History upkeep no longer saves songs it found unchanged, and no longer reads again at every start the files it has already read in full. Download rows and the queue header no longer gather animations while a download runs. Material song rows take less to build. Album, playlist and folder page headers no longer build their cover and details again on every frame while they collapse. The lyric line under the mini player and on the desktop mini player no longer rebuilds on every position update, and scrolling titles keep their place when another page covers them. Dragging across the Mornye selection pill rebuilds it only when it reaches another option, and the Mornye landscape player fades only the part of its lyrics you can see. The app reads your saved settings once at start instead of twice, music haptics are no longer worked out again on every position update, and removing songs from a playlist takes less work. Library scans now take the cover of M4A, AAC, Ogg and Opus songs from the same read as their tags instead of opening each song again, more resized covers fit in the cover cache, and a cover that is already resized no longer waits while another is being resized. The Hi-Res check and saving a scanned Library take less work.
- **Dependencies & Toolchains**: Updated Flutter to 3.50.1, FFmpegKit to 3.0.0 (FFmpeg 8.1.3), Android Gradle Plugin to 9.5.2, Gradle to 9.9.2, AndroidX Lifecycle to 2.11.1, and Rust and Dart dependencies.

### Fixed

- **Closing the Material Player**: Closing the full player with the back gesture now flies the cover into the mini player, as the close button and the back button do, instead of sliding it down with the page. The player also closes as quickly as it opens, the cover no longer jumps in size when you let go of a drag, and closing the player again while it is still opening takes the cover straight back.
- **Previous Song When Closing the Player**: After you skip songs in the full player, closing it no longer shows the previous song's cover and title in the mini player for a moment before they fade to the new song.
- **Music After a Call on Android**: Music paused by a call now plays on once the call ends, also after calls in other apps that never hand the sound back, and it waits until the call has fully ended. If the song does not move when it starts again, it reloads at the same spot, so a skip is no longer needed to get it playing.
- **Playback, Previews & Cast**: Re-fetches expired preview URLs and falls back across extensions; respects *Metadata Priority* when opening artists or albums; eliminated cover flicker/blink when opening track details or collections; falls back to embedded artwork when web covers fail; preserves the last session when the system stops playback; fixes continuing through an album or playlist from a local tap; keeps Android awake and advances cleanly to the next track on Cast; fixes black screen from lingering touches after closing the player; keeps Mornye player corners rounded while moving; lines up the song title and buttons with the small cover above the Mornye lyrics and Up Next; shows a single cover while the Mornye player closes onto the mini player, also when the page is scrolled meanwhile; and aligns album descriptions under the sheet's rounded top edge. On iPhone, iPad and Mac, moving an equalizer control no longer lets a moment of sound through without the equalizer, which could be heard as a small tick.
- **Search Opening on Recent Searches**: If you had turned the feed off to see your own Home, Search now opens on the feed again instead of only your recent searches. You can still turn it off under *Search feed*.
- **Home With an External Player**: A tap on a *Recently added* song on Home now opens it in your chosen player instead of the built-in one.
- **Direct USB DAC**: Keeps playing when another app plays a sound, pausing only for a call; releases idle DACs so other apps retain audio, restores initial DAC volume on exit, downloads network tracks fully before USB playback, and handles smaller USB endpoints reliably.
- **Lyrics & Translations**: Lyric lines follow the sung language direction while translations follow their own setting; aligned translation editor rows and icon; fixed Android pinyin data loading.
- **Network & Link**: Automatically rebinds the local playback proxy after iOS closes its listener, and keeps manually typed computer addresses in Link instead of overwriting them with discovery results.
- **Downloads & Platforms**: Keeps failed downloads in the queue across restarts; keeps download and Library scan progress updating on Android after the system closes the app's window while music keeps playing; allows absolute Windows download directories in the extension sandbox; fixes the Android player widget prior to Android 12; fixes dragged row offset under UI scaling; releases desktop audio devices cleanly on exit and keeps outputs open across gapless track changes; fixes desktop crashes when moving windows across displays; disables Impeller automatically on Linux with NVIDIA drivers and aligns the Linux system unwinder; the Play button on desktop album and playlist pages is as tall as the buttons beside it again. In the Material style on iPhone and iPad, pulling a list down to refresh no longer opens a gap under its pinned title.

---

## [4.9.6] - 2026-09-07

### Added

- **Batch Metadata Editing**: Set shared metadata values for multiple tracks and review changes before writing. Empty inputs retain existing values; track titles, numbers, and ISRCs remain unchanged in this mode.
- **Bulk Duplicate Cleanup**: Keep the best copy across all duplicate groups, with confirmation before lower-quality files are deleted.
- **Build Identification**: Show the compiled short Git commit on the About page to distinguish test builds with the same version number.

### Fixed

- **Verification Notifications**: Open the pending verification challenge when its notification is tapped, including when the app is resumed or launched from the notification.
- **Verification During Fallback**: Prepare each provider's session before checking availability, retain the identity of the provider requesting verification, and pause fallback for its challenge instead of treating verification errors as an unavailable track.
- **Verification Callbacks**: Preserve shared challenge identity and callback retries so concurrent requests do not lose the active verification flow.
- **Download Timeouts**: Bound stalled stream resolution without applying that timeout to established transfers that are still downloading data.
- **Fallback Quality**: Translate provider-specific quality options by audio type, avoiding accidental selection of spatial audio for ordinary lossless downloads.
- **Track Matching**: Handle differences in artist-credit order, capitalization, punctuation, and title annotations while retaining checks for different recording versions. Matching recording IDs and names can also resolve inconsistent catalog durations without accepting short previews.
- **Collection Metadata**: Preserve genre, label, copyright, comments, and UPC when loading album and artist tracks or opening extension albums, playlists, and artists. Also retain album credits and audio-quality fields previously lost when rebuilding track objects. This fixes missing tags when optional metadata enrichment is disabled.
- **Metadata Enrichment**: Retain existing track fields during enrichment and preserve Opus tags during batch metadata updates.
- **Native Download Formats**: Remove the legacy rule that automatically converted `HIGH` quality downloads to MP3. Preserve native M4A/MP4 containers unless the user enables automatic conversion.
- **SAF Output Files**: Publish converted audio with the final format's extension, preventing MP3 data from being saved with an M4A filename and subsequently failing metadata or lyrics reads. Preserve Unicode document names and avoid overwriting existing FLAC conversion outputs.
- **Album Folders**: Resolve missing album names from finalized metadata before publishing downloads, including spatial-audio downloads resumed after verification, instead of retaining an early `Unknown` folder choice.
- **SAF Metadata Reads**: Restore temporary-file fallback when a file descriptor cannot be read, while allowing valid audio files with no embedded tags.
- **Opus Quality Labels**: Recognize Opus inside M4A/MP4 containers, read its bitrate and sample rate, and avoid displaying container sample depth as lossless bit depth. Keep the Opus badge when bitrate is unavailable.
- **ReplayGain**: Write and verify native Opus R128 gain tags while preserving audio and artwork, retain playback normalization for SAF descriptor leases, and refresh normalization after saving. Reject incomplete loudness scans and report unsupported decoders clearly.
- **Download Quality Picker**: Restore downward drag dismissal and size the sheet to its content rather than leaving excessive empty space.
- **Search and Library**: Let newer live searches supersede cancelled requests, keep large playlist-picker queries within SQLite parameter limits, and make missing-file cleanup safer around temporary SAF access failures.
- **Artwork and Layout**: Preserve provider-supplied high-resolution artwork, fix collapsed-header title overlap, and improve adaptive phone and tablet layouts.
- **iOS and AltStore**: Isolate download-progress subscriptions, restore local iOS builds, and match the AltStore source bundle identifier to the released IPA.

### Improved

- **Memory Use**: Release discarded extension runtimes and reclaim idle native download memory after the queue finishes. Bound cover-cache usage and decode artwork at sizes appropriate to its layout.
- **Large Libraries and Queues**: Reduce progress-update allocations, stream scan snapshots, page cleanup work, and reuse history and collection lookups across rebuilds.
- **Metadata and Search Performance**: Share bounded MP3 tag/cover reads, read SAF metadata through descriptors when possible, decode large extension search responses outside the UI isolate, and copy only requested extension storage values.
- **UI and Maintenance**: Batch cached-artwork validation, retain platform-link lookups across rebuilds, share batch-action settings, and resolve analyzer diagnostics.

### Compatibility

- **iOS Requirement**: The minimum supported iOS version is now 16.0.
- **AC-4 ReplayGain**: AC-4 loudness analysis still requires decoder support unavailable in the current bundled FFmpeg build. This release improves the failure message; it does not add an AC-4 decoder.

---

## [4.9.5] - 2026-08-31

### Added

- **Direct Lyrics Sources**: KuGou, QQ Music, and Genius now fetch lyrics directly from their source services instead of relying on the Paxsenix proxy. Direct QQ Music results provide line-synced LRC, while Genius pages preserve every verse and chorus container.
- **Sleep Timer**: Stop playback after a selected duration or when the current track ends.
- **Resilient Backup Format**: Backups now use the compact `.sflb` extension and a versioned, streaming ZIP format that avoids loading the complete library and cover archive into memory.
- **Resolver Fallbacks**: Expanded cross-platform link resolution with additional fallback services while retiring endpoints that are no longer available.
- **Library Metadata Tools**: Filter tracks by lyrics availability and perform additional metadata maintenance directly from the Library.

### Fixed

- **Download Reliability**: Restored reliable provider fallback retries, prevented stale cancellation state from aborting new attempts, preserved finalized metadata and Library quality labels, and reduced duplicate transfer work.
- **Library Availability**: Recover from transient file-availability races without showing misleading missing-file indicators; stabilize completed-download artwork, labels, and playback actions.
- **Library Scrolling**: Prevent multi-touch and pinch recognition from unexpectedly interrupting vertical grid scrolling.
- **Playback Controls**: Keep Library play/pause actions synchronized with the internal player and handle headset media controls correctly.
- **Download Notifications**: Hide meaningless `0.0 / 0.0 MB` totals when a provider cannot report the transfer size.
- **Search Compatibility**: Cache unavailable SQLite FTS5 capability and continue with the LIKE fallback without repeatedly attempting unsupported virtual tables.
- **Android Build Compatibility**: Keep internal lyrics search result types out of the gomobile API so Android ARM bindings generate successfully.

### Improved

- **Download Pipeline**: Stream concurrent native queue work, reduce progress wakeups and log churn, reuse prepared extension context, and harden resumable transfer handling.
- **Extension Runtime**: Coalesce signed-session lifecycle work, refresh provider health outside the download path, reduce JavaScript bridge overhead, quarantine stalled runtimes, and bound native queue state.
- **Network Performance**: Improve IPv4/IPv6 connection fallback, DNS validation, HTTP connection reuse, retry draining, and rate-limit coordination.
- **Library & Metadata Performance**: Use staged database updates, incremental scan reconciliation, coalesced MusicBrainz/Deezer lookups, and fewer redundant metadata probes and rebuilds.
- **Playback Performance**: Stream SAF tracks through descriptor leases instead of retaining many complete temporary song copies.
- **Lyrics Performance**: Coalesce identical provider requests, cancel losing lookups, and persist positive and negative results.
- **Playlist Import**: Batch metadata enrichment with bounded concurrency instead of resolving every imported track sequentially.
- **Extension Store**: Coalesce registry requests, use conditional responses, and avoid holding cache locks during network activity.
- **App Updater**: Resume interrupted APK downloads, publish completed files atomically, and verify SHA-256 checksums when a release provides one.
- **Codebase & APK Size**: Removed generated and duplicated code, tightened Android R8 keep rules, and standardized supported ARM release outputs.
- **Diagnostics**: Removed noisy navigation and high-frequency progress logs while retaining actionable failures and performance data.
- **Dependencies & Localization**: Updated Flutter, Go, Android, and native dependencies and merged the latest Crowdin translations.

### Security

- **Extension Sandbox**: Prevent raw FFmpeg argument/path escapes, restrict extension file and network access, and harden DNS resolution against private-network bypasses.
- **Credential Protection**: Encrypt extension storage with a platform-provided master key and strengthen OAuth callback state with short-lived, single-use nonces.
- **Network & Memory Safety**: Bound cover and response downloads, redact JSON credentials, cookies, and signed URLs from exported logs, and update Go to 1.26.6 security fixes.
- **Release Workflow**: Validate manually supplied versions and pin sensitive GitHub Actions dependencies.

---

## [4.9.0] - 2026-08-25

### Added

- **Metadata Editing & Identity**: Edit release tags, write release identity fields, render UPC barcodes, preserve provider metadata, and add provider traceability and download-attribution comments.
- **Cover and Quality Details**: Inspect embedded-cover dimensions and resolution, retain the best available artwork, and choose combined or bit-depth/sample-rate quality labels.
- **Automatic Conversion**: Optionally convert downloaded lossy sources automatically while preserving the selected SAF destination.
- **Explicit Track Badges**: Show explicit-content badges in track titles without duplicating the indicator across metadata sources or conversions.
- **Library Storage Folders**: Scan and manage multiple storage folders, with live scan progress and readable SAF locations.
- **Playlist Actions**: Play tracks from playlist results and keep the source provider ID available for recent playlists.
- **Log Export Tools**: Copy selected diagnostic log entries directly from the log viewer.

### Fixed

- **Download Queue Recovery**: Restore user-paused items, recover batches after worker timeouts, resume short clean EOFs, and unblock the queue after verification cancellation.
- **Download Storage & File Naming**: Preserve the selected SAF destination, defer unsafe background starts, normalize MP4 audio extensions according to the actual codec, preserve retained files during duplicate cleanup, and keep iOS security-scoped download-folder bookmarks.
- **Provider Matching**: Accept matching tracks across releases, match by primary artist, preserve collaboration albums, and retain source release fields during enrichment and conversion.
- **Metadata and Lyrics**: Honor provider priority and the selected lyrics extension during autofill, normalize Genius responses, and support batch metadata review with verification prompts.
- **Library Stability**: Keep folder actions discoverable, restore live scan counts, clear recent activity permanently, and batch SAF orphan inspection without losing retained records.
- **Audio Analysis**: Bound spectrogram memory, reject false low spectral cutoffs, and avoid unsupported analysis results.
- **Playback and UI**: Improve timed-lyrics highlighting, align track badges and metadata layouts, and update tutorial and Library play-button copy.
- **iOS Scanning**: Correctly handle library scan-count output on iOS.
- **Startup Compatibility**: Prevent concurrent database startup locks.
- **Accessibility**: Add semantic labels to interactive controls.

### Improved

- **Library Performance**: Stream library scans and optimize queue/history queries to reduce memory use and refresh work on large libraries.
- **Metadata Pipeline**: Move cover-resolution selection into extensions and prioritize configurable extension settings during enrichment.
- **Download Metadata**: Preserve final provider metadata through verification and conversion so Library records remain grouped and complete.
- **Dependencies**: Update the Flutter and Go dependency sets used by the release.

---

## [4.8.5] - 2026-08-01

### Added

- **Searchable Settings**: Search both top-level pages and controls inside them. Opening a nested result now scrolls to the matching control and briefly highlights it.
- **Album Multi-Select Download**: Select several tracks in an album and choose the provider and quality once for the whole selection.
- **Player & Queue Controls**: Repeat Off/All/One modes, swipe up from Now Playing to open the queue, move queued tracks up or down, `Download next`, and one-tap retry when connectivity returns.
- **Playback Session Restore**: Restore the previous queue, track, technical quality, and playback position after the app process is restarted.
- **Track Navigation**: `Go to Album` is available from track actions, including sparse search results, and `Open on...` exposes supported platform links.
- **Library Views**: Playlist filtering, a configurable default Library view, a missing-ISRC filter, and clearer horizontally scrollable filter chips.
- **Quality Labels**: Choose between measured bitrate labels and classic bit-depth/sample-rate labels. High-bitrate tracks receive a distinct badge color, and lossless average bitrate is shown in Track Metadata.
- **Duplicate Review**: Detect ISRC duplicates beyond FLAC, review matching files, and keep the preferred copy.
- **M3U Playlists**: Import M3U/M3U8 playlists and export Library collections as M3U8.
- **Metadata Sources**: Choose a specific extension for online auto-fill, use extension-defined custom search, or manually fetch metadata from MusicBrainz.
- **Cover Tools**: View the current embedded-cover dimensions, preview the dimensions of a fetched cover, resize embedded artwork, and select the best available online cover candidate.
- **Android Download Widget**: Monitor the active download queue from the Android home screen.
- **Appearance Controls**: Adaptive detail-page colors derived from cover art and an optional force-backdrop-blur setting for lower device tiers.
- **Audio Processing**: Very-high-quality SoXR resampling settings for supported lossless conversions.

### Fixed

- **Provider Matching**: Honor the explicitly selected provider and reject mismatched provider results that could download a cover or unrelated song with the original album metadata.
- **Verification & Sessions**: Coordinate one verification flow across sequential and parallel album downloads, follow canonical gateway/provider error contracts, block challenged session generations, and prevent stale requests from invalidating a newer session.
- **Verification Alerts**: Notify the user when downloads pause for verification and recover signed-session bootstrap failures more reliably.
- **Download Storage**: Recover from an unwritable selected folder, retain published files when bookkeeping fails, and keep cancelled items retryable after app restarts.
- **Quality Variants**: Complete alternate-quality downloads reliably and append technical quality to filenames only when a real filename collision exists.
- **Library Stability**: Keep rows and cached history visible during active downloads and refreshes, retain records when deletion fails, and backfill/persist local bitrate metadata without opening every track.
- **Playback & Lyrics**: Refresh lyrics after automatic track changes and cold starts, reject empty embedded lyric payloads, preserve technical quality between tracks, and restore playback position reliably.
- **WAV & AIFF Metadata**: Preserve supported tags and artwork through conversion and metadata editing.
- **Audio Analysis**: Wait for complete FFmpeg metrics, isolate analysis from active downloads, detect effective/full-band spectral cutoff more accurately, and avoid unsupported AC-4 spectrogram analysis.
- **Startup Compatibility**: Stop forcing the highest Android display mode during every cold start, avoiding OEM-specific crashes and unnecessary GPU load.
- **User-Facing Errors**: Replace raw `PlatformException` and backend details with concise, sanitized messages.
- **Metadata UI**: Keep Track Metadata headers readable in light themes and make the online source picker, preview, apply, and feedback flow consistent with the rest of the app.
- **Selection & Sheets**: Keep selection bars and modal sheets above the app navbar and make download-picker drag dismissal feel natural.
- **Database Upgrade**: Make playback-session migration safe when an older installation already contains the destination table.

### Improved

- **Now Playing**: Smoother track transitions, consistent custom action sheets, better synced-lyrics positioning, and aligned play/preview controls and hitboxes.
- **Responsive UI**: More consistent search fields, settings groups, page headers, modal sheets, empty/error states, and collection selection behavior, with improved tablet widths and short-screen setup/tutorial layouts.
- **Download Performance**: Faster duplicate checks for large playlists, fewer native-widget updates, reduced progress/session write churn, and safer HTTP Range recovery.
- **Library Performance**: Batched history/index updates, fewer rebuilds during scans, lazy duplicate loading, cached MusicBrainz lookups, and quality probes that avoid unnecessary SAF copies.
- **Extension Security**: Verify decentralized package integrity, isolate bad registry checksums, anchor URL handlers to their declared hosts, and enforce `minAppVersion` and required runtime features.
- **Dependencies**: Updated Flutter, Go, FFmpeg, Android notification, and supporting native dependencies.

---

## [4.8.0] - 2026-07-24

### Added

- **Tablet & Landscape UI**: Navigation rail, landscape Now Playing, clamped layouts for track lists, dialogs, sheets, settings, queue lists, and the setup wizard, with adaptive selection-card columns.
- **Playback Volume Normalization**: ReplayGain/R128 volume normalization for the built-in player (Library > Playback, off by default).
- **Concurrent Downloads**: Support up to 3 simultaneous downloads.
- **Download Resume**: Interrupted downloads resume via HTTP Range/If-Range instead of restarting from zero.
- **Lost Folder Access Recovery**: Detects a lost SAF grant and offers folder re-selection.
- **Native Tag Editors**: New native MP3 ID3v2, Ogg/Opus Vorbis comment, and M4A ilst tag editors — metadata edits for these formats no longer need FFmpeg.
- **Shared-Element Transitions**: Hero covers fly from search/recents to detail screens, the player expands from the mini player with drag-to-dismiss, and skeletons crossfade into content.
- **Player Gestures**: Swipe the mini player away to stop playback.
- **Convert Options**: Optionally retain original files after conversion, and support same-format lossless re-encoding.
- **Quality Variants**: Downloads preserve quality variants, named by measured quality.
- **Explicit Badge**: Explicit tracks show an [E] badge.
- **iOS Verification**: Extension verification and OAuth run through ASWebAuthenticationSession.
- **Forced Update**: Force update when 3 or more stable releases behind.
- **Display**: Requests the highest display refresh rate on Android; fluid bouncing scroll physics on capable devices; shimmer skeletons for home feed and artist screens.
- **Hero Animation Toggle**: Setting to disable Hero animations.
- **Network Hardening**: DNS-over-HTTPS fallback and download retry hardening.

### Fixed

- **Safer File Writes**: All SAF and direct-mode downloads are staged then atomically promoted with fsync; FLAC, M4A, and AC-4 tags are written atomically; fixed the endless FLAC-write failures on misnamed files.
- **Native Worker Reliability**: Recovers from dead runs, keeps batches and retries intact across races, never deletes a published download over bookkeeping failures, and flushes queue persistence when the app is backgrounded.
- **Download History**: Persisted and reconciled reliably; completed downloads bridge into the library; library records persist before download completion.
- **Playlist Import Order**: Imported playlists keep their track order (#482).
- **Playback**: No auto-resume after an audio interruption while backgrounded; stale playback and SAF temp files cleaned up.
- **M4A Metadata**: stco/co64 chunk offsets shift correctly when the ilst tag resizes.
- **Extensions**: Data directory removed on uninstall, storage/credential writes serialized across runtimes, stale pending auth challenges expire, package and runtime lifecycle hardened, bounded file reads and cookie state.
- **Localization**: Deezer requests send Accept-Language so names follow the app language.
- **arm32 Stability**: Built with Go 1.26.5 for aligned cgo frames.
- **CSV Import**: Use State's context instead of a stale parameter (#460) — thanks @A831ARD0.

### Improved

- **Broad Performance Pass**: Streaming tag rewrites for Ogg and M4A, streamed PCM analysis, SAF scan results spill to disk, Go heap and image caches released on memory pressure, per-extension goja runtime pool, incremental queue persistence and ISRC index, byte-capped cover disk cache, TTL/ETag-cached update checks, gzip and TLS session resumption, backdrop blur gated by device capability, incremental DB auto-vacuum.
- **Codebase Health**: Large-scale deduplication across screens, providers, and the Go backend; dead code paths removed.

### Changed

- **Graduated from Beta**: Native download worker and Backup & Restore are now stable.
- **Terminology**: Extension "store" renamed to "repo" across all layers.

---

## [4.7.1] - 2026-07-02

### Added

- **Full Extension Metadata Embedding**: Full metadata and cover are embedded after extension downloads.
- **Lossless Conversion Options**: Dither and resampler options.
- **Verification Browser Preference**: Choose in-app or external browser for extension verification, with manual verification help when browser launch fails.

### Fixed

- **Convert Sheets**: Draggable and scroll-controlled bottom sheets.
- **Verification**: Defaults to the in-app browser first; native worker verification hands off to the interactive queue; signed-session auth bootstraps and clears pending state correctly.
- **AC-4**: Truncated sample entries are rejected safely.

---

## [4.7.0] - 2026-07-01

### Added

- **New Playback Experience**: Rebuilt built-in player with media integration, reorderable up-next queue, and playback stability fixes.
- **Track Previews**: Play short preview snippets from track lists.
- **Motion Artwork**: HLS motion-artwork header banners (Apple Music style) and audio-quality badges.
- **Backup & Restore (Beta)**: Settings, download history, library, and installed extensions.
- **Lossless Conversion Caps**: Cap bit depth/sample rate on lossless conversion, including album batch convert.
- **ReplayGain**: Opus R128 gain tags.
- **AC-4 Passthrough**: Download support for AC-4 streams.
- **Queue**: Tap a failed download to view its error details.
- **Filename Placeholders**: `{playlist_position}` placeholder.
- **Playlist Folders**: Rename action.
- **Network Setting**: Opt-in allow local/private network access.

### Fixed

- **Verification**: Retries tracked per service; signed session files scoped by endpoint and app context; early abort in fallback.
- **Lyrics**: Provider priority synced to backend, improved fallback and health handling.
- **Metadata**: Oversized cover art capped, QuickTime/MP4 tag support, native M4A ISRC/label writes, all edited fields read back from file.
- **Navigation**: Tapping an artist name navigates to the correct artist.
- **Compatibility**: Impeller disabled on Sony audio players and Vivante GPUs.
- **Fallback Quality**: Actual output format detected from audio codec; requested quality honored when the fallback provider recognizes it.

### Improved

- **Performance**: Optimized queue/library pagination, counts, scan, and extension runtime.

---

## [4.6.0] - 2026-06-14

### Added

- **WAV & AIFF Support**: Full metadata support with a settings-style metadata menu.
- **LyricsPlus Provider** and **ReplayGain batch scanning**.
- **French & German Locales**.
- **UI Polish**: Blurred backdrop playlist headers, frosted translucent bottom navbar, active downloads shown inside the library grid, actual lyrics source shown in metadata.

### Fixed

- **Downloads**: Selected provider honored when it equals the track source; fallback provider requests its own highest quality; iOS background task handling.
- **UI**: High-res cover in the track metadata header, centered modals on large screens, modernized edit-metadata and convert sheets, predictive-back page transition override.

### Removed

- **Concurrent Download Option**: Removed during the playback rework (returned in 4.8.0 with proper support).

---

## [4.5.6] - 2026-06-02

### Added

- **Cross-Extension Sharing**: Rebuilt sharing and queue controls; polished search empty state.

### Fixed

- **Sharing & Fallback Routing**: Cross-service sharing aligned with fallback routing.
- **Metadata**: Stricter matching, `embedLyrics` setting respected, improved Apple Music lyrics; album-only autofill and placeholder re-enrich regressions resolved.
- **Downloads**: Hardened error handling and re-enrich sidecars.
- **iOS**: Deployment target aligned for the file picker.

---

## [4.5.5] - 2026-05-15

### Added

- **5 New Lyrics Providers**.
- **Enhanced Audio Analysis**: Loudness, clipping, and spectral cutoff metrics, with rescan support after a cached result.
- **AAC Support**: AAC conversion and lossy download target.
- **Apple Music Word-Synced Lyrics**: Toggle for eLRC word sync.
- **Launch Announcements**: Remote-config announcements shown on app start.
- **History**: Codec format and bitrate persisted in download history.
- **MP4 Codec Detection**: FLAC/ALAC/EAC3/AC3/AC4 detected inside MP4 containers.
- **Library**: Scroll-to-top and scroll-to-bottom quick buttons.

### Fixed

- **No Fake Lossless**: Codec probes prevent lossy-to-lossless upscale conversions in every branch.
- **MP3 Lyrics**: Embedded via ID3v2.3 USLT frame.
- **FLAC**: Native muxer forced when decrypting to .flac output; native handling fixes.
- **SAF**: Extension-agnostic `.partial` staged filename.

---

## [4.5.1] - 2026-05-08

### Fixed

- **Native Worker**: Avoids the Android binder payload limit.
- **Extensions**: Missing-extension state shown for returning users.
- **Downloads**: `dataSync` foreground service type declared; default quality settings restored.
- **UI**: Settings editor white screens fixed; library search stabilized.

---

## [4.5.0] - 2026-05-06

### Changed

- **All Built-in Download Providers Retired**: Tidal, Qobuz, and Deezer now live as extensions with isolated runtimes. Install them from the Store to keep downloading.
- **Settings Reorganized**: Split into focused pages — thanks @Amonoman.

### Added

- **Android Native Download Worker (Experimental)**: Downloads continue reliably in the background.
- **Favorite Artists Collection**.
- **Extension Service Health**: Health indicators for extension services.
- **Download Deduplication Setting** — thanks @Amonoman.
- **New Look**: Google Sans Flex font and monochrome icon support.
- **Extension APIs**: `skip_fallback` capability, download dedup/ISRC/lyrics APIs, generic provider resolution, progress phases.
- **Metadata**: MusicBrainz album artist fallback; instrumental lyrics heuristic; audio duration exposed.
- **Home Feed**: Can be disabled.

### Fixed

- **iOS**: Security-scoped bookmarks for download directory persistence.
- **SAF**: Filenames and directory segments truncate safely at UTF-8 boundaries.
- **Native Worker**: Metadata embedding, notification progress, and history schema sync.
- **Localization**: Missing Crowdin locale variants mapped; unsupported locales fall back to English.

### Improved

- **Database-Backed Pagination**: Queue tab and local library migrated from in-memory lists to paginated database queries — much lower memory use on large libraries.
- **Performance**: Delta-mode native worker snapshots, reduced bridge/UI churn, improved queue resilience.

---

## [4.3.1] - 2026-04-14

### Added

- **Extension Output Control**: `preserveNativeOutputExtensions` capability; M4A converts to FLAC when the extension doesn't prefer native M4A output; extension download metadata carried through the host pipeline.

### Fixed

- **Container Handling**: `.mp4` treated as alias for `.m4a` throughout the download pipeline; `OutputExt` reset on extension→extension and extension→built-in fallback.
- **Provider Choice**: User's provider choice respected over source extension priority.
- **Tidal Metadata**: Copyright and album artist improved; DATE/YEAR tag sync fixed.

---

## [4.3.0] - 2026-04-13

### Added

- **Artist Search Filter** and normalized search filter handling.
- **Default Search Tab Preference**.
- **Native M4A ReplayGain** tag writing and SAF picker error handling.
- **Download Cancel**: Propagates to extension HTTP requests.

### Changed

- **Deezer Search via Extension**: Search flow moved out of the core app.
- **Extension Manifest**: `author` field removed.

### Fixed

- **iOS**: Extension OAuth callback handled.
- **M4A**: Existing metadata preserved during embed; ALAC quality parsing improved.
- **Extensions**: Shared link handling stabilized; genre falls back to extra metadata.

---

## [4.2.2] - 2026-04-06

### Added

- **Configurable Extension Download Fallback**.

### Changed

- **Deezer is now an Extension**: Moved from built-in service to installable extension.

### Fixed

- **Metadata**: Downloaded metadata persisted, re-enrich matching aligned with autofill, composer preserved across Qobuz and history, flat singles output preserved for extension releases.

---

## [4.2.1] - 2026-04-04

### Added

- **Metadata Enrichment**: Composer and track totals.

### Fixed

- **Crash Fix**: Stale audio service manifest entries removed (crashed on some devices).
- **Stability**: Hardened gomobile extension bindings, M4A cover retention, local convert format and library entries preserved, embedded metadata details preserved.

---

## [4.2.0] - 2026-04-04

### Added

- **ReplayGain Scanning** and APEv2 tag support.
- **Singles/EP Filename Format**: Separate format setting (#271).
- **Bulk Re-enrich Field Selection**: Choose which fields to update.
- **Resolve API**: With SongLink fallback.
- **Extension API**: `skipLyrics` manifest field; additional search/metadata API with separate rate limiting.

### Fixed

- **Multi-Artist Tags** (#288).
- **Qobuz 401 Errors**: API calls routed through an authenticated gateway.
- **Metadata**: Missing track/disc numbers from search downloads, ISRC validation to prevent ID leakage, label/copyright resolved from file metadata.
- **UI**: System navigation bar matches app theme.

### Improved

- **UI Smoothness**: Memoization, compute isolates, SQL-backed playlist picker, viewport-aware image caching.
- **Performance**: Incremental queue lookups, async cover cleanup, native JSON decoding on iOS.

### Removed

- **Legacy API Clients**: Including the Yoinkify fallback and an unused lyrics provider.

---

## [4.1.3] - 2026-03-30

### Added

- **Artist Tag Mode**: Setting with split Vorbis support.
- **Search & Filters**: Metadata filters and extended sort options; Qobuz album-search fallback; stable cover cache keys.

### Fixed

- **Samsung SAF Library Scan**, Qobuz album cover, and M4A metadata save.

---

## [4.1.2] - 2026-03-29

### Added

- **Batch Progress Dialog**: Replaces snackbars for batch operations.
- **Library**: Haptic feedback when swiping tabs; play button on playlist/library track tiles.

### Fixed

- **Extension Quality**: Tidal quality options used as fallback; DEFAULT quality normalized to prevent API failures.
- **ALAC**: `attached_pic` disposition for cover art embedding.
- **Downloads**: `START_NOT_STICKY` prevents DownloadService auto-restart.

### Improved

- **Track Matching**: Scoring-based ReEnrich selection; Spotify URLs routed through extensions.

---

## [4.1.1] - 2026-03-27

### Added

- **Extension Download Progress**: Byte-level progress tracking.
- **Spectrogram Cache**: Cached as PNG for instant loading on subsequent views.

### Fixed

- **UI**: Artist skeleton polish; SpectrogramView null crash when loading from PNG cache.
- **SAF**: `artist_album_flat` case added to relative output dir builder.

---

## [4.1.0] - 2026-03-26

Version numbering returns to 4.x, continuing from the 3.x rollback in 3.7.0.

### Added

- **Audio Quality Analysis**: Analysis widget with cached results.
- **Smart Service Selection**: Recommended download service auto-selected based on content source.
- **Search Result Sorting**.

### Changed

- **YouTube Downloads**: Extracted to the YouTube Music extension.

### Fixed

- **UI**: Skeleton visibility and artist header in light mode, store URL input flash on startup, unintended home reset on tab switch, embedded cover refresh.
- **Metadata**: Hi-res cover art for Tidal/Qobuz, album metadata override, FLAC metadata fallback for mismatched files, USLT lyrics detection.
- **Navigation**: Tidal/Qobuz items from Recent Access open built-in screens.

### Improved

- **Startup**: Lazy extension VM init and incremental startup maintenance.
- **Deezer Resolution**: Uses Tidal/Qobuz metadata; Qobuz skips SongLink when ISRC is already available.

---

## [3.9.0] - 2026-03-25

### Added

- **Built-in Tidal/Qobuz Search**: With a recommended service picker and a built-in search provider setting.
- **Home Feed Provider Setting**.
- **Tidal HIGH Restored**: AAC 320kbps lossy quality option (#242).
- **Full M4A Tag Engine**: Read engine with atom path fallback, metadata/cover embed across all screens, and library scan support.
- **Playlist Source Folders**: `createPlaylistFolder` setting for playlist folder prefixes.
- **Resilient Artist Matching**: Diacritic folding for loose artist name matching.

### Fixed

- **Localization**: Crowdin locale files consolidated, ICU plural warnings fixed.

---

## [3.8.8] - 2026-03-18

### Added

- **Tidal ISRC & Metadata Search**.

### Changed

- **Lyrics Providers**: Migrated to Paxsenix endpoints.

### Fixed

- **Extension Download Reliability** and Qobuz API integration.
- **Stability**: Library scan IDs, pause queue behavior, and a scan race condition.

---

## [3.8.7] - 2026-03-17

### Fixed

- **Queue**: Active downloads properly stop when pausing; queue-as-FLAC hides when all selected tracks are already FLAC and skips FLAC tracks from selection.
- **Downloads**: Already-downloaded tracks skipped in library folder download-all; Spotify track availability resolution improved.
- **Covers**: Deezer and Tidal cover art upgraded to max quality.
- **Library**: Auto-scan cooldown honored.

---

## [3.8.6] - 2026-03-16

### Added

- **Local Library Auto-Scan** option.

### Fixed

- **Re-downloads**: Tracks converted to a different format are no longer re-downloaded.
- **iOS**: Folder picker delayed until sheet dismiss; Afkar hosts updated.
- **UI**: Double horizontal padding removed in the store tab.

---

## [3.8.5] - 2026-03-16

### Added

- **FLAC/ALAC Bidirectional Lossless Conversion**.
- **Selective Auto-Fill**: Pick fields to auto-fill from online in the Edit Metadata sheet, with improved track resolution.
- **FLAC Redownload Queue**: Queue FLAC redownloads for local library tracks.
- **Opus 320kbps Quality** (Tidal HIGH tier removed; restored in 3.9.0).
- **Bulk Playlist Download**: Download multiple selected playlists — thanks @ViscousPot.
- **Playlist Import**: Playlist name auto-filled during import — thanks @ViscousPot.
- **Qobuz Afkar API Provider**: With request metadata preferred for consistent album grouping.

### Fixed

- **Wrong-Track Protection**: Resolved Tidal/Deezer tracks are verified against the download request before downloading.
- **Download All**: Skips already-downloaded tracks for albums and playlists.
- **Various Artists**: Album-level artist used instead of the first track's artist.
- **M4A/ALAC**: Cover art extracted for conversion, embedded lyrics detected, metadata and cover preserved in ALAC/M4A→FLAC conversion.
- **Batch Convert**: Target formats filtered by source formats.

---

## [3.8.0] - 2026-03-14

### Added

- **Qobuz & Tidal Metadata Search**: Built-in metadata search providers with priority-based unified search, full metadata API, URL parsers, and store support.
- **Auto-Enrich for Extension Downloads**: Metadata is automatically enriched.
- **Store Registry URL Management**: With iOS handler support and a cleaner store UI.
- **Provider Priority**: Deezer entry added to the priority UI.

### Fixed

- **Tidal**: Track resolution and playlist owner info.
- **iOS**: Stale built-in Spotify bridge handlers removed.

### Improved

- **Performance**: Optimized polling, progress caching, staggered warmup, snapshot-based library scan, SAF metadata reading, CUE sibling resolution, and startup initialization.
- **Localization**: Hardcoded strings replaced with l10n keys across 13 screens.

---

## [3.7.2] - 2026-03-07

### Changed

- **Amazon Music is now an Extension**: Amazon Music has been moved from a built-in service to a separate installable extension. Install the "Amazon Music" extension from the Store to continue using it.

### Fixed

- **Deezer Downloads Timing Out**: Deezer downloads were failing with "context deadline exceeded" on larger files. Now uses the proper download timeout, matching Tidal and Qobuz.
- **iOS Local Library Scan Fails**: Local library scanning was failing on iOS because the app lost access to user-picked folders after the FilePicker session ended. Implemented iOS security-scoped bookmark system:
  - When a library folder is picked on iOS, a security-scoped bookmark is created and persisted in settings (`localLibraryBookmark`)
  - Before each scan, the bookmark is resolved and security-scoped access is started; access is released in `finally` block after scan completes
  - `cleanupMissingFiles` also activates the bookmark before checking file existence on iOS
  - New `AppDelegate.swift` method channel handlers: `createIosBookmarkFromPath`, `startAccessingIosBookmark`, `stopAccessingIosBookmark`, `resolveIosBookmark`
  - New `PlatformBridge` methods: `createIosBookmarkFromPath()`, `startAccessingIosBookmark()`, `stopAccessingIosBookmark()`
  - All scan call-sites (Library Settings, Queue tab, Local Album screen) now pass the iOS bookmark to `startScan()`

### Added

- **Amazon Music Extension**: Available in `extension/Amazon-SpotiFLAC/` — same functionality as before, now as an installable extension.
- **Accessibility Tooltips**: Added localized tooltips to all `IconButton` and `PopupMenuButton` widgets across the entire UI for screen reader and long-press discoverability
  - Back buttons use `MaterialLocalizations.backButtonTooltip`
  - Close buttons use `MaterialLocalizations.closeButtonTooltip`
  - Menu buttons use `MaterialLocalizations.showMenuTooltip`
  - Search buttons use `MaterialLocalizations.searchFieldLabel`
  - Contextual actions use descriptive labels: "Play track", "Dismiss", "Clear search", "Change folder", "Refresh"
  - Screens affected: Album, Artist, Playlist, Downloaded Album, Local Album, Home, Search, Queue, Library Playlists, Library Tracks Folder, Setup, Tutorial, Track Metadata, Store, Extension Store Details, and all Settings sub-pages (About, Appearance, Cache Management, Donate, Download, Extensions, Extension Detail, Library, Log, Options, Provider Priority)
- **Semantics Wrappers**: Added `Semantics` widgets to interactive elements that previously had no accessibility information
  - Album tiles in Artist screen: announces selection state and album name
  - Recently downloaded track tiles in Home tab: announces track name and artist
  - Explore items (albums/artists/playlists) in Home tab: announces item type and name
  - Color palette picker in Appearance settings: announces selected state and color hex value
  - Download button demo in Tutorial screen: added `ExcludeSemantics` on icon to prevent duplicate screen reader announcements
  - Queue tab playlist cards: announces playlist name and item count
  - Queue tab downloaded album cards: announces album name, artist, and track count
  - Queue tab local album cards: announces album name, artist, and track count
  - Queue tab play button on completed downloads: announces track name and artist with `ExcludeSemantics` on icon
  - Queue tab download status indicators: "Finalizing download", "Download completed", "Downloaded file missing" labels with `ExcludeSemantics` on icons

### Improved

- **Code Formatting**: Reformatted and corrected indentation across multiple files to comply with Dart style guidelines
  - `extension_detail_page.dart`: Fixed `SliverAppBar` and all subsequent slivers indentation (was 2 spaces short)
  - `log_screen.dart`: Fixed `SliverAppBar` indentation alignment
  - `donate_page.dart`: Reformatted ternary expressions and `_cr` function body
  - `library_tracks_folder_screen.dart`: Minor line-break formatting

---

## [3.7.1] - 2026-03-06

### Added

- **Deezer Download Service**: Deezer is now available as a built-in download service (FLAC CD Quality).
- **Smarter YouTube Downloads**: If the YouTube Music extension is installed, the app now uses it first to find the correct song — more accurate than SongLink, especially for new releases.
- **Songs-Only Search Filter**: YouTube Music extension search now filters results server-side, so you only get actual songs — no music videos or covers mixed in.
- **Qobuz Squid.wtf Fallback**: Added Squid.wtf as an additional Qobuz download provider.
- **Qobuz Search Fallback**: If Qobuz API search returns nothing, the app now tries the Qobuz web store as a backup to find the track.
- **Better ISRC Lookup**: Tracks can now be resolved via ISRC even without a Spotify ID, using Deezer as an intermediary.

### Fixed

- **Download Queue Stability**: Fixed duplicate queue item IDs, cancel not working reliably, and "Clear All" not properly stopping active downloads.
- **Queue Restore on Restart**: Duplicate or broken queue item IDs are now auto-fixed when the app restarts.

### Changed

- **Update Checker**: The app can now detect updates across all versions, not just within the same major version.
- **Localization Cleanup**: Cleaned up and consolidated translation files across all 13 supported languages.

---

## [3.7.0] - 2026-03-04

Hey everyone, thank you so much for sticking with SpotiFLAC Mobile.

Starting from this release, we're rolling the version back from **v4.x to v3.x**.

### Removed

- **Internal Audio Player** — Removed `just_audio`, `audio_service`, and `audio_session` dependencies entirely. The internal playback engine (smart queue, media notification, shuffle/repeat, lyrics sync, prefetch, playback state persistence) has been completely removed. Playback now delegates to the system's external player.
- **PlaybackItem Model** — No longer needed without internal playback.
- **MiniPlayerBar Widget** — Removed the in-app mini player UI.
- **Media Notification Controls** — Removed notification drawables (`ic_stat_favorite`, `ic_stat_favorite_border`) and the `keep.xml` resource file.
- **Player Mode Setting** — The `playerMode` setting has been removed since external player is now the only mode.
- **Online Playback Feature** — Online streaming mode, DASH pipeline, and related components introduced in v4.0.0 are gone from the main branch.

### Changed

- **MainActivity** now extends `FlutterFragmentActivity` directly (previously `AudioServiceFragmentActivity`).
- **PlaybackController** simplified from ~1200 lines to ~87 lines — now only resolves local file paths and opens them via external player.
- **ProGuard rules** cleaned up — removed audio_service/just_audio/audio_session rules.
- **Qobuz** migrated to MusicDL API (Thanks @Ruubiiiii for Hosting the API).

### Note
There are three main reasons behind this decision:

   1. **Respecting the API providers** — After giving it some thought, we realized that the streaming feature was indirectly hurting the API providers who have been generous enough to make their services available. They already offer streaming directly on their own websites, and it only feels right to direct streaming usage back to their platforms.

   2. **Long-term sustainability** — We want SpotiFLAC to be around for as long as possible. Keeping certain features in the app could attract unwanted attention and put the project's continued existence at risk. Removing them is a proactive step to keep things running smoothly for everyone.

**Still want online playback? Check out these services:**
- [DabMusic](https://dabmusic.xyz)
- [SquidWTF](https://tidal.squid.wtf)

Thank you for your understanding and continued support. This decision was made to ensure the long-term sustainability of the app and to respect the ecosystem that has been supporting SpotiFLAC all along. You guys are the best, and we truly appreciate each and every one of you!

---

## [3.6.0] - 2026-02-19

### Added

- **Library Tab Redesign**: Wishlist, Loved, and individual Playlist collections now appear as unified list/grid items in the "All" tab alongside tracks, replacing the old "My Folders" horizontal card section
- **Drag-and-Drop Track Categorization**: Long-press-drag tracks onto playlist items to add them to that playlist; when multiple tracks are selected and one is dragged, all selected tracks are added to the target playlist
  - Drag feedback widget displays multi-select count badge
- **Playlist Multi-Select Deletion**: Long-press playlists to enter selection mode, select multiple playlists, and batch-delete all selected at once via a dedicated selection bottom bar
- **Track Categorization System**: Tracks added to any playlist are automatically hidden from the main tracks list; removing a track from a playlist or deleting the playlist makes the track reappear — no actual file deletion ever occurs
- **Create Playlist Button**: New "+" `TextButton.icon` in Library tab header with dynamic theme colors, replacing the old "Select" button
- **Track Options Bottom Sheet**: Rewrote `TrackCollectionQuickActions` from inline action buttons to a single styled bottom sheet with track header (cover, title, artist), divider, and option tiles matching `DownloadServicePicker` visual style
- **Library Tracks Folder SliverAppBar**: Wishlist, Loved, and Playlist detail screens now feature a collapsible SliverAppBar with cover art (45% viewport height, parallax, gradient overlay), mode-specific icons (bookmark/heart/queue_music), title, and track count badge
- **Custom Playlist Cover Images**: Users can set custom cover images for playlists via long-press menu or camera icon in SliverAppBar
  - Covers stored locally in app support directory with priority: custom cover > first track URL > icon fallback
  - Cover options bottom sheet with change/remove actions
  - Playlist list screen shows cover thumbnails
- **Long-Press Context Menus**: Track tiles in library folders and playlist list items now use long-press for styled bottom sheet context menus instead of trailing icon buttons, matching platform conventions
- **Wishlist Quick Download**: Tapping a track in Wishlist opens quality picker (respects "Ask quality before download" setting) and starts download
- **Playlist Track Playback**: Tapping a downloaded track in a Playlist opens it in the device's external music player via `openFile()` with file existence check
- **Collapsible AppBar on Playlist List Screen**: Playlist list screen now uses a collapsible SliverAppBar matching Settings sub-page style (animated title size 20→28px, animated left padding 56→24px) for visual consistency
- **`UnifiedLibraryItem.collectionKey` Getter**: Efficient playlist membership checking without constructing a full `Track` object
- **Multi-select Share**: Share multiple downloaded/local tracks at once from the selection bottom bar
  - Supports SAF content URIs via native `ACTION_SEND_MULTIPLE` intent
  - Supports regular file paths via SharePlus
  - Available in Downloaded Album, Local Album, and Queue tab screens
- **Multi-select Batch Convert**: Convert multiple selected tracks to MP3 or Opus in one operation
  - Bottom sheet UI with format (MP3 / Opus) and bitrate (128k / 192k / 256k / 320k) selection
  - Full SAF support: copies to temp, converts, writes back, deletes original, updates history
  - Progress and result snackbar feedback during conversion
  - Available in Downloaded Album, Local Album, and Queue tab screens
- **Native `shareMultipleContentUris`**: New Android `ACTION_SEND_MULTIPLE` handler in `MainActivity` for sharing multiple SAF content URIs
- **Localization**: Added selection share/convert strings to all 13 supported locales (`selectionShareCount`, `selectionShareNoFiles`, `selectionConvertCount`, `selectionConvertNoConvertible`, `selectionBatchConvertConfirmTitle`, `selectionBatchConvertConfirmMessage`, `selectionBatchConvertProgress`, `selectionBatchConvertSuccess`)
- **Localization**: Added library collection l10n keys (`trackOptionAddToLoved`, `trackOptionRemoveFromLoved`, `trackOptionAddToWishlist`, `trackOptionRemoveFromWishlist`, `libraryTracksUnit`, `collectionPlaylistChangeCover`, `collectionPlaylistRemoveCover`)
- **Global Network Compatibility Mode**: New Download settings toggle to help restricted/ISP-filtered networks
  - Applies to backend API requests (not SongLink-only)
  - Enables HTTP scheme fallback and optional insecure TLS behavior in one switch
  - Synced end-to-end across Flutter settings, platform channel (Android/iOS), and Go backend

### Changed

- **Removed "My Folders" Section**: Horizontal card section removed from Library tab header; collections are now inline items in the unified main list/grid
- **Playlist Subtitle Simplified**: Playlist items now show "N tracks" instead of "Playlist • N tracks"
- **Pinned App Bar on All Detail Screens**: `SliverAppBar` changed from `pinned: false` to `pinned: true` in 6 detail screens (album, downloaded album, local album, playlist, track metadata, library tracks folder) so the app bar stays visible when scrolling
- **Local Album Multi-select Action Updated**: Replaced batch `Share` action with batch `Re-enrich`
  - Local album selection bar now uses `Re-enrich` + `Convert` actions
  - Added batch re-enrich processing for local tracks (FLAC native path and MP3/Opus FFmpeg path, including SAF write-back flow)
  - After batch re-enrich completes, local library is refreshed via incremental scan so updated metadata appears in UI immediately
- **Queue Multi-select Local Action Updated**: Queue selection bar now switches the first action to `Re-enrich` when selected items are local-only
  - If selection contains downloaded or mixed items, action remains `Share`
  - Local-only selection now supports batch re-enrich with the same native/FFmpeg + SAF flow and auto-refreshes local library metadata after completion
- **SongLink Network Option Scope Expanded**: The previous SongLink compatibility path now routes through global network compatibility controls so all supported backend API clients can benefit under problematic networks
- **Removed Per-Track Action Buttons**: Album, playlist, home, artist, and search screens no longer show individual download/add buttons on each track tile; all actions accessed via `TrackCollectionQuickActions` bottom sheet
- **Loved SliverAppBar Always Shows Heart Icon**: Loved tracks folder always displays the heart icon as cover, never uses first track's cover art (like Spotify's Liked Songs)
- **Wishlist Long-Press Menu Conditional Actions**: "Add to Playlist" option only appears when the track is already downloaded
- **Loved Track Tap Disabled**: Tapping a track in the Loved folder performs no action (long-press for options only)
- **Removed Duplicate Create Playlist Button**: Removed `+` IconButton from playlist list screen AppBar since the FAB already serves the same purpose
- **`coverImagePath` Field on `UserPlaylistCollection`**: Model now supports nullable custom cover path with `copyWith` using `String? Function()?` pattern for explicit null assignment

### Fixed

- **Local Cover Path Handling**: All cover image renderers (Library tab, playlist detail screen hero cover, per-track tiles, options bottom sheet) now detect whether `coverUrl` is a URL or local file path and use `Image.file` for local paths instead of `CachedNetworkImage`
- **Empty Playlists Now Clickable**: Empty playlist items in Library tab can now be tapped to navigate to their detail screen
- **RenderFlex Overflow**: Fixed overflow in unified library item Row layout when track metadata text was too long
- **SAF FD Permission Denied on Tidal Downloads**: Fixed `failed to create file: open /proc/self/fd/*: permission denied` on some devices/providers
  - Android SAF bridge now hands off detached raw FD (`output_fd`) to Go instead of forcing procfs path reopen
  - Go output writer includes safer procfs fallback behavior for providers that reject truncate semantics
- **Batch Convert Lyrics Embedding Gap**: Batch convert in Downloaded Album, Local Album, and Queue now preserves/adds lyrics consistently like single convert
  - Reuses embedded lyrics when available
  - Falls back to sidecar `.lrc` when present
  - Falls back to online lyrics fetch and injects into conversion metadata when embedding is enabled

---

## [3.6.9] - 2026-02-17

### Added

- **YouTube Bitrate Presets**: YouTube bitrate selection now uses supported presets only
  - Opus: 128 / 256 kbps
  - MP3: 128 / 256 / 320 kbps
- **Go Test Coverage for YouTube Quality Parsing**: Added tests for supported-bitrate normalization behavior
- **Localization for YouTube Bitrate UI**: Added localized strings (EN/ID) for YouTube bitrate titles and labels

### Fixed

- **Cover Image Cache Clear Not Working**: Clearing "Cover image cache" now performs a full on-disk wipe, clears in-memory image cache, and reinitializes cache manager state
  - Prevents stale/orphaned cache files from keeping the same storage usage after clear
- **YouTube Queue Fallback Quality Mismatch**: Queue fallback now normalizes YouTube quality IDs so conversion paths use valid bitrate format IDs

### Changed

- **Default Lyrics Behavior**: `Apple/QQ Multi-Person Word-by-Word` is now OFF by default for new installs
- **Removed Dynamic YouTube Bitrate Mode**: Arbitrary values are now normalized to nearest supported Spotube preset across settings, picker, queue fallback, and Go backend parser
- **Lyrics Embedding Control**: Users can now disable the embedded-lyrics process from settings (`Embed Lyrics` off)

---

## [3.6.8] - 2026-02-14

### Added

- **Lyrics Source Tracking**: Track Metadata screen now displays the source of loaded lyrics (LRCLIB, Musixmatch, Netease, Apple Music, QQ Music, Embedded, or Extension)
  - New `getLyricsLRCWithSource` API returns lyrics with source metadata
  - Source badge appears below lyrics section in Track Metadata screen
- **Dedicated Lyrics Provider Priority Page**: Lyrics providers can now be configured from a dedicated settings page with full-screen reorderable list
  - Replaced inline bottom sheet with `LyricsProviderPriorityPage`
  - Cleaner UI with provider descriptions and priority ordering
- **Paxsenix Integration**: Added Paxsenix API as official lyrics proxy partner for Apple Music, QQ Music, Musixmatch, and Netease sources
  - Listed in About page and Partners page on project site
  - README updated with partner attribution

### Fixed

- **LRC Background Vocal Preservation**: Apple Music/QQ Music `[bg:...]` background vocal tags are now preserved during LRC parsing instead of being stripped
  - Background vocals attach to the previous timed line in exported LRC files
- **LRC Display Improvements**:
  - Inline word-by-word timestamps (`<mm:ss.xx>`) are stripped from lyrics display
  - Speaker prefixes (`v1:`, `v2:`) are removed for cleaner display
  - Multi-line background vocals converted to readable secondary vocal lines
- **Apple Music Lyrics Case Sensitivity**: Fixed `lyricsType` comparison to use case-insensitive matching for "Syllable" type

### Changed

- Track Metadata lyrics fetching now uses `getLyricsLRCWithSource` for consistent source attribution across embedded and online lyrics

---

## [3.6.7] - 2026-02-13

### Added

- "Advanced Filename Templates" - new placeholders for custom track/disc formatting and date patterns
  - `{track_raw}` and `{disc_raw}` - unpadded raw numbers
  - `{track:N}` and `{disc:N}` - zero-padded to N digits (e.g. `{track:02}` → `01`)
  - `{date}` - full release date from metadata
  - `{date:%Y-%m-%d}` - date formatting with strftime patterns
  - "Show advanced tags" toggle in Settings > Download > Filename Format to reveal these placeholders
- Low-RAM / ARM32-only device profiling - detects constrained devices at startup and reduces image cache (120 items / 24 MiB) and disables overscroll effects for smoother performance
- Responsive selection bar on artist screen - switches to compact stacked layout on narrow screens (< 430dp) or large text scale (> 1.15x)
- Quality picker dialog before downloading individual tracks from artist screen (when "Ask quality before download" is enabled)
- Project website with GitHub Pages deployment workflow
  - Mobile burger menu navigation for all site pages
- Go filename template test suite
- "Lyrics Provider" extension type - extensions can now provide lyrics (synced or plain text) via `fetchLyrics()` function
  - Lyrics provider extensions are called before built-in providers, giving extensions highest priority
  - New `lyrics_provider` manifest type alongside `metadata_provider` and `download_provider`
  - Shows "Lyrics Provider" capability badge on extension detail page
- "Lyrics Providers" settings - configurable provider cascade order and per-provider options
  - Reorderable provider list: LRCLIB, Musixmatch, Netease, Apple Music, QQ Music
  - Netease: toggle translated/romanized lyrics appending
  - Apple Music / QQ Music: multi-person word-by-word speaker tags
  - Musixmatch: selectable language code for localized lyrics
- "Documentation Search" - global search modal on all site pages
  - Opens with Ctrl+K / Cmd+K / `/` keyboard shortcuts on every page
  - Search button with bordered pill styling in desktop nav and mobile hamburger menu
  - On non-docs pages, search results navigate to the docs page at the matching section
  - Full keyboard navigation: arrow keys, Enter to select, Esc to close

### Fixed

- Fixed ICU plural syntax errors in DE, ES, PT, RU translations - incorrect `=1` clause was causing missing plural forms
- Fixed featured-artist regex incorrectly splitting on `&` character (e.g. "Simon & Garfunkel" was being split) - removed `&` from separator pattern
- Fixed `{date}` placeholder not working in filename templates - release date was not being passed to the template builder across all providers (Amazon, Qobuz, Tidal, YouTube, extensions)

### Changed

- Improved Go backend metadata handling - filename builder now supports fallback metadata keys and automatic type conversion for more robust template rendering
- Extension providers now pass full metadata set to filename builder (track, disc, year, date, release_date)
- Updated translations: added filename advanced tags strings (EN, ID), regenerated all locale dart files
- Updated app screenshot assets

---

## [3.6.6] - 2026-02-12

### Added

- "Filter Contributing Artists in Album Artist" setting - strips featured/contributing artists from Album Artist metadata tag
- Library scan notifications (Android and iOS) - shows progress, completion, failure, and cancellation status
- Collapsible "Artist Name Filters" section in download settings UI

### Fixed

- Fixed downloads not working on iOS - missing `downloadByStrategy` and `downloadFromYouTube` method channel handlers in AppDelegate.swift
- Fixed extended metadata (genre, label, copyright) lost during service fallback (e.g. Tidal unavailable, falls back to Qobuz) - Go backend now enriches metadata from Deezer by ISRC before download and preserves it through the fallback chain
- Fixed local library showing incorrect "16-bit" quality label for lossy formats (MP3, Opus) - now displays actual bitrate (e.g. "MP3 320kbps")
- Fixed inaccurate Opus/Vorbis duration calculation (e.g. 4:11 showing as 8:44) - now reads granule position from last Ogg page for precise duration
- Fixed MP3 duration/bitrate inaccuracy for VBR files - added Xing/Info and VBRI header parsing with MPEG2/2.5 bitrate table support
- Fixed Track Metadata screen showing scan date instead of file date for local library items
- Fixed SAF content URI paths displayed as raw `content://` strings in Track Metadata - now shows human-readable paths

### Changed

- Removed legacy iOS download handlers (`downloadTrack`, `downloadWithFallback`, `downloadFromYouTube`) - iOS now uses `downloadByStrategy` only
- Updated translations from Crowdin (all 14 languages)

---

## [3.6.5] - 2026-02-10

### Highlights

- **Audio Format Conversion**: Convert between FLAC, MP3, and Opus directly from Track Metadata screen with full metadata and cover art preservation
- **PC v7.0.8 Backend Merge**: Adopts several Go backend improvements from SpotiFLAC PC v7.0.8 including Amazon encrypted stream support, SpotFetch metadata fallback, and Qobuz API update
- **Amazon Music Re-enabled**: Amazon provider back in service with new API

### Added

- "Use Primary Artist Only" setting: strips featured artists from folder names (e.g. "Justin Bieber, Quavo" becomes "Justin Bieber") for cleaner folder organization
  - Supports separators: `, ` `;` `&` `feat.` `ft.` `featuring` `with` `x`
  - Available in Settings > Download > below "Use Album Artist for folders"
- Audio format conversion from Track Metadata screen
  - Convert between FLAC, MP3, and Opus formats (any direction)
  - Selectable bitrate: 128k, 192k, 256k, 320k
  - Full metadata and cover art preservation during conversion
  - Confirmation dialog before converting (original file deleted after)
  - SAF storage support: copies to temp, converts, writes back via SAF
  - Download history automatically updated with new file path
- Unified download request contract (`DownloadRequestPayload`) for all providers/flows
  - Includes full superset fields: lyrics mode, genre/label/copyright, provider IDs, SAF params, cover/quality settings
  - Added strategy flags in payload: `use_extensions`, `use_fallback`
- New Go unified router entrypoint: `DownloadByStrategy(requestJSON)`
  - Routing priority: YouTube service -> extension fallback -> built-in fallback -> direct service
- New Android method channel handler: `"downloadByStrategy"` -> `Gobackend.downloadByStrategy(...)`
- SpotFetch metadata fallback integration for Spotify-blocked regions
  - New backend client for `sp.afkarxyz.qzz.io/api`
  - Automatic fallback in Spotify metadata fetch path when primary source fails
- Lyrics extraction now supports MP3 (ID3v2) and Opus/OGG (Vorbis comments) in addition to FLAC
  - Includes heuristic detection of lyrics stored in Comment fields
- Edit Metadata now supports manual cover selection (pick/replace cover image) and embeds it into audio tags on save
- Save Lyrics now shows an immediate in-progress snackbar (`Saving lyrics...`) so users know the operation has started

### Changed

- Merged several Go backend improvements from SpotiFLAC PC v7.0.8: Amazon new API with encrypted stream/decryption support, SpotFetch metadata fallback for Spotify-blocked regions, multi-format lyrics extraction (MP3/Opus/OGG), Qobuz Jumo API update.
- Download queue execution now builds one payload and uses a single bridge entrypoint (`PlatformBridge.downloadByStrategy`) instead of branching into multiple bridge methods
- Dart `downloadByStrategy` now sends a single request to Go (`downloadByStrategy` channel); routing concern is centralized in Go backend
- Legacy Dart bridge methods (`downloadTrack`, `downloadWithFallback`, `downloadWithExtensions`, `downloadFromYouTube`) are now thin wrappers and marked `@Deprecated`
- Qobuz downloader updated to latest Jumo API contract (`/get` endpoint, required headers)
- Amazon download flow now returns `decryption_key` from Go and performs decryption in Flutter (local file + SAF paths)
- Amazon now uses the new `amzn.afkarxyz.qzz.io` API flow (ASIN-based track endpoint + legacy fallback) with encrypted stream support
- Amazon ASIN extraction rewritten with robust URL/query-param parsing and regex fallback
- Amazon provider re-enabled in download service picker and download settings (alongside Tidal, Qobuz, and YouTube picker flow)
- Track Metadata cover UI now refreshes from the embedded file after Edit Metadata/Re-enrich, so the displayed art matches actual file tags
- Edit Metadata cover section moved to the top of the form and now previews current embedded cover before replacement (plus selected replacement preview)
- Edit Metadata cover preview enlarged (120px to 160px) with shadow, side-by-side layout for current vs selected cover, and label repositioned below image

### Fixed

- Fixed lyrics mode "External .LRC" still embedding lyrics into metadata - `lyrics_mode` was not being sent to Go backend for single-service downloads and YouTube provider, causing Go to default to "embed"
- Fixed `flutter_local_notifications` v20 breaking changes - migrated all `initialize()`, `show()`, and `cancel()` calls from positional parameters to named parameters
- Fixed SAF duplicate folder bug: concurrent batch downloads creating empty folders with `(1)`, `(2)`, `(3)` suffixes - added synchronized lock to `ensureDocumentDir` in Kotlin with duplicate detection and cleanup
- Track Metadata lyrics section now hides "Embed Lyrics" when lyrics are already embedded in file, preventing redundant embed attempts
- Fixed lyrics embed path to support FLAC/MP3/Opus consistently (including SAF files) without forcing unsupported parser paths
- Inconsistent parameter parity across download paths
  - `downloadWithExtensions` now carries `copyright`
  - YouTube path now carries `embed_max_quality_cover` and metadata parity fields
- Inconsistent success response metadata between direct/fallback flows
  - Added shared Go response builder for `DownloadTrack` and `DownloadWithFallback`
  - Success responses now consistently include `genre`, `label`, `copyright`, and `lyrics_lrc`
- YouTube success response now also includes extended metadata fields (`cover_url`, `genre`, `label`, `copyright`) for parity with other providers
- Fixed `Save Lyrics` crash on Android (`java.lang.Integer cannot be cast to java.lang.Long`) by normalizing `duration_ms` channel argument as `Number -> Long`
- Fixed FLAC Re-enrich cover edge case where metadata could be written without cover when temp cover file creation failed; FLAC cover embed now uses in-memory bytes and verifies cover after write
- Fixed FLAC picture-block embed robustness by detecting image MIME via magic bytes (JPEG/PNG/GIF/WEBP) instead of relying on filename extension
- Fixed MP3/Opus metadata rewrite flows to preserve existing embedded cover when no new cover is available
- Fixed Library tab cover not updating after manual cover edit/re-embed for downloaded tracks
  - Queue/Library now prefers embedded cover art extracted from local files (not just cached `coverUrl`)
  - Added per-track extraction cache with file-modification invalidation so updated embedded art is reflected in Library
  - Extraction is now on-demand for edited tracks only (not full-library reload)
  - Returning from Track Metadata now refreshes cover cache only for the affected track
  - Cover refresh is now skipped when file modification time is unchanged, removing unnecessary flash when simply opening/closing metadata screen
- Fixed repeated cover preview extraction in Track Metadata screen (`track_cover_preview_*`) causing visible flash when reopening
  - Added in-memory preview cache keyed by file path so reopening metadata reuses existing preview without re-extract
  - Cache validation uses file modification time for filesystem paths; SAF paths are refreshed only after successful edit actions
  - Queue/Library now also compares SAF file last-modified (`getSafFileModTimes`) before refreshing embedded-cover cache
  - Preview cache key is now stable per track item (not volatile temp SAF path), eliminating false cache misses on SAF-backed files
  - Track Metadata no longer auto-extracts cover preview on every screen open; extraction now runs only after actual edit/re-enrich changes (or when explicitly forced)
- Track metadata edits/re-enrich now sync updated tags back into `downloadHistoryProvider` + SQLite history rows
  - Non-Library screens that read download history (Home/album/history views) now reflect updated title/artist/album/tags without manual rescan
  - Track Metadata back-navigation now returns an explicit update result after successful edits/re-enrich, enabling History-tab cover refresh fallback when SAF timestamps are unreliable

### Performance

- Configured Flutter image cache limits (240 entries / 60 MiB) and added `ResizeImage` wrappers for cover art precaching across all screens, reducing peak memory usage on cover-heavy pages
- Added LRU eviction to Deezer cache with configurable max entries per cache type (search/album/artist/ISRC) and periodic expired-entry cleanup to prevent unbounded memory growth in long sessions
- Download progress notifications are now normalized (2-decimal progress, 1-decimal speed, 0.1 MiB byte steps) and deduplicated by track/artist/percent/queue-count, reducing notification overhead during batch downloads
- Each queue item now uses a dedicated `ConsumerWidget` with per-item `.select()` instead of rebuilding the entire list on any item change; items are wrapped in `RepaintBoundary` for paint isolation
- Queue/Library search indexes are now built on-demand per item instead of upfront for all items, with bounded LRU caches (max 4000 entries)
- `copyWith` now preserves derived lookup indexes (ISRC map, track key set) when items list is unchanged, avoiding O(n) rebuild on every scan progress update
- Scan progress polling now compares values before calling `setState`, skipping unnecessary widget rebuilds when nothing changed
- Added in-flight flag to download progress and library scan polling to prevent concurrent timer callbacks from overlapping
- New `DownloadedEmbeddedCoverResolver` service replaces per-screen cover extraction logic with a shared bounded cache (160 entries), mod-time validation, and throttled refresh checks
- Multiple embedded cover change callbacks are now coalesced into a single frame via `addPostFrameCallback`, preventing redundant rebuilds
- Downloaded album screen now caches filtered/sorted track lists and reuses them when the source data reference is unchanged
- Home tab recent downloads now use single-pass aggregation instead of building full per-album lists, and store only IDs instead of full item objects for the clear-all action
- Removed duplicate `_downloadedSpotifyIds` Set and `_isrcSet` (both now use existing map lookups), removed unused `_isTyping` state in home tab
- Track cache pre-warming is now capped at 80 tracks per request to avoid excessive backend calls on large playlists
- About page contributor avatars now use `memCacheWidth`/`memCacheHeight` to decode at display size instead of full resolution
- Orphaned download cleanup now checks file existence in parallel (chunk 16) instead of sequentially
- Local library `findByTrackAndArtist` now uses O(1) map lookup (`_byTrackKey`) instead of O(n) linear scan
- Local library database load and SharedPreferences fetch now run in parallel
- Legacy mod-time backfill now uses chunked parallel `File.stat` (chunk 24) with per-chunk cancel check
- Downloaded album screen now caches disc grouping, sorted disc numbers, common quality, and embedded cover path with reference-identity invalidation
- Local album screen common quality is now computed once during cache rebuild instead of per-build
- Batch delete in album screens now uses O(1) map lookup (`tracksById`) instead of `.where().firstOrNull`
- Cache management page now fires all async init calls in parallel and uses chunked async directory deletion (chunk 24)
- Cover resolver preview file existence check is now throttled (2.2s interval) to reduce synchronous I/O in build path
- History and library database DELETE operations are now chunked (500 per batch) to stay within SQLite variable limits
- Library database `cleanupMissingFiles` now checks file existence in parallel (chunk 16) and deletes in batched SQL

### Security

- All logs (Go and Dart) now automatically redact Bearer tokens, access/refresh tokens, client secrets, API keys, and passwords using regex-based sanitization before storage
- Extension auth URLs are now validated for HTTPS-only, no embedded credentials, and no private/local network targets before opening
- Auth URLs in logs are summarized to scheme+host+path only (query params stripped) to prevent token leakage; token exchange error bodies are truncated and sanitized
- Extension HTTP requests now block URLs with embedded credentials (`user:pass@host`)
- Extension storage files changed from `0644` to `0600` (owner-only read/write)
- All SAF relative directory paths are now sanitized per-segment with `.`/`..` filtering; all user-provided file names pass through `sanitizeFilename()` before use
- Extension ID is sanitized before building download destination path
- Log export device info now shows Build ID and Security Patch level instead of masked Device ID

### Technical

- Centralized request serialization in `PlatformBridge` via shared invoke helper and unified payload model
- Go strategy router normalizes incoming service casing before dispatch
- Extension runtime: `customSearch` now passes query/options via VM globals instead of string interpolation, preventing parser edge cases on certain devices
- Extension runtime: JS panic handler now logs full stack trace for easier debugging
- `DownloadQueueLookup` expanded with `byItemId` map and `itemIds` list for O(1) queue item access from UI
- Non-error/non-fatal log entries are now skipped entirely (not just hidden) when detailed logging is disabled, reducing buffer growth and Go log polling overhead

### Removed

- Buy Me a Coffee references removed from donate page, FUNDING.yml, README, and all localization files (account suspended)

---

## [3.6.0] - 2026-02-09

### Highlights

- **YouTube Provider (Lossy)**: New download option via Cobalt API for tracks not available on lossless services
  - Opus 256kbps (recommended) or MP3 320kbps quality options
  - Full metadata embedding: cover art, title, artist, album, track/disc number, year, ISRC
  - Lyrics fetching from lrclib.net with embed and external .lrc support
  - Works as fallback when Tidal/Qobuz/Amazon downloads fail
- **Edit Metadata**: Edit embedded metadata directly from the Track Metadata screen (FLAC, MP3, Opus)
  - Editable fields: Title, Artist, Album, Album Artist, Date, Track#, Disc#, Genre, ISRC
  - Advanced fields: Label, Copyright, Composer, Comment
  - FLAC: native Go writer, MP3/Opus: FFmpeg-based writer
  - UI refreshes in-place after save without needing to re-open the screen
  - iOS and Android support

### Added

- Save Cover Art: download high-quality album art as standalone .jpg from track metadata screen
- Save Lyrics (.lrc): fetch and save lyrics as standalone .lrc file without downloading the song
- Re-enrich Metadata: re-embed metadata, cover art, and lyrics into existing audio files without re-downloading (FLAC native, MP3/Opus via FFmpeg)
- Re-enrich now supports local library items: searches Spotify/Deezer by track name + artist to fetch complete metadata from the internet, then embeds cover art, lyrics, genre, label, and all tags into the file
- YouTube download provider using Cobalt API with SongLink/Odesli integration for Spotify/Deezer ID → YouTube URL conversion
- SpotubeDL as fallback Cobalt proxy when primary API fails
- YouTube video ID detection for YT Music extension compatibility
- Parallel cover art and lyrics fetching during YouTube download
- Queue progress now shows "X.X MB" instead of "0%" for streaming downloads where total size is unknown (Cobalt tunnel mode)
- Full metadata pipeline for YouTube downloads: cover art, lyrics, title, artist, album, track#, disc#, year, ISRC

### Changed

- Removed Tidal HIGH (lossy AAC) quality option - use YouTube provider for lossy downloads instead
- Simplified download service picker by removing dead lossy format code
- Removed Amazon from download settings UI (now only used as automatic fallback)
- Cleaned up dead disabled-chip code in download service selector

### Fixed

- Fixed `error.api.youtube.login` by using YouTube Music URLs instead of regular YouTube URLs for Cobalt requests
- Fixed SongLink to prioritize `youtubeMusic` platform URL over `youtube` for Cobalt compatibility
- Fixed YouTube metadata not being overwritten by setting `DisableMetadata: true` in Cobalt requests
- Fixed ISRC validation in metadata enrichment flow - invalid ISRCs no longer trigger failed Deezer lookups
- Fixed YouTube metadata enrichment to work like other providers (SongLink Deezer ID extraction, proper metadata embedding)
- Go metadata parsers now read Composer, Comment, Label, Copyright from FLAC, MP3 (ID3v2.2/v2.3/v2.4), and Opus/OGG files
- Added proper COMM frame parser for ID3v2 (handles language code + description prefix correctly)
- Fixed Re-enrich Metadata failing on SAF storage files (`content://` URIs) - Kotlin now copies SAF file to temp, Go processes temp file, then writes back for FLAC or returns temp path for FFmpeg (MP3/Opus)
- Fixed Save Cover Art and Save Lyrics crashing on SAF-stored download history items - now saves to temp then writes to SAF tree via `createSafFileFromPath`
- Fixed `_getFileDirectory()` crash when called with `content://` URI by adding SAF guard
- Fixed `readAudioMetadata` Kotlin handler not handling SAF URIs - now copies to temp for reading
- Added metadata summary log in Re-enrich flow showing all fields before embedding (title, artist, album, track#, disc#, date, ISRC, genre, label)

---

## [3.5.3] - 2026-02-09

### Added

- CSV import flow now includes a new option: **Skip already downloaded songs** before enqueueing tracks
- Added regression test suite for cross-script matching behavior in Go backend (`go_backend/matching_test.go`)

### Changed

- CSV import confirmation dialog now supports filtering out tracks already present in download history (matched by Spotify ID and ISRC)
- CSV import enqueue feedback now reports added/skipped counts when duplicate downloads are skipped
- Home search now prioritizes **Recent Access** when search field is focused with empty input, even if old search results still exist in memory
- Search filter/result sections are now hidden while Recent Access mode is active to avoid stale-result overlap
- Recent Access now shows a localized empty-state message when no recent items are available
- Normalized collapsing AppBar top inset across iOS/Android so header height/animation stays visually consistent on Apple devices
- Storage & Cache UX improved: `Clear all cache` now preserves web/runtime cache by default (optional), with explicit warnings/actions for runtime cache resets
- Local library settings now include a display count for tracks excluded because they already exist in download history
- Responsive layout tuning applied across key screens to reduce hardcoded-height overflow issues on smaller devices

### Fixed

- Fixed false-positive cross-script matching in Qobuz/Tidal where unrelated titles/artists in different scripts could be incorrectly accepted
- Cross-script title/artist matching now requires transliteration-aware normalization and strict similarity checks instead of auto-accepting script differences
- Qobuz metadata fallback no longer scans all results when zero title matches are found; title verification is now required
- Qobuz metadata final validation now rejects results when title does not match expected track name
- Fixed Home search regression where Recent Access panel could disappear after previous searches
- Fixed Local Library card/layout crash caused by `Flex` usage under unbounded height constraints
- Hardened FFmpeg metadata embedding temp-file naming to prevent rare collisions during parallel downloads/fallback flows (Qobuz → Tidal) that could cause missing embedded metadata
- Fixed SAF external lyrics naming where some providers saved `.lrc` files as `.lrc.txt`; LRC export now uses neutral MIME to preserve `.lrc` extension

## [3.5.2] - 2026-02-08

### Performance

- Home tab search result sections are now virtualized with `SliverList` (lazy item build) instead of eager `Column` rendering, reducing frame drops on large result sets
- Home tab now narrows Riverpod subscriptions using field-level `select(...)` for search/provider state to reduce unnecessary full-tab rebuilds
- Search provider dropdown now watches only required fields (`searchProvider`, `metadataSource`, `extensions`) instead of full provider states
- Track row rendering in Home search now receives precomputed thumbnail sizing/local-library flags from parent to avoid repeated per-item provider watches
- Removed thumbnail `debugPrint` calls inside track row `build()` to reduce runtime overhead during scrolling/rebuilds
- Queue tab root subscription no longer watches full queue item list; it now watches only queue presence (`items.isNotEmpty`) to avoid full Library UI rebuilds on every progress tick
- Queue download header/list rendering has been isolated into dedicated `Consumer` slivers; header now watches only queue length (`items.length`) while item list watches queue item updates
- Queue filter/sort computations are now centralized and memoized per filter mode within a build pass (`all`/`albums`/`singles`), reducing repeated list transforms for chip counts and page content
- Selection bottom bar content is now computed only when selection mode is active, removing hidden-state heavy list preparation
- File existence checks in queue/library rows now use per-path `ValueNotifier` + `ValueListenableBuilder` updates instead of triggering global `setState`, reducing unnecessary whole-tab repaints

### Changed

- Replaced date range filter with sorting options in Library tab: Latest, Oldest, A-Z, Z-A
- Sorting applies to all views: unified items, downloaded albums, and local library albums
- Local library items now use file modification time (`fileModTime`) for sorting instead of scan time, providing more accurate chronological ordering
- Removed redundant manual "Export Failed Downloads" button from Library UI (auto-export setting in Settings is sufficient)
- Library filters (quality, format, source) now correctly apply to album tabs and update tab chip counts (All/Albums/Singles)

### Fixed

- Fixed local library scan crashing on Samsung One UI devices due to MediaStore URI mismatch in SAF tree traversal
- Added MediaStore URI fallback in SAF file reader: when SAF permission is denied for Samsung-returned MediaStore URIs, automatically retries using READ_MEDIA_AUDIO permission
- Hardened SAF scan with per-directory and per-file error handling: scan now skips problematic files instead of aborting entirely
- Added visited directory tracking to prevent infinite loops from circular SAF references
- Fixed metadata enrichment cascading failure after one queued download fails: metadata APIs (Deezer, SongLink, Spotify) now use isolated `metadataTransport` so failed download connections cannot poison metadata requests
- Added immediate connection cleanup on every download failure path (error response and exception), not only periodic cleanup every N downloads
- Fixed incremental SAF scan edge case where `lastModified()` failure could misclassify existing files as removed (`removedUris`)
- Fixed tracks marked "In Library" still showing active download button - download button now shows as completed (checkmark) for local library tracks across all screens (album, playlist, artist, home/search)
- Fixed FFmpeg M4A-to-FLAC conversion erroneously triggered on already-existing FLAC files when re-downloading duplicates via Tidal
- Fixed SAF download creating empty artist/album folders when re-downloading duplicate tracks; directory is now only created after confirming the file does not already exist

## [3.5.1] - 2026-02-08

### Performance

- Removed PaletteService (palette_generator) from all screens for faster navigation and reduced memory usage
- Album, Playlist, Downloaded Album, Local Album, and Track Metadata screens now use blurred cover art as header background instead of dominant color extraction
- Removed `palette_generator` dependency
- App startup now renders immediately (`runApp`) while service initialization runs asynchronously in eager init
- Main shell provider subscriptions now use field-level `select(...)` to reduce unnecessary rebuilds
- Settings persistence now uses single-flight + queued save coalescing to avoid redundant disk writes
- Progress polling cadence adjusted to 800ms for download queue, local library scan progress, and Go log polling
- Android foreground download service progress updates are throttled (change-based updates + 5s heartbeat)
- SAF history repair is now batched (`20` items per batch) and capped per launch (`60`) to reduce startup I/O spikes
- Incremental library scan now builds final item list in-memory instead of reloading from database
- Local cover images in queue/library use direct `Image.file` with `errorBuilder` instead of `FutureBuilder` existence check
- CSV parser `_parseLine` rewritten: correct escaped-quote handling, no quote characters in output
- Removed unused legacy screen files (`home_screen.dart`, `queue_screen.dart`, `settings_screen.dart`, `settings_tab.dart`)
- Incremental local library scan now merges delta results in-memory and sorts once, avoiding full-state reload churn
- Queue local cover rendering now uses direct `Image.file` + `errorBuilder` (removed repeated async file-exists checks)

### Added

- Auto-cleanup orphaned downloads on history load (files that no longer exist are automatically removed from history)

### Changed

- Removed legacy screen files that were no longer used after the tab/part refactor:
  - `lib/screens/home_screen.dart`
  - `lib/screens/queue_screen.dart`
  - `lib/screens/settings_screen.dart`
  - `lib/screens/settings_tab.dart`
- Concurrent download limit increased from `3` to `5` (settings clamp + Options UI chips now support `1..5`)
- Download queue now uses a single parallel scheduler path; `1` concurrency is handled as parallel-with-limit-1 (no separate sequential engine)
- Download queue now listens to settings updates in real-time so concurrency/output settings stay in sync while queue is active

### Fixed

- CSV parser now correctly handles escaped quotes (`""`) inside quoted fields during import
- Fixed dynamic concurrency update during active downloads: changing limit (e.g. `1 -> 3`) now schedules additional queued items without waiting current active item to finish
- Queue scheduler now re-checks capacity/queued items on short intervals to avoid blocking on long-running single active download

### Dependencies

#### Flutter
- `flutter_local_notifications` 19.x → 20.0.0 (breaking: all positional params converted to named params)
- `connectivity_plus` 6.x → 7.0.0
- `flutter_secure_storage` 9.x → 10.0.0
- Removed `palette_generator` dependency

#### Go
- `go-flac/go-flac` v1.0.0 → v2.0.4
- `go-flac/flacvorbis` v0.2.0 → v2.0.2
- `go-flac/flacpicture` v0.3.0 → v2.0.2
- Go toolchain 1.24 → 1.25.7

#### Android
- Android Gradle Plugin 8.x → 9.0.0
- Kotlin 2.1.x → 2.3.10
- `desugar_jdk_libs` → 2.1.5
- `kotlinx-coroutines-android` → 1.10.2
- `lifecycle-runtime-ktx` → 2.10.0
- `activity-ktx` → 1.12.3

#### CI/CD
- `actions/cache` v4 → v5
- `actions/checkout` v4 → v6
- `actions/setup-go` v5 → v6
- `actions/setup-java` v4 → v5
- `softprops/action-gh-release` v1 → v2
- GitHub artifact actions updated

---

## [3.5.0] - 2026-02-07

### Highlights

- **SAF Storage (Android 10+)**: Proper Storage Access Framework support for download destination (content URIs)
  - Select download folder via SAF tree picker
  - Downloads now write to SAF file descriptors (`/proc/self/fd/*`) instead of raw filesystem paths
  - Works around Android 10+ scoped storage permission errors
- **Modern Onboarding Experience**: Completely redesigned Setup and Tutorial screens

### Added

- Home feed disk caching via SharedPreferences for instant restore on app startup
- SAF display path resolver in native Android layer (converts tree URIs to readable paths)
- New settings fields for storage mode + SAF tree URI
- SAF platform bridge methods: pick tree, stat/exists/delete, open content URI, copy to temp, write back to SAF
- SAF library scan mode (DocumentFile traversal + metadata read)
- Incremental library scanning for filesystem and SAF paths (only scans new/modified files and detects removed files)
- Force Full Scan action in Library Settings to rescan all files on demand
- Downloaded files are now excluded from Local Library scan results to prevent duplicate entries
- Legacy library rows now support `file_mod_time` backfill before incremental scans (faster follow-up scans after upgrade)
- Library UI toggle to show SAF-repaired history items
- Scan cancelled banner + retry action for library scans
- Android DocumentFile dependency for SAF operations
- Post-processing API v2 (SAF-aware, ready to replace v1)
- Donate page in Settings with Ko-fi and Buy Me a Coffee links
- Per-App Language support on Android 13+ (locale_config.xml)
- Interactive tutorial with working search bar simulation and clickable download buttons
- Tutorial completion state is persisted after onboarding
- Visual feedback animations for page transitions, entrance effects, and feature lists
- New dedicated welcome step in setup wizard with improved branding

### Changed

- Download pipeline supports `output_path` + `output_ext` for Go backend
- Tidal/Qobuz/Amazon/Extension downloads use SAF-aware output when enabled
- Post-processing hooks run for SAF content URIs (via temp file bridge)
- File operations in Library/Queue/Track screens now SAF-aware (`open`, `exists`, `delete`, `stat`)
- Local Library scan defaults to incremental mode; full rescan is available via Force Full Scan
- Local library database upgraded to schema v3 with `file_mod_time` tracking for incremental scan cache
- Platform channels expanded with incremental scan APIs (`scanLibraryFolderIncremental`) on Android and iOS
- Android platform channel adds `getSafFileModTimes` for SAF legacy cache backfill
- Android build tooling upgraded to Gradle 9.3.1 (wrapper)
- Android build path validated with Java 25 (Gradle/Kotlin/assemble debug)
- SAF tree picker flow in `MainActivity` migrated to Activity Result API (`registerForActivityResult`)
- `MainActivity` host migrated to `FlutterFragmentActivity` for SAF picker compatibility
- Legacy `startActivityForResult` / `onActivityResult` SAF picker path removed
- Setup screen UI polish: smaller logo, thin outline borders on text fields
- Removed support section from About page (moved to Donate page)
- Qobuz squid.wtf region fallback for blocked regions
- Setup screen converted to PageView flow with animated progress bar and modern card layouts
- Tutorial screen aligned with Setup Screen design, updated typography and softened UI shapes
- Larger, more accessible navigation buttons for onboarding flow
- Reduced visual noise by removing unnecessary glow effects

### Fixed

- Android 10+ `permission denied` when writing to `/storage/emulated/0` (now handled via SAF)
- SAF history repair: auto-resolve missing content URIs using tree + filename
- SAF download fallback: retry in app-private storage when SAF write fails
- Tidal DASH manifest writing when output path is a file descriptor (no invalid `.m4a` path)
- External LRC output in SAF mode
- Restored old-device renderer fallback while using `FlutterFragmentActivity` by injecting shell args from a custom `FlutterFragment` (`--enable-impeller=false` on problematic devices)
- Preserved Flutter fragment creation behavior (cached engine, engine group, new engine) while adding Impeller fallback support
- SAF tree picker result now consistently returns `tree_uri` payload with persisted URI permission handling
- SAF share file now copies to temp before sharing (fixes share from SAF content URI)
- Home feed not updating after installing extension with homeFeed capability (no longer requires app restart)
- Library scan hero card showing 0 tracks during scan (now shows scanned file count in real-time)
- Library folder picker no longer requires MANAGE_EXTERNAL_STORAGE on Android 10+ (uses SAF tree picker)
- One-time SAF migration prompt for users updating from pre-SAF versions
- Fixed `fileModTime` propagation across Go/Android/Dart so incremental scan cache is stored and reused correctly
- Fixed SAF incremental scan key mismatch (`lastModified` vs `fileModTime`) and normalized result fields (`skippedCount`, `totalFiles`)
- Fixed incremental scan progress when all files are skipped (`scanned_files` now reaches total files)
- Removed duplicate `"removeExtension"` branch in Android method channel handler (eliminates Kotlin duplicate-branch warning)

---

## [3.4.2] - 2026-02-04

### Improved

- **Mobile Network Reliability**: All providers (Qobuz, Tidal, Amazon, Deezer) now have retry logic with exponential backoff
  - Increased API timeouts: 15s → 25s (Deezer, Qobuz, Tidal), 30s (Amazon)
  - Up to 3 retry attempts per API call (500ms → 1s → 2s backoff)
  - Retryable: timeout, connection reset/refused, EOF, HTTP 5xx, HTTP 429
- **SongLink ID Extraction**: Extract QobuzID/TidalID directly from SongLink URLs
  - New fields in `TrackAvailability`: `QobuzID`, `TidalID`
  - Qobuz/Tidal now use direct Track ID from SongLink instead of re-parsing URLs
- **Qobuz Download Flow**: New Strategy 3 - get QobuzID from SongLink before ISRC search
  - Cache hit now uses `GetTrackByID()` directly instead of searching again
  - Pre-warm cache tries SongLink first before direct ISRC search
- **Tidal Download Flow**: Use `availability.TidalID` directly from SongLink struct

---

## [3.4.1] - 2026-02-04

### Fixed

- Metadata Priority order now persists after app restart
- Download Provider Priority order now persists after app restart

---

## [3.4.0] - 2026-02-03

### Highlights

- **Local Library Scanning** ([#117](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/117)): Scan existing music collection to detect duplicates (FLAC, M4A, MP3, Opus, OGG)
- **Duplicate Detection** ([#117](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/117)): "In Library" badge on tracks matching by ISRC or track name + artist
- **Unified Library Tab**: History renamed to Library, shows Downloaded + Local Library tracks with source badges

### Added

- Local Album Screen with cover art, disc grouping, and selection mode
- Albums tab shows local library albums with folder icon badge
- Singles filter includes local library singles
- Advanced library filters: Source, Quality, Format, Date
- Cover art extraction from embedded tags (FLAC, MP3, Opus/Ogg)
- "Already in Library" notification when downloading existing tracks
- Spotify secrets now stored in secure storage (`flutter_secure_storage`)
- **Multi-Service Link Support**: Share links from Deezer, Tidal, and YouTube Music (in addition to Spotify)
  - Deezer: Full support for track, album, playlist, artist links
  - Tidal: Track links converted via SongLink to Spotify/Deezer for metadata
  - YouTube Music: Handled via ytmusic extension URL handler
- Local library tracks now open metadata screen on tap

### Changed

- Extension HTTP sandbox enforces HTTPS and blocks private IPs
- Extension file sandbox validates paths with boundary-safe checks

### Fixed

- Search filter bar now only appears after results load, not during loading
- MP3/Ogg metadata parsing (ID3v2 extended headers, Ogg packet reassembly)
- Library scan metadata (ISRC, disc number, release date)
- Cover cache robustness (size + mtime cache key)
- Local library selection and delete in list/grid views
- Albums/Singles count includes local library items

---

## [3.3.6] - 2026-02-02

### Added

- **WiFi-Only Download Mode**: Pause downloads on mobile data, auto-resume on WiFi (Settings > Download > Download Network)
- Added `connectivity_plus: ^6.0.3` dependency

---

## [3.3.5] - 2026-02-01

Same as 3.3.1 but fixes crash issues caused by FFmpeg.

### Added

- **Export Failed Downloads**: Export failed downloads to TXT file for easy lookup on other platforms
- **Auto-Export Setting**: Option to automatically export failed downloads when queue finishes

### Fixed

- **FFmpeg Crash**: Fixed crash issues during M4A to MP3/Opus conversion
- **Service Selection Ignored**: Fixed bug where selecting Qobuz/Amazon from service picker was ignored and always used Tidal instead
- **iOS iCloud Drive Permission Error**: Block iCloud Drive folder selection on iOS (Go backend cannot access iCloud due to sandboxing)

### Changed

- **Amazon Fallback Only**: Amazon Music is now grayed out in service picker and can only be used as fallback provider

---

## [3.3.1] - 2026-02-01

### Added

- **Clear All Queue Button**: Cancel all queued downloads with one tap ([#96](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/96))
- **IDHS Fallback**: Fallback link resolver when SongLink fails (rate limited 8 req/min)
- **Lossy Bitrate Options**: MP3 (320/256/192/128kbps), Opus (128/96/64kbps)
- **Search Filters**: Filter results by type (Tracks, Artists, Albums, Playlists)
- **Album/Playlist Search**: Deezer search now includes albums and playlists
- **New Languages**: Turkish (Kaan, BedirhanGltkn), Japanese (Re\*Index.(ot_inc))
- **Optional All Files Access**: Android 13+ no longer requires full storage access; enable in Settings if needed
- **Improved VPN Compatibility**: Better HTTP/2 support for users behind VPN or restricted networks

### Changed

- **Amazon Download API**: Switched to AfkarXYZ API
- **Qobuz Download API**: Added Jumo API as fallback
- **Search Results**: Reduced artist limit from 5 to 2

### Fixed

- **MP3 Download Error 403**: Fixed 403 Forbidden error when downloading MP3 files ([#108](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/108))
- **Opus Cover Art**: Implemented METADATA_BLOCK_PICTURE for proper cover embedding
- **Deezer Pagination**: Fixed >25 tracks only showing first 25 ([#112](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/112))
- **Duplicate Embed Lyrics Setting**: Removed from Options page ([#110](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/110))

---

## [3.2.1] - 2026-01-22

### Added

- **Artist/Album + Singles Folder Structure**: Singles go inside artist folder (`Artist/Album/`, `Artist/Singles/`)
- **Embed Lyrics Button**: Manually embed online lyrics into tracks from Track Info screen (preserves synced timestamps)
- **Pause/Resume Button**: Added pause and resume controls next to "Downloading" header in History screen
- **Instrumental Detection**: Tracks marked as instrumental on lrclib.net now show "Instrumental track" instead of "Lyrics not available"

### Fixed

- **Lyrics**: Multi-artist tracks now search by primary artist first, then full string
- **Lyrics**: Metadata tags (`[ti:...]`, `[ar:...]`, `[by:...]`) no longer shown in display
- **Lyrics**: Embed button now correctly appears for tracks with online lyrics
- **Lyrics**: Manual embed preserves original timestamps instead of plain text
- **iOS**: Fixed "File not found" after 3.1.x → 3.2.0 update (container UUID migration)
- **Home Feed**: Greeting now uses device local time
- **Deezer**: Track position fallback to index+1 when API returns 0
- **Localization**: Fixed 16 ICU plural syntax warnings in Spanish & Portuguese

### Performance

- **Home Feed**: Precomputed Quick Picks section flag and reduced per-page allocations; explore state now watched by field to cut rebuilds
- **Home Recent**: Cached recent-access aggregation and limited list allocations for recent downloads
- **Settings/Theme/Recent**: Cached SharedPreferences instance to avoid repeated `getInstance()` calls
- **History/DB**: Batched iOS path migration updates to reduce write overhead
- **Download Queue**: Reduced polling allocations and avoided double-load scheduling for history
- **Misc**: Precompiled regex in share intent, update dialog, extensions error parsing, log analysis, and LRC cleanup; faster palette cache hits and log filtering

---

## [3.2.0] - 2026-01-22

> **Note:** Starting from v3.2.0, changelogs will be concise.

### Highlights

- **Discography Download** (Highly Requested): Download entire artist discography with album selection mode
- **Home Feed / Explore**: Personalized sections from spotify-web and ytmusic extensions
- **SQLite History Database**: O(1) lookups, non-blocking writes

### Added

- Discography download with options: All, Albums Only, Singles Only, or Select Albums
- Artist navigation from album screen (tap artist name)
- Home feed sections with pull-to-refresh
- YT Music Quick Picks swipeable UI
- `gobackend.getLocalTime()` API for extensions
- Track duration in home feed items
- Release date badge in album info card

### Improved

- Album track list shows track number instead of cover image
- Download buttons with more rounded corners
- Downloaded songs in Recent show primary-colored subtitle

### Fixed

- Home feed timezone detection
- Track duration 0:00 when downloading from home feed

### Extensions

- spotify-web v1.8.1: Home feed, artist_id support
- ytmusic v1.6.1: Home feed, artist_id support

---

## [3.1.3] - 2026-01-19

### Added

- **External LRC Lyrics File Support**: Option to save lyrics as separate .lrc files for compatibility with external music players
  - New "Lyrics Mode" setting in Settings > Download > Lyrics section
  - Three modes available:
    - **Embed in file** (default): Lyrics stored inside FLAC metadata
    - **External .lrc file**: Save lyrics as separate .lrc file next to audio file
    - **Both**: Embed and save external .lrc file
  - Perfect for players like Samsung Music that prefer external .lrc files
  - LRC files include metadata headers (title, artist, by:SpotiFLAC-Mobile)
  - Works with all download services (Tidal, Qobuz, Amazon)
- **CSV Import Quality Selection**: Choose audio quality when importing CSV playlists
  - Quality picker now appears before adding CSV tracks to download queue
  - Select between FLAC qualities (Lossless, Hi-Res, Hi-Res Max) or MP3
  - Respects "Ask quality before download" setting - uses default quality if disabled
  - **Persistent Cover Image Cache**: Album/track cover images now cached to persistent storage instead of temporary directory
  - Cover images no longer disappear when app is closed or device restarts
  - Cache stored in `app_flutter/cover_cache/` directory (not cleared by system)
  - Maximum 1000 images cached for up to 365 days
  - Covers are cached when displayed in History, Home, Album, Artist, or any other screen
  - New `CoverCacheManager` service with `clearCache()` and `getStats()` methods for future cache management
- **Extended Metadata from Deezer Enrichment**: Track downloads now include label, copyright, and genre metadata from Deezer
  - New fields in `ExtTrackMetadata`: `label`, `copyright`, `genre`
  - Metadata fetched during `enrichTrack()` via Deezer album API
  - Embedded as FLAC Vorbis comments: `GENRE`, `ORGANIZATION` (label), `COPYRIGHT`
  - Works for both extension downloads and built-in provider downloads (Tidal, Qobuz, Amazon)
- **Track Metadata Screen Extended Info**: Genre, label, and copyright now displayed in track metadata screen
  - Added `genre`, `label`, `copyright` fields to `DownloadHistoryItem` model
  - Metadata is stored in download history and persists across app restarts
  - New localization strings: `trackGenre`, `trackLabel`, `trackCopyright`
- `**utils.randomUserAgent()` for Extensions\*\*: New utility function for extensions to get random browser User-Agent strings
  - Returns modern Chrome User-Agent format: `Chrome/{120-145}.0.{6000-7499}.{100-299}` with `Windows NT 10.0`
  - Useful for extensions that need to rotate User-Agents to avoid detection

### Fixed

- **Portuguese Language Bug**: Fixed locale parsing for languages with country codes (e.g., pt_PT, es_ES)
  - App now correctly loads Portuguese and Spanish translations
  - Updated Portuguese label to "Português (Brasil)"
- **VM Race Condition Panic**: Fixed `panic during execution: runtime error: index out of range [-2]` crash when switching search providers
  - Root cause: Goja VM was being accessed concurrently by multiple goroutines without synchronization
  - Added `VMMu sync.Mutex` to `LoadedExtension` struct
  - Added mutex lock/unlock to ALL `ExtensionProviderWrapper` methods:
    - `SearchTracks`, `GetTrack`, `GetAlbum`, `GetArtist`
    - `EnrichTrack`, `CheckAvailability`, `GetDownloadURL`, `Download`
    - `CustomSearch`, `HandleURL`, `MatchTrack`, `PostProcess`
  - Prevents race conditions when rapidly switching between extension search providers
- **Tidal Release Date Fallback**: Fixed missing release date in FLAC metadata when downloading from Tidal
  - Now uses Tidal API's release date when `req.ReleaseDate` is empty
  - Ensures release date is always embedded in downloaded files
- **Extended Metadata for M4A→FLAC Conversion**: Fixed genre, label, and copyright not being embedded when converting Amazon M4A to FLAC
  - Flutter now extracts extended metadata from Go backend response
  - Passes `genre`, `label`, `copyright` parameters to `_embedMetadataAndCover()`
  - Tags correctly embedded during FFmpeg conversion
- **Extended Metadata for MP3 Conversion**: Genre, label, and copyright now embedded in MP3 files when converting from FLAC
  - Added `genre`, `label`, `copyright` parameters to `_embedMetadataToMp3()`
  - Tags embedded as ID3v2: `GENRE`, `ORGANIZATION` (label), `COPYRIGHT`

### Extensions

- **spotify-web Extension**: Updated to v1.7.0
  - Added `getMetadataFromDeezer()` function to fetch extended metadata:
    - ISRC from track
    - Label from album
    - Copyright (generated as "YEAR LABEL")
    - Genre from album genres
    - Release date
  - `enrichTrack()` now returns all extended metadata to Go backend
  - Replaced all hardcoded User-Agent strings with `utils.randomUserAgent()`

### Performance

- **Faster App Startup**: Notification, Share Intent, and Cover Cache Manager initialization now run in parallel
- **Download Queue Polling**: Batched progress updates reduce rebuilds and list allocations during active downloads
- **Queue Item Updates**: Status/progress updates now skip no-op changes and update by index for fewer allocations
- **Directory Creation**: Download output folders are created once per path, reducing repeated I/O for albums/singles
- **Search Results Rendering**: Single-pass filtering avoids repeated `indexOf` calls for large result sets
- **Queue Lookups in UI**: O(1) lookup for queue status in Home/Album/Playlist/Artist track lists
- **History Filtering**: Album/single counts and grouping are computed once per build
- **Downloaded Album View**: Tracks are grouped by disc in one pass to reduce filtering overhead
- **Track Metadata Screen**:
  - Palette extraction deferred until after transition; reduced sample size for smoother navigation
  - File stat uses a single syscall and only triggers state updates on change
  - Static regex/month table avoids repeated allocations
  - Cover precached before opening metadata from history/queue/recents
- **Flutter Provider Optimizations**:
  - Cache `SharedPreferences` instance in `DownloadHistoryNotifier` and `DownloadQueueNotifier` to avoid repeated `getInstance()` calls
  - Precompile regex for folder name sanitization and year extraction (top-level `final`)
  - Use `indexWhere` instead of `firstWhere` with placeholder object to reduce allocations in queue processing
- **Flutter UI Optimizations**:
  - Selective `ref.watch()` for `downloadQueueProvider` (watch only `queuedCount` or `items` instead of entire state)
  - Pass `Track` directly to `_buildTrackTile()` instead of index lookup inside builder
  - Pass `historyItems` as parameter to `_buildRecentAccess()` to avoid `ref.read()` inside method
- **M4A Metadata Embedding**: Streaming implementation reduces memory usage for large files
  - Uses `os.Open()` + `ReadAt` instead of `os.ReadFile()` (no full file load into memory)
  - Atomic file replacement via temp file + rename for safer writes
  - New helper functions: `findAtomInRange()`, `readAtomHeaderAt()`, `copyRange()`

### Backend

- **Deezer ISRC Fetching**: Uses ISRCs already present in payloads and caches them, cutting extra API calls
- **SearchAll Allocation**: Preallocated slices to reduce allocations during Deezer search
- **HTTP Client Helper**: Refactored HTTP client creation to use `NewHTTPClientWithTimeout()` helper function across `lyrics.go`, `qobuz.go`, `tidal.go`

### Technical

- **Go Backend Changes**:
  - `go_backend/extension_providers.go`: Added `Label`, `Copyright`, `Genre` fields to `ExtTrackMetadata`; added mutex locks to all provider methods
  - `go_backend/extension_manager.go`: Added `VMMu sync.Mutex` to `LoadedExtension` struct
  - `go_backend/extension_runtime.go`: Added `utils.randomUserAgent` function
  - `go_backend/extension_runtime_utils.go`: Added `randomUserAgent()` implementation
  - `go_backend/httputil.go`: Updated `getRandomUserAgent()` to use modern Chrome versions
  - `go_backend/tidal.go`: Added release date fallback logic
  - `go_backend/exports.go`: Added `Genre`, `Label`, `Copyright` fields to `DownloadResponse`
- **Flutter Changes**:
  - `lib/services/cover_cache_manager.dart`: New persistent cache manager for cover images (365 days, 1000 images max)
  - `lib/widgets/cached_cover_image.dart`: Wrapper widget for CachedNetworkImage with persistent cache
  - `lib/main.dart`: Added `CoverCacheManager.initialize()` to app startup
  - `lib/screens/*.dart`: All 11 screens updated to use persistent cache manager for CachedNetworkImage
  - `lib/providers/download_queue_provider.dart`: Updated `_embedMetadataAndCover()` to accept and embed genre, label, copyright; added `genre`, `label`, `copyright` fields to `DownloadHistoryItem`
  - `lib/screens/track_metadata_screen.dart`: Display genre, label, copyright in metadata grid
  - `lib/l10n/arb/app_en.arb`: Added `trackGenre`, `trackLabel`, `trackCopyright` localization strings

### Dependencies

- Added `flutter_cache_manager: ^3.4.1` (explicit dependency for persistent cache)
- Added `path: ^1.9.0` (for cache directory path handling)

---

## [3.1.2] - 2026-01-19

### Added

- **New Languages**: Added Spanish (es) and Portuguese (pt) translations
  - Spanish: Credits 125 ([@credits125](https://crowdin.com/profile/credits125))
  - Portuguese: Pedro Marcondes ([@justapedro](https://crowdin.com/profile/justapedro))
  - Russian: Владислав ([@odinokiy_kot](https://crowdin.com/profile/odinokiy_kot))
- **Quick Search Provider Switcher** ([#76](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/76)): Dropdown menu in search bar for instant provider switching
  - Tap the search icon to reveal a dropdown menu with all available search providers
  - Shows default provider (Deezer based on metadata source setting) at the top
  - Lists all enabled extensions with custom search capability
  - Displays extension icons when available
  - Checkmark indicates currently selected provider
  - Search hint text updates immediately when switching providers
  - Re-triggers search automatically if there's existing text in the search bar
  - Eliminates need to navigate to Settings > Extensions > Search Provider
- **Extension Button Setting Type** ([#74](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/74)): New setting type for extension actions
  - Extensions can define `button` type in manifest settings
  - Triggers JavaScript function when tapped (e.g., start OAuth flow)
  - Useful for authentication, manual sync, or any custom action
- **Genre & Label Metadata** ([#75](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/75)): Downloaded tracks now include genre and record label information
  - Fetches genre and label from Deezer album API for each track
  - Embeds GENRE, ORGANIZATION (label), and COPYRIGHT tags into FLAC files
  - Works automatically when Deezer track ID is available (via ISRC matching)
  - Supports all download services (Tidal, Qobuz, Amazon) and extension downloads
- **MP3 Quality Option** ([#69](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/69)): Optional MP3 download format with FLAC-to-MP3 conversion
  - New "Enable MP3 Option" toggle in Settings > Download > Audio Quality
  - When enabled, MP3 (320kbps) appears as a quality option alongside FLAC options
  - Available in both the quality picker dialog and default quality settings
  - Works with all services (Tidal, Qobuz, Amazon) and extensions
- **MP3 Metadata Embedding**: Full metadata support for MP3 files
  - Cover art embedded using ID3v2 tags
  - Synced lyrics embedded (fetched from lrclib.net)
  - All metadata preserved: title, artist, album, album artist, track/disc number, date, ISRC
  - Automatic tag conversion from Vorbis comments (FLAC) to ID3v2 (MP3)
- **Dominant Color Header**: Album, Playlist, Downloaded Album, and Track Metadata screens now feature dynamic header backgrounds
  - Extracts dominant color from cover art using `palette_generator`
  - Creates a gradient from dominant color to theme surface color
  - Smooth 500ms color transition animation
- **Larger Cover Art**: Cover images on detail screens are now 50% of screen width (previously 140px fixed)
  - More prominent album artwork display
  - Larger shadow and rounded corners (20px radius)
  - Higher resolution cover caching
- **Sticky Title**: Title appears in AppBar when scrolling past the info card
  - Smooth fade-in animation (200ms) when scrolling down
  - Title hidden when header is expanded (shows in info card instead)
  - AppBar uses theme color (surface) for clean, native look
  - Works on Album, Playlist, Downloaded Album, Track Metadata, and Artist screens
- **Artist Name in Album Screen**: Album info card now displays artist name below album title
  - Extracted from first track's artist metadata
  - Styled with `onSurfaceVariant` color for visual hierarchy
- **Disc Separation for Multi-Disc Albums** ([#70](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/70)): Downloaded albums with multiple discs now display tracks grouped by disc
  - Visual disc separator header showing "Disc 1", "Disc 2", etc.
  - Tracks sorted by disc number first, then by track number
  - Single-disc albums display normally without separators
  - Fixes confusion when albums have duplicate track numbers across discs
- **Album Grouping in Recents** ([#70](https://github.com/spotiflacapp/SpotiFLAC-Mobile/issues/70)): Downloads now show as albums instead of individual tracks in the Recent section
  - Prevents flooding the recents list when downloading full albums
  - Groups tracks by album name and artist
  - Tapping navigates directly to the downloaded album screen
  - Shows the most recent download time for each album

### Changed

- **FFmpeg FLAC-to-MP3 Conversion**: Improved conversion process
  - MP3 files now saved in the same folder as FLAC (no separate MP3 subfolder)
  - Original FLAC file automatically deleted after successful conversion
  - New `embedMetadataToMp3()` method for MP3-specific tag embedding
- **Sticky Header Theme Integration**: AppBar background uses `colorScheme.surface` instead of dominant color when collapsed
  - Dark theme: Black background with white text
  - Light theme: White background with black text
  - Matches modern app behavior for better readability

### Fixed

- **MP3 Quality Display in Track Metadata**: Fixed incorrect quality display for MP3 files
  - MP3 files now show "320kbps" instead of FLAC's bit depth/sample rate
  - History no longer stores FLAC audio specs for converted MP3 files
  - Both File Info badges and metadata grid show correct MP3 quality
- **Empty Catch Blocks**: Fixed analyzer warnings for empty catch blocks
  - `download_queue_provider.dart`: Added comments explaining why polling errors are silently ignored
  - `track_provider.dart`: Added comments explaining why availability check errors are silently ignored
  - `ffmpeg_service.dart`: Added proper error logging for temp file cleanup failures
- **Russian Plural Forms**: Fixed ICU syntax warnings in Russian localization
  - Removed redundant `=1` clauses that were overriding `one` plural category
  - Affected 10 plural strings including track counts and delete confirmations
  - Plurals now correctly handle Russian grammar (1 трек, 2 трека, 5 треков)

### Dependencies

- Added `palette_generator: ^0.3.3+4` for cover art color extraction

---

## [3.1.1] - 2026-01-17

### Added

- **Lyrics Caching**: Lyrics are now cached for 24 hours to reduce API calls and improve performance
  - Thread-safe cache with automatic expiration
  - Cache key based on artist, track, and duration
  - Log indicator shows "(cached)" when lyrics are served from cache
- **Lyrics Duration Matching**: Improved lyrics accuracy with duration-based matching
  - Compares track duration with lrclib.net results
  - 10-second tolerance to handle version differences (radio edit, remaster, etc.)
  - Prioritizes synced lyrics over plain text when duration matches
  - Falls back gracefully if no duration match found
- **Deezer Cover Art Upgrade**: Cover art from Deezer CDN now automatically upgraded to maximum quality
  - Detects Deezer CDN URLs (`cdn-images.dzcdn.net`)
  - Upgrades cover resolution to 1800x1800 (max available)
  - Works alongside existing cover upgrade
- **Live Search for Extensions**: Search-as-you-type functionality for extension search
  - 800ms debounce delay to prevent excessive API calls
  - Minimum 3 characters required before searching
  - Concurrency control to prevent race conditions in extension runtime
  - Queues pending searches if a search is already in progress
- **Russian Language Support**: Added Russian (Русский) translation - 99% complete
  - Translated via Crowdin community contributions
  - Covers all UI elements, settings, and error messages

### Fixed

- **ISRC Index Race Condition**: Fixed repeated index rebuilding during parallel downloads
  - Added per-directory build lock using `sync.Map` and `sync.Mutex`
  - Double-check locking pattern ensures index is built only once
  - Significantly improves performance during CSV import with many tracks
- **Queue Tab Scroll Exception**: Fixed Flutter rendering exception with NestedScrollView
  - Disabled Material 3 stretch overscroll indicator that caused `_StretchController` assertion
  - Wrapped NestedScrollView with ScrollConfiguration to prevent `setState during build` errors
  - Issue was especially noticeable during rapid queue updates (CSV import)
- **CSV Import**: Fixed CSV export not being parsed correctly
  - Added support for `Artist Name(s)` header (with parentheses)
  - Added support for `Track URI` header for track IDs
  - Added `artists` and `track_id` as alternative header names
  - Now correctly parses "Liked Songs" and playlist exports

---

## [3.1.0] - 2026-01-16

### Added

- **Recent Access History**: Quick access to recently visited content when tapping the search bar
- **Artist Screen Redesign**: Full-width header, monthly listeners, top tracks section
- **Extension Store Update Badge**: Badge indicator showing available extension updates
- **Extension Compatibility Warning**: Warning for extensions requiring newer app version
- **Year in Album Folder Name**: New folder structure options with release year
- **Extension Album/Playlist/Artist Support**: Extensions can now return collections in search
- **Odesli Integration**: YouTube Music extension can now match tracks to Deezer/Tidal/Qobuz
- **Download Cancel**: Properly stops in-flight downloads

### Changed

- Search bar behavior improved with recent access history

### Fixed

- Multiple extension-related fixes for artist, album, and playlist handling
- UI fixes for search, settings, and navigation

---

## [3.0.0] - 2026-01-14

### Extension System (Major Feature)

SpotiFLAC 3.0 introduces a powerful extension system that allows third-party integrations for metadata, downloads, and more.

- **Extension Store**: Browse and install extensions directly from the app
- **Web Extension**: Metadata provider for personalized playlists
- **Extension Capabilities**: Custom search, URL handlers, thumbnail ratios, post-processing
- **Extension APIs**: Full HTTP, storage, file, and crypto support
- **Security**: Sandboxed JavaScript runtime with permission-based access

### Added

- Album folder structure settings
- Separate singles folder option
- Year in album folder name
- Parallel API calls for faster downloads
- Swipeable history filters

### Fixed

- Tab edge overscroll
- Extension duplicate load error
- Settings item highlight on swipe
- Back gesture freeze on Android 13+
- Bottom overflow in dialogs
- Japanese artist name matching
- Multi-artist matching
- Max resolution cover download
- Various extension-related fixes

---

_For older versions, see [GitHub Releases_](https://github.com/spotiflacapp/SpotiFLAC-Mobile/releases)
