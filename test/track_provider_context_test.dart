import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/track_provider.dart';

class _SearchResults extends TrackNotifier {
  @override
  TrackState build() => const TrackState(
    searchExtensionId: 'example.provider',
    selectedSearchFilter: 'album',
    searchSource: 'example.source',
  );
}

void main() {
  test('search UI edits retain the provider that owns existing results', () {
    final container = ProviderContainer(
      overrides: [trackProvider.overrideWith(_SearchResults.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(trackProvider.notifier);

    void expectProvider() {
      expect(
        container.read(trackProvider).searchExtensionId,
        'example.provider',
      );
      expect(container.read(trackProvider).searchSource, 'example.source');
    }

    notifier.setSearchText(true);
    expectProvider();
    notifier.setShowingRecentAccess(true);
    expectProvider();
    notifier.setSearchFilter('playlist');
    expectProvider();
    notifier.setSearchFilter(null);
    expectProvider();

    notifier.clear();
    expect(container.read(trackProvider).searchExtensionId, isNull);
    expect(container.read(trackProvider).searchSource, isNull);
  });
}
