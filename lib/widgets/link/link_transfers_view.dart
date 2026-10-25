import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_transfers.dart';

/// Opens the Transfers list: a page on phones, a panel on desktop.
// Base placeholder: unit U (contract section 13.6) replaces this file.
Future<void> showLinkTransfers(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const LinkTransfersPage()));

class LinkTransfersPage extends ConsumerWidget {
  const LinkTransfersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(linkTransfersProvider);
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        children: [
          for (final transfer in transfers)
            ListTile(
              title: Text(transfer.peerName),
              subtitle: LinearProgressIndicator(
                value: transfer.status.fraction,
              ),
            ),
        ],
      ),
    );
  }
}
