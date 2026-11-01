import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/clickable_metadata.dart';

/// A stand-in album page that links to [linkTo].
class _AlbumPage extends StatefulWidget {
  const _AlbumPage(this.page, {required this.linkTo});

  final DetailPage page;
  final DetailPage linkTo;

  @override
  State<_AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<_AlbumPage> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    DetailPage.mark(context, widget.page);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => pushViaPreferredNavigator(
        context,
        (_) => _AlbumPage(widget.linkTo, linkTo: widget.linkTo),
        page: widget.linkTo,
      ),
      child: Text('album ${widget.page.id}'),
    ),
  );
}

void main() {
  Future<void> pumpAlbum(WidgetTester tester, DetailPage linkTo) =>
      tester.pumpWidget(
        MaterialApp(
          home: _AlbumPage(
            const DetailPage.album('one', providerId: 'provider'),
            linkTo: linkTo,
          ),
        ),
      );

  Future<void> follow(WidgetTester tester) async {
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
  }

  testWidgets('a link to the album on top keeps it', (tester) async {
    await pumpAlbum(tester, const DetailPage.album('one'));
    await follow(tester);
    expect(find.byType(_AlbumPage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('a link to another album opens it once', (tester) async {
    await pumpAlbum(tester, const DetailPage.album('two'));
    await follow(tester);
    expect(find.byType(_AlbumPage, skipOffstage: false), findsNWidgets(2));
    // The second page now links to itself.
    await follow(tester);
    expect(find.byType(_AlbumPage, skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('the same id from another provider opens', (tester) async {
    await pumpAlbum(
      tester,
      const DetailPage.album('one', providerId: 'other-provider'),
    );
    await follow(tester);
    expect(find.byType(_AlbumPage, skipOffstage: false), findsNWidgets(2));
  });
}
