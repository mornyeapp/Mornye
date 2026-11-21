import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/services/shell_navigation_service.dart';

void main() {
  int? switched(
    int index, {
    required bool fromMornye,
    required bool showStore,
    bool desktop = true,
  }) => shellIndexOfTab(
    shellTabAt(index, showStore: showStore),
    mornye: !fromMornye,
    showStore: showStore,
    desktop: desktop,
  );

  for (final showStore in [false, true]) {
    test('switching styles keeps the tab (store: $showStore)', () {
      final search = showStore ? 3 : 2;
      final settings = showStore ? 4 : 3;

      // Both styles order their destinations alike.
      for (final fromMornye in [false, true]) {
        for (final index in [0, 1, if (showStore) 2, search, settings]) {
          expect(
            switched(index, fromMornye: fromMornye, showStore: showStore),
            index,
          );
        }
      }
      // Mornye phones have no Settings destination.
      expect(
        switched(
          settings,
          fromMornye: false,
          showStore: showStore,
          desktop: false,
        ),
        isNull,
      );
      expect(
        switched(
          search,
          fromMornye: false,
          showStore: showStore,
          desktop: false,
        ),
        search,
      );
    });
  }

  test('Search follows the Store, Settings follows Search', () {
    expect(shellTabAt(2, showStore: false), ShellTab.search);
    expect(shellTabAt(3, showStore: false), ShellTab.settings);
    expect(shellTabAt(2, showStore: true), ShellTab.repository);
    expect(shellTabAt(3, showStore: true), ShellTab.search);
    expect(shellTabAt(4, showStore: true), ShellTab.settings);
  });
}
