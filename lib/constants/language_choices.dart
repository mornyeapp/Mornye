import 'package:flutter/material.dart';
import 'package:mornye/l10n/supported_locales.dart';

/// Display choices shared by onboarding and appearance settings.
const appLanguageChoices = [
  ('system', 'System Default', Icons.phone_android),
  ('en', 'English', Icons.language),
  ('ar', 'العربية', Icons.language),
  ('id', 'Bahasa Indonesia', Icons.language),
  ('de', 'Deutsch', Icons.language),
  ('es', 'Español', Icons.language),
  ('es_ES', 'Español (España)', Icons.language),
  ('fr', 'Français', Icons.language),
  ('hi', 'हिन्दी', Icons.language),
  ('it', 'Italiano', Icons.language),
  ('ja', '日本語', Icons.language),
  ('ko', '한국어', Icons.language),
  ('nl', 'Nederlands', Icons.language),
  ('pt', 'Português', Icons.language),
  ('pt_PT', 'Português (Brasil)', Icons.language),
  ('ru', 'Русский', Icons.language),
  ('tr', 'Türkçe', Icons.language),
  ('uk', 'Українська', Icons.language),
  ('vi', 'Tiếng Việt', Icons.language),
  ('zh_CN', '简体中文', Icons.language),
  ('zh_TW', '繁體中文', Icons.language),
];

final supportedLanguageChoices = List<(String, String, IconData)>.unmodifiable(
  appLanguageChoices.where(
    (choice) =>
        choice.$1 == 'system' || filteredLocaleCodes.contains(choice.$1),
  ),
);
