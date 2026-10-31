import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/link/link_library_actions.dart';
import 'package:mornye/widgets/settings_group.dart';

Future<void> showDesktopLinkLibraryJobs(BuildContext context) =>
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.linkFileJobs,
      builder: (context, scroll) =>
          DesktopLinkLibraryJobsView(scrollController: scroll),
    );

/// All phones' file changes on this computer, including completed work from
/// a phone that has disconnected. No phone connection is needed to read them.
class DesktopLinkLibraryJobsView extends ConsumerWidget {
  const DesktopLinkLibraryJobsView({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(linkDesktopHostProvider);
    final host = ref.read(linkDesktopHostProvider.notifier);
    final jobs = state.libraryJobs.reversed
        .where(
          (entry) =>
              entry.job.action != LinkLibraryAction.readMetadata &&
              entry.job.action != LinkLibraryAction.reEnrichPreview,
        )
        .toList();
    final tokens = context.tokens;
    return ListView(
      controller: scrollController,
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(tokens.gapMd, 0, tokens.gapMd, tokens.gapLg),
      children: [
        if (jobs.isEmpty)
          EmptyState(
            icon: Icons.history,
            title: context.l10n.linkFileJobsEmpty,
            message: context.l10n.linkDesktopFileJobsEmptyMessage,
          )
        else
          SettingsGroup(
            children: [
              for (final (i, entry) in jobs.indexed)
                LinkLibraryJobRow(
                  key: ValueKey('${entry.deviceId}:${entry.job.id}'),
                  job: entry.job,
                  deviceName: host.deviceName(entry.deviceId),
                  showDivider: i < jobs.length - 1,
                  onCancel: () =>
                      host.cancelLibraryJob(entry.deviceId, entry.job.id),
                ),
            ],
          ),
      ],
    );
  }
}
