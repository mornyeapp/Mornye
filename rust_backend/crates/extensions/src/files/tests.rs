use super::*;
use std::io::Write;
#[cfg(unix)]
use std::io::{Seek, SeekFrom};

#[cfg(unix)]
#[test]
fn native_reads_reject_links_at_every_component_and_never_write_or_wait_on_special_files() {
    use std::io::Read;
    use std::os::unix::{fs::symlink, net::UnixListener};

    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    std::fs::create_dir_all(root.path().join("album/disc")).unwrap();
    std::fs::write(root.path().join("album/disc/song.wav"), b"original").unwrap();
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let parent = root.path().join("album");
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o111)).unwrap();
        let result = files
            .resolve("album/disc/song.wav")
            .unwrap()
            .open_native_read();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(result.is_ok(), "execute-only parent: {result:?}");
    }
    let mut file = files
        .resolve("album/disc/song.wav")
        .unwrap()
        .open_native_read()
        .unwrap();
    let mut data = Vec::new();
    file.read_to_end(&mut data).unwrap();
    assert_eq!(data, b"original");
    assert!(file.write_all(b"changed").is_err());
    for (target, link) in [
        ("album", "album-link"),
        ("album/disc/song.wav", "song-link.wav"),
        ("missing.wav", "dangling.wav"),
    ] {
        symlink(target, root.path().join(link)).unwrap();
    }
    for path in ["album-link/disc/song.wav", "song-link.wav", "dangling.wav"] {
        assert!(
            files
                .resolve(path)
                .unwrap()
                .open_native_read()
                .unwrap_err()
                .to_string()
                .contains("symlinks")
        );
    }
    assert_eq!(
        files
            .resolve("missing.wav")
            .unwrap()
            .open_native_read()
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    assert!(
        std::process::Command::new("mkfifo")
            .arg(root.path().join("pipe.wav"))
            .status()
            .unwrap()
            .success()
    );
    let _socket = UnixListener::bind(root.path().join("socket.wav")).unwrap();
    for path in ["pipe.wav", "socket.wav"] {
        assert!(
            files
                .resolve(path)
                .unwrap()
                .open_native_read()
                .unwrap_err()
                .to_string()
                .contains("special files")
        );
    }
    assert_eq!(
        std::fs::read(root.path().join("album/disc/song.wav")).unwrap(),
        b"original"
    );
}

