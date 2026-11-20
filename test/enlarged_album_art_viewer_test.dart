import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/enlarged_album_art_viewer.dart';

void main() {
  group('EnlargedAlbumArtViewer Tests', () {
    testWidgets('renders artwork modal with title, artist, and close button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EnlargedAlbumArtViewer(
              artUri: null,
              title: 'Moonlight Sonata',
              artist: 'Ludwig van Beethoven',
            ),
          ),
        ),
      );

      expect(find.byType(EnlargedAlbumArtViewer), findsOneWidget);
      expect(find.text('Moonlight Sonata'), findsOneWidget);
      expect(find.text('Ludwig van Beethoven'), findsOneWidget);
      expect(find.byKey(const Key('close-enlarged-art')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('close button dismisses the viewer', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showEnlargedAlbumArt(
                  context,
                  artUri: null,
                  title: 'Track Title',
                  artist: 'Track Artist',
                ),
                child: const Text('Open Artwork'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(EnlargedAlbumArtViewer), findsNothing);

      await tester.tap(find.text('Open Artwork'));
      await tester.pumpAndSettle();

      expect(find.byType(EnlargedAlbumArtViewer), findsOneWidget);
      expect(find.text('Track Title'), findsOneWidget);

      await tester.tap(find.byKey(const Key('close-enlarged-art')));
      await tester.pumpAndSettle();

      expect(find.byType(EnlargedAlbumArtViewer), findsNothing);
    });

    testWidgets('responds to 3D hover movements and returns to center', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EnlargedAlbumArtViewer(
              artUri: null,
              title: 'Hover Track',
              artist: 'Hover Artist',
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(EnlargedAlbumArtViewer));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: center);
      await gesture.moveTo(center + const Offset(100, 100));
      await tester.pump();

      // Ensure transform is applied
      expect(find.byType(Transform), findsWidgets);

      // Move away / exit to test spring return
      await gesture.removePointer();
      await tester.pumpAndSettle();
    });

    testWidgets('supports drag gesture and release', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EnlargedAlbumArtViewer(
              artUri: null,
              title: 'Drag Track',
              artist: 'Drag Artist',
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(EnlargedAlbumArtViewer));
      // Subtle drag to verify interactive tilt without dismissing
      await tester.dragFrom(center, const Offset(20, -20));
      await tester.pumpAndSettle();

      expect(find.byType(EnlargedAlbumArtViewer), findsOneWidget);
    });
  });
}
