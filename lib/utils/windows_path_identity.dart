/// A comparison/display path only. Keep the original path for filesystem IO.
/// Device namespaces and verbatim-only names must not acquire Win32 aliases.
String? windowsPathIdentity(String path) {
  var value = path.replaceAll('\\', '/');
  if (value.startsWith('//?/UNC/')) {
    value = '//${value.substring(8)}';
  } else if (value.startsWith('//?/')) {
    value = value.substring(4);
  }
  final drive = RegExp(r'^[A-Za-z]:/').hasMatch(value);
  final unc =
      value.startsWith('//') &&
      !value.startsWith('//?/') &&
      !value.startsWith('//./');
  if (!drive && !unc) return null;
  final parts = value.substring(drive ? 3 : 2).split('/');
  if (unc && (parts.length < 2 || parts.take(2).any((p) => p.isEmpty))) {
    return null;
  }
  if (parts.any(
    (p) => p == '.' || p == '..' || p.endsWith('.') || p.endsWith(' '),
  )) {
    return null;
  }
  return value;
}
