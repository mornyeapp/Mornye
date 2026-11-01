import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/update_checker.dart';
import 'package:mornye/services/apk_downloader.dart';
import 'package:mornye/services/desktop_diagnostics.dart';
import 'package:mornye/services/desktop_updater.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/update_progress_notifications.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/theme/mornye_theme.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final VoidCallback onDismiss;
  final VoidCallback onDisableUpdates;

  /// When true the dialog cannot be dismissed: the installed version is too
  /// many releases behind and updating is mandatory.
  final bool forced;

  const UpdateDialog({
    super.key,
    required this.updateInfo,
    required this.onDismiss,
    required this.onDisableUpdates,
    this.forced = false,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0;
  String _statusText = '';
  static final RegExp _whatsNewPattern = RegExp(
    r"###?\s*What'?s\s*New\s*\n",
    caseSensitive: false,
  );
  static final RegExp _cutoffPattern = RegExp(
    r'\n---|\n###?\s*Downloads',
    caseSensitive: false,
  );
  static final RegExp _sectionPattern = RegExp(r'^#{1,3}\s*(.+)$');
  static final RegExp _listPattern = RegExp(r'^[-*]\s+(.+)$');
  static final RegExp _subListPattern = RegExp(r'^\s+[-*]\s+(.+)$');
  static final RegExp _boldPattern = RegExp(r'\*\*([^*]+)\*\*');
  static final RegExp _codePattern = RegExp(r'`([^`]+)`');

  /// Set once a desktop update needs one more step from the user: quitting
  /// (macOS) or restarting (Linux AppImage).
  _DesktopFinish? _desktopFinish;

  bool get _opensReleasePage {
    final info = widget.updateInfo;
    if (info.installKind == UpdateInstallKind.apk) {
      return info.apkDownloadUrl == null;
    }
    return !info.hasDesktopPackage;
  }

  Future<void> _openReleasePage() async {
    final uri = Uri.parse(widget.updateInfo.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (mounted && !widget.forced) Navigator.pop(context);
  }

  Future<void> _downloadAndInstall() async {
    if (_opensReleasePage) {
      await _openReleasePage();
      return;
    }
    if (widget.updateInfo.hasDesktopPackage) {
      await _downloadAndInstallDesktop();
      return;
    }
    final apkUrl = widget.updateInfo.apkDownloadUrl!;

    setState(() {
      _isDownloading = true;
      _progress = 0;
      _statusText = context.l10n.updateStartingDownload;
    });

    final notificationService = NotificationService();

    // Without a foreground service the download freezes when the screen
    // turns off; its notification then carries the progress.
    await notificationService.beginUpdateDownloadWork(
      version: widget.updateInfo.version,
    );
    final progressNotifications = UpdateProgressNotifications(
      (received, total) => notificationService.showUpdateDownloadProgress(
        version: widget.updateInfo.version,
        received: received,
        total: total,
      ),
    );
    final String? filePath;
    try {
      filePath = await ApkDownloader.downloadApk(
        url: apkUrl,
        version: widget.updateInfo.version,
        expectedSha256: widget.updateInfo.apkSha256,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _progress = total > 0 ? received / total : 0;
              final receivedMB = formatMegabytes(received);
              final totalMB = formatMegabytes(total);
              _statusText = '$receivedMB / $totalMB MB';
            });
          }
          progressNotifications.update(received, total);
        },
      );
    } finally {
      await progressNotifications.finish();
      await notificationService.endBackgroundWork(
        NotificationService.updateDownloadWorkKind,
      );
    }

    if (filePath != null) {
      await notificationService.cancelUpdateNotification();

      await notificationService.showUpdateDownloadComplete(
        version: widget.updateInfo.version,
      );

      if (mounted) {
        if (widget.forced) {
          // Keep the mandatory dialog up behind the installer so backing out
          // of the install cannot bypass it; allow a retry.
          setState(() {
            _isDownloading = false;
            _statusText = '';
          });
        } else {
          Navigator.pop(context);
        }
      }

      await ApkDownloader.installApk(filePath);
    } else {
      await notificationService.cancelUpdateNotification();

      await notificationService.showUpdateDownloadFailed();

      if (mounted) {
        setState(() {
          _isDownloading = false;
          _statusText = context.l10n.updateDownloadFailed;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.updateFailedMessage)),
        );
      }
    }
  }

  Future<void> _downloadAndInstallDesktop() async {
    final info = widget.updateInfo;
    final updater = DesktopUpdater();
    setState(() {
      _isDownloading = true;
      _progress = 0;
      _statusText = context.l10n.updateStartingDownload;
    });

    try {
      final file = await updater.download(
        info,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0 ? received / total : 0;
            _statusText =
                '${formatMegabytes(received)} / ${formatMegabytes(total)} MB';
          });
        },
      );
      if (!mounted) return;

      switch (info.installKind) {
        case UpdateInstallKind.windowsInstaller:
          setState(() => _statusText = context.l10n.updateStartingInstaller);
          await updater.startWindowsInstaller(file);
          // The installer waits for this process to close its files. A
          // planned quit, so the next launch reports no crash.
          DesktopDiagnostics.instance?.endSession();
          exit(0);
        case UpdateInstallKind.macosDiskImage:
          await updater.openDiskImage(file);
          if (mounted) {
            setState(() {
              _isDownloading = false;
              _desktopFinish = _DesktopFinish.quit;
            });
          }
        case UpdateInstallKind.linuxAppImage:
          await updater.replaceAppImage(file, info.appImagePath!);
          if (mounted) {
            setState(() {
              _isDownloading = false;
              _desktopFinish = _DesktopFinish.restart;
            });
          }
        case UpdateInstallKind.apk:
        case UpdateInstallKind.releasePage:
          break;
      }
    } catch (_) {
      // DesktopUpdater logs the cause.
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _statusText = context.l10n.updateDownloadFailed;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.updateFailedMessage)));
    }
  }

  Future<void> _finishDesktopUpdate() async {
    if (_desktopFinish == _DesktopFinish.restart) {
      await DesktopUpdater().restartAppImage(widget.updateInfo.appImagePath!);
    }
    DesktopDiagnostics.instance?.endSession();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !widget.forced,
      child: AppDialogSurface(
        backgroundColor: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          // Keeps the changelog column readable on tablets/landscape.
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.system_update_rounded,
                        color: colorScheme.onPrimaryContainer,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.forced
                                ? context.l10n.updateRequiredTitle
                                : context.l10n.updateAvailable,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.forced
                                ? context.l10n.updateRequiredNotice(
                                    widget.updateInfo.releasesBehind,
                                  )
                                : context.l10n.updateNewVersionReady,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: widget.forced
                                      ? colorScheme.error
                                      : colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  // Material's version chips carry their own containers, so
                  // the row is not boxed a second time.
                  decoration: context.isMornye
                      ? BoxDecoration(
                          color: MornyeTheme.controlFill(context),
                          borderRadius: BorderRadius.circular(16),
                        )
                      : null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: _VersionChip(
                          version: AppInfo.displayVersion,
                          label: context.l10n.updateCurrent,
                          colorScheme: colorScheme,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: _VersionChip(
                          version: widget.updateInfo.version,
                          label: context.l10n.updateNew,
                          colorScheme: colorScheme,
                          isNew: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                if (_isDownloading) ...[
                  Container(
                    padding: context.isMornye
                        ? const EdgeInsets.all(16)
                        : EdgeInsets.zero,
                    decoration: context.isMornye
                        ? BoxDecoration(
                            color: MornyeTheme.controlFill(context),
                            borderRadius: BorderRadius.circular(16),
                          )
                        : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            AppLoadingIndicator(
                              size: 20,
                              strokeWidth: 2,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              context.l10n.updateDownloading,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: AppProgressIndicator.linear(
                            value: _progress,
                            minHeight: 6,
                            trackColor: colorScheme.surfaceContainerHighest,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _statusText,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            Text(
                              '${(_progress * 100).toInt()}%',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else if (_desktopFinish != null) ...[
                  Text(
                    _desktopFinish == _DesktopFinish.restart
                        ? context.l10n.updateReadyToRestart
                        : context.l10n.updateMacInstallHint,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ] else ...[
                  Text(
                    context.l10n.updateWhatsNew,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    // The scroll well uses the next tonal step above the
                    // dialog surface.
                    decoration: BoxDecoration(
                      color: context.isMornye
                          ? MornyeTheme.controlFill(context)
                          : colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _formatChangelog(
                          widget.updateInfo.changelog,
                          context.l10n.updateSeeReleaseNotes,
                        ),
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(height: 1.5),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                if (_isDownloading)
                  SizedBox(
                    width: double.infinity,
                    child: widget.forced
                        ? const SizedBox.shrink()
                        : AppDialogAction(
                            outlined: true,
                            onPressed: () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(context.l10n.dialogCancel),
                          ),
                  )
                else
                  Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: AppActionButton(
                          onPressed: _desktopFinish != null
                              ? _finishDesktopUpdate
                              : _downloadAndInstall,
                          icon: Icon(switch (_desktopFinish) {
                            _DesktopFinish.restart => Icons.restart_alt_rounded,
                            _DesktopFinish.quit => Icons.exit_to_app_rounded,
                            null =>
                              _opensReleasePage
                                  ? Icons.open_in_new_rounded
                                  : Icons.download_rounded,
                          }, size: 20),
                          label: Text(switch (_desktopFinish) {
                            _DesktopFinish.restart =>
                              context.l10n.updateRestartNow,
                            _DesktopFinish.quit => context.l10n.updateQuitApp,
                            null =>
                              _opensReleasePage
                                  ? context.l10n.updateViewRelease
                                  : context.l10n.updateDownloadInstall,
                          }),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      if (!widget.forced) const SizedBox(height: 8),
                      if (!widget.forced)
                        Row(
                          children: [
                            Expanded(
                              child: AppDialogAction(
                                onPressed: () {
                                  widget.onDisableUpdates();
                                  Navigator.pop(context);
                                },
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  context.l10n.updateDontRemind,
                                  style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AppDialogAction(
                                outlined: true,
                                onPressed: () {
                                  widget.onDismiss();
                                  Navigator.pop(context);
                                },
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(context.l10n.updateLater),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatChangelog(String changelog, String emptyFallback) {
    var content = changelog;

    final whatsNewMatch = _whatsNewPattern.firstMatch(content);
    if (whatsNewMatch != null) {
      content = content.substring(whatsNewMatch.end);
    }

    final cutoffMatch = _cutoffPattern.firstMatch(content);
    if (cutoffMatch != null) {
      content = content.substring(0, cutoffMatch.start);
    }

    final lines = content.split('\n');
    final formattedLines = <String>[];

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      final sectionMatch = _sectionPattern.firstMatch(line);
      if (sectionMatch != null) {
        final section = sectionMatch.group(1)?.trim();
        if (section != null && section.isNotEmpty) {
          if (formattedLines.isNotEmpty) formattedLines.add('');
          formattedLines.add(section);
        }
        continue;
      }

      final listMatch = _listPattern.firstMatch(line);
      if (listMatch != null) {
        var itemText = listMatch.group(1) ?? '';
        itemText = itemText.replaceAllMapped(
          _boldPattern,
          (m) => m.group(1) ?? '',
        );
        itemText = itemText.replaceAllMapped(
          _codePattern,
          (m) => m.group(1) ?? '',
        );
        formattedLines.add('• $itemText');
        continue;
      }

      final subListMatch = _subListPattern.firstMatch(line);
      if (subListMatch != null) {
        var itemText = subListMatch.group(1) ?? '';
        itemText = itemText.replaceAllMapped(
          _boldPattern,
          (m) => m.group(1) ?? '',
        );
        formattedLines.add('  - $itemText');
        continue;
      }
    }

    var formatted = formattedLines.join('\n').trim();
    if (formatted.length > 2000) {
      formatted = '${formatted.substring(0, 2000)}...';
    }

    return formatted.isEmpty ? emptyFallback : formatted;
  }
}

enum _DesktopFinish { quit, restart }

class _VersionChip extends StatelessWidget {
  final String version;
  final String label;
  final ColorScheme colorScheme;
  final bool isNew;

  const _VersionChip({
    required this.version,
    required this.label,
    required this.colorScheme,
    this.isNew = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: context.isMornye
                ? Colors.transparent
                : isNew
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            'v$version',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: context.isMornye && isNew
                  ? colorScheme.primary
                  : isNew
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
              fontWeight: isNew ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> showUpdateDialog(
  BuildContext context, {
  required UpdateInfo updateInfo,
  required VoidCallback onDisableUpdates,
  bool forced = false,
}) async {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: !forced,
    builder: (context) => UpdateDialog(
      updateInfo: updateInfo,
      onDismiss: () {},
      onDisableUpdates: onDisableUpdates,
      forced: forced,
    ),
  );
}
