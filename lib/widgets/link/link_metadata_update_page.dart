import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoButton;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/features/link_metadata_update.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/error_card.dart' show EmptyState;
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

final _log = AppLogger('LinkMetadata');

/// Opens the Update metadata page for the connected host.
Future<void> showLinkMetadataUpdate(BuildContext context) =>
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: const MornyeSettingsTheme(child: LinkMetadataUpdatePage()),
      ),
    );

/// The Link page's row that opens [LinkMetadataUpdatePage]. The page lists
/// it only while a host is connected.
class LinkMetadataUpdateSettingsItem extends ConsumerWidget {
  const LinkMetadataUpdateSettingsItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(linkPhoneClientProvider);
    final name = client == null ? '' : linkDesktopName(client);
    return SettingsItem(
      key: const ValueKey('link-metadata-update-row'),
      icon: Icons.sync_outlined,
      showIconInMornye: true,
      title: context.l10n.linkMetadataUpdateTitle,
      subtitle: context.l10n.linkMetadataUpdateSubtitle(name),
      onTap: () => showLinkMetadataUpdate(context),
    );
  }
}

String _fieldLabel(BuildContext context, LinkMetadataField field) {
  final l10n = context.l10n;
  return switch (field) {
    LinkMetadataField.title => l10n.editMetadataFieldTitle,
    LinkMetadataField.artist => l10n.trackArtist,
    LinkMetadataField.album => l10n.trackAlbum,
    LinkMetadataField.albumArtist => l10n.trackAlbumArtist,
    LinkMetadataField.genre => l10n.trackGenre,
    LinkMetadataField.year => l10n.linkMetadataFieldYear,
    LinkMetadataField.trackNumber => l10n.trackTrackNumber,
    LinkMetadataField.discNumber => l10n.trackDiscNumber,
    LinkMetadataField.isrc => l10n.editMetadataFieldIsrc,
  };
}

/// Which differences are chosen, all of them until turned off.
class _Selection extends ChangeNotifier {
  final _off = <String, Set<LinkMetadataField>>{};

  bool isOn(LinkMetadataCandidate candidate, LinkMetadataField field) =>
      !(_off[candidate.copy.id]?.contains(field) ?? false);

  void set(LinkMetadataCandidate candidate, LinkMetadataField field, bool on) {
    final off = _off.putIfAbsent(candidate.copy.id, () => {});
    if (on ? off.remove(field) : off.add(field)) notifyListeners();
  }

  List<LinkMetadataDifference> chosen(LinkMetadataCandidate candidate) => [
    for (final difference in candidate.differences)
      if (isOn(candidate, difference.field)) difference,
  ];

  bool allOn(List<LinkMetadataCandidate> candidates) => candidates.every(
    (candidate) => chosen(candidate).length == candidate.differences.length,
  );

  void selectAll() {
    _off.clear();
    notifyListeners();
  }

  void selectNone(List<LinkMetadataCandidate> candidates) {
    for (final candidate in candidates) {
      _off[candidate.copy.id] = {
        for (final difference in candidate.differences) difference.field,
      };
    }
    notifyListeners();
  }
}

/// The saved songs whose tags differ from the connected host's, each with
/// how many; a song opens to its differences, each with its own switch.
/// Nothing is written until the update button at the bottom.
class LinkMetadataUpdatePage extends ConsumerStatefulWidget {
  const LinkMetadataUpdatePage({super.key});

  @override
  ConsumerState<LinkMetadataUpdatePage> createState() =>
      _LinkMetadataUpdatePageState();
}

