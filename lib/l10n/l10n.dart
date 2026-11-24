import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/user_facing_error.dart';

export 'package:mornye/l10n/app_localizations.dart';

/// The app's strings with the Material, Cupertino and widget strings of
/// `material_ui`, in every language.
///
/// The generated `AppLocalizations.localizationsDelegates` still lists the
/// delegates of Flutter's built-in Material library, which the widgets of
/// `material_ui` do not read, so a language other than English needs this.
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  String friendlyError(
    Object? error, {
    String fallback = defaultUserFacingErrorMessage,
  }) => userFacingErrorMessage(error, fallback: fallback);
}
