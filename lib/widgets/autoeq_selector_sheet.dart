import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/autoeq_models.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/services/autoeq_database.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

Future<void> showAutoEqSelectorSheet(BuildContext context) {
  return showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    title: 'AutoEq (Wavelet)',
    maxHeightFactor: 0.90,
    builder: (sheetContext) => const _AutoEqSelectorContent(),
  );
}

class _AutoEqSelectorContent extends ConsumerStatefulWidget {
  const _AutoEqSelectorContent();

  @override
  ConsumerState<_AutoEqSelectorContent> createState() =>
      _AutoEqSelectorContentState();
}

class _AutoEqSelectorContentState
    extends ConsumerState<_AutoEqSelectorContent> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedBrand;
  final List<AutoEqProfile> _customProfiles = [];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _importGraphicEq() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'lrc', 'eq'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final content = utf8.decode(bytes);

      final profile = AutoEqDatabase.parseWaveletGraphicEq(file.name, content);
      if (profile != null) {
        setState(() {
          _customProfiles.insert(0, profile);
        });
        ref.read(equalizerProvider.notifier).applyPreset(profile.toEqualizerPreset());
        if (mounted) {
          showAppSnackBar(
            context,
            content: Text('AutoEq: ${profile.displayName} applicato'),
          );
          Navigator.pop(context);
        }
      } else {
        if (mounted) {
          showAppSnackBar(
            context,
            content: const Text('Formato GraphicEQ non valido'),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text('Errore durante l\'importazione: $e'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final eqState = ref.watch(equalizerProvider);
    final isMornye = context.isMornye;

    final results = [
      ..._customProfiles.where((p) =>
          _query.isEmpty ||
          p.displayName.toLowerCase().contains(_query.toLowerCase())),
      ...AutoEqDatabase.search(_query, brand: _selectedBrand),
    ];

    final brands = AutoEqDatabase.availableBrands;

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Cerca cuffie (es. AirPods, Sony, HD 600...)',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: isMornye
                          ? Colors.white.withValues(alpha: 0.08)
                          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 0,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Importa GraphicEQ (.txt)',
                child: IconButton.filledTonal(
                  onPressed: _importGraphicEq,
                  icon: const Icon(Icons.file_upload_outlined, size: 20),
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Brand chips row
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: const Text('Tutte', style: TextStyle(fontSize: 12)),
                  selected: _selectedBrand == null,
                  onSelected: (selected) {
                    if (selected) setState(() => _selectedBrand = null);
                  },
                ),
              ),
              for (final brand in brands)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(brand, style: const TextStyle(fontSize: 12)),
                    selected: _selectedBrand == brand,
                    onSelected: (selected) {
                      setState(() => _selectedBrand = selected ? brand : null);
                    },
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 8),
        const Divider(height: 1),

        // Results list
        Expanded(
          child: results.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nessun preset cuffie trovato per "$_query"',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
                  itemBuilder: (context, index) {
                    final profile = results[index];
                    final isApplied = _isProfileApplied(profile, eqState.settings);

                    return ListTile(
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundColor: isApplied
                            ? colorScheme.primary
                            : colorScheme.surfaceContainerHighest,
                        child: Icon(
                          _iconForType(profile.type),
                          size: 20,
                          color: isApplied
                              ? colorScheme.onPrimary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      title: Text(
                        profile.displayName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: isApplied ? FontWeight.w700 : FontWeight.w600,
                          color: isApplied ? colorScheme.primary : null,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: colorScheme.onSurface.withValues(alpha: 0.08),
                            ),
                            child: Text(
                              profile.type,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Preamp: ${profile.preamp > 0 ? '+' : ''}${profile.preamp.toStringAsFixed(1)} dB',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      trailing: SizedBox(
                        width: 72,
                        height: 28,
                        child: CustomPaint(
                          painter: _MiniEqCurvePainter(
                            gains: profile.gains,
                            color: isApplied
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      onTap: () {
                        ref
                            .read(equalizerProvider.notifier)
                            .applyPreset(profile.toEqualizerPreset());
                        showAppSnackBar(
                          context,
                          content: Text('AutoEq applicato: ${profile.displayName}'),
                        );
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  bool _isProfileApplied(AutoEqProfile profile, EqualizerSettings currentSettings) {
    if (currentSettings.gains.length != profile.gains.length) return false;
    for (var i = 0; i < profile.gains.length; i++) {
      if ((currentSettings.gains[i] - profile.gains[i]).abs() > 0.1) {
        return false;
      }
    }
    return true;
  }

  IconData _iconForType(String type) {
    final lower = type.toLowerCase();
    if (lower.contains('in-ear') || lower.contains('earbud')) {
      return Icons.earbuds;
    }
    return Icons.headphones;
  }
}

class _MiniEqCurvePainter extends CustomPainter {
  final List<double> gains;
  final Color color;

  const _MiniEqCurvePainter({required this.gains, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (gains.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final stepX = size.width / (gains.length - 1);
    final midY = size.height / 2;
    const maxRange = 8.0; // +/- 8 dB range

    for (var i = 0; i < gains.length; i++) {
      final x = i * stepX;
      final normalizedGain = (gains[i] / maxRange).clamp(-1.0, 1.0);
      final y = midY - (normalizedGain * (size.height * 0.45));

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        final prevX = (i - 1) * stepX;
        final prevGain = (gains[i - 1] / maxRange).clamp(-1.0, 1.0);
        final prevY = midY - (prevGain * (size.height * 0.45));
        final cpX1 = prevX + (stepX / 2);
        final cpX2 = prevX + (stepX / 2);
        path.cubicTo(cpX1, prevY, cpX2, y, x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MiniEqCurvePainter oldDelegate) =>
      oldDelegate.gains != gains || oldDelegate.color != color;
}
