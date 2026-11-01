//! Comparison/display identities. Never replace the original filesystem path.

pub fn identity(path: &str) -> Option<String> {
    let slashes = path.replace('\\', "/");
    let value = if let Some(tail) = slashes.strip_prefix("//?/UNC/") {
        format!("//{tail}")
    } else {
        slashes.strip_prefix("//?/").unwrap_or(&slashes).to_owned()
    };
    let bytes = value.as_bytes();
    let drive =
        bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'/';
    let unc = value.starts_with("//") && !value.starts_with("//?/") && !value.starts_with("//./");
    if !drive && !unc {
        return None;
    }
    let parts: Vec<_> = value[if drive { 3 } else { 2 }..].split('/').collect();
    if unc && (parts.len() < 2 || parts[..2].iter().any(|p| p.is_empty())) {
        return None;
    }
    if parts
        .iter()
        .any(|p| *p == "." || *p == ".." || p.ends_with(['.', ' ']))
    {
        return None;
    }
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::identity;

    #[test]
    fn windows_aliases_keep_file_names_and_namespaces_distinct() {
        assert_eq!(
            identity(r"\\?\C:\Music\a.flac"),
            identity(r"C:\Music\a.flac")
        );
        assert_eq!(
            identity(r"\\?\UNC\server\share\a.flac"),
            identity(r"\\server\share\a.flac")
        );
        for path in [
            r"\\.\PhysicalDrive0",
            r"\\?\Volume{123}\a",
            r"\\?\C:\a.\b",
            r"\\?\C:\a \b",
            "/music/a.flac",
            "network://id/a",
        ] {
            assert_eq!(identity(path), None, "{path}");
        }
    }
}
