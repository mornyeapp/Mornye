//! Provider artwork sizing. Resolution selection remains extension-owned.

use image::{DynamicImage, ImageFormat, ImageReader};
use std::borrow::Cow;
use std::io::Cursor;

mod library;
pub use library::{
    LibraryThumbnail, library_content_stem, library_thumbnail, library_thumbnail_entry,
};

pub const MAX_DOWNLOAD_BYTES: usize = 24 << 20;
pub const LIBRARY_MAX_DIMENSION: i64 = 800;
const MAX_DECODE_PIXELS: u64 = 16_000_000;

fn reader(data: &[u8]) -> Result<ImageReader<Cursor<&[u8]>>, String> {
    let reader = ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|error| error.to_string())?;
    match reader.format() {
        Some(ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::Gif | ImageFormat::WebP) => {
            Ok(reader)
        }
        _ => Err("unknown image format".into()),
    }
}

pub fn dimensions(data: &[u8]) -> (u32, u32) {
    reader(data)
        .and_then(|reader| reader.into_dimensions().map_err(|error| error.to_string()))
        .unwrap_or_default()
}

/// Keep original bytes unless shrinking is required. Returned PNG pixels retain
/// alpha; other decoded formats are encoded as JPEG at the Go quality setting.
pub fn resize<'a>(
    data: &'a [u8],
    max_dimension: i64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Cow<'a, [u8]>, String> {
    check()?;
    if data.is_empty() || max_dimension <= 0 {
        return Ok(Cow::Borrowed(data));
    }
    let header = reader(data).map_err(|error| format!("decode artwork dimensions: {error}"))?;
    let png = header.format() == Some(ImageFormat::Png);
    let (width, height) = header
        .into_dimensions()
        .map_err(|error| format!("decode artwork dimensions: {error}"))?;
    if width == 0 || height == 0 {
        return Err(format!("invalid artwork dimensions {width}x{height}"));
    }
    if i64::from(width.max(height)) <= max_dimension {
        return Ok(Cow::Borrowed(data));
    }
    if u64::from(width) * u64::from(height) > MAX_DECODE_PIXELS {
        return Err(format!(
            "artwork dimensions {width}x{height} exceed safe decode limit"
        ));
    }
    check()?;
    let source = reader(data)?
        .decode()
        .map_err(|error| format!("decode artwork: {error}"))?;
    check()?;
    let limit = max_dimension as u32; // Positive and less than an input u32 dimension.
    let (dw, dh) = if width >= height {
        (
            limit,
            ((u64::from(height) * u64::from(limit) + u64::from(width) / 2) / u64::from(width))
                .max(1) as u32,
        )
    } else {
        (
            ((u64::from(width) * u64::from(limit) + u64::from(height) / 2) / u64::from(height))
                .max(1) as u32,
            limit,
        )
    };
    let source = Pixels::new(source);
    // JPEG only consumes RGB. Write those channels directly instead of keeping
    // an RGBA destination alongside a second RGB copy during encoding.
    let channels = if png { 4 } else { 3 };
    let mut pixels = vec![0; dw as usize * dh as usize * channels];
    // Match x/image/draw ApproxBiLinear: sample four neighbors at pixel centers
    // in premultiplied 16-bit space, then truncate into a premultiplied RGBA8
    // destination. See NOTICE.
    for y in 0..dh {
        let (y0, y1, fy) = neighbors(y, height, dh);
        for x in 0..dw {
            if x % 1024 == 0 {
                check()?;
            }
            let (x0, x1, fx) = neighbors(x, width, dw);
            let samples = [
                source.at(x0, y0),
                source.at(x1, y0),
                source.at(x0, y1),
                source.at(x1, y1),
            ];
            let offset = (y as usize * dw as usize + x as usize) * channels;
            for channel in 0..channels {
                let top = (1.0 - fx) * f64::from(samples[0][channel])
                    + fx * f64::from(samples[1][channel]);
                let bottom = (1.0 - fx) * f64::from(samples[2][channel])
                    + fx * f64::from(samples[3][channel]);
                pixels[offset + channel] = (((1.0 - fy) * top + fy * bottom) as u32 >> 8) as u8;
            }
        }
    }
    // The original decode can be tens of MiB; encoding no longer needs it.
    drop(source);
    check()?;
    let mut encoded = Vec::new();
    if png {
        for pixel in pixels.as_chunks_mut::<4>().0 {
            let alpha = u32::from(pixel[3]);
            for channel in &mut pixel[..3] {
                *channel = ((u32::from(*channel) * 0xffff)
                    .checked_div(alpha)
                    .unwrap_or(0)
                    >> 8)
                    .min(255) as u8;
            }
        }
        let image = image::RgbaImage::from_raw(dw, dh, pixels).expect("cover pixel dimensions");
        image
            .write_to(&mut Cursor::new(&mut encoded), ImageFormat::Png)
            .map_err(|error| format!("encode resized PNG artwork: {error}"))?;
    } else {
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, 88)
            .encode(&pixels, dw, dh, image::ExtendedColorType::Rgb8)
            .map_err(|error| format!("encode resized JPEG artwork: {error}"))?;
    }
    check()?;
    Ok(Cow::Owned(encoded))
}

