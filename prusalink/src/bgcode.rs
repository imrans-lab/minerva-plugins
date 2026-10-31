//! Read only bounded, checksum-verified BGCode v1 print metadata. Unsupported data
//! is unavailable, never an estimate inferred from model geometry.
use serde::Serialize;
use std::io::Read;
use std::path::Path;

#[derive(Serialize)]
pub struct Estimates {
    pub est_time_s: Option<u64>,
    pub filament_g_per_tool: Option<Vec<f64>>,
}
fn u16_at(bytes: &[u8], at: usize) -> Option<u16> {
    let v = bytes.get(at..at.checked_add(2)?)?;
    Some(u16::from_le_bytes([v[0], v[1]]))
}
fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    let v = bytes.get(at..at.checked_add(4)?)?;
    Some(u32::from_le_bytes([v[0], v[1], v[2], v[3]]))
}
fn unique<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let mut values = text.lines().filter_map(|line| {
        let (k, v) = line.split_once('=')?;
        (k.trim() == key).then_some(v.trim())
    });
    let first = values.next()?;
    values.next().is_none().then_some(first)
}
fn duration(value: &str) -> Option<u64> {
    if value.is_empty() {
        return None;
    }
    value.split_whitespace().try_fold(0_u64, |total, token| {
        let unit = token.chars().last()?;
        let multiplier = match unit {
            'd' => 86400,
            'h' => 3600,
            'm' => 60,
            's' => 1,
            _ => return None,
        };
        let number = token.strip_suffix(unit)?.parse::<u64>().ok()?;
        total.checked_add(number.checked_mul(multiplier)?)
    })
}
pub fn estimates(path: &Path, tools: u8) -> Option<Estimates> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take(8 * 1024 * 1024)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.get(..4)? != b"GCDE" || u32_at(&bytes, 4)? != 1 || u16_at(&bytes, 8)? != 1 {
        return None;
    }
    let mut cursor = 10_usize;
    for _ in 0..128 {
        let start = cursor;
        let kind = u16_at(&bytes, cursor)?;
        let compression = u16_at(&bytes, cursor + 2)?;
        let unpacked = u32_at(&bytes, cursor + 4)? as usize;
        cursor += 8;
        let size = if compression == 0 {
            unpacked
        } else {
            let size = u32_at(&bytes, cursor)? as usize;
            cursor += 4;
            size
        };
        let parameters = match kind {
            0..=4 => 2,
            5 => 6,
            _ => return None,
        };
        let encoding = u16_at(&bytes, cursor)?;
        cursor += parameters;
        let end = cursor.checked_add(size)?;
        let data = bytes.get(cursor..end)?;
        if crc32fast::hash(bytes.get(start..end)?) != u32_at(&bytes, end)? {
            return None;
        }
        cursor = end.checked_add(4)?;
        if kind != 4 {
            continue;
        }
        if encoding != 0 || unpacked > 1024 * 1024 {
            return None;
        }
        let raw = match compression {
            0 => data.to_vec(),
            1 => {
                let mut output = Vec::new();
                flate2::read::ZlibDecoder::new(data)
                    .take(1024 * 1024 + 1)
                    .read_to_end(&mut output)
                    .ok()?;
                output
            }
            _ => return None,
        };
        if raw.len() != unpacked {
            return None;
        }
        let text = std::str::from_utf8(&raw).ok()?;
        let time = unique(text, "estimated printing time (normal mode)").and_then(duration);
        let masses = unique(text, "filament used [g]").and_then(|value| {
            value
                .split(',')
                .map(|v| v.trim().parse::<f64>().ok())
                .collect::<Option<Vec<_>>>()
        });
        let masses = masses.filter(|v| {
            v.len() == usize::from(tools) && v.iter().all(|n| n.is_finite() && *n >= 0.0)
        });
        return Some(Estimates {
            est_time_s: time,
            filament_g_per_tool: masses,
        });
    }
    None
}
