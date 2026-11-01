part of '../platform_bridge.dart';

Object? _decodeJsonInBackground(String json) => jsonDecode(json);
String _encodeJsonInBackground(Object? value) => jsonEncode(value);

Future<String> _encodeNativeDataJobRequest(Map<String, dynamic> request) async {
  var nodes = 0;
  var characters = 0;
  bool small(Object? value, int depth) {
    if (++nodes > 256 || depth > 8) return false;
    if (value == null || value is bool || value is num) return true;
    if (value is String) {
      characters += value.length;
      return characters <= 16 * 1024;
    }
    if (value is List<Object?>) {
      if (value.length > 64) return false;
      return value.every((item) => small(item, depth + 1));
    }
    if (value is Map<Object?, Object?>) {
      if (value.length > 64) return false;
      return value.entries.every(
        (entry) =>
            entry.key is String &&
            small(entry.key, depth + 1) &&
            small(entry.value, depth + 1),
      );
    }
    return false;
  }

  if (small(request, 0)) return jsonEncode(request);
  return compute(_encodeJsonInBackground, request);
}

String _encodeBoundedLookupCacheInBackground(Map<String, dynamic> entries) {
  final result = StringBuffer('{');
  var bytes = 2; // Opening and closing braces.
  var count = 0;
  for (final entry in entries.entries) {
    final fragment =
        '${_encodeJsonInBackground(entry.key)}:${_encodeJsonInBackground(entry.value)}';
    final entryBytes = utf8.encode(fragment).length;
    final separatorBytes = count == 0 ? 0 : 1;
    if (entryBytes > PlatformBridge._persistentCacheMaxEntryBytes ||
        bytes + separatorBytes + entryBytes >
            PlatformBridge._persistentCacheMaxBytes) {
      continue;
    }
    if (count > 0) result.write(',');
    result.write(fragment);
    bytes += separatorBytes + entryBytes;
    count++;
  }
  result.write('}');
  return result.toString();
}

Object? _decodeJsonFileInBackground(String path) {
  final contents = File(path).readAsStringSync();
  return contents.isEmpty ? null : jsonDecode(contents);
}
