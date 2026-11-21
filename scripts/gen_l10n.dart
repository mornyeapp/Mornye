import 'dart:convert';
import 'dart:io';

/// Generates compact `lib/l10n/app_localizations*.dart` from `lib/l10n/arb`:
///
/// 1. Only locales enabled in `lib/l10n/supported_locales.dart`
///    (`filteredLocaleCodes`) are generated; incomplete Crowdin ARBs remain in
///    `lib/l10n/arb/` for translators without bloating release binaries.
/// 2. Non-English classes extend `AppLocalizationsEn` and omit every override
///    whose generated body is identical to English, letting Dart AOT drop
///    thousands of duplicate fallback getters and methods.
/// 3. Language-only intermediate classes (`es`, `pt`, `zh`) are omitted when
///    only a country variant (`es_ES`, `pt_PT`, `zh_CN`) is enabled.
///
/// Usage:
/// ```sh
/// dart scripts/gen_l10n.dart
/// ```
Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('Usage: dart scripts/gen_l10n.dart');
    exitCode = 64;
    return;
  }
  final projectRoot = File.fromUri(Platform.script).parent.parent;
  await generateCompactL10n(projectRoot: projectRoot);
}

Future<void> generateCompactL10n({required Directory projectRoot}) async {
  final supportedFile = File(
    '${projectRoot.path}/lib/l10n/supported_locales.dart',
  );
  final activeCodes = _parseFilteredLocaleCodes(
    supportedFile.readAsStringSync(),
  );
  if (!activeCodes.contains('en')) {
    throw StateError('filteredLocaleCodes must include "en".');
  }

  final arbSourceDir = Directory('${projectRoot.path}/lib/l10n/arb');
  final outputDir = Directory('${projectRoot.path}/lib/l10n');
  final flutterBin = _findFlutterExecutable();
  final dartBin = Platform.resolvedExecutable;

  final tempRoot = await Directory.systemTemp.createTemp('mornye_l10n_');
  try {
    final tempArb = Directory('${tempRoot.path}/arb')..createSync();
    final tempOut = Directory('${tempRoot.path}/out')..createSync();

    // Minimal staging project so `flutter gen-l10n` runs cleanly without
    // requiring `generate: true` in the root pubspec.yaml.
    File('${tempRoot.path}/pubspec.yaml').writeAsStringSync(
      'name: mornye_l10n_gen\n'
      'environment:\n'
      '  sdk: ^3.10.0\n'
      'flutter:\n'
      '  generate: true\n',
    );
    File('${tempRoot.path}/l10n.yaml').writeAsStringSync(
      'arb-dir: arb\n'
      'template-arb-file: app_en.arb\n'
      'output-dir: out\n'
      'output-localization-file: app_localizations.dart\n'
      'output-class: AppLocalizations\n'
      'nullable-getter: false\n'
      'format: false\n',
    );

    // Map language -> country variants among active locales.
    final activeSet = activeCodes.toSet();
    final countryOnlyLangs = <String, String>{};
    for (final code in activeCodes) {
      final src = File('${arbSourceDir.path}/app_$code.arb');
      if (!src.existsSync()) {
        throw StateError('Missing ARB for active locale "$code": ${src.path}');
      }
      src.copySync('${tempArb.path}/app_$code.arb');
      if (code.contains('_')) {
        final lang = code.split('_').first;
        if (!activeSet.contains(lang)) {
          countryOnlyLangs[lang] = code;
          File(
            '${tempArb.path}/app_$lang.arb',
          ).writeAsStringSync(jsonEncode({'@@locale': lang}));
        }
      }
    }

    final genResult = await Process.run(flutterBin, [
      'gen-l10n',
    ], workingDirectory: tempRoot.path);
    if (genResult.exitCode != 0) {
      throw StateError(
        'flutter gen-l10n failed (${genResult.exitCode}):\n'
        '${genResult.stdout}\n${genResult.stderr}',
      );
    }

    final enSource = File(
      '${tempOut.path}/app_localizations_en.dart',
    ).readAsStringSync();
    final enClasses = _parseGeneratedClasses(enSource);
    final enClass = enClasses.single;
    final enMembers = <String, String>{
      for (final member in enClass.members) member.name: member.normalized,
    };

    var totalMembersBefore = 0;
    var totalMembersKept = 0;
    final writtenFiles = <String>{};

    // Write English base implementation unchanged.
    final enDest = File('${outputDir.path}/app_localizations_en.dart');
    enDest.writeAsStringSync(enSource);
    writtenFiles.add(enDest.uri.pathSegments.last);

    final generatedFiles =
        tempOut
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in generatedFiles) {
      final name = file.uri.pathSegments.last;
      if (name == 'app_localizations.dart' ||
          name == 'app_localizations_en.dart') {
        continue;
      }
      final lang = name
          .substring('app_localizations_'.length)
          .replaceAll('.dart', '');
      final source = file.readAsStringSync();
      final classes = _parseGeneratedClasses(source);
      final dropBase = countryOnlyLangs.containsKey(lang);

      final out = StringBuffer()
        ..writeln('// ignore: unused_import')
        ..writeln("import 'package:intl/intl.dart' as intl;")
        ..writeln("import 'app_localizations_en.dart';")
        ..writeln()
        ..writeln('// ignore_for_file: type=lint');

      for (final cls in classes) {
        final isEmptyBase = dropBase && cls.className == _classNameFor(lang);
        if (isEmptyBase) continue;

        final keptMembers = <_Member>[];
        for (final member in cls.members) {
          totalMembersBefore++;
          final enBody = enMembers[member.name];
          if (enBody != null && enBody == member.normalized) {
            continue;
          }
          keptMembers.add(member);
          totalMembersKept++;
        }

        out
          ..writeln()
          ..writeln(cls.docComment)
          ..writeln('class ${cls.className} extends AppLocalizationsEn {')
          ..writeln('  ${cls.constructorLine}');
        for (final member in keptMembers) {
          out
            ..writeln()
            ..writeln(member.raw);
        }
        out.writeln('}');
      }

      final dest = File('${outputDir.path}/$name');
      dest.writeAsStringSync(out.toString());
      writtenFiles.add(name);
    }

    // Rewrite app_localizations.dart so supportedLocales and
    // lookupAppLocalizations drop empty parent classes (es, pt, zh).
    final mainSource = File(
      '${tempOut.path}/app_localizations.dart',
    ).readAsStringSync();
    final rewrittenMain = _rewriteMainLocalizations(
      mainSource,
      activeCodes: activeCodes,
      countryOnlyLangs: countryOnlyLangs,
    );
    final mainDest = File('${outputDir.path}/app_localizations.dart');
    mainDest.writeAsStringSync(rewrittenMain);
    writtenFiles.add('app_localizations.dart');

    // Remove any stale generated localization files (e.g. disabled locales).
    for (final entity in outputDir.listSync().whereType<File>()) {
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('app_localizations') &&
          name.endsWith('.dart') &&
          !writtenFiles.contains(name)) {
        entity.deleteSync();
      }
    }

    _forgetFlutterL10nOutputs(projectRoot);

    // Format generated files so CI `dart format --set-exit-if-changed lib` passes.
    final toFormat =
        writtenFiles.map((name) => '${outputDir.path}/$name').toList()..sort();
    final formatResult = await Process.run(dartBin, [
      'format',
      ...toFormat,
    ], workingDirectory: projectRoot.path);
    if (formatResult.exitCode != 0) {
      throw StateError(
        'dart format failed (${formatResult.exitCode}):\n'
        '${formatResult.stderr}',
      );
    }

    final omitted = totalMembersBefore - totalMembersKept;
    stdout.writeln(
      'Generated ${writtenFiles.length} l10n files for '
      '${activeCodes.length} locales '
      '(kept $totalMembersKept/$totalMembersBefore non-English overrides, '
      'omitted $omitted English fallbacks).',
    );
  } finally {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  }
}

