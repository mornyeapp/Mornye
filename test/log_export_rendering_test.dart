import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the renderer line tells Impeller from Skia', () {
    expect(
      rendererDiagnosticLine(shaderFilters: true),
      'Renderer: Impeller (shader filters supported)',
    );
    expect(
      rendererDiagnosticLine(shaderFilters: false),
      'Renderer: Skia (no shader filters)',
    );
  });

  test('the log export carries the renderer and glass level', () async {
    final export = await LogBuffer().exportWithDeviceInfo(
      glassLevel: 'frosted',
    );
    expect(export, contains('--- Rendering ---'));
    expect(export, contains(rendererDiagnosticLine()));
    expect(export, contains('Glass Level: frosted'));
    expect(
      export.indexOf('--- Rendering ---'),
      lessThan(export.indexOf('--- Log Summary ---')),
    );
  });
}
