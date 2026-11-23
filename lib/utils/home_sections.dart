import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/home_layout.dart';

/// The title Home gives [section].
String homeSectionName(AppLocalizations l10n, HomeSection section) =>
    switch (section) {
      HomeSection.downloads => l10n.libraryDownloads,
      HomeSection.topPicks => l10n.homeTopPicks,
      HomeSection.recentlyPlayed => l10n.homeRecentlyPlayed,
      HomeSection.continueListening => l10n.homeContinueListening,
      HomeSection.quickPlay => l10n.homeQuickPlay,
      HomeSection.shortcuts => l10n.homeShortcuts,
      HomeSection.pins => l10n.homePinned,
      HomeSection.link => l10n.homeSectionLink,
      HomeSection.hiRes => l10n.homeHiResInYourLibrary,
      HomeSection.mixes => l10n.homeMixesForYou,
      HomeSection.recentlyAdded => l10n.homeRecentlyAdded,
      HomeSection.unfinished => l10n.homeUnfinishedTitle,
      HomeSection.recommended => l10n.homeRecommendedForYou,
      HomeSection.newReleases => l10n.weeklyReleases,
      HomeSection.onRepeat => l10n.homeOnRepeat,
    };

/// One line on what [section] shows, for the page that arranges Home.
String homeSectionAbout(AppLocalizations l10n, HomeSection section) =>
    switch (section) {
      HomeSection.downloads => l10n.homeSectionAboutDownloads,
      HomeSection.topPicks => l10n.homeSectionAboutTopPicks,
      HomeSection.recentlyPlayed => l10n.homeSectionAboutRecentlyPlayed,
      HomeSection.continueListening => l10n.appearanceContinueListeningSubtitle,
      HomeSection.quickPlay => l10n.homeSectionAboutQuickPlay,
      HomeSection.shortcuts => l10n.homeSectionAboutShortcuts,
      HomeSection.pins => l10n.homeSectionAboutPins,
      HomeSection.link => l10n.homeSectionAboutLink,
      HomeSection.hiRes => l10n.homeSectionAboutHiRes,
      HomeSection.mixes => l10n.homeSectionAboutMixes,
      HomeSection.recentlyAdded => l10n.homeSectionAboutRecentlyAdded,
      HomeSection.unfinished => l10n.homeSectionAboutUnfinished,
      HomeSection.recommended => l10n.appearanceRecommendationsSubtitle,
      HomeSection.newReleases => l10n.homeSectionAboutNewReleases,
      HomeSection.onRepeat => l10n.homeSectionAboutOnRepeat,
    };

IconData homeSectionIcon(HomeSection section) => switch (section) {
  HomeSection.downloads => Icons.download_outlined,
  HomeSection.topPicks => Icons.auto_awesome_mosaic_outlined,
  HomeSection.recentlyPlayed => Icons.history,
  HomeSection.continueListening => Icons.play_circle_outline,
  HomeSection.quickPlay => Icons.grid_view,
  HomeSection.shortcuts => Icons.apps,
  HomeSection.pins => Icons.push_pin_outlined,
  HomeSection.link => Icons.devices_outlined,
  HomeSection.hiRes => Icons.high_quality_outlined,
  HomeSection.mixes => Icons.queue_music,
  HomeSection.recentlyAdded => Icons.library_add_outlined,
  HomeSection.unfinished => Icons.checklist,
  HomeSection.recommended => Icons.auto_awesome_outlined,
  HomeSection.newReleases => Icons.new_releases_outlined,
  HomeSection.onRepeat => Icons.repeat,
};
