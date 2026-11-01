import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/network_file_editor.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/artist_utils.dart';

import 'support/network_edit_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final protocol in [NetworkProtocol.smb, NetworkProtocol.webdav]) {
    group('$protocol metadata edits', () {
      late NetworkEditFixture nas;
      late Directory temporary;
      late NetworkFileEditor editor;
      late List<String> changes;
      const original = {
        'title': 'Old title',
        'artist': 'Artist',
        'lyrics': 'Old lyrics',
        'custom_tag': 'Keep me',
        'replaygain_track_gain': '-4.20 dB',
      };
      List<int> originalBytes() => utf8.encode(jsonEncode(original));

      setUp(() async {
        nas = NetworkEditFixture(protocol);
        await nas.start();
        nas.files['song.flac'] = originalBytes();
        temporary = await Directory.systemTemp.createTemp(
          'network-editor-test-',
        );
        changes = [];
        editor = NetworkFileEditor(
          storage: nas.storage,
          input: NetworkAudioAnalysisInput(
            storage: nas.storage,
            temporaryDirectory: () async => temporary,
          ),
          changed: (source) async => changes.add(source),
        );
      });
      tearDown(() async {
        await nas.close();
        expect(nas.openHandles, 0);
        expect(nas.openSessions, 0);
        expect(await temporary.list().toList(), isEmpty);
        await temporary.delete(recursive: true);
      });

      Future<MetadataSaveResult> save({
        bool failEdit = false,
        void Function()? duringEdit,
      }) async {
        final covers = MetadataCoverResources();
        try {
          return await MetadataPersistenceService(
            covers: covers,
            networkEditor: editor,
            edit: (path, metadata) async {
              expect(path, endsWith('.flac'));
              expect(path, isNot(startsWith('network://')));
              final old = jsonDecode(await File(path).readAsString()) as Map;
              await File(path).writeAsString(
                jsonEncode({
                  ...old,
                  'title': metadata['title'],
                  'lyrics': metadata['lyrics'],
                }),
              );
              duringEdit?.call();
              return failEdit
                  ? {'error': 'Could not edit tags'}
                  : {'method': 'native'};
            },
          ).save(
            MetadataSaveRequest(
              filePath: NetworkEditFixture.source,
              artistTagMode: artistTagModeJoined,
              metadata: const {
                'title': 'New title',
                'lyrics': '[00:01.00]New lyrics',
              },
            ),
          );
        } finally {
          await covers.dispose();
        }
      }

      test('writes metadata and lyrics back to the same NAS file', () async {
        expect((await save()).failure, isNull);
        expect(jsonDecode(utf8.decode(nas.files['song.flac']!)), {
          ...original,
          'title': 'New title',
          'lyrics': '[00:01.00]New lyrics',
        });
        expect(nas.files.keys, ['song.flac']);
        expect(changes, [NetworkEditFixture.source]);
      });

      test('a failed tag writer never uploads or publishes a change', () async {
        expect(
          (await save(failEdit: true)).failure,
          MetadataSaveFailure.backend,
        );
        expect(nas.files, {'song.flac': originalBytes()});
        expect(nas.methods, isEmpty);
        expect(changes, isEmpty);
      });

      test(
        'permission denial leaves the original and UI state unchanged',
        () async {
          nas.rejectWrites = true;
          expect((await save()).failure, isNotNull);
          expect(nas.files, {'song.flac': originalBytes()});
          expect(changes, isEmpty);
        },
      );

      test('a concurrent remote change is preserved', () async {
        final external = utf8.encode(
          jsonEncode({...original, 'title': 'Other editor'}),
        );
        expect(
          (await save(
            duringEdit: () => nas.files['song.flac'] = external,
          )).failure,
          isNotNull,
        );
        expect(nas.files, {'song.flac': external});
        expect(changes, isEmpty);
      });

      test('a failed final rename restores the original', () async {
        nas.rejectPublish = true;
        expect((await save()).failure, isNotNull);
        expect(nas.files, {'song.flac': originalBytes()});
        expect(changes, isEmpty);
      });

      test('a remote change during the original rename is restored', () async {
        final external = utf8.encode(
          jsonEncode({...original, 'title': 'Other editor'}),
        );
        nas.beforeMove = (from, to) {
          if (from == 'song.flac' && to.startsWith('.mornye-original-')) {
            nas.files[from] = external;
          }
        };
        expect((await save()).failure, isNotNull);
        expect(nas.files, {'song.flac': external});
        expect(changes, isEmpty);
      });

      test('a lost final rename response is verified by content', () async {
        nas.losePublishReply = true;
        expect((await save()).failure, isNull);
        expect(nas.files.keys, ['song.flac']);
        expect(
          jsonDecode(utf8.decode(nas.files['song.flac']!)),
          containsPair('title', 'New title'),
        );
        expect(changes, [NetworkEditFixture.source]);
      });

      test('a failed operation does not block the next edit', () async {
        expect((await save(failEdit: true)).failure, isNotNull);
        expect((await save()).failure, isNull);
        expect(changes, [NetworkEditFixture.source]);
      });

      test('simultaneous edits read the preceding saved version', () async {
        final started = Completer<void>();
        final release = Completer<void>();
        var secondStarted = false;
        final first = editor.edit(NetworkEditFixture.source, (path) async {
          started.complete();
          await release.future;
          await File(
            path,
          ).writeAsString(jsonEncode({...original, 'title': 'First'}));
          return true;
        }, succeeded: (saved) => saved);
        await started.future;
        final second = editor.edit(NetworkEditFixture.source, (path) async {
          secondStarted = true;
          final tags = jsonDecode(await File(path).readAsString()) as Map;
          expect(tags['title'], 'First');
          await File(
            path,
          ).writeAsString(jsonEncode({...tags, 'title': 'Second'}));
          return true;
        }, succeeded: (saved) => saved);
        expect(secondStarted, isFalse);
        release.complete();
        expect(await Future.wait([first, second]), [true, true]);
        expect(
          jsonDecode(utf8.decode(nas.files['song.flac']!)),
          containsPair('title', 'Second'),
        );
        expect(changes, hasLength(2));
      });

      test('an empty edited file cannot replace the original', () async {
        await expectLater(
          editor.edit(NetworkEditFixture.source, (path) async {
            await File(path).writeAsBytes([]);
            return true;
          }, succeeded: (saved) => saved),
          throwsStateError,
        );
        expect(nas.files, {'song.flac': originalBytes()});
        expect(changes, isEmpty);
      });

      for (final extension in ['mp3', 'm4a', 'aac', 'opus', 'ogg']) {
        test(
          'FFmpeg tag fallback publishes $extension artwork and gain tags',
          () async {
            final name = 'song.$extension';
            final source = NetworkStorageService.source('edit-nas', name);
            nas.files[name] = originalBytes();
            final covers = MetadataCoverResources();
            final cover = await covers.copyPicked(
              extension: 'jpg',
              bytes: utf8.encode('cover'),
            );
            try {
              final result =
                  await MetadataPersistenceService(
                    covers: covers,
                    networkEditor: editor,
                    edit: (path, _) async {
                      expect(path, endsWith('.$extension'));
                      return {'method': 'ffmpeg'};
                    },
                    read: (_) async => Map<String, dynamic>.from(original),
                    embed: (codec, path, coverPath, tags, mode) async {
                      expect(coverPath, cover.path);
                      expect(await File(coverPath!).exists(), isTrue);
                      expect(tags['REPLAYGAIN_TRACK_GAIN'], '-4.20 dB');
                      expect(tags['LYRICS'], '[00:01.00]Edited lyrics');
                      expect(tags['TITLE'], 'Edited title');
                      final old =
                          jsonDecode(await File(path).readAsString()) as Map;
                      await File(path).writeAsString(
                        jsonEncode({
                          ...old,
                          'title': tags['TITLE'],
                          'lyrics': tags['LYRICS'],
                          'cover': base64Encode(
                            await File(coverPath).readAsBytes(),
                          ),
                        }),
                      );
                      return path;
                    },
                  ).save(
                    MetadataSaveRequest(
                      filePath: source,
                      metadata: const {
                        'title': 'Edited title',
                        'lyrics': '[00:01.00]Edited lyrics',
                      },
                      artistTagMode: artistTagModeJoined,
                      selectedCoverPath: cover.path,
                    ),
                  );
              expect(result.failure, isNull);
              expect(jsonDecode(utf8.decode(nas.files[name]!)), {
                ...original,
                'title': 'Edited title',
                'lyrics': '[00:01.00]Edited lyrics',
                'cover': base64Encode(utf8.encode('cover')),
              });
              expect(nas.files.keys, unorderedEquals(['song.flac', name]));
              expect(changes, [source]);
            } finally {
              await covers.dispose();
            }
          },
        );
      }
    });
  }

  for (final protocol in [NetworkProtocol.http, NetworkProtocol.subsonic]) {
    test('$protocol cannot enter the NAS editor', () async {
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        NetworkConnection(
          id: 'readonly',
          name: 'Read only',
          protocol: protocol,
          address: 'https://example.test/music/',
        ),
      );
      final editor = NetworkFileEditor(storage: storage);
      await expectLater(
        editor.edit('network://readonly/song.flac', (_) async {
          fail('A read-only server must not be edited');
        }, succeeded: (_) => true),
        throwsFormatException,
      );
    });
  }
}
