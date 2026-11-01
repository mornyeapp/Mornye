use cap_std::fs::Dir;
use rustix::io::Errno;
use std::ffi::OsStr;
use std::io;

pub(super) fn publish_new(parent: &Dir, name: &str, target: &OsStr) -> io::Result<()> {
    publish_new_with(parent, name, target, || {
        rustix::fs::renameat_with(
            parent,
            name,
            parent,
            target,
            rustix::fs::RenameFlags::NOREPLACE,
        )
    })
}

fn publish_new_with(
    parent: &Dir,
    name: &str,
    target: &OsStr,
    rename: impl FnOnce() -> Result<(), Errno>,
) -> io::Result<()> {
    match rename() {
        Ok(()) => Ok(()),
        Err(error)
            if [Errno::INVAL, Errno::NOSYS, Errno::OPNOTSUPP, Errno::NOTSUP].contains(&error) =>
        {
            // Some mounted filesystems cannot rename with NOREPLACE. Linking
            // the completed stage is also atomic and refuses an existing name.
            // Both names belong to the same open parent, so no copy is needed.
            parent.hard_link(name, parent, target)?;
            // Publication has succeeded. A cleanup failure must not turn a
            // completed download into a failure or remove the published file.
            let _ = parent.remove_file(name);
            Ok(())
        }
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::FileRegistry;
    use cap_std::fs::MetadataExt;
    use std::io::Write;
    use std::os::unix::fs::symlink;
    use std::sync::Arc;

    #[test]
    fn unsupported_exclusive_rename_publishes_complete_audio_without_copying() {
        for error in [Errno::INVAL, Errno::NOSYS, Errno::OPNOTSUPP, Errno::NOTSUP] {
            let root = tempfile::tempdir().unwrap();
            let files = Arc::new(FileRegistry::default())
                .extension(root.path())
                .unwrap();
            let path = files.resolve("音乐 album/Björk 🎵.opus").unwrap();
            let mut stage = path.stage().unwrap();
            stage.file.write_all(b"complete audio").unwrap();
            stage.file.sync_all().unwrap();
            let original = stage.file.metadata().unwrap();
            let staging_path = path.absolute.parent().unwrap().join(&stage.name);

            publish_new_with(&stage.parent, &stage.name, &stage.target, || Err(error)).unwrap();
            drop(stage);

            assert_eq!(std::fs::read(&path.absolute).unwrap(), b"complete audio");
            let published = path.metadata().unwrap();
            assert_eq!(original.dev(), published.dev());
            assert_eq!(original.ino(), published.ino());
            assert!(!staging_path.exists());
            assert_eq!(
                std::fs::read_dir(path.absolute.parent().unwrap())
                    .unwrap()
                    .count(),
                1
            );
        }
    }

    #[test]
    fn fallback_preserves_destinations_created_during_exclusive_rename() {
        for kind in ["file", "directory", "symlink", "dangling symlink"] {
            let root = tempfile::tempdir().unwrap();
            let files = Arc::new(FileRegistry::default())
                .extension(root.path())
                .unwrap();
            let path = files.resolve("track.flac").unwrap();
            let mut stage = path.stage().unwrap();
            stage.file.write_all(b"new audio").unwrap();
            std::fs::write(root.path().join("existing.flac"), b"existing audio").unwrap();
            let error = publish_new_with(&stage.parent, &stage.name, &stage.target, || {
                match kind {
                    "file" => std::fs::write(&path.absolute, b"other publisher").unwrap(),
                    "directory" => std::fs::create_dir(&path.absolute).unwrap(),
                    "symlink" => symlink("existing.flac", &path.absolute).unwrap(),
                    _ => symlink("missing.flac", &path.absolute).unwrap(),
                }
                Err(Errno::INVAL)
            })
            .unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::AlreadyExists, "{kind}");
            drop(stage);

            match kind {
                "file" => assert_eq!(std::fs::read(&path.absolute).unwrap(), b"other publisher"),
                "directory" => assert!(path.absolute.is_dir()),
                "symlink" => assert_eq!(
                    std::fs::read_link(&path.absolute).unwrap(),
                    std::path::Path::new("existing.flac")
                ),
                _ => assert_eq!(
                    std::fs::read_link(&path.absolute).unwrap(),
                    std::path::Path::new("missing.flac")
                ),
            }
            assert_eq!(
                std::fs::read(root.path().join("existing.flac")).unwrap(),
                b"existing audio"
            );
            assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 2);
        }
    }

    #[test]
    fn publication_does_not_hide_other_rename_errors() {
        for error in [Errno::ACCESS, Errno::IO, Errno::NOSPC, Errno::EXIST] {
            let root = tempfile::tempdir().unwrap();
            let files = Arc::new(FileRegistry::default())
                .extension(root.path())
                .unwrap();
            let path = files.resolve("track.flac").unwrap();
            let stage = path.stage().unwrap();
            let actual = publish_new_with(&stage.parent, &stage.name, &stage.target, || Err(error))
                .unwrap_err();
            assert_eq!(actual.raw_os_error(), Some(error.raw_os_error()));
            drop(stage);
            assert!(!path.absolute.exists());
            assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
        }
    }

    #[test]
    fn fallback_uses_the_open_parent_after_its_directory_is_renamed() {
        let root = tempfile::tempdir().unwrap();
        let files = Arc::new(FileRegistry::default())
            .extension(root.path())
            .unwrap();
        let path = files.resolve("album/track.flac").unwrap();
        let mut stage = path.stage().unwrap();
        stage.file.write_all(b"complete audio").unwrap();
        std::fs::rename(root.path().join("album"), root.path().join("moved")).unwrap();
        std::fs::create_dir(root.path().join("album")).unwrap();

        publish_new_with(&stage.parent, &stage.name, &stage.target, || {
            Err(Errno::INVAL)
        })
        .unwrap();
        drop(stage);

        assert_eq!(
            std::fs::read(root.path().join("moved/track.flac")).unwrap(),
            b"complete audio"
        );
        assert_eq!(
            std::fs::read_dir(root.path().join("moved"))
                .unwrap()
                .count(),
            1
        );
        assert_eq!(
            std::fs::read_dir(root.path().join("album"))
                .unwrap()
                .count(),
            0
        );
    }
}
