import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/retail_barcode.dart';
import 'package:mornye/widgets/metadata_barcode.dart';

void main() {
  test('encodes a valid UPC-A with its native retail symbology', () {
    final barcode = encodeRetailBarcode('036000291452');

    expect(barcode, isNotNull);
    expect(barcode!.symbology, 'UPC-A');
    expect(barcode.value, '036000291452');
    expect(barcode.modules, hasLength(95));
    expect(barcode.modules, startsWith('101'));
    expect(barcode.modules, endsWith('101'));
  });

  test('encodes a valid EAN-13 with its native retail symbology', () {
    final barcode = encodeRetailBarcode('4006381333931');

    expect(barcode, isNotNull);
    expect(barcode!.symbology, 'EAN-13');
    expect(barcode.modules, hasLength(95));
    expect(hasValidGtinCheckDigit(barcode.value), isTrue);
  });

  test('uses an exact scannable fallback for a malformed provider value', () {
    final barcode = encodeRetailBarcode('0012345678901');

    expect(barcode, isNotNull);
    expect(barcode!.symbology, 'CODE 128');
    expect(barcode.value, '0012345678901');
    expect(barcode.modules, isNotEmpty);
  });

  test('normalizes separators but rejects non-numeric values', () {
    expect(encodeRetailBarcode('0 36000-29145 2')?.value, '036000291452');
    expect(encodeRetailBarcode('not-a-upc'), isNull);
  });

  testWidgets('metadata barcode stays usable in a narrow metadata card', (
    tester,
  ) async {
    var copied = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: MetadataBarcode(
                value: '036000291452',
                label: 'UPC / Barcode',
                onCopy: () => copied = true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('UPC-A'), findsOneWidget);
    expect(find.text('036000291452'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(MetadataBarcode));
    expect(copied, isTrue);
  });
}