class _LinkMetadataUpdatePageState
    extends ConsumerState<LinkMetadataUpdatePage> {
  /// Held for the page's life, so a disconnect cannot stop an update.
  late final LinkMetadataUpdater? _updater = ref.read(
    linkMetadataUpdaterProvider,
  );
  final _selection = _Selection();
  List<LinkMetadataCandidate>? _candidates;
  var _failed = false;
  ({int done, int total})? _progress;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  String get _name => _updater?.name ?? '';

  void _retry() {
    setState(() {
      _candidates = null;
      _failed = false;
    });
    _load();
  }

  Future<void> _load() async {
    final updater = _updater;
    if (updater == null) {
      _failed = true;
      return;
    }
    try {
      final found = await updater.collector.collect(cancelled: () => !mounted);
      if (!mounted) return;
      _selection.selectAll();
      setState(() => _candidates = found);
    } on Object catch (error) {
      _log.w('Comparing with the host failed: $error');
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _apply() async {
    final updater = _updater;
    final candidates = _candidates;
    if (updater == null || candidates == null || _progress != null) return;
    final updates = [
      for (final candidate in candidates)
        if (_selection.chosen(candidate) case final changes
            when changes.isNotEmpty)
          LinkMetadataUpdate(copy: candidate.copy, changes: changes),
    ];
    if (updates.isEmpty) return;
    setState(() => _progress = (done: 0, total: updates.length));
    final result = await updater.applier.apply(
      updates,
      onProgress: (done, total) {
        if (mounted) setState(() => _progress = (done: done, total: total));
      },
    );
    if (!mounted) return;
    final written = {for (final item in result.updated) item.id: item};
    final remaining = <LinkMetadataCandidate>[];
    for (final candidate in candidates) {
      final item = written[candidate.copy.id];
      if (item == null) {
        remaining.add(candidate);
        continue;
      }
      // What was left off still differs, and stays off.
      final left = [
        for (final difference in candidate.differences)
          if (!_selection.isOn(candidate, difference.field)) difference,
      ];
      if (left.isNotEmpty) {
        remaining.add(LinkMetadataCandidate(copy: item, differences: left));
      }
    }
    setState(() {
      _candidates = remaining;
      _progress = null;
    });
    final l10n = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            l10n.linkMetadataUpdateResult(result.updated.length),
            if (result.failed > 0)
              l10n.linkMetadataUpdateResultFailed(result.failed),
          ].join('. '),
        ),
      ),
    );
  }

  void _openSong(LinkMetadataCandidate candidate) => Navigator.of(context).push(
    slidePageRoute<void>(
      page: MornyeSettingsTheme(
        child: _LinkMetadataSongPage(
          candidate: candidate,
          selection: _selection,
          hostName: _name,
        ),
      ),
    ),
  );

  Widget _row(BuildContext context, List<LinkMetadataCandidate> all, int i) {
    final l10n = context.l10n;
    final candidate = all[i];
    final count = candidate.differences.length;
    final chosen = _selection.chosen(candidate).length;
    final artist = candidate.copy.artistName.trim();
    return SettingsItem(
      key: ValueKey('link-metadata-song-${candidate.copy.id}'),
      icon: Icons.music_note_outlined,
      title: candidate.copy.trackName,
      subtitle: [
        if (artist.isNotEmpty) artist,
        l10n.linkMetadataUpdateDiffers(count),
        if (chosen < count) l10n.linkMetadataUpdateChosen(chosen, count),
      ].join(' · '),
      onTap: _progress == null ? () => _openSong(candidate) : null,
      showDivider: i < all.length - 1,
    );
  }

  List<Widget> _body(BuildContext context) {
    final l10n = context.l10n;
    final candidates = _candidates;
    if (_failed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: context.adaptiveIcon(Icons.sync_problem_outlined),
            title: l10n.linkMetadataUpdateFailedTitle(_name),
            message: l10n.linkMetadataUpdateFailedMessage(_name),
            action: _updater == null
                ? null
                : AppActionButton(
                    onPressed: _retry,
                    icon: const AppIcon(Icons.refresh),
                    label: Text(l10n.dialogRetry),
                    tonal: true,
                  ),
          ),
        ),
      ];
    }
    if (candidates == null) {
      final theme = Theme.of(context);
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppLoadingIndicator(),
                SizedBox(height: context.tokens.gapLg),
                Text(
                  l10n.linkMetadataUpdateComparing(_name),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (candidates.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: context.adaptiveIcon(Icons.check_circle_outline),
            title: l10n.linkMetadataUpdateNoneTitle,
            message: l10n.linkMetadataUpdateNoneMessage(_name),
          ),
        ),
      ];
    }
    final theme = Theme.of(context);
    return [
      SliverToBoxAdapter(
        child: _Inset(
          child: Text(
            l10n.linkMetadataUpdateDescription(_name),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      // The same edges as the settings groups at any width.
      SliverLayoutInfoBuilder<double>(
        select: (constraints) => constraints.crossAxisExtent,
        builder: (context, width) => SliverSettingsGroup(
          margin: EdgeInsets.symmetric(
            horizontal: settingsHorizontalInset(context, width),
            vertical: 4,
          ),
          itemCount: candidates.length,
          itemBuilder: (context, index) => _row(context, candidates, index),
        ),
      ),
    ];
  }

  Widget? _footer(BuildContext context) {
    final candidates = _candidates;
    if (candidates == null || _failed) return null;
    final l10n = context.l10n;
    final progress = _progress;
    final Widget content;
    if (progress != null) {
      final theme = Theme.of(context);
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.linkMetadataUpdateUpdating(
              (progress.done + 1).clamp(1, progress.total),
              progress.total,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          AppProgressIndicator.linear(
            value: progress.total == 0 ? null : progress.done / progress.total,
          ),
        ],
      );
    } else {
      final songs = candidates
          .where((candidate) => _selection.chosen(candidate).isNotEmpty)
          .length;
      // Hidden while nothing is chosen.
      if (songs == 0) return null;
      content = Row(
        children: [
          Expanded(
            child: AppActionButton(
              key: const ValueKey('link-metadata-apply'),
              onPressed: _apply,
              icon: const AppIcon(Icons.save_outlined),
              label: Text(l10n.linkMetadataUpdateApply(songs)),
            ),
          ),
        ],
      );
    }
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = settingsHorizontalInset(context, constraints.maxWidth);
          return Padding(
            padding: EdgeInsets.fromLTRB(inset + 16, 8, inset + 16, 16),
            child: content,
          );
        },
      ),
    );
  }

  Widget? _selectAction(BuildContext context) {
    final candidates = _candidates;
    if (candidates == null || candidates.isEmpty || _progress != null) {
      return null;
    }
    final l10n = context.l10n;
    final all = _selection.allOn(candidates);
    final label = all
        ? l10n.linkMetadataUpdateSelectNone
        : l10n.linkMetadataUpdateSelectAll;
    void onPressed() =>
        all ? _selection.selectNone(candidates) : _selection.selectAll();
    const key = ValueKey('link-metadata-select');
    if (context.isMornye) {
      return CupertinoButton(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: Size.square(context.tokens.minTouchTarget),
        onPressed: onPressed,
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    return AppIconButton(
      key: key,
      tooltip: label,
      icon: AppIcon(all ? Icons.deselect : Icons.select_all),
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final footer = _footer(context);
    final action = _selectAction(context);
    final list = CustomScrollView(
      slivers: [
        AppSliverHeader.page(
          title: context.l10n.linkMetadataUpdateTitle,
          actions: [?action],
        ),
        ..._body(context),
        // The footer keeps clear of the bar itself.
        if (footer == null)
          const NavBarSliverSpacer()
        else
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
    return Scaffold(
      body: footer == null
          ? list
          : Column(
              children: [
                Expanded(
                  child: AbsorbPointer(
                    absorbing: _progress != null,
                    child: list,
                  ),
                ),
                footer,
              ],
            ),
    );
  }
}

/// One saved song's differences, each with a switch: the phone's value
/// above the host's.
class _LinkMetadataSongPage extends StatelessWidget {
  const _LinkMetadataSongPage({
    required this.candidate,
    required this.selection,
    required this.hostName,
  });

  final LinkMetadataCandidate candidate;
  final _Selection selection;
  final String hostName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final differences = candidate.differences;
    final artist = candidate.copy.artistName.trim();
    return Scaffold(
      body: ListenableBuilder(
        listenable: selection,
        builder: (context, _) => CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: candidate.copy.trackName),
            if (artist.isNotEmpty)
              SliverToBoxAdapter(
                child: _Inset(
                  child: Text(
                    artist,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  for (final (index, difference) in differences.indexed)
                    SettingsSwitchItem(
                      key: ValueKey('link-metadata-${difference.field.name}'),
                      title: _fieldLabel(context, difference.field),
                      subtitle: [
                        l10n.linkMetadataUpdateOnPhone(
                          difference.phone.isEmpty
                              ? l10n.linkMetadataUpdateEmpty
                              : difference.phone,
                        ),
                        l10n.linkMetadataUpdateOnHost(
                          hostName,
                          difference.computer,
                        ),
                      ].join('\n'),
                      value: selection.isOn(candidate, difference.field),
                      onChanged: (on) =>
                          selection.set(candidate, difference.field, on),
                      showDivider: index < differences.length - 1,
                    ),
                ],
              ),
            ),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }
}

/// Lines free content up with the settings groups at any width.
class _Inset extends StatelessWidget {
  const _Inset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = settingsHorizontalInset(context, constraints.maxWidth);
      return Padding(
        padding: EdgeInsets.fromLTRB(inset + 8, 8, inset + 8, 8),
        child: child,
      );
    },
  );
}
