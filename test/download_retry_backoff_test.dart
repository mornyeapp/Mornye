import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_retry_backoff.dart';

void main() {
  test('elapsed delays allow retry and leave no cancellation behind', () async {
    final backoff = DownloadRetryBackoff();
    expect(await backoff.wait('item', Duration.zero), true);
    backoff.cancelItem('item');
    expect(await backoff.wait('item', Duration.zero), true);
  });

  test('cancellation releases only the selected long delay', () async {
    final backoff = DownloadRetryBackoff();
    final first = backoff.wait('first', const Duration(minutes: 5));
    final second = backoff.wait('second', Duration.zero);
    backoff.cancelItem('first');
    expect(await first, false);
    expect(await second, true);
  });

  test('replacement and disposal settle every pending waiter', () async {
    final backoff = DownloadRetryBackoff();
    final first = backoff.wait('item', const Duration(minutes: 5));
    final replacement = backoff.wait('item', const Duration(minutes: 5));
    final other = backoff.wait('other', const Duration(minutes: 5));
    expect(await first, false);
    backoff.cancelAll();
    expect(await replacement, false);
    expect(await other, false);
    backoff.cancelAll();
  });
}
