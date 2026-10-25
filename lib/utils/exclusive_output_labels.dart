import 'package:flutter/foundation.dart';
import 'package:mornye/l10n/app_localizations.dart';

/// The exclusive output setting's wording on this desktop: WASAPI on
/// Windows, hog mode on macOS, ALSA on Linux.
({String title, String description, String unavailable}) exclusiveOutputLabels(
  AppLocalizations l10n,
) => switch (defaultTargetPlatform) {
  TargetPlatform.macOS => (
    title: l10n.exclusiveOutputMacos,
    description: l10n.exclusiveOutputDescriptionMacos,
    unavailable: l10n.exclusiveOutputUnavailableMacos,
  ),
  TargetPlatform.linux => (
    title: l10n.exclusiveOutputLinux,
    description: l10n.exclusiveOutputDescriptionLinux,
    unavailable: l10n.exclusiveOutputUnavailableLinux,
  ),
  _ => (
    title: l10n.exclusiveOutputWindows,
    description: l10n.exclusiveOutputDescriptionWindows,
    unavailable: l10n.exclusiveOutputUnavailableWindows,
  ),
};
