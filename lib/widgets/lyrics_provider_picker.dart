import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/lyrics_provider_names.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/settings_group.dart';

typedef LyricsProviderLoader = Future<List<String>> Function();
typedef LyricsProviderFetcher =
    Future<Map<String, dynamic>> Function(String provider);

/// What a lyrics result is, for its label in the picker.
enum LyricsResultKind { wordSynced, synced, plain, instrumental, none }

/// One provider's answer in the picker.
class LyricsProviderResult {
  final String lyrics;
  final LyricsResultKind kind;

  const LyricsProviderResult(this.lyrics, this.kind);

  static const none = LyricsProviderResult('', LyricsResultKind.none);

  static final _wordTiming = RegExp(r'<\d+:\d+(?:[.:]\d+)?>');

  factory LyricsProviderResult.fromBridge(Map<String, dynamic> result) {
    final lyrics = result['lyrics']?.toString() ?? '';
    if (result['instrumental'] == true) {
      return LyricsProviderResult(lyrics, LyricsResultKind.instrumental);
    }
    if (lyricsPreviewLines(lyrics, limit: 1).isEmpty) return none;
    final synced = result['sync_type'] == 'LINE_SYNCED';
    return LyricsProviderResult(
      lyrics,
      !synced
          ? LyricsResultKind.plain
          : _wordTiming.hasMatch(lyrics)
          ? LyricsResultKind.wordSynced
          : LyricsResultKind.synced,
    );
  }

  bool get usable => kind != LyricsResultKind.none;
}

final _tags = RegExp(r'\[[^\]]*\]|<[^>]*>');

/// Multi-person lyrics mark each line's singer, as in `[00:01.00]v1:Words`.
final _voice = RegExp(r'^v\d+:');

/// The first [limit] lines of lyric text, without timestamps, word timing,
/// singer marks or header tags such as `[ar:...]`. A negative [limit]
/// returns every line.
List<String> lyricsPreviewLines(String lyrics, {int limit = 3}) {
  final lines = <String>[];
  for (final raw in lyrics.split('\n')) {
    final text = raw.replaceAll(_tags, '').trim().replaceFirst(_voice, '');
    if (text.isEmpty) continue;
    lines.add(text);
    if (limit >= 0 && lines.length >= limit) break;
  }
  return lines;
}

/// Asks every enabled lyrics provider for this track and returns the lyrics
/// the user picks, or null when the sheet is dismissed.
Future<String?> showLyricsProviderPicker(
  BuildContext context, {
  required String title,
  required String artist,
  String spotifyId = '',
  int durationMs = 0,
  LyricsProviderLoader? loadProviders,
  LyricsProviderFetcher? fetch,
}) {
  return showAppBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.lyricsPickerTitle,
    subtitle: [
      title,
      artist,
    ].where((value) => value.trim().isNotEmpty).join(' · '),
    maxHeightFactor: 0.82,
    builder: (_) => LyricsProviderPicker(
      loadProviders: loadProviders ?? PlatformBridge.getEnabledLyricsProviders,
      fetch:
          fetch ??
          (provider) => PlatformBridge.getLyricsFromProvider(
            provider,
            trackName: title,
            artistName: artist,
            spotifyId: spotifyId,
            durationMs: durationMs,
          ),
    ),
  );
}

/// Lists each enabled provider in priority order, filling in its result as
/// it arrives. Tapping a result closes the sheet with its lyrics.
class LyricsProviderPicker extends ConsumerStatefulWidget {
  final LyricsProviderLoader loadProviders;
  final LyricsProviderFetcher fetch;

  const LyricsProviderPicker({
    super.key,
    required this.loadProviders,
    required this.fetch,
  });

  @override
  ConsumerState<LyricsProviderPicker> createState() =>
      _LyricsProviderPickerState();
}

class _LyricsProviderPickerState extends ConsumerState<LyricsProviderPicker> {
  /// Searches at once; the rest wait their turn so a long provider list
  /// does not occupy every native worker.
  static const _concurrency = 4;

  List<String>? _providers;
  final _results = <String, LyricsProviderResult>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    List<String> providers;
    try {
      providers = await widget.loadProviders();
    } catch (_) {
      providers = const [];
    }
    if (!mounted) return;
    setState(() => _providers = providers);
    var next = 0;
    Future<void> worker() async {
      while (mounted && next < providers.length) {
        final provider = providers[next++];
        LyricsProviderResult result;
        try {
          result = LyricsProviderResult.fromBridge(
            await widget.fetch(provider),
          );
        } catch (_) {
          result = LyricsProviderResult.none;
        }
        if (!mounted) return;
        setState(() => _results[provider] = result);
      }
    }

    await Future.wait([for (var i = 0; i < _concurrency; i++) worker()]);
  }

  String _status(BuildContext context, LyricsProviderResult result) {
    final l10n = context.l10n;
    final lines = lyricsPreviewLines(result.lyrics, limit: -1).length;
    final kind = switch (result.kind) {
      LyricsResultKind.wordSynced => l10n.lyricsPickerWordSynced,
      LyricsResultKind.synced => l10n.lyricsPickerSynced,
      LyricsResultKind.plain => l10n.lyricsPickerPlain,
      LyricsResultKind.instrumental => l10n.lyricsPickerInstrumental,
      LyricsResultKind.none => l10n.lyricsPickerNotFound,
    };
    return switch (result.kind) {
      LyricsResultKind.instrumental || LyricsResultKind.none => kind,
      _ => '$kind · ${l10n.lyricsPickerLineCount(lines)}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final providers = _providers;
    if (providers == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: AppLoadingIndicator()),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    if (providers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Text(
          context.l10n.lyricsPickerNoProviders,
          textAlign: TextAlign.center,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    final extensionNames = <String, String>{
      for (final extension in ref.watch(extensionProvider).extensions)
        'extension:${extension.id.toLowerCase()}': extension.displayName,
    };
    final previewStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        SettingsGroup(
          children: [
            for (var index = 0; index < providers.length; index++)
              _tile(
                providers[index],
                _results[providers[index]],
                extensionNames: extensionNames,
                previewStyle: previewStyle,
                last: index == providers.length - 1,
              ),
          ],
        ),
      ],
    );
  }

  Widget _tile(
    String provider,
    LyricsProviderResult? result, {
    required Map<String, String> extensionNames,
    required TextStyle? previewStyle,
    required bool last,
  }) {
    final preview = result == null || result.kind == LyricsResultKind.none
        ? const <String>[]
        : lyricsPreviewLines(result.lyrics);
    final item = SettingsItem(
      key: ValueKey('lyrics-provider-$provider'),
      title: lyricsProviderDisplayName(provider, extensionNames),
      subtitle: result == null ? null : _status(context, result),
      footer: preview.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                preview.join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: previewStyle,
              ),
            ),
      trailing: result == null
          ? const AppLoadingIndicator(size: 20, strokeWidth: 2)
          : null,
      onTap: result != null && result.usable
          ? () => Navigator.pop(context, result.lyrics)
          : null,
      showDivider: !last,
    );
    // Providers without lyrics stay listed, dimmed, so the user sees
    // which ones were asked.
    return result != null && !result.usable
        ? Opacity(opacity: 0.5, child: item)
        : item;
  }
}
