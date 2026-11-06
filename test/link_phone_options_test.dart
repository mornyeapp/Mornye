import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_phone_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('existing users keep computer songs visible by default', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(linkPhoneOptionsProvider.notifier).ensureLoaded();
    final options = container.read(linkPhoneOptionsProvider);
    expect(options.loaded, isTrue);
    expect(options.showComputerSongs, isTrue);
    expect(options.shareSongs, isTrue);
  });

  test(
    'computer song visibility persists independently of phone sharing',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(linkPhoneOptionsProvider.notifier);
      await notifier.ensureLoaded();
      notifier.setShowComputerSongs(false);
      notifier.setFollowDesktop(false);
      await pumpEventQueue();
      expect(
        (await SharedPreferences.getInstance()).getBool(
          LinkPhoneOptionsNotifier.showComputerSongsKey,
        ),
        isFalse,
      );

      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      await restored.read(linkPhoneOptionsProvider.notifier).ensureLoaded();
      final options = restored.read(linkPhoneOptionsProvider);
      expect(options.showComputerSongs, isFalse);
      expect(options.shareSongs, isTrue);
      expect(options.followDesktop, isFalse);
    },
  );
}
