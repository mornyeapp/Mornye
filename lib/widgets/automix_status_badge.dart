import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/automix_status.dart';

class AutoMixStatusBadge extends StatelessWidget {
  const AutoMixStatusBadge({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AutoMixStatus>(
    valueListenable: autoMixStatus,
    builder: (context, status, _) {
      if (status == AutoMixStatus.idle) return const SizedBox.shrink();
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            status == AutoMixStatus.mixing
                ? context.l10n.autoMixMixing
                : context.l10n.autoMixCrossfading,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );
    },
  );
}
