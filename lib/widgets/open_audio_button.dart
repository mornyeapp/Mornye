import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/open_audio_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

Future<void> pickOpenAudio(
  BuildContext context,
  WidgetRef ref, {
  required bool folder,
}) async {
  try {
    final controller = ref.read(openAudioControllerProvider.notifier);
    if (folder) {
      await controller.pickFolder();
    } else {
      await controller.pickFiles();
    }
  } catch (error) {
    if (context.mounted) showCannotOpenFileSnackBar(context, error);
  }
}

/// A direct playback entry point, separate from adding a Library source.
class OpenAudioButton extends ConsumerWidget {
  const OpenAudioButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(openAudioControllerProvider);
    return AppIconButton(
      icon: const Icon(Icons.folder_open_outlined),
      tooltip: context.l10n.openAudio,
      onPressed: busy
          ? null
          : () {
              final box = context.findRenderObject()! as RenderBox;
              unawaited(
                showContextMenu(
                  context,
                  position: box.localToGlobal(Offset(0, box.size.height)),
                  groups: [
                    [
                      ContextMenuAction(
                        icon: Icons.audio_file_outlined,
                        label: context.l10n.openAudioFiles,
                        onSelected: () => unawaited(
                          pickOpenAudio(context, ref, folder: false),
                        ),
                      ),
                      ContextMenuAction(
                        icon: Icons.folder_open_outlined,
                        label: context.l10n.openAudioFolder,
                        onSelected: () => unawaited(
                          pickOpenAudio(context, ref, folder: true),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
    );
  }
}
