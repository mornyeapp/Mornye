import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/confirm_and_delete_tracks.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:sqflite/sqflite.dart';

class _DeleteDatabase implements Database, Transaction {
  final rows = <String>{};
  final pathKeys = <String>{};
  final chunks = <List<Object?>>[];
  int transactions = 0;
  bool failRows = false;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    transactions++;
    final previousRows = Set<String>.of(rows);
    final previousKeys = Set<String>.of(pathKeys);
    try {
      return await action(this);
    } catch (_) {
      rows
        ..clear()
        ..addAll(previousRows);
      pathKeys
        ..clear()
        ..addAll(previousKeys);
      rethrow;
    }
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    expect(whereArgs!.length, lessThanOrEqualTo(500));
    expect('?'.allMatches(where!).length, whereArgs.length);
    expect(table, isIn(['library_path_keys', 'library']));
    if (table == 'library_path_keys') {
      expect(where, startsWith('item_id IN ('));
      chunks.add(List.of(whereArgs));
      pathKeys.removeAll(whereArgs);
    } else {
      expect(where, startsWith('id IN ('));
      expect(whereArgs, chunks.last);
      if (failRows) throw StateError('write failed');
      rows.removeAll(whereArgs);
    }
    return whereArgs.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('large selection deletes paired rows in bounded chunks once', () async {
    final ids = List.generate(1205, (index) => 'track-$index');
    final db = _DeleteDatabase()
      ..rows.addAll([...ids, 'retained'])
      ..pathKeys.addAll([...ids, 'retained']);
    await deleteLibraryItemsByIds(db, [...ids, ...ids.take(10)]);
    expect(db.transactions, 1);
    expect(db.chunks.map((chunk) => chunk.length), [500, 500, 205]);
    expect(db.chunks.expand((chunk) => chunk), ids);
    expect(db.rows, {'retained'});
    expect(db.pathKeys, {'retained'});
  });

  test('empty selection skips storage; failure keeps rows and keys', () async {
    final db = _DeleteDatabase()
      ..rows.add('retained')
      ..pathKeys.add('retained');
    await deleteLibraryItemsByIds(db, []);
    expect(db.transactions, 0);
    db.failRows = true;
    await expectLater(
      deleteLibraryItemsByIds(db, ['retained']),
      throwsStateError,
    );
    expect(db.rows, {'retained'});
    expect(db.pathKeys, {'retained'});
  });

  for (final mode in ['partial', 'cancel', 'throw', 'none', 'leave']) {
    testWidgets('batch confirmation persists successful IDs: $mode', (
      tester,
    ) async {
      final events = <String>[];
      final persisted = <List<String>>[];
      final commit = Completer<void>();
      int? result;
      Object? failure;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  try {
                    result = await confirmAndDeleteTracks(
                      context: context,
                      ids: ['first', 'failed', 'last'],
                      deleteItem: (id) async {
                        events.add(id);
                        if (mode == 'throw' && id == 'last') {
                          throw StateError('file delete failed');
                        }
                        return mode != 'none' && id != 'failed';
                      },
                      persistDeletedItems: (ids) async {
                        persisted.add(List.of(ids));
                        await commit.future;
                        events.add('committed');
                      },
                      onExitSelectionMode: () => events.add('exit'),
                    );
                  } catch (error) {
                    failure = error;
                  }
                },
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      if (mode == 'cancel') {
        await tester.tap(find.widgetWithText(AppDialogAction, 'Cancel'));
      } else {
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget is AppDialogAction && widget.filled,
          ),
        );
      }
      await tester.pumpAndSettle();
      if (mode == 'cancel' || mode == 'none') {
        expect(persisted, isEmpty);
      } else {
        expect(persisted, [
          mode == 'throw' ? ['first'] : ['first', 'last'],
        ]);
        expect(events, isNot(contains('exit')));
      }
      if (mode == 'leave') await tester.pumpWidget(const SizedBox());
      commit.complete();
      await tester.pumpAndSettle();
      if (mode == 'throw') {
        expect(failure, isStateError);
        expect(events.last, 'committed');
        expect(events, isNot(contains('exit')));
      } else {
        expect(failure, isNull);
        expect(result, mode == 'cancel' ? null : (mode == 'none' ? 0 : 2));
        if (mode == 'cancel') {
          expect(events, isEmpty);
        } else if (mode == 'leave') {
          expect(events.last, 'committed');
          expect(events, isNot(contains('exit')));
        } else {
          expect(events.last, 'exit');
          final message = tester
              .widget<Text>(
                find
                    .descendant(
                      of: find.byType(SnackBar),
                      matching: find.byType(Text),
                    )
                    .first,
              )
              .data!;
          expect(
            message,
            contains(
              mode == 'none'
                  ? 'Could not delete 3 tracks'
                  : 'Could not delete 1 track',
            ),
          );
          expect(message, isNot(contains('Deleted 0')));
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}
