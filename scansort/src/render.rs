//! Page rendering to base64-encoded PNGs for vision model classification.
//!
//! Port of the experiment's render.rs. Supports PDFs (via justpdf) and
//! image files (PNG, JPG, etc.) directly.

use crate::types::*;
use std::path::Path;

/// Image file extensions that can be rendered directly.
const IMAGE_EXTS: &[&str] = &[
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".tif", ".webp",
];

/// Target square dimension for vision-model payloads. Justpdf ignores `dpi`
/// for image-only PDFs (it emits the embedded image at native resolution),
/// so we always normalize here. 448 = 16 × 28, matching qwen2.5-vl's 14-pixel
/// patch grid (effective 28-pixel cell after the 2×2 fusion). Multiples of 28
/// avoid the Ollama-side resize step that has been observed to crash the
/// runner on dense content at non-aligned sizes (e.g. 512).
const VISION_TARGET_DIM: u32 = 256;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Render document pages to base64-encoded PNGs.
///
/// Dispatches to the right renderer based on file type:
/// - PDF: renders pages via justpdf
/// - Image: returns the image as base64 PNG (converting if needed)
/// - Other: returns an error (text files should use text classification)
pub fn render_pages(file_path: &str, max_pages: i32, dpi: i32) -> VaultResult<RenderResult> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Err(VaultError::new(format!("File not found: {file_path}")));
    }

    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    if IMAGE_EXTS.contains(&ext.as_str()) {
        render_image_file(file_path)
    } else if ext == ".pdf" {
        render_pdf_pages(file_path, max_pages, dpi)
    } else {
        Err(VaultError::new(format!(
            "Cannot render file type '{ext}': only PDF and image files are supported"
        )))
    }
}

// ---------------------------------------------------------------------------
// PDF rendering
// ---------------------------------------------------------------------------

/// Render PDF pages to base64 PNGs via justpdf.
fn render_pdf_pages(file_path: &str, max_pages: i32, dpi: i32) -> VaultResult<RenderResult> {
    let doc = justpdf::Document::open(file_path)
        .map_err(|e| VaultError::new(format!("Cannot open PDF: {e}")))?;

    let total_pages = doc.page_count();
    let render_count = std::cmp::min(total_pages, max_pages as usize);

    let mut pages = Vec::new();

    for i in 0..render_count {
        let page = match doc.page(i) {
            Ok(p) => p,
            Err(_) => continue,
        };

        let png_bytes = match page.render_png(dpi as f64) {
            Ok(data) => data,
            Err(_) => continue,
        };

        let normalized = match normalize_for_vision(&png_bytes) {
            Ok(b) => b,
            Err(_) => continue,
        };

        let b64 = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            &normalized,
        );

        pages.push(RenderedPage {
            page_num: (i + 1) as i32,
            base64: b64,
        });
    }

    let page_count = pages.len() as i32;
    Ok(RenderResult {
        success: true,
        pages,
        page_count,
    })
}

// ---------------------------------------------------------------------------
// Image rendering
// ---------------------------------------------------------------------------

/// Return an image file directly as base64 PNG, converting if needed.
fn render_image_file(file_path: &str) -> VaultResult<RenderResult> {
    let path = Path::new(file_path);
    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    let raw = std::fs::read(path)?;

    let png_bytes = if ext == ".png" {
        raw
    } else {
        match image::load_from_memory(&raw) {
            Ok(img) => {
                let mut buf = std::io::Cursor::new(Vec::new());
                img.write_to(&mut buf, image::ImageFormat::Png)
                    .map_err(|e| VaultError::new(format!("Image conversion failed: {e}")))?;
                buf.into_inner()
            }
            Err(_) => {
                // Fallback: send raw bytes as base64 (original format)
                raw
            }
        }
    };

    let normalized = normalize_for_vision(&png_bytes)
        .map_err(|e| VaultError::new(format!("Vision normalize failed: {}", e.message)))?;

    let b64 = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &normalized,
    );

    Ok(RenderResult {
        success: true,
        pages: vec![RenderedPage {
            page_num: 1,
            base64: b64,
        }],
        page_count: 1,
    })
}

// ---------------------------------------------------------------------------
// Vision normalization (downscale + letterbox + JPEG re-encode)
// ---------------------------------------------------------------------------

/// Decode a PNG, scale-to-fit a VISION_TARGET_DIM square preserving aspect,
/// letterbox the remainder with black, re-encode as PNG.
///
/// Returns PNG bytes regardless of input. Minerva's CapabilityBroker only
/// decodes PNG (Image.load_png_from_buffer) when relaying plugin chat
/// payloads — JPEG bytes would be silently dropped and the model would
/// receive no image. The downscale guards against the upstream qwen2.5vl:7b
/// runner crash on large dense images.
///
/// Skipped (returns input unchanged) when the source is already at or below
/// the target on both axes — avoids any quality loss on small images.
fn normalize_for_vision(png_bytes: &[u8]) -> VaultResult<Vec<u8>> {
    let img = image::load_from_memory(png_bytes)
        .map_err(|e| VaultError::new(format!("decode: {e}")))?;
    let (w, h) = (img.width(), img.height());
    let target = VISION_TARGET_DIM;

    if w <= target && h <= target {
        return Ok(png_bytes.to_vec());
    }

    let scale = target as f32 / w.max(h) as f32;
    let new_w = ((w as f32) * scale).round().max(1.0) as u32;
    let new_h = ((h as f32) * scale).round().max(1.0) as u32;

    let scaled = img.resize(new_w, new_h, image::imageops::FilterType::Lanczos3);
    let scaled_rgba = scaled.to_rgba8();

    let mut canvas = image::ImageBuffer::from_pixel(
        target,
        target,
        image::Rgba([0u8, 0, 0, 255]),
    );
    let x_off = ((target - new_w) / 2) as i64;
    let y_off = ((target - new_h) / 2) as i64;
    image::imageops::overlay(&mut canvas, &scaled_rgba, x_off, y_off);

    let mut buf = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(canvas)
        .write_to(&mut buf, image::ImageFormat::Png)
        .map_err(|e| VaultError::new(format!("png encode: {e}")))?;
    Ok(buf.into_inner())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_pages_missing_file() {
        let result = render_pages("/nonexistent/file.pdf", 2, 96);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.message.contains("not found") || err.message.contains("File not found"));
    }

    #[test]
    fn test_render_pages_unsupported_type() {
        let dir = std::env::temp_dir().join("scansort_render_test");
        let _ = std::fs::create_dir_all(&dir);
        let txt_path = dir.join("test.txt");
        let _ = std::fs::write(&txt_path, "hello");

        let result = render_pages(txt_path.to_str().unwrap(), 2, 96);
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
