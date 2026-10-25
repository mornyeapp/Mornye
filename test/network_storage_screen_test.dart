import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/services/link/link_source_names.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';

void main() {
  for (final olderFails in [false, true]) {
    testWidgets('latest folder refresh wins (older fails: $olderFails)', (
      tester,
    ) async {
      final service = _DelayedListings();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NetworkStorageScreen(
              service: service,
              connection: const NetworkConnection(
                id: 'nas',
                name: 'NAS',
                protocol: NetworkProtocol.webdav,
                address: 'https://nas.test/music/',
              ),
            ),
          ),
        ),
      );
      service.requests.single.complete([
        const NetworkEntry('Initial.flac', 'Initial.flac'),
      ]);
      await tester.pumpAndSettle();
      final refresh = find.byTooltip('Refresh');
      // Two taps before the disabled state is painted can overlap requests.
      await tester.tap(refresh);
      await tester.tap(refresh);
      expect(service.requests, hasLength(3));
      service.requests.last.complete([
        const NetworkEntry('Latest.flac', 'Latest.flac'),
      ]);
      await tester.pumpAndSettle();
      if (olderFails) {
        service.requests[1].completeError(const SocketException('offline'));
      } else {
        service.requests[1].complete([
          const NetworkEntry('Stale.flac', 'Stale.flac'),
        ]);
      }
      await tester.pumpAndSettle();
      expect(find.text('Latest.flac'), findsOneWidget);
      expect(find.text('Stale.flac'), findsNothing);
      expect(
        find.textContaining('The server could not be reached.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed sign-in stays on the form with a specific error', (
    tester,
  ) async {
    final service = _NetworkFixture()
      ..error = const SocketException('private-host');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NetworkStorageScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add connection'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('Name')), 'NAS');
    await tester.enterText(
      find.byKey(const ValueKey('Server or audio URL')),
      'smb://server/share',
    );
    final save = find.widgetWithText(AppActionButton, 'Connect and save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The server could not be reached.'),
      findsOneWidget,
    );
    expect(find.textContaining('private-host'), findsNothing);
    expect(await service.connections(), isEmpty);
  });
  for (final mornye in [false, true]) {
    testWidgets('local permission denial can be retried (Mornye: $mornye)', (
      tester,
    ) async {
      final service = _NetworkFixture()
        ..error = const LocalNetworkPermissionException();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : ThemeData(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NetworkStorageScreen(
              service: service,
              connection: const NetworkConnection(
                id: 'nas',
                name: 'NAS',
                protocol: NetworkProtocol.smb,
                address: 'smb://nas.local/music/',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Allow Nearby devices'), findsOneWidget);
      expect(
        find.textContaining('The server rejected the sign-in'),
        findsNothing,
      );
      service.error = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Allow Nearby devices'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'certificate trust requires a tap and stays on its server (Mornye: $mornye)',
      (tester) async {
        const certificate = NetworkCertificateException(
          origin: 'https://nas.test:6008',
          fingerprint: 'fixture-fingerprint',
        );
        final service = _NetworkFixture()..error = certificate;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : ThemeData(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: NetworkStorageScreen(service: service),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add connection'));
        await tester.pumpAndSettle();
        // The connected button group also lays out an offstage copy of each
        // label to measure it; tap the visible one.
        await tester.tap(find.text('WebDAV').hitTestable());
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('Name')), 'NAS');
        final address = find.byKey(const ValueKey('Server or audio URL'));
        await tester.enterText(address, 'https://nas.test:6008/music');
        await tester.pumpAndSettle();
        final save = find.widgetWithText(AppActionButton, 'Connect and save');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(await service.connections(), isEmpty);
        expect(find.textContaining(certificate.fingerprint), findsOneWidget);
        final trust = find.widgetWithText(
          AppActionButton,
          'Trust certificate and retry',
        );
        // Editing the server after an error must not transfer the approval.
        await tester.ensureVisible(address);
        await tester.enterText(address, 'https://other.test:6008/music');
        await tester.pumpAndSettle();
        await tester.ensureVisible(trust);
        await tester.pumpAndSettle();
        await tester.tap(trust);
        await tester.pumpAndSettle();
        expect(service.lastAttempt!.trustedCertificateSha256, isNull);
        expect(await service.connections(), isEmpty);
        await tester.ensureVisible(address);
        await tester.enterText(address, 'https://nas.test:6008/music');
        await tester.pumpAndSettle();
        await tester.ensureVisible(trust);
        await tester.pumpAndSettle();
        await tester.tap(trust);
        await tester.pumpAndSettle();
        expect(
          (await service.connections()).single.trustedCertificateSha256,
          certificate.fingerprint,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'saved networks open their own browser and retry (Mornye: $mornye)',
      (tester) async {
        final service = _NetworkFixture();
        await service.save(
          const NetworkConnection(
            id: 'nas',
            name: 'My NAS',
            protocol: NetworkProtocol.webdav,
            address: 'https://nas.test/music/',
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : ThemeData(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: NetworkStorageScreen(service: service),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('My NAS'), findsOneWidget);
        await tester.tap(find.text('My NAS'));
        await tester.pumpAndSettle();
        expect(find.text('Album'), findsOneWidget);
        await tester.tap(find.text('Album'));
        await tester.pumpAndSettle();
        expect(find.text('Song.flac'), findsOneWidget);
        expect(service.paths, ['', 'Album/']);
        service.fail = true;
        await tester.tap(find.byTooltip('Refresh').last);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not access the network source.'),
          findsOneWidget,
        );
        service.fail = false;
        await tester.tap(find.widgetWithText(AppActionButton, 'Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Song.flac'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('a paired computer shows as Mornye Link (Mornye: $mornye)', (
      tester,
    ) async {
      final service = _NetworkFixture();
      await service.save(
        const NetworkConnection(
          id: 'desk',
          name: 'Studio Mac',
          protocol: NetworkProtocol.subsonic,
          address: 'https://192.168.1.20:4533/',
        ),
      );
      await service.save(
        const NetworkConnection(
          id: 'nas',
          name: 'My NAS',
          protocol: NetworkProtocol.subsonic,
          address: 'https://nas.test/',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            linkSourceNamesProvider.overrideWithValue(const {
              'desk': 'Studio Mac',
            }),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : ThemeData(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NetworkStorageScreen(service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mornye Link · 192.168.1.20'), findsOneWidget);
      expect(find.text('Subsonic · nas.test'), findsOneWidget);
      // Link manages the computer, so only the NAS can be edited here.
      expect(find.byTooltip('Edit connection'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'connection form saves in the selected theme (Mornye: $mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _NetworkFixture();
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : ThemeData(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: NetworkStorageScreen(service: service),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add connection'));
        await tester.pumpAndSettle();
        expect(
          find.byType(CupertinoTextFormFieldRow),
          mornye ? findsWidgets : findsNothing,
        );
        expect(
          find.byType(TextFormField),
          mornye ? findsNothing : findsWidgets,
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('Name')),
            matching: find.byType(EditableText),
          ),
          'Home music',
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('Server or audio URL')),
            matching: find.byType(EditableText),
          ),
          'smb://nas.test/Music/',
        );
        final save = find.widgetWithText(AppActionButton, 'Connect and save');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect((await service.connections()).single.name, 'Home music');
        expect(find.text('Home music'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _NetworkFixture extends NetworkStorageService {
  _NetworkFixture() : super(read: () async => null, write: (_) async {});
  final paths = <String>[];
  bool fail = false;
  Object? error;
  NetworkConnection? lastAttempt;
  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async {
    paths.add(path);
    lastAttempt = c;
    if (error case final NetworkCertificateException certificate) {
      if (c.trustedCertificateSha256 != certificate.fingerprint ||
          c.root.origin != certificate.origin) {
        throw certificate;
      }
    } else if (error != null) {
      throw error!;
    }
    if (fail) throw StateError('Offline');
    return path.isEmpty
        ? [const NetworkEntry('Album/', 'Album', directory: true)]
        : [const NetworkEntry('Album/Song.flac', 'Song.flac')];
  }
}

class _DelayedListings extends NetworkStorageService {
  _DelayedListings() : super(read: () async => null, write: (_) async {});
  final requests = <Completer<List<NetworkEntry>>>[];

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection connection, [
    String path = '',
  ]) {
    final request = Completer<List<NetworkEntry>>();
    requests.add(request);
    return request.future;
  }
}
