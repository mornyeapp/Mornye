package com.zarz.mornye

private val sidecarExtension = Regex("[a-z0-9]{1,8}")

/**
 * What one look into a song's folder asks for: each sidecar extension with
 * the file name it has for this song, and plain file names such as an
 * album's "cover.mp4".
 */
internal data class SafSiblingWanted(
    val sidecars: Map<String, String>,
    val files: Set<String>,
) {
    val names: Set<String> get() = sidecars.values.toSet() + files
}

/**
 * The sibling names for a song named [audioName]: "Song.lrc" for
 * "Song.flac" and the extension "lrc". Sidecars need the song's name, so
 * none are asked for without it. Invalid extensions and names that are not
 * a plain file name in the same folder are left out.
 */
internal fun safSiblingWanted(
    audioName: String?,
    extensions: List<String>,
    names: List<String>,
): SafSiblingWanted {
    val sidecars = linkedMapOf<String, String>()
    if (audioName != null) {
        for (extension in extensions) {
            if (!extension.matches(sidecarExtension)) continue
            sidecars[extension] = "${audioName.substringBeforeLast('.', audioName)}.$extension"
        }
    }
    return SafSiblingWanted(sidecars, names.filterTo(linkedSetOf(), ::isPlainSiblingName))
}

/** A plain file name: never a path into another folder or a hidden file. */
internal fun isPlainSiblingName(name: String): Boolean =
    !(name.isBlank() || name.contains('/') || name.startsWith('.'))
