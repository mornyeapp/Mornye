import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_queue_policy.dart';
import 'package:mornye/utils/file_access.dart';

void main() {
  group('isAbsoluteLocalPath', () {
    test('recognizes POSIX and Windows absolute paths', () {
      expect(isAbsoluteLocalPath(r'D:\Music'), isTrue);
      expect(isAbsoluteLocalPath(r'C:\Users\Mohammed\Music\Mornye'), isTrue);
      expect(isAbsoluteLocalPath(r'\\server\share\Music'), isTrue);
      expect(isAbsoluteLocalPath('/storage/emulated/0/Music'), isTrue);
      expect(isAbsoluteLocalPath(r'\Music'), isFalse);
      expect(isAbsoluteLocalPath('relative/path'), isFalse);
      expect(isAbsoluteLocalPath(''), isFalse);
      expect(
        isAbsoluteLocalPath('content://com.android.externalstorage/tree'),
        isFalse,
      );
    });
  });

  group('isStorageWriteFailure', () {
    test('does not treat extension sandbox path rejection as folder loss', () {
      expect(
        isStorageWriteFailure(
          errorType: 'permission',
          errorMessage:
              'file access denied: absolute paths are not allowed. Use relative paths within extension sandbox',
        ),
        isFalse,
      );
    });

    test(
      'still treats genuine permission failures as storage write failures',
      () {
        expect(
          isStorageWriteFailure(
            errorType: 'permission',
            errorMessage: 'Access is denied.',
          ),
          isTrue,
        );
      },
    );
  });
}
