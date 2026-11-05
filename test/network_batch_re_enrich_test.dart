import 'dart:convert';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/network_file_editor.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/network_edit_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final protocol in [NetworkProtocol.smb, NetworkProtocol.webdav]) {
    group('$protocol batch re-enrich', () {
      late NetworkEditFixture nas;
      late Directory temporary;
      late NetworkFileEditor editor;
      late LocalLibraryItem item;
      final changed = <String>[];
      const original = {'title': 'Old title', 'custom_tag': 'Preserve me'};

      setUp(() async {
        changed.clear();
        nas = NetworkEditFixture(protocol);
        await nas.start();
        nas.files['song.flac'] = utf8.encode(jsonEncode(original));
        temporary = await Directory.systemTemp.createTemp('batch-nas-test-');
        editor = NetworkFileEditor(
          storage: nas.storage,
          input: NetworkAudioAnalysisInput(
            storage: nas.storage,
            temporaryDirectory: () async => temporary,
          ),
          changed: (source) async => changed.add(source),
        );
        item = LocalLibraryItem(
          id: 'network_example',
          filePath: NetworkEditFixture.source,
          trackName: 'Old title',
          artistName: 'Artist',
          albumName: 'Album',
          scannedAt: DateTime(2026),
          format: 'flac',
        );
      });

      tearDown(() async {
        await nas.close();
        expect(nas.openHandles, 0);
        expect(nas.openSessions, 0);
        expect(await temporary.list().toList(), isEmpty);
        await temporary.delete(recursive: true);
      });

      Future<void> updateFile(String path) async {
        expect(File(path).isAbsolute, isTrue);
        expect(path, startsWith(temporary.path));
        expect(path, endsWith('.flac'));
        final tags = jsonDecode(await File(path).readAsString()) as Map;
        await File(
          path,
        ).writeAsString(jsonEncode({...tags, 'title': 'New title'}));
      }

      for (final method in ['native', 'ffmpeg']) {
        test(
          '$method edits an owned copy and reports the original source',
          () async {
            final written = <String>[];
            final runner = BatchReEnrichRunner(
              networkEditor: editor,
              beginPhase: () async => const AppSettings(),
              reEnrich: (request) async {
                if (request['preview_only'] == true) {
                  expect(request['file_path'], item.filePath);
                  return {
                    'method': 'preview',
                    'enriched_metadata': {
                      'track_name': 'New title',
                      // Never allow provider metadata to redirect a local write.
                      'file_path': 'network://invalid/redirect.flac',
                    },
                  };
                }
                final path = request['file_path'] as String;
                if (method == 'native') await updateFile(path);
                return {'method': method};
              },
              applyFfmpeg:
                  ({
                    required item,
                    required result,
                    required artistTagMode,
                  }) async {
                    expect(item.id, 'network_example');
                    await updateFile(item.filePath);
                    return true;
                  },
            );
            final preview = await runner.preview(
              [item],
              const ReEnrichFieldSelection(
                mode: ReEnrichBatchMode.selectedFields,
                fields: [ReEnrichFields.basicTags],
              ),
              shouldStop: () => false,
              onProgress: (_, _) {},
            );
            expect(preview, hasLength(1));
            expect(nas.files['song.flac'], utf8.encode(jsonEncode(original)));
            final count = await runner.apply(
              preview,
              shouldStop: () => false,
              onProgress: (_, _) {},
              onWritten: (item) {
                expect(changed, [NetworkEditFixture.source]);
                expect(jsonDecode(utf8.decode(nas.files['song.flac']!)), {
                  ...original,
                  'title': 'New title',
                });
                written.add(item.filePath);
              },
            );
            expect(count, 1);
            expect(written, [NetworkEditFixture.source]);
            expect(nas.files.keys, ['song.flac']);
          },
        );
      }

      for (final existing in [false, true]) {
        test('publishes external lyrics (existing: $existing)', () async {
          if (existing) nas.files['song.lrc'] = utf8.encode('Old lyrics');
          final runner = BatchReEnrichRunner(
            networkEditor: editor,
            beginPhase: () async => const AppSettings(),
            reEnrich: (request) async {
              await updateFile(request['file_path'] as String);
              return {
                'method': 'native',
                'write_external_lrc': true,
                'lyrics': '[00:01.00]New lyrics',
              };
            },
          );
          final count = await runner.apply(
            [
              BatchReEnrichPreview(
                item: item,
                updateFields: [ReEnrichFields.lyrics],
                enrichedMetadata: const {},
                changes: const [],
              ),
            ],
            shouldStop: () => false,
            onProgress: (_, _) {},
          );
          expect(count, 1);
          expect(utf8.decode(nas.files['song.lrc']!), '[00:01.00]New lyrics');
          expect(nas.files.keys.toSet(), {'song.flac', 'song.lrc'});
        });
      }

      test(
        'sidecar failure keeps committed audio and invalidates its metadata',
        () async {
          nas.files['song.lrc'] = utf8.encode('Old lyrics');
          nas.beforeMove = (from, to) {
            if (from.startsWith('.mornye-edit-') && to == 'song.lrc') {
              throw const Smb2Exception(
                'Cannot publish lyrics',
                type: Smb2ErrorType.accessDenied,
              );
            }
          };
          final runner = BatchReEnrichRunner(
            networkEditor: editor,
            beginPhase: () async => const AppSettings(),
            reEnrich: (request) async {
              await updateFile(request['file_path'] as String);
              return {
                'method': 'native',
                'write_external_lrc': true,
                'lyrics': '[00:01.00]New lyrics',
              };
            },
          );
          final count = await runner.apply(
            [
              BatchReEnrichPreview(
                item: item,
                updateFields: [ReEnrichFields.lyrics],
                enrichedMetadata: const {},
                changes: const [],
              ),
            ],
            shouldStop: () => false,
            onProgress: (_, _) {},
          );
          expect(count, 0);
          expect(changed, [item.filePath]);
          expect(jsonDecode(utf8.decode(nas.files['song.flac']!)), {
            ...original,
            'title': 'New title',
          });
          expect(utf8.decode(nas.files['song.lrc']!), 'Old lyrics');
          expect(nas.files.keys.toSet(), {'song.flac', 'song.lrc'});
        },
      );

      for (final failure in ['native', 'ffmpeg', 'upload']) {
        test(
          '$failure failure retains the original and reports no success',
          () async {
            nas.rejectPublish = failure == 'upload';
            final runner = BatchReEnrichRunner(
              networkEditor: editor,
              beginPhase: () async => const AppSettings(),
              reEnrich: (request) async {
                await updateFile(request['file_path'] as String);
                return {
                  'method': failure == 'native'
                      ? 'error'
                      : failure == 'ffmpeg'
                      ? 'ffmpeg'
                      : 'native',
                };
              },
              applyFfmpeg:
                  ({
                    required item,
                    required result,
                    required artistTagMode,
                  }) async => false,
            );
            final count = await runner.apply(
              [
                BatchReEnrichPreview(
                  item: item,
                  updateFields: [ReEnrichFields.basicTags],
                  enrichedMetadata: const {},
                  changes: const [],
                ),
              ],
              shouldStop: () => false,
              onProgress: (_, _) {},
              onWritten: (_) =>
                  fail('A failed write cannot be reported as saved'),
            );
            expect(count, 0);
            expect(changed, isEmpty);
            expect(nas.files.keys, ['song.flac']);
            expect(jsonDecode(utf8.decode(nas.files['song.flac']!)), original);
          },
        );
      }
    });
  }
}
