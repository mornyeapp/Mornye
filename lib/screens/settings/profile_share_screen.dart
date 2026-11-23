import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart'
    show BoxHitTestResult, RenderProxyBox, TransformLayer;
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/profile_overview_provider.dart';
import 'package:mornye/screens/lyrics_share_screen.dart'
    show
        LyricsCardBackground,
        LyricsCardSaver,
        LyricsCardShape,
        ShareCardBackdrop,
        ShareCardBackgroundPicker,
        ShareCardBrand,
        saveShareCardWithSystemDialog;
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/page_transitions.dart';
import 'package:mornye/utils/widget_capture.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/hires_report_view.dart' show HiResSongColors;
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Minutes under an hour, hours above: one decimal under ten hours.
String profileDuration(BuildContext context, int milliseconds) {
  final minutes = (milliseconds / 60000).round();
  if (minutes < 60) return context.l10n.listeningStatsMinutes(minutes);
  final hours = milliseconds / 3600000;
  return context.l10n.profileHours(
    NumberFormat.decimalPatternDigits(
      locale: Localizations.localeOf(context).toLanguageTag(),
      decimalDigits: hours < 10 ? 1 : 0,
    ).format(hours),
  );
}

String _percent(BuildContext context, double share) =>
    NumberFormat.percentPattern(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(share);

IconData profileTraitIcon(ProfileTrait trait) => switch (trait) {
  ProfileTrait.onAStreak => Icons.local_fire_department_outlined,
  ProfileTrait.dailyRitual => Icons.event_repeat_outlined,
  ProfileTrait.marathon => Icons.directions_run,
  ProfileTrait.onTheRise => Icons.trending_up,
  ProfileTrait.audiophile => Icons.graphic_eq,
  ProfileTrait.losslessPurist => Icons.diamond_outlined,
  ProfileTrait.nightOwl => Icons.bedtime_outlined,
  ProfileTrait.earlyBird => Icons.wb_twilight,
  ProfileTrait.daytime => Icons.wb_sunny_outlined,
  ProfileTrait.sunset => Icons.nights_stay_outlined,
  ProfileTrait.weekender => Icons.weekend_outlined,
  ProfileTrait.workday => Icons.work_outline,
  ProfileTrait.loyal => Icons.favorite_outline,
  ProfileTrait.devotee => Icons.album_outlined,
  ProfileTrait.explorer => Icons.explore_outlined,
  ProfileTrait.songHunter => Icons.manage_search,
  ProfileTrait.eclectic => Icons.auto_awesome_outlined,
  ProfileTrait.throwback => Icons.radio_outlined,
  ProfileTrait.freshEars => Icons.new_releases_outlined,
  ProfileTrait.onRepeat => Icons.repeat_one,
  ProfileTrait.patient => Icons.hourglass_bottom,
  ProfileTrait.quickSkipper => Icons.fast_forward_outlined,
};

String profileTraitName(BuildContext context, ProfileTraitFact fact) {
  final l10n = context.l10n;
  return switch (fact.trait) {
    ProfileTrait.onAStreak => l10n.profileTraitStreak,
    ProfileTrait.dailyRitual => l10n.profileTraitDailyRitual,
    ProfileTrait.marathon => l10n.profileTraitMarathon,
    ProfileTrait.onTheRise => l10n.profileTraitOnTheRise,
    ProfileTrait.audiophile => l10n.profileTraitAudiophile,
    ProfileTrait.losslessPurist => l10n.profileTraitLosslessPurist,
    ProfileTrait.nightOwl => l10n.profileTraitNightOwl,
    ProfileTrait.earlyBird => l10n.profileTraitEarlyBird,
    ProfileTrait.daytime => l10n.profileTraitDaytime,
    ProfileTrait.sunset => l10n.profileTraitSunset,
    ProfileTrait.weekender => l10n.profileTraitWeekender,
    ProfileTrait.workday => l10n.profileTraitWorkday,
    ProfileTrait.loyal => l10n.profileTraitLoyal,
    ProfileTrait.devotee => l10n.profileTraitDevotee(fact.subject),
    ProfileTrait.explorer => l10n.profileTraitExplorer,
    ProfileTrait.songHunter => l10n.profileTraitSongHunter,
    ProfileTrait.eclectic => l10n.profileTraitEclectic,
    ProfileTrait.throwback => l10n.profileTraitThrowback,
    ProfileTrait.freshEars => l10n.profileTraitFreshEars,
    ProfileTrait.onRepeat => l10n.profileTraitOnRepeat,
    ProfileTrait.patient => l10n.profileTraitPatient,
    ProfileTrait.quickSkipper => l10n.profileTraitQuickSkipper,
  };
}

/// The first [count] trait names in one short line, for under the name.
String? profileTraitLine(
  BuildContext context,
  List<ProfileTraitFact> traits, {
  int count = 2,
}) => traits.isEmpty
    ? null
    : [
        for (final fact in traits.take(count)) profileTraitName(context, fact),
      ].join(' · ');

/// What bears the trait out, in one line.
String profileTraitBody(BuildContext context, ProfileTraitFact fact) {
  final l10n = context.l10n;
  final share = _percent(context, fact.share);
  return switch (fact.trait) {
    ProfileTrait.onAStreak => l10n.profileTraitStreakBody(fact.count),
    ProfileTrait.dailyRitual => l10n.profileTraitDailyRitualBody(share),
    ProfileTrait.marathon => l10n.profileTraitMarathonBody(
      profileDuration(context, fact.count),
    ),
    ProfileTrait.onTheRise => l10n.profileTraitOnTheRiseBody(share),
    ProfileTrait.audiophile => l10n.profileTraitAudiophileBody(share),
    ProfileTrait.losslessPurist => l10n.profileTraitLosslessPuristBody(share),
    ProfileTrait.nightOwl => l10n.profileTraitNightOwlBody(share),
    ProfileTrait.earlyBird => l10n.profileTraitEarlyBirdBody(share),
    ProfileTrait.daytime => l10n.profileTraitDaytimeBody(share),
    ProfileTrait.sunset => l10n.profileTraitSunsetBody(share),
    ProfileTrait.weekender => l10n.profileTraitWeekenderBody(share),
    ProfileTrait.workday => l10n.profileTraitWorkdayBody(share),
    ProfileTrait.loyal => l10n.profileTraitLoyalBody(fact.subject, share),
    ProfileTrait.devotee => l10n.profileTraitDevoteeBody(share, fact.subject),
    ProfileTrait.explorer => l10n.profileTraitExplorerBody(fact.count),
    ProfileTrait.songHunter => l10n.profileTraitSongHunterBody(fact.count),
    ProfileTrait.eclectic => l10n.profileTraitEclecticBody(fact.count, share),
    ProfileTrait.throwback => l10n.profileTraitThrowbackBody(share),
    ProfileTrait.freshEars => l10n.profileTraitFreshEarsBody(share),
    ProfileTrait.onRepeat => l10n.profileTraitOnRepeatBody(
      fact.subject,
      fact.count,
    ),
    ProfileTrait.patient => l10n.profileTraitPatientBody(share),
    ProfileTrait.quickSkipper => l10n.profileTraitQuickSkipperBody(share),
  };
}

String profileQualityName(BuildContext context, ProfileQuality tier) =>
    switch (tier) {
      ProfileQuality.hiRes => context.l10n.profileQualityHiRes,
      ProfileQuality.lossless => context.l10n.profileQualityLossless,
      ProfileQuality.lossy => context.l10n.profileQualityLossy,
    };

/// Hi-Res in amber, lossless in blue, lossy in [lossy].
Color profileQualityColor(
  Brightness brightness,
  ProfileQuality tier, {
  required Color lossy,
}) => switch (tier) {
  ProfileQuality.hiRes => HiResSongColors.on(brightness, 3),
  ProfileQuality.lossless => HiResSongColors.on(brightness, 0),
  ProfileQuality.lossy => lossy,
};

/// What a profile card can show.
enum ProfileCardPart {
  identity,
  highlights,
  traits,
  taste,
  artists,
  tracks,
  sound,
}

/// How the profile card looks and what it shows. The last choice is kept
/// for the next share.
class ProfileCardStyle {
  const ProfileCardStyle({
    this.background = LyricsCardBackground.color,
    this.shape = LyricsCardShape.story,
    this.parts = defaultParts,
  });

  static const defaultParts = {
    ProfileCardPart.identity,
    ProfileCardPart.highlights,
    ProfileCardPart.traits,
    ProfileCardPart.taste,
    ProfileCardPart.artists,
    ProfileCardPart.tracks,
  };

  /// The shapes a profile fits: the wide card has no room for it.
  static const shapes = [LyricsCardShape.story, LyricsCardShape.square];

  final LyricsCardBackground background;
  final LyricsCardShape shape;
  final Set<ProfileCardPart> parts;

  static const _key = 'profile_card_style';

  ProfileCardStyle copyWith({
    LyricsCardBackground? background,
    LyricsCardShape? shape,
    Set<ProfileCardPart>? parts,
  }) => ProfileCardStyle(
    background: background ?? this.background,
    shape: shape ?? this.shape,
    parts: parts ?? this.parts,
  );

  ProfileCardStyle toggled(ProfileCardPart part) => copyWith(
    parts: parts.contains(part) ? ({...parts}..remove(part)) : {...parts, part},
  );

  String encode() => [
    background.name,
    shape.name,
    [
      for (final part in ProfileCardPart.values)
        if (parts.contains(part)) part.name,
    ].join('|'),
  ].join(',');

  /// Unknown or missing parts fall back to the default look.
  factory ProfileCardStyle.decode(String? saved) {
    final fields = (saved ?? '').split(',');
    String? field(int index) => index < fields.length ? fields[index] : null;
    const fallback = ProfileCardStyle();
    final shape = LyricsCardShape.values.asNameMap()[field(1)];
    final names = field(2);
    final known = ProfileCardPart.values.asNameMap();
    return ProfileCardStyle(
      background:
          LyricsCardBackground.values.asNameMap()[field(0)] ??
          fallback.background,
      shape: shapes.contains(shape) ? shape! : fallback.shape,
      parts: names == null
          ? fallback.parts
          : {for (final name in names.split('|')) ?known[name]},
    );
  }

  static Future<ProfileCardStyle> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ProfileCardStyle.decode(prefs.getString(_key));
    } catch (_) {
      return const ProfileCardStyle();
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, encode());
    } catch (_) {}
  }
}