List<String> _parseFilteredLocaleCodes(String source) {
  final block = RegExp(
    r'const\s+Set<String>\s+filteredLocaleCodes\s*=\s*<String>\s*\{([^}]*)\}',
    multiLine: true,
    dotAll: true,
  ).firstMatch(source);
  if (block == null) {
    throw StateError('Could not locate filteredLocaleCodes.');
  }
  return [
    for (final match in RegExp(r"'([^']+)'").allMatches(block.group(1)!))
      match.group(1)!,
  ];
}

/// Builds made while Flutter generated these files recorded them as build
/// outputs, and the next build would delete them as stale. Drop those records.
void _forgetFlutterL10nOutputs(Directory projectRoot) {
  final builds = Directory('${projectRoot.path}/.dart_tool/flutter_build');
  if (!builds.existsSync()) return;
  for (final build in builds.listSync().whereType<Directory>()) {
    for (final name in const ['gen_localizations.stamp', 'outputs.json']) {
      final record = File('${build.path}/$name');
      if (record.existsSync() &&
          record.readAsStringSync().contains('app_localizations')) {
        record.deleteSync();
      }
    }
  }
}

String _findFlutterExecutable() {
  final dartFile = File(Platform.resolvedExecutable);
  // Standard layout: <flutter>/bin/cache/dart-sdk/bin/dart
  final candidate = File(
    '${dartFile.parent.parent.parent.parent.path}/'
    '${Platform.isWindows ? 'flutter.bat' : 'flutter'}',
  );
  if (candidate.existsSync()) return candidate.path;
  return Platform.isWindows ? 'flutter.bat' : 'flutter';
}

