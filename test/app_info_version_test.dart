import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/app_info.dart';

void main() {
  test('release builds show the stable version on every platform', () {
    expect(AppInfo.versionLabel(debug: false), AppInfo.version);
  });

  test('debug builds stay internal on every platform', () {
    expect(AppInfo.versionLabel(debug: true), 'Internal');
  });
}