/// Opens the profile card editor for [overview], with the traits [rhythm]
/// bears out.
Future<void> openProfileShare(
  BuildContext context, {
  required UserProfile profile,
  required ProfileOverview overview,
  ProfileRhythm? rhythm,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final style = await ProfileCardStyle.load();
  if (!navigator.mounted) return;
  await navigator.push(
    SteadyPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ProfileShareScreen(
        profile: profile,
        overview: overview,
        traits: profileTraits(overview, rhythm: rhythm, limit: 4),
        style: style,
      ),
    ),
  );
}

class ProfileShareScreen extends StatefulWidget {
  const ProfileShareScreen({
    super.key,
    required this.profile,
    required this.overview,
    this.traits = const [],
    this.style = const ProfileCardStyle(),
    this.saveImage = saveShareCardWithSystemDialog,
  });

  final UserProfile profile;
  final ProfileOverview overview;
  final List<ProfileTraitFact> traits;

  /// The look the card opens with.
  final ProfileCardStyle style;
  final LyricsCardSaver saveImage;

  @override
  State<ProfileShareScreen> createState() => _ProfileShareScreenState();
}

class _ProfileShareScreenState extends State<ProfileShareScreen> {
  final _cardKey = GlobalKey();
  final _shareButtonKey = GlobalKey();
  late ProfileCardStyle _style = widget.style;
  bool _sharing = false;