#[test]
fn exclusive_publication_preserves_racing_output_and_cleans_cancelled_stage() {
    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let path = files.resolve("track.flac").unwrap();
    let mut stage = path.stage().unwrap();
    stage.file.write_all(b"new audio").unwrap();
    assert!(!path.absolute.exists());
    let error = stage
        .publish_new(&|| {
            // A different publisher creates the destination after the
            // planner's existence check but before the publication syscall.
            std::fs::write(&path.absolute, b"other publisher").unwrap();
            Ok(())
        })
        .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(std::fs::read(&path.absolute).unwrap(), b"other publisher");

    let cancelled = files.resolve("cancelled.flac").unwrap();
    let mut stage = cancelled.stage().unwrap();
    stage.file.write_all(b"cancelled audio").unwrap();
    assert_eq!(
        stage
            .publish_new(&|| Err("cancelled".into()))
            .unwrap_err()
            .to_string(),
        "cancelled"
    );
    assert!(!cancelled.absolute.exists());

    path.remove().unwrap();
    let mut stage = path.stage().unwrap();
    stage.file.write_all(b"complete audio").unwrap();
    stage.publish_new(&|| Ok(())).unwrap();
    assert_eq!(std::fs::read(&path.absolute).unwrap(), b"complete audio");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

fn check_directory_operations(root: &Path) {
    let files = Arc::new(FileRegistry::default()).extension(root).unwrap();
    let album = files.resolve("音乐 collection").unwrap();
    let track = files.resolve("音乐 collection/Björk 🎵.flac").unwrap();
    let mut stage = track.stage().unwrap();
    stage.file.write_all(b"first download").unwrap();
    stage.publish_new(&|| Ok(())).unwrap();
    assert_eq!(
        files.resolve(".").unwrap().entries().unwrap(),
        vec![("音乐 collection".into(), true)]
    );
    assert_eq!(
        album.entries().unwrap(),
        vec![("Björk 🎵.flac".into(), false)]
    );
    assert_eq!(track.metadata().unwrap().len(), 14);

    // A later publisher must preserve the existing completed download.
    let mut stage = track.stage().unwrap();
    stage.file.write_all(b"duplicate").unwrap();
    assert_eq!(
        stage.publish_new(&|| Ok(())).unwrap_err().kind(),
        io::ErrorKind::AlreadyExists
    );
    assert_eq!(std::fs::read(&track.absolute).unwrap(), b"first download");

    // Metadata updates intentionally replace the completed file through the
    // capability rename path, which also derives a pathname from the handle.
    let mut stage = track.stage().unwrap();
    stage.file.write_all(b"updated tags").unwrap();
    stage.publish(&|| Ok(())).unwrap();
    assert_eq!(std::fs::read(&track.absolute).unwrap(), b"updated tags");
    let renamed = files.resolve("音乐 collection/renamed.flac").unwrap();
    track.rename_to(&renamed).unwrap();
    assert_eq!(
        album.entries().unwrap(),
        vec![("renamed.flac".into(), false)]
    );
    renamed.remove().unwrap();
    album.remove().unwrap();
    assert!(files.resolve(".").unwrap().entries().unwrap().is_empty());
}

#[test]
fn capability_directory_operations_preserve_downloads_and_leave_no_staging_files() {
    let root = tempfile::tempdir().unwrap();
    check_directory_operations(root.path());
}

#[cfg(windows)]
#[test]
fn windows_publication_supports_paths_longer_than_max_path() {
    let root = tempfile::tempdir().unwrap();
    let long = root.path().join("album collection\\".repeat(24));
    check_directory_operations(&long);
}

#[cfg(windows)]
#[test]
#[ignore = "requires a writable SMB share in MORNYE_TEST_SMB_ROOT"]
fn windows_network_share_directory_operations() {
    let share = std::env::var_os("MORNYE_TEST_SMB_ROOT")
        .expect("set MORNYE_TEST_SMB_ROOT to a writable UNC path or mapped drive");
    let root = tempfile::Builder::new()
        .prefix("mornye-smb-test-")
        .tempdir_in(share)
        .unwrap();
    // Exercise both the supplied spelling and the verbatim path obtained
    // from Windows, just as the desktop directory grants do.
    check_directory_operations(root.path());
    check_directory_operations(&std::fs::canonicalize(root.path()).unwrap());
}

#[test]
fn batched_publication_keeps_each_folder_once_until_the_flush() {
    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let batch = SyncBatch::default();
    for name in ["covers/a.jpg", "covers/b.jpg", "other/c.jpg"] {
        let output = files.resolve(name).unwrap();
        let mut stage = output.stage().unwrap();
        stage.file.write_all(name.as_bytes()).unwrap();
        stage.publish_batched(&batch, &|| Ok(())).unwrap();
        assert_eq!(std::fs::read(&output.absolute).unwrap(), name.as_bytes());
    }
    let output = files.resolve("covers/cancelled.jpg").unwrap();
    let stage = output.stage().unwrap();
    assert_eq!(
        stage
            .publish_batched(&batch, &|| Err("cancelled".into()))
            .unwrap_err(),
        "cancelled"
    );
    assert!(!output.absolute.exists());
    assert_eq!(
        std::fs::read_dir(root.path().join("covers"))
            .unwrap()
            .count(),
        2
    );
    #[cfg(target_vendor = "apple")]
    assert_eq!(batch.folders.lock().unwrap().len(), 2);
    batch.flush();
    #[cfg(target_vendor = "apple")]
    assert!(batch.folders.lock().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn stage_from_links_same_filesystem_source_and_survives_source_cleanup() {
    use cap_std::fs::MetadataExt;

    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let source_path = files.resolve("source.bin").unwrap();
    std::fs::write(&source_path.absolute, b"source audio").unwrap();
    let source = source_path.open(OpenOptions::new().read(true)).unwrap();
    let destination = files.resolve("destination.bin").unwrap();
    let (stage, promoted) = destination.stage_from(&source_path, &source).unwrap();
    assert!(promoted);
    let source_metadata = source.metadata().unwrap();
    let stage_metadata = stage.file.metadata().unwrap();
    assert_eq!(source_metadata.dev(), stage_metadata.dev());
    assert_eq!(source_metadata.ino(), stage_metadata.ino());

    stage.publish_new(&|| Ok(())).unwrap();
    drop(source);
    source_path.remove().unwrap();
    assert_eq!(
        std::fs::read(&destination.absolute).unwrap(),
        b"source audio"
    );
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[cfg(unix)]
#[test]
fn stage_from_copies_open_source_after_path_replacement() {
    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let source_path = files.resolve("source.bin").unwrap();
    std::fs::write(&source_path.absolute, b"original audio").unwrap();
    let mut source = source_path.open(OpenOptions::new().read(true)).unwrap();
    std::fs::rename(&source_path.absolute, root.path().join("source.old")).unwrap();
    std::fs::write(&source_path.absolute, b"replacement audio").unwrap();
    let destination = files.resolve("destination.bin").unwrap();
    let (mut stage, promoted) = destination.stage_from(&source_path, &source).unwrap();
    assert!(!promoted);
    source.seek(SeekFrom::Start(0)).unwrap();
    std::io::copy(&mut source, &mut stage.file).unwrap();
    stage.publish_new(&|| Ok(())).unwrap();
    assert_eq!(
        std::fs::read(&destination.absolute).unwrap(),
        b"original audio"
    );
}

#[cfg(unix)]
#[test]
fn stage_from_copies_open_source_after_path_becomes_symlink() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let source_path = files.resolve("source.bin").unwrap();
    std::fs::write(&source_path.absolute, b"original audio").unwrap();
    let mut source = source_path.open(OpenOptions::new().read(true)).unwrap();
    std::fs::rename(&source_path.absolute, root.path().join("source.old")).unwrap();
    symlink("source.old", &source_path.absolute).unwrap();
    let destination = files.resolve("destination.bin").unwrap();
    let (mut stage, promoted) = destination.stage_from(&source_path, &source).unwrap();
    assert!(!promoted);
    source.seek(SeekFrom::Start(0)).unwrap();
    std::io::copy(&mut source, &mut stage.file).unwrap();
    stage.publish_new(&|| Ok(())).unwrap();
    assert_eq!(
        std::fs::read(&destination.absolute).unwrap(),
        b"original audio"
    );
}

#[cfg(unix)]
#[test]
fn stage_from_preserves_existing_destination_and_cleans_cancelled_stage() {
    let root = tempfile::tempdir().unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    let source_path = files.resolve("source.bin").unwrap();
    std::fs::write(&source_path.absolute, b"source audio").unwrap();
    let source = source_path.open(OpenOptions::new().read(true)).unwrap();
    let destination = files.resolve("destination.bin").unwrap();
    std::fs::write(&destination.absolute, b"existing audio").unwrap();

    let (stage, promoted) = destination.stage_from(&source_path, &source).unwrap();
    assert!(promoted);
    let error = stage.publish_new(&|| Ok(())).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
    assert_eq!(
        std::fs::read(&destination.absolute).unwrap(),
        b"existing audio"
    );
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 2);

    std::fs::remove_file(&destination.absolute).unwrap();
    let (stage, promoted) = destination.stage_from(&source_path, &source).unwrap();
    assert!(promoted);
    let error = stage.publish_new(&|| Err("cancelled".into())).unwrap_err();
    assert_eq!(error.to_string(), "cancelled");
    assert!(!destination.absolute.exists());
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

/// Create a directory junction, which needs no privilege unlike symlinks.
#[cfg(windows)]
fn junction(link: &Path, target: &Path) {
    let status = std::process::Command::new("cmd")
        .arg("/C")
        .arg("mklink")
        .arg("/J")
        .arg(link)
        .arg(target)
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "mklink /J {}", link.display());
}

#[cfg(windows)]
#[test]
fn windows_resolve_rejects_escape_and_alias_paths() {
    let root = tempfile::tempdir().unwrap();
    let grant = tempfile::tempdir().unwrap();
    let registry = Arc::new(FileRegistry::default());
    registry
        .set_allowed_directories(&[grant.path().to_owned()])
        .unwrap();
    let files = registry.extension(root.path()).unwrap();
    for path in [
        "..\\outside.flac",
        "../outside.flac",
        "album\\..\\..\\outside.flac",
        "album/../song.flac",
        "\\outside.flac",
        "/outside.flac",
        "\\\\server\\share\\outside.flac",
        "//server/share/outside.flac",
        "\\\\?\\C:\\Windows\\win.ini",
        "\\\\.\\PhysicalDrive0",
        "C:outside.flac",
        "C:\\Windows\\win.ini",
        "song.flac:hidden",
        "song.flac::$DATA",
        "NUL",
        "album\\con.txt",
        "COM1.flac",
        "song.",
        "song ",
        "so*ng.flac",
    ] {
        assert!(
            files
                .resolve(path)
                .err()
                .is_some_and(|error| error.starts_with("file access denied")),
            "{path:?} was not denied"
        );
    }
    // Granted absolute paths still reject aliases below the grant.
    let granted = grant.path().join("song.flac");
    assert!(files.resolve(granted.to_str().unwrap()).is_ok());
    for suffix in [":hidden", "::$DATA"] {
        let path = format!("{}{suffix}", granted.display());
        assert!(files.resolve(&path).is_err(), "{path:?} was accepted");
    }
    let device = grant.path().join("NUL");
    assert!(files.resolve(device.to_str().unwrap()).is_err());
    // Nothing above created files outside the sandbox or a stream inside it.
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
}

#[cfg(windows)]
#[test]
fn windows_native_reads_reject_junctions_and_links_at_every_component() {
    use std::io::Read;

    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret.wav"), b"secret").unwrap();
    let files = Arc::new(FileRegistry::default())
        .extension(root.path())
        .unwrap();
    std::fs::create_dir_all(root.path().join("album/disc")).unwrap();
    std::fs::write(root.path().join("album/disc/song.wav"), b"original").unwrap();

    let mut file = files
        .resolve("album\\disc\\song.wav")
        .unwrap()
        .open_native_read()
        .unwrap();
    let mut data = Vec::new();
    file.read_to_end(&mut data).unwrap();
    assert_eq!(data, b"original");
    assert!(file.write_all(b"changed").is_err());

    junction(
        &root.path().join("album-junction"),
        &root.path().join("album"),
    );
    junction(&root.path().join("outside-junction"), outside.path());
    for path in [
        "album-junction/disc/song.wav",
        "outside-junction/secret.wav",
    ] {
        let resolved = files.resolve(path).unwrap();
        assert!(
            resolved
                .open_native_read()
                .unwrap_err()
                .to_string()
                .contains("symlinks"),
            "{path}"
        );
        assert!(resolved.native_display().is_err(), "{path}");
    }
    // The capability open never leaves the root through a junction either.
    assert!(
        files
            .resolve("outside-junction/secret.wav")
            .unwrap()
            .open(OpenOptions::new().read(true))
            .is_err()
    );
    // File symlinks need Developer Mode or a privilege; test them when
    // available.
    if std::os::windows::fs::symlink_file(
        outside.path().join("secret.wav"),
        root.path().join("link.wav"),
    )
    .is_ok()
    {
        let resolved = files.resolve("link.wav").unwrap();
        assert!(
            resolved
                .open_native_read()
                .unwrap_err()
                .to_string()
                .contains("symlinks")
        );
        assert!(resolved.open(OpenOptions::new().read(true)).is_err());
    }
    assert_eq!(
        files
            .resolve("album")
            .unwrap()
            .open_native_read()
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    assert_eq!(
        files
            .resolve("missing.wav")
            .unwrap()
            .open_native_read()
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    assert_eq!(
        std::fs::read(outside.path().join("secret.wav")).unwrap(),
        b"secret"
    );
}
