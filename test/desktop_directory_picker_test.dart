import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/desktop_folders.dart';

class _Picker extends FilePickerPlatform {
  _Picker(this.result);

  final String? result;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => result;
}

void main() {
  void usePicker(String? result) {
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker(result);
    addTearDown(() => FilePickerPlatform.instance = original);
  }

  test('returns the picked folder as the same plain path', () async {
    usePicker('/Users/someone/Music/Mornye');
    expect(await pickDesktopDirectoryPath(), '/Users/someone/Music/Mornye');
  });

  test('keeps spaces and non-ASCII names', () async {
    usePicker('/Volumes/Data/Música Nueva');
    expect(await pickDesktopDirectoryPath(), '/Volumes/Data/Música Nueva');
  });

  test('a cancelled picker returns null', () async {
    usePicker(null);
    expect(await pickDesktopDirectoryPath(), isNull);
  });
}