  /// The cover the artwork and color backgrounds come from.
  String? get _artwork =>
      widget.overview.allTime.topAlbums.firstOrNull?.artwork ??
      widget.overview.summary.tracks.firstOrNull?.track.artwork;

  void _restyle(ProfileCardStyle style) {
    setState(() => _style = style);
    unawaited(style.save());
  }

  /// The parts this record has something for.
  List<ProfileCardPart> get _offered {
    final overview = widget.overview;
    return [
      for (final part in ProfileCardPart.values)
        if (switch (part) {
          ProfileCardPart.traits => widget.traits.isNotEmpty,
          ProfileCardPart.taste => overview.genres.isNotEmpty,
          ProfileCardPart.artists => overview.allTime.topArtists.isNotEmpty,
          ProfileCardPart.tracks => overview.summary.tracks.isNotEmpty,
          ProfileCardPart.sound => overview.sound.qualityMilliseconds > 0,
          ProfileCardPart.identity || ProfileCardPart.highlights => true,
        })
          part,
    ];
  }

  Future<File?> _capture() async {
    // A style change or a cover color can still be waiting for paint.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;
    final file = await captureBoundaryToPngFile(
      _cardKey,
      pixelRatio: _style.shape.pixelRatio,
      fileName: 'mornye_profile.png',
    );
    if (file == null) throw StateError('Card could not be captured');
    return file;
  }

