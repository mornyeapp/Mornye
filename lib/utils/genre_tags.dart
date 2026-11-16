final _listSeparators = RegExp(r'[;,\u0000]');

/// The genres a genre tag names, trimmed, in tag order and without
/// case-insensitive repeats.
///
/// A tag lists several genres with `;` or `,`, as the tag writer's list rule
/// reads them (`format_metadata_tag_value`), with the NUL between ID3v2.4
/// values, or with [separator], the user's own genre separator. Slashes and
/// ampersands stay inside a genre: `Hip-Hop/Rap` and `R&B` are one each.
List<String> splitGenreTag(String? tag, {String separator = ''}) {
  var text = tag ?? '';
  if (separator.trim().isNotEmpty) text = text.replaceAll(separator, ';');
  final seen = <String>{};
  return [
    for (final part in text.split(_listSeparators))
      if (part.trim().isNotEmpty && seen.add(part.trim().toLowerCase()))
        part.trim(),
  ];
}