fn neighbors(destination: u32, source_size: u32, destination_size: u32) -> (u32, u32, f64) {
    let source = (f64::from(destination) + 0.5)
        * (f64::from(source_size) / f64::from(destination_size))
        - 0.5;
    if source < 0.0 {
        return (0, 0, 0.0);
    }
    let first = source as u32;
    if first >= source_size - 1 {
        return (source_size - 1, source_size - 1, 0.0);
    }
    (first, first + 1, source - f64::from(first))
}

enum Pixels {
    Rgb(image::RgbImage),
    Eight(image::RgbaImage),
    Sixteen(image::ImageBuffer<image::Rgba<u16>, Vec<u16>>),
}

impl Pixels {
    fn new(image: DynamicImage) -> Self {
        if let DynamicImage::ImageRgb8(image) = image {
            return Self::Rgb(image);
        }
        match image.color() {
            image::ColorType::L16
            | image::ColorType::La16
            | image::ColorType::Rgb16
            | image::ColorType::Rgba16 => Self::Sixteen(image.into_rgba16()),
            _ => Self::Eight(image.into_rgba8()),
        }
    }

    fn at(&self, x: u32, y: u32) -> [u32; 4] {
        let mut pixel = match self {
            Self::Rgb(image) => {
                let [r, g, b] = image
                    .get_pixel(x, y)
                    .0
                    .map(|value| u32::from(value) * 0x101);
                return [r, g, b, 0xffff];
            }
            Self::Eight(image) => image
                .get_pixel(x, y)
                .0
                .map(|value| u32::from(value) * 0x101),
            Self::Sixteen(image) => image.get_pixel(x, y).0.map(u32::from),
        };
        for channel in 0..3 {
            pixel[channel] = pixel[channel] * pixel[3] / 0xffff;
        }
        pixel
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb_and_opaque_rgba_produce_identical_resized_pngs() {
        for (width, height) in [(13, 7), (7, 13), (1, 13), (13, 1)] {
            let rgb = image::RgbImage::from_fn(width, height, |x, y| {
                image::Rgb([(x * 37 + y * 11) as u8, (x * 3 + y * 71) as u8, 255])
            });
            let rgb = DynamicImage::ImageRgb8(rgb);
            let rgba = DynamicImage::ImageRgba8(rgb.to_rgba8());
            let encode = |image: &DynamicImage| {
                let mut output = Cursor::new(Vec::new());
                image.write_to(&mut output, ImageFormat::Png).unwrap();
                output.into_inner()
            };
            let (rgb, rgba) = (encode(&rgb), encode(&rgba));
            for dimension in [1, 2, 3, 6] {
                assert_eq!(
                    resize(&rgb, dimension, &|| Ok(())).unwrap(),
                    resize(&rgba, dimension, &|| Ok(())).unwrap(),
                    "{width}x{height} to {dimension}"
                );
            }
        }
    }

    #[test]
    fn webp_is_preserved_when_small_and_resized_to_jpeg_with_alpha_composited() {
        let image = DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            6,
            3,
            image::Rgba([20, 40, 60, 128]),
        ));
        let mut encoded = Cursor::new(Vec::new());
        image.write_to(&mut encoded, ImageFormat::WebP).unwrap();
        let data = encoded.into_inner();
        let unchanged = resize(&data, 6, &|| Ok(())).unwrap();
        assert!(matches!(unchanged, Cow::Borrowed(_)));
        assert_eq!(unchanged.as_ref(), data);
        let resized = resize(&data, 3, &|| Ok(())).unwrap();
        assert_eq!(image::guess_format(&resized).unwrap(), ImageFormat::Jpeg);
        let image = image::load_from_memory(&resized).unwrap().into_rgb8();
        assert_eq!(image.dimensions(), (3, 2));
        for pixel in image.pixels() {
            for (actual, expected) in pixel.0.into_iter().zip([10, 20, 30]) {
                assert!(actual.abs_diff(expected) <= 3);
            }
        }
    }
}