  Future<void> _save() async {
    if (_sharing) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final name = widget.profile.name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    setState(() => _sharing = true);
    try {
      final file = await _capture();
      if (file == null) return;
      final saved = await widget.saveImage(
        '${name.isEmpty ? 'profile' : '$name profile'}.png',
        await file.readAsBytes(),
      );
      if (saved) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.profileShareSaved)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.profileShareError)));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final box = _shareButtonKey.currentContext?.findRenderObject();
    final origin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    setState(() => _sharing = true);
    try {
      final file = await _capture();
      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: l10n.profileShareText,
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.profileShareError)));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final l10n = context.l10n;
    final buttonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(64, 56)),
      textStyle: WidgetStatePropertyAll(theme.textTheme.titleMedium),
    );
    return Scaffold(
      appBar: AppBar(
        leading: AppIconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const AppIcon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.profileShare),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              flex: 6,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: tokens.gapSm,
                  horizontal: tokens.gapMd,
                ),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _style.shape.size.aspectRatio,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: colors.shadow.withValues(alpha: 0.22),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: FittedBox(
                          child: CoverSourceColorBuilder(
                            imageSource: _artwork,
                            builder: (context, coverColor) => RepaintBoundary(
                              key: _cardKey,
                              child: ProfileShareCard(
                                profile: widget.profile,
                                overview: widget.overview,
                                traits: widget.traits,
                                style: _style,
                                artwork: _artwork,
                                coverColor: coverColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(flex: 5, child: _stylePane(context)),
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapMd,
                tokens.gapSm,
                tokens.gapMd,
                tokens.gapMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ExpressiveButton(
                      tonal: true,
                      icon: const AppIcon(Icons.download_outlined),
                      style: buttonStyle,
                      onPressed: _sharing ? null : _save,
                      child: Text(l10n.lyricsShareSave),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ExpressiveButton(
                      key: _shareButtonKey,
                      icon: const AppIcon(Icons.ios_share),
                      style: buttonStyle,
                      onPressed: _sharing ? null : _share,
                      child: Text(l10n.lyricsShareAction),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the card shows, its background and its shape.
  Widget _stylePane(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final label = theme.textTheme.titleSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget group(String title, Widget choice) => Padding(
      padding: EdgeInsets.only(bottom: tokens.gapMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, bottom: 8),
            child: Text(title, style: label),
          ),
          choice,
        ],
      ),
    );
    final names = {
      ProfileCardPart.identity: (
        l10n.profileShareIdentity,
        Icons.person_outline,
      ),
      ProfileCardPart.highlights: (
        l10n.profileShareHighlights,
        Icons.insights_outlined,
      ),
      ProfileCardPart.traits: (l10n.profileTraits, Icons.auto_awesome_outlined),
      ProfileCardPart.taste: (l10n.profileTaste, Icons.donut_large_outlined),
      ProfileCardPart.artists: (
        l10n.listeningStatsTopArtists,
        Icons.mic_none_outlined,
      ),
      ProfileCardPart.tracks: (
        l10n.listeningStatsTopTracks,
        Icons.music_note_outlined,
      ),
      ProfileCardPart.sound: (l10n.profileSound, Icons.graphic_eq),
    };
    return ListView(
      padding: EdgeInsets.fromLTRB(tokens.gapMd, tokens.gapSm, tokens.gapMd, 0),
      children: [
        group(
          l10n.profileShareShow,
          SettingsChoiceGrid(
            children: [
              for (final part in _offered)
                SettingsChoiceChip(
                  label: names[part]!.$1,
                  icon: names[part]!.$2,
                  isSelected: _style.parts.contains(part),
                  onTap: () => _restyle(_style.toggled(part)),
                ),
            ],
          ),
        ),
        group(
          l10n.lyricsShareBackground,
          ShareCardBackgroundPicker(
            value: _style.background,
            onChanged: (value) => _restyle(_style.copyWith(background: value)),
          ),
        ),
        group(
          l10n.lyricsShareShape,
          SettingsSegmentedChoice<LyricsCardShape>(
            semanticLabel: l10n.lyricsShareShape,
            options: [
              SettingsSegmentOption(
                value: LyricsCardShape.story,
                label: l10n.lyricsShareShapeStory,
                icon: Icons.crop_portrait,
              ),
              SettingsSegmentOption(
                value: LyricsCardShape.square,
                label: l10n.lyricsShareShapeSquare,
                icon: Icons.crop_square,
              ),
            ],
            selected: _style.shape,
            onChanged: (value) => _restyle(_style.copyWith(shape: value)),
          ),
        ),
      ],
    );
  }
}

/// The profile on one image, as [style] picks: the listener on the card's
/// one decorative shape, the listener type as the headline, figures, the
/// genres in their colors, the top artists and songs and the sound quality.
/// Every part sits straight on the backdrop, set apart by space, not by
/// surfaces of its own. Its layout ignores the device, so every phone makes
/// the same card.
class ProfileShareCard extends StatelessWidget {
  const ProfileShareCard({
    super.key,
    required this.profile,
    required this.overview,
    this.traits = const [],
    this.style = const ProfileCardStyle(),
    this.artwork,
    this.coverColor,
  });

  final UserProfile profile;
  final ProfileOverview overview;
  final List<ProfileTraitFact> traits;
  final ProfileCardStyle style;

  /// The cover behind [LyricsCardBackground.artwork].
  final String? artwork;

  /// The cover's average color, for [LyricsCardBackground.color].
  final Color? coverColor;

  /// Genres with a hue of their own on the card; the rest share Other.
  static const _genres = 5;

  /// The genre shares as hues on [brightness], biggest first.
  List<_SharePart> _genreParts(BuildContext context, Brightness brightness) {
    final genres = overview.genres.take(_genres).toList();
    final total = overview.genreMilliseconds;
    final other =
        total - genres.fold<int>(0, (sum, genre) => sum + genre.milliseconds);
    return [
      for (final (index, genre) in genres.indexed)
        (
          label: genre.name,
          milliseconds: genre.milliseconds,
          color: HiResSongColors.on(brightness, index),
        ),
      if (other > 0)
        (
          label: context.l10n.profileTasteOther,
          milliseconds: other,
          color: brightness == Brightness.light
              ? const Color(0x55111111)
              : const Color(0x66FFFFFF),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final light = style.background == LyricsCardBackground.light;
    final ink = _Ink(
      foreground: light ? const Color(0xFF111111) : Colors.white,
      brightness: light ? Brightness.light : Brightness.dark,
      story: style.shape == LyricsCardShape.story,
    );
    final size = style.shape.size;
    final padding = ink.story
        ? const EdgeInsets.fromLTRB(24, 28, 24, 22)
        : const EdgeInsets.all(20);
    final parts = style.parts;
    final genres = _genreParts(context, ink.brightness);
    final artists =
        parts.contains(ProfileCardPart.artists) &&
        overview.allTime.topArtists.isNotEmpty;
    final tracks =
        parts.contains(ProfileCardPart.tracks) &&
        overview.summary.tracks.isNotEmpty;
    final both = artists && tracks;
    final rows = both || !ink.story ? 3 : 5;
    final highlights = parts.contains(ProfileCardPart.highlights)
        ? _highlights(context, ink)
        : null;
    // Each part with about how tall it is, to balance the square's columns.
    // The square keeps the figures above its columns, at full width.
    final sections = <(Widget, double)>[
      if (parts.contains(ProfileCardPart.traits) && traits.isNotEmpty)
        (_traits(context, ink), 120),
      if (highlights != null && ink.story) (highlights, 80),
      if (parts.contains(ProfileCardPart.taste) && genres.isNotEmpty)
        (
          _Section(
            ink: ink,
            title: context.l10n.profileTaste,
            child: _ShareParts(
              ink: ink,
              total: overview.genreMilliseconds,
              parts: genres,
            ),
          ),
          80,
        ),
      // The story sets both lists side by side.
      if (both && ink.story)
        (
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _artists(context, ink, rows, compact: true)),
              SizedBox(width: ink.gap),
              Expanded(child: _tracks(context, ink, rows, compact: true)),
            ],
          ),
          30 + rows * 38,
        )
      else ...[
        if (artists) (_artists(context, ink, rows), 30 + rows * 44),
        if (tracks) (_tracks(context, ink, rows), 30 + rows * 44),
      ],
      if (parts.contains(ProfileCardPart.sound) &&
          overview.sound.qualityMilliseconds > 0)
        (_sound(context, ink), 70),
    ];
    Widget stack(List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) SizedBox(height: ink.gap),
          child,
        ],
      ],
    );
    final Widget body;
    if (!ink.story && sections.length >= 3) {
      // The square sets its parts in two columns, each to the shorter one.
      final columns = [<Widget>[], <Widget>[]];
      final heights = [0.0, 0.0];
      for (final (section, height) in sections) {
        final column = heights[0] <= heights[1] ? 0 : 1;
        columns[column].add(section);
        heights[column] += height;
      }
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: stack(columns[0])),
          SizedBox(width: ink.gap),
          Expanded(child: stack(columns[1])),
        ],
      );
    } else {
      body = stack([for (final (section, _) in sections) section]);
    }
    // The card sets its own type, so it reads the same wherever it is drawn.
    return MediaQuery.withNoTextScaling(
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
        child: SizedBox.fromSize(
          size: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShareCardBackdrop(
                background: style.background,
                artUri: artwork,
                coverColor: coverColor,
              ),
              Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Everything chosen stays on the card: too much for its
                    // shape shrinks instead of being cut.
                    Expanded(
                      child: _FitCard(
                        child: stack([
                          _identity(context, ink),
                          if (highlights != null && !ink.story) highlights,
                          body,
                        ]),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ShareCardBrand(foreground: ink.foreground, light: light),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The photo (or the app's sound mark) on the card's one decorative
  /// shape, the name and since when.
  Widget _identity(BuildContext context, _Ink ink) {
    final l10n = context.l10n;
    final name = profile.name.trim();
    final shown = style.parts.contains(ProfileCardPart.identity);
    final since = overview.since;
    final stage = ink.story ? 84.0 : 64.0;
    final inner = stage * 0.7;
    return Row(
      children: [
        SizedBox.square(
          dimension: stage,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: AppShapeClip(
                  kind: AppShapes.brand,
                  child: ColoredBox(color: ink.stage),
                ),
              ),
              shown
                  ? ProfileAvatar(
                      name: profile.name,
                      photoPath: profile.photoPath,
                      size: inner,
                    )
                  : Icon(
                      Icons.graphic_eq,
                      size: inner * 0.6,
                      color: ink.foreground,
                    ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                shown && name.isNotEmpty ? name : l10n.profileShareHeadline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink.foreground,
                  fontSize: ink.story ? 24 : 20,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                  letterSpacing: -0.3,
                ),
              ),
              if (since != null) ...[
                const SizedBox(height: 2),
                Text(
                  l10n.profileListeningSince(
                    DateFormat.yMMMM(
                      Localizations.localeOf(context).toLanguageTag(),
                    ).format(since),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ink.secondary, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The leading listener type as the headline with what bears it out, and
  /// the others in one line under it.
  Widget _traits(BuildContext context, _Ink ink) {
    final lead = traits.first;
    return _Section(
      ink: ink,
      title: context.l10n.profileTraits,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            profileTraitName(context, lead),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: ink.foreground,
              fontSize: ink.story ? 34 : 28,
              fontWeight: FontWeight.w600,
              height: 1.1,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            profileTraitBody(context, lead),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ink.secondary, fontSize: 13, height: 1.3),
          ),
          if (traits.length > 1) ...[
            const SizedBox(height: 8),
            Text(
              [
                for (final fact in traits.skip(1))
                  profileTraitName(context, fact),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink.foreground,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _highlights(BuildContext context, _Ink ink) {
    final l10n = context.l10n;
    final number = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toLanguageTag(),
    );
    final summary = overview.summary;
    final figures = [
      (
        profileDuration(context, summary.milliseconds),
        l10n.profileStatListening,
      ),
      (number.format(summary.tracks.length), l10n.profileStatSongs),
      (
        number.format(overview.allTime.topArtists.length),
        l10n.profileStatArtists,
      ),
    ];
    // Listening time is the big figure; songs and artists follow smaller.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final (index, (value, label)) in figures.indexed) ...[
          if (index > 0) SizedBox(width: ink.gap),
          Expanded(
            flex: index == 0 ? 2 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: TextStyle(
                      color: ink.foreground,
                      fontSize: index == 0
                          ? (ink.story ? 56 : 44)
                          : (ink.story ? 26 : 22),
                      fontWeight: FontWeight.w500,
                      height: 1.05,
                      letterSpacing: index == 0 ? -1.5 : -0.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ink.secondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _sound(BuildContext context, _Ink ink) {
    final sound = overview.sound;
    final format = sound.formats.isEmpty ? null : sound.formats.first.name;
    return _Section(
      ink: ink,
      title: context.l10n.profileSound,
      trailing: format,
      child: _ShareParts(
        ink: ink,
        total: sound.qualityMilliseconds,
        parts: [
          for (final tier in ProfileQuality.values)
            if ((sound.quality[tier] ?? 0) > 0)
              (
                label: profileQualityName(context, tier),
                milliseconds: sound.quality[tier]!,
                color: profileQualityColor(
                  ink.brightness,
                  tier,
                  lossy: ink.foreground.withValues(alpha: 0.4),
                ),
              ),
        ],
      ),
    );
  }

  Widget _artists(
    BuildContext context,
    _Ink ink,
    int rows, {
    bool compact = false,
  }) {
    final artwork = overview.summary.artistArtwork;
    return _Section(
      ink: ink,
      title: context.l10n.listeningStatsTopArtists,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, artist)
              in overview.allTime.topArtists.take(rows).indexed)
            _ShareRow(
              ink: ink,
              rank: index + 1,
              artwork: artwork[artist.key],
              round: true,
              compact: compact,
              title: artist.key,
              detail: profileDuration(context, artist.value),
            ),
        ],
      ),
    );
  }

  Widget _tracks(
    BuildContext context,
    _Ink ink,
    int rows, {
    bool compact = false,
  }) => _Section(
    ink: ink,
    title: context.l10n.listeningStatsTopTracks,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, total) in overview.summary.tracks.take(rows).indexed)
          _ShareRow(
            ink: ink,
            rank: index + 1,
            artwork: total.track.artwork,
            compact: compact,
            title: total.track.title,
            detail: total.track.artist.trim().isEmpty
                ? context.l10n.unknownArtist
                : total.track.artist,
          ),
      ],
    ),
  );
}

/// The card's text colors and the surface its chart colors are made for.
class _Ink {
  const _Ink({
    required this.foreground,
    required this.brightness,
    required this.story,
  });

  final Color foreground;
  final Brightness brightness;

  /// The tall story shape, which gets larger type.
  final bool story;

  bool get light => brightness == Brightness.light;
  Color get secondary => foreground.withValues(alpha: 0.72);

  /// The tone of the card's one decorative shape, behind the photo.
  Color get stage => foreground.withValues(alpha: light ? 0.08 : 0.14);

  /// The space between parts.
  double get gap => story ? 22 : 16;
}

/// A part of the card: a title, [trailing] text and [child] under it, on
/// the backdrop itself.
class _Section extends StatelessWidget {
  const _Section({
    required this.ink,
    required this.title,
    required this.child,
    this.trailing,
  });

  final _Ink ink;
  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink.foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: TextStyle(
                  color: ink.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// Sets [child] at the card's width and, when that is too tall, at a wider
/// width it then scales down, so the content always fills the card's width.
class _FitCard extends SingleChildRenderObjectWidget {
  const _FitCard({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFitCard();
}

class _RenderFitCard extends RenderProxyBox {
  double _scale = 1;

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    // Whether [width], scaled to the card's width, is short enough.
    bool fits(double width) {
      child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      return child.size.height * size.width / width <= size.height;
    }

    var width = size.width;
    if (!fits(width) && size.height > 0) {
      // Too tall at the card's width: search the narrowest width that fits.
      var low = width;
      var high = width * child.size.height / size.height;
      while (!fits(high)) {
        low = high;
        high *= 1.25;
      }
      for (var step = 0; step < 6; step++) {
        final middle = (low + high) / 2;
        fits(middle) ? high = middle : low = middle;
      }
      width = high;
      fits(width);
    }
    _scale = math.min(
      1.0,
      math.min(size.width / width, size.height / child.size.height),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    layer = context.pushTransform(
      needsCompositing,
      offset,
      Matrix4.diagonal3Values(_scale, _scale, 1),
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.scaleByDouble(_scale, _scale, 1, 1);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: Matrix4.diagonal3Values(_scale, _scale, 1),
        position: position,
        hitTest: (result, position) =>
            child?.hitTest(result, position: position) ?? false,
      );
}

typedef _SharePart = ({String label, int milliseconds, Color color});

/// A share bar with a legend of each part and its share.
class _ShareParts extends StatelessWidget {
  const _ShareParts({
    required this.ink,
    required this.total,
    required this.parts,
  });

  final _Ink ink;
  final int total;
  final List<_SharePart> parts;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: context.tokens.borderRadiusBadge,
        child: SizedBox(
          height: ink.story ? 14 : 12,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, part) in parts.indexed) ...[
                if (index > 0) const SizedBox(width: 2),
                Expanded(
                  flex: (part.milliseconds * 1000 / total).round().clamp(
                    1,
                    1000,
                  ),
                  child: ColoredBox(color: part.color),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          for (final part in parts)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: part.color,
                    shape: const CircleBorder(),
                  ),
                  child: const SizedBox.square(dimension: 8),
                ),
                const SizedBox(width: 5),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${part.label} '),
                      TextSpan(
                        text: _percent(context, part.milliseconds / total),
                        style: TextStyle(
                          color: ink.foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  style: TextStyle(color: ink.secondary, fontSize: 12),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({
    required this.ink,
    required this.rank,
    required this.artwork,
    required this.title,
    required this.detail,
    this.round = false,
    this.compact = false,
  });

  final _Ink ink;
  final int rank;
  final String? artwork;
  final String title;
  final String detail;

  /// The artist shape instead of a cover's rounded square.
  final bool round;

  /// Smaller, for a list that shares its row with another.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = SizedBox.square(
      dimension: compact ? 30 : 36,
      child: round && artwork == null
          ? ColoredBox(
              color: ink.foreground.withValues(alpha: 0.16),
              child: Icon(
                Icons.person_outline,
                size: 18,
                color: ink.foreground,
              ),
            )
          : PlayerArtwork(
              artUri: artwork,
              colorScheme: scheme,
              iconSize: 16,
              cacheWidth: 120,
            ),
    );
    return SizedBox(
      height: compact ? 38 : 44,
      child: Row(
        children: [
          SizedBox(
            width: compact ? 16 : 20,
            child: Text(
              '$rank',
              style: TextStyle(
                // The first place stands out.
                color: rank == 1 ? ink.foreground : ink.secondary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          round
              ? AppShapeClip(kind: AppShapes.artist, child: image)
              : ClipRRect(
                  borderRadius: context.tokens.borderRadiusThumb,
                  child: image,
                ),
          SizedBox(width: compact ? 8 : 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink.foreground,
                    fontSize: compact ? 12.5 : 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink.secondary,
                    fontSize: compact ? 11 : 11.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
