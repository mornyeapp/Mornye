//! Folder images (cover.jpg and the like) for Library songs without embedded
//! artwork. Large libraries often keep the album picture beside the songs.

use std::io::Read;

/// Stems in priority order; the first stem found in a folder wins.
const STEMS: [&str; 5] = ["cover", "folder", "front", "album", "albumart"];
const EXTENSIONS: [&str; 4] = ["jpg", "jpeg", "png", "webp"];

/// The priority of `name` as a folder image, lower first, or `None` when it
/// is not one. Matching ignores case. Hidden files never qualify: macOS
/// leaves AppleDouble `._cover.jpg` files beside the real image on shared
/// and FAT volumes.
fn folder_image_rank(name: &str) -> Option<usize> {
    if name.starts_with('.') {
        return None;
    }
    let (stem, extension) = name.rsplit_once('.')?;
    let stem = STEMS
        .iter()
        .position(|candidate| stem.eq_ignore_ascii_case(candidate))?;
    let extension = EXTENSIONS
        .iter()
        .position(|candidate| extension.eq_ignore_ascii_case(candidate))?;
    Some(stem * EXTENSIONS.len() + extension)
}

/// The folder image among a directory's file `names`, if any.
pub fn folder_image<'a>(names: impl IntoIterator<Item = &'a str>) -> Option<&'a str> {
    names
        .into_iter()
        .filter_map(|name| Some((folder_image_rank(name)?, name)))
        .min_by_key(|(rank, _)| *rank)
        .map(|(_, name)| name)
}

/// Whether `name` looks like one disc of a multi-disc album (`CD1`, `CD 2`,
/// `Disc 1`, `Disk 02`, `Disc 1 - Title`). Such folders often leave the
/// album picture to their parent.
pub fn is_disc_folder(name: &str) -> bool {
    let name = name.trim().to_ascii_lowercase();
    let Some(rest) = ["disc", "disk", "cd"]
        .iter()
        .find_map(|prefix| name.strip_prefix(prefix))
    else {
        return false;
    };
    let rest = rest.trim_start_matches([' ', '_', '-', '.']);
    let number = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    number > 0
        && rest[number..]
            .chars()
            .next()
            .is_none_or(|c| !c.is_alphanumeric())
}

/// Reads a folder image for a Library thumbnail. Only bytes the thumbnail
/// decoder recognizes qualify, so a damaged or misnamed file never becomes
/// a song's artwork.
pub fn read_folder_image(
    reader: &mut dyn Read,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<u8>, String> {
    check()?;
    let mut data = Vec::new();
    reader
        .take(super::MAX_DOWNLOAD_BYTES as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|error| format!("read folder image: {error}"))?;
    if data.len() > super::MAX_DOWNLOAD_BYTES {
        return Err("folder image exceeds 24 MiB limit".into());
    }
    super::reader(&data)?;
    check()?;
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn stems_outrank_extensions_and_case_is_ignored() {
        assert_eq!(
            folder_image(["album.png", "Folder.JPG", "front.jpg", "song.flac"]),
            Some("Folder.JPG")
        );
        assert_eq!(
            folder_image(["COVER.PNG", "cover.webp", "folder.jpg"]),
            Some("COVER.PNG")
        );
        assert_eq!(folder_image(["AlbumArt.Jpeg"]), Some("AlbumArt.Jpeg"));
        assert_eq!(
            folder_image(["back.jpg", "cover.gif", "cover", "cover.jpg.txt"]),
            None
        );
    }

    #[test]
    fn hidden_and_apple_double_files_never_qualify() {
        assert_eq!(
            folder_image(["._cover.jpg", "folder.jpg"]),
            Some("folder.jpg")
        );
        assert_eq!(folder_image(["._cover.jpg", ".cover.jpg"]), None);
    }

    #[test]
    fn disc_folders_are_recognized_by_name() {
        for name in [
            "CD1",
            "cd 2",
            "Disc 1",
            "Disk 02",
            "Disc 1 - Title",
            "disc_3",
            "CD-4",
            "Disc 2 (Live)",
        ] {
            assert!(is_disc_folder(name), "{name}");
        }
        for name in [
            "Discography",
            "CDs",
            "Disc",
            "CD1A",
            "Album",
            "Best of CD 1",
            "",
        ] {
            assert!(!is_disc_folder(name), "{name}");
        }
    }

    #[test]
    fn only_decodable_images_within_the_limit_are_read() {
        let mut png = Cursor::new(Vec::new());
        image::ImageBuffer::from_pixel(4, 4, image::Rgb([1_u8, 2, 3]))
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let png = png.into_inner();
        assert_eq!(
            read_folder_image(&mut Cursor::new(png.clone()), &|| Ok(())).unwrap(),
            png
        );
        assert!(read_folder_image(&mut Cursor::new(b"not an image".to_vec()), &|| Ok(())).is_err());
        let mut large = png.clone();
        large.resize(super::super::MAX_DOWNLOAD_BYTES + 1, 0);
        assert!(read_folder_image(&mut Cursor::new(large), &|| Ok(())).is_err());
        assert!(read_folder_image(&mut Cursor::new(png), &|| Err("cancelled".into())).is_err());
    }
}
