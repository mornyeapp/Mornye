import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/open_audio_controller.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/audio_file_open_service.dart';
import 'package:mornye/services/playable_media.dart';

class _Player extends MusicPlayerController {
  final queues = <List<PlayableMedia>>[];
  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    expect(initialIndex, 0);
    queues.add(items);
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'external');
  @override
  void setPlayerMode(String mode) => state = state.copyWith(playerMode: mode);
}

class _LocalItem extends LocalMediaItemNotifier {
  @override
  Stream<MediaItem?> build() => Stream.value(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late ProviderContainer container;
  late _Player player;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('mornye-open-controller-');
    player = _Player();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localMediaItemProvider.overrideWith(_LocalItem.new),
        musicPlayerControllerProvider.overrideWithValue(player),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await folder.delete(recursive: true);
  });

  test(
    'opens standalone files without a Library record or external-player loop',
    () async {
      final file = await File(
        '${folder.path}/01. Song.flac',
      ).writeAsString('audio');
      await container.read(openAudioControllerProvider.notifier).open([
        OpenAudioFile(file.path),
      ]);
      final media = player.queues.single.single;
      expect(media.source, file.path);
      expect(media.id, 'opened:${file.path}');
      expect(media.title, '01. Song');
      expect(media.format, 'FLAC');
      expect(container.read(settingsProvider).playerMode, 'internal');
      expect(container.read(openAudioControllerProvider), isFalse);
    },
  );

  test(
    'an empty folder reports an error without replacing the existing queue',
    () async {
      await expectLater(
        container.read(openAudioControllerProvider.notifier).open([
          OpenAudioFile(folder.path),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      expect(player.queues, isEmpty);
      expect(container.read(settingsProvider).playerMode, 'external');
      expect(container.read(openAudioControllerProvider), isFalse);
    },
  );

  test(
    'a newer open request supersedes an unfinished folder expansion',
    () async {
      final file = await File('${folder.path}/Song.wav').writeAsString('audio');
      final controller = container.read(openAudioControllerProvider.notifier);
      final old = controller.open([OpenAudioFile(folder.path)]);
      final current = controller.open([
        const OpenAudioFile('content://media/42', name: 'Latest.opus'),
      ]);
      await Future.wait([old, current]);
      expect(player.queues, hasLength(1));
      expect(player.queues.single.single.source, 'content://media/42');
      expect(await file.exists(), isTrue);
    },
  );
}
