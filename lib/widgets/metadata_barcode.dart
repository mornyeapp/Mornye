import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/retail_barcode.dart';

class MetadataBarcode extends StatelessWidget {
  final String value;
  final String label;
  final VoidCallback? onCopy;

  const MetadataBarcode({
    super.key,
    required this.value,
    required this.label,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final barcode = encodeRetailBarcode(value);
    if (barcode == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label ${barcode.value}',
      button: onCopy != null,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onCopy,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.qr_code_2_rounded,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      barcode.symbology,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (onCopy != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 9),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      RepaintBoundary(
                        child: SizedBox(
                          width: double.infinity,
                          height: 76,
                          child: CustomPaint(painter: _BarcodePainter(barcode)),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        barcode.value,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: const TextStyle(
                          color: Colors.black,
                          fontFamily: 'monospace',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  final RetailBarcodeData barcode;

  const _BarcodePainter(this.barcode);

  @override
  void paint(Canvas canvas, Size size) {
    final totalModules =
        barcode.modules.length + (barcode.quietZoneModules * 2);
    final moduleWidth = size.width / totalModules;
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    for (var i = 0; i < barcode.modules.length; i++) {
      if (barcode.modules.codeUnitAt(i) != 49) continue;
      final left = (barcode.quietZoneModules + i) * moduleWidth;
      canvas.drawRect(
        Rect.fromLTWH(left, 0, moduleWidth + 0.01, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarcodePainter oldDelegate) {
    return barcode.modules != oldDelegate.barcode.modules ||
        barcode.quietZoneModules != oldDelegate.barcode.quietZoneModules;
  }
}
