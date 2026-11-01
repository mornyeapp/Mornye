import 'dart:io';

/// An ALSA playback device the Linux exclusive output can open directly,
/// without the sound server.
class AlsaOutputDevice {
  const AlsaOutputDevice({required this.id, required this.label});

  /// The mpv device name, `alsa/hw:CARD=<card>,DEV=<device>`.
  final String id;

  /// The card and device names, as the system lists them.
  final String label;
}

final _cardLine = RegExp(r'^\s*(\d+)\s+\[(\S+)\s*\]:\s*\S+\s+-\s+(.+?)\s*$');
final _pcmLine = RegExp(r'^(\d+)-(\d+):\s*(.*?)\s*:.*\bplayback\b');

/// The playback devices that `/proc/asound/cards` and `/proc/asound/pcm`
/// list, in card and device order.
List<AlsaOutputDevice> parseAlsaOutputDevices({
  required String cards,
  required String pcm,
}) {
  final cardsByIndex = <int, (String, String)>{};
  for (final line in cards.split('\n')) {
    final match = _cardLine.firstMatch(line);
    if (match == null) continue;
    cardsByIndex[int.parse(match[1]!)] = (match[2]!, match[3]!);
  }
  final devices = <AlsaOutputDevice>[];
  for (final line in pcm.split('\n')) {
    final match = _pcmLine.firstMatch(line);
    if (match == null) continue;
    final card = cardsByIndex[int.parse(match[1]!)];
    if (card == null) continue;
    final (id, name) = card;
    final device = int.parse(match[2]!);
    devices.add(
      AlsaOutputDevice(
        id: 'alsa/hw:CARD=$id,DEV=$device',
        label: '$name: ${match[3]!}',
      ),
    );
  }
  return devices;
}

/// This machine's ALSA playback devices; empty where `/proc/asound` is
/// missing.
Future<List<AlsaOutputDevice>> listAlsaOutputDevices() async {
  try {
    return parseAlsaOutputDevices(
      cards: await File('/proc/asound/cards').readAsString(),
      pcm: await File('/proc/asound/pcm').readAsString(),
    );
  } on FileSystemException {
    return const [];
  }
}