String _classNameFor(String localeCode) {
  final parts = localeCode.split('_');
  final buffer = StringBuffer('AppLocalizations');
  for (final part in parts) {
    if (part.isEmpty) continue;
    buffer
      ..write(part[0].toUpperCase())
      ..write(part.substring(1).toLowerCase());
  }
  return buffer.toString();
}

class _Member {
  const _Member({
    required this.name,
    required this.raw,
    required this.normalized,
  });

  final String name;
  final String raw;
  final String normalized;
}

class _GeneratedClass {
  const _GeneratedClass({
    required this.docComment,
    required this.className,
    required this.constructorLine,
    required this.members,
  });

  final String docComment;
  final String className;
  final String constructorLine;
  final List<_Member> members;
}

List<_GeneratedClass> _parseGeneratedClasses(String source) {
  final normalized = source.replaceAll('\r\n', '\n');
  final headerRe = RegExp(
    r'(///[^\n]*\n)class\s+(\w+)\s+extends\s+\w+\s*\{\n'
    r'\s*(\w+\([^)]*\)\s*:\s*super\([^)]*\);)\n',
    multiLine: true,
  );
  final matches = headerRe.allMatches(normalized).toList();
  if (matches.isEmpty) {
    throw StateError('No generated AppLocalizations class found.');
  }

  final classes = <_GeneratedClass>[];
  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    final bodyStart = m.end;
    final nextStart = i + 1 < matches.length
        ? matches[i + 1].start
        : normalized.length;
    final slice = normalized.substring(bodyStart, nextStart);
    final closingBrace = slice.lastIndexOf('\n}');
    if (closingBrace < 0) {
      throw StateError('Malformed class body for ${m.group(2)}.');
    }
    final body = slice.substring(0, closingBrace);
    final members = _parseMembers(body);
    classes.add(
      _GeneratedClass(
        docComment: m.group(1)!.trimRight(),
        className: m.group(2)!,
        constructorLine: m.group(3)!.trim(),
        members: members,
      ),
    );
  }
  return classes;
}

List<_Member> _parseMembers(String body) {
  final starts = RegExp(
    r'^  @override$',
    multiLine: true,
  ).allMatches(body).map((m) => m.start).toList();
  final members = <_Member>[];
  final nameRe = RegExp(
    r'^\s*String\s+(?:get\s+)?([A-Za-z_][A-Za-z0-9_]*)',
    multiLine: true,
  );
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : body.length;
    final raw = body.substring(start, end).trimRight();
    final nameMatch = nameRe.firstMatch(raw);
    if (nameMatch == null) {
      throw StateError('Could not parse member name in:\n$raw');
    }
    // Strip trailing/leading blank lines for exact comparison across locales.
    final normalized = raw.trim();
    members.add(
      _Member(name: nameMatch.group(1)!, raw: raw, normalized: normalized),
    );
  }
  return members;
}

String _rewriteMainLocalizations(
  String source, {
  required List<String> activeCodes,
  required Map<String, String> countryOnlyLangs,
}) {
  var result = source.replaceAll('\r\n', '\n');

  // Rewrite supportedLocales to only include the enabled locales.
  final sortedCodes = [...activeCodes]..sort();
  final localeEntries = sortedCodes
      .map((code) {
        final parts = code.split('_');
        return parts.length == 2
            ? "    Locale('${parts[0]}', '${parts[1]}')"
            : "    Locale('${parts[0]}')";
      })
      .join(',\n');

  result = result.replaceFirstMapped(
    RegExp(
      r'static const List<Locale> supportedLocales = <Locale>\[\n.*?\n  \];',
      dotAll: true,
    ),
    (_) =>
        'static const List<Locale> supportedLocales = <Locale>[\n'
        '$localeEntries,\n'
        '  ];',
  );

  // Route language-only fallbacks for country-only locales directly to their
  // enabled country subclass (since the empty parent class was omitted).
  for (final entry in countryOnlyLangs.entries) {
    final baseClass = _classNameFor(entry.key);
    final countryClass = _classNameFor(entry.value);
    result = result.replaceAll(
      'return $baseClass();',
      'return $countryClass();',
    );
  }
  return result;
}
