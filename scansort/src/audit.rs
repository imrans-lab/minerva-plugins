//! W9: Append-only CSV audit log for Scansort filing operations.
//!
//! ## Purpose
//!
//! When the user enables the audit log in Settings, every placement and
//! reprocess-supersede event is written here as an append-only CSV row.
//! The file is intended for spreadsheet import — it is NEVER read back
//! by the plugin for any processing decision (dedup, processed-state, etc.).
//!
//! ## Toggle / split of responsibility
//!
//! The audit log is **opt-in** (disabled by default).  The Settings toggle
//! (`audit_log_enabled` / `audit_log_path`) lives entirely in GDScript
//! (`settings_dialog.gd` → `ScansortSettings`).  The MCP tool
//! `minerva_scansort_audit_append` simply writes the rows it receives —
//! it has no knowledge of whether the toggle is on or off.  The panel /
//! W10 Process All pipeline is responsible for reading the toggle from
//! Settings before deciding whether to call this tool.
//!
//! ## Robustness contract
//!
//! If the log path is unwritable (permissions, bad path, full disk), the
//! tool returns `{ok: false, error: "..."}` in the MCP envelope — it does
//! NOT panic and does NOT block placement.  W10 MUST treat audit failure
//! as non-fatal (log the error, continue placing documents).
//!
//! ## CSV format
//!
//! Header (written once, on file creation):
//!
//! ```text
//! timestamp,event,source_sha256,source_filename,rule_label,destination_id,destination_kind,resolved_path,disposition,detail
//! ```
//!
//! Columns:
//!
//! | Column            | Description |
//! |-------------------|-------------|
//! | `timestamp`       | ISO-8601 UTC (e.g. `2026-05-14T12:34:56Z`) |
//! | `event`           | `placement`, `skipped`, or `superseded` |
//! | `source_sha256`   | Hex SHA-256 of the source file content |
//! | `source_filename` | Fully-qualified source path (OS-native separators, CSV-escaped) |
//! | `rule_label`      | The classification rule label that fired |
//! | `destination_id`  | Destination registry id |
//! | `destination_kind`| `vault` or `directory` |
//! | `resolved_path`   | For directory dests: absolute target path; for vault: vault path |
//! | `disposition`     | `placed`, `skipped-already-present`, `kept-both`, `replaced`, `superseded`, or `error` |
//! | `detail`          | Human-readable detail (error message, doc_id, etc.) |
//!
//! All string fields are quoted and internal `"` characters are doubled
//! (standard RFC 4180 CSV escaping).  Newlines within field values are
//! replaced with a space to keep rows unambiguous.

use crate::types::VaultError;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;

/// Hard cap on `tail_rows`' `limit` argument to bound response size.
pub const TAIL_LIMIT_CAP: usize = 1000;
/// Default `tail_rows` limit when caller omits one.
pub const TAIL_LIMIT_DEFAULT: usize = 50;

// ---------------------------------------------------------------------------
// CSV header
// ---------------------------------------------------------------------------

/// Current header (11 columns — G13 added `model_spec`).
const CSV_HEADER: &str =
    "timestamp,event,source_sha256,source_filename,rule_label,destination_id,destination_kind,resolved_path,disposition,detail,model_spec\n";

/// Legacy header prefix used by pre-G13 log files (10 columns). Recognised
/// by [`tail_rows`] so old log files keep parsing after the schema bump.
const CSV_HEADER_LEGACY: &str =
    "timestamp,event,source_sha256,source_filename,rule_label,destination_id,destination_kind,resolved_path,disposition,detail";

// ---------------------------------------------------------------------------
// Row type
// ---------------------------------------------------------------------------

/// A single audit log row.
///
/// Construct via [`AuditRow::placement`], [`AuditRow::skipped`], or
/// [`AuditRow::superseded`] rather than filling fields directly.
#[derive(Debug, Clone)]
pub struct AuditRow {
    /// ISO-8601 timestamp (caller provides; use [`crate::types::now_iso`]).
    pub timestamp: String,
    /// Event kind: `"placement"`, `"skipped"`, or `"superseded"`.
    pub event: String,
    /// Hex SHA-256 of the source file.
    pub source_sha256: String,
    /// Fully-qualified path of the source file. OS-native separators preserved
    /// (Windows backslashes, POSIX slashes) so the value is a usable locator
    /// on whichever host produced the log.
    pub source_filename: String,
    /// Rule label that fired.
    pub rule_label: String,
    /// Destination registry id.
    pub destination_id: String,
    /// `"vault"` or `"directory"`.
    pub destination_kind: String,
    /// For directory: absolute target path; for vault: vault path.
    pub resolved_path: String,
    /// Disposition string.
    pub disposition: String,
    /// Human-readable detail (error msg, doc_id, etc.).
    pub detail: String,
    /// G13 (DCR `019e564809a9`): identifier of the LLM model_spec /
    /// model name that fired the classification — empty string for rows
    /// that didn't involve an LLM call (reprocess clears, manual edits)
    /// or when the caller didn't supply one. Stable string so the audit
    /// log is greppable / pivotable by model.
    pub model_spec: String,
}

impl AuditRow {
    /// Build a row for a successful `placed` event from a `PlacementResult`.
    ///
    /// - `source_sha256`   — content hash of the source file.
    /// - `source_filename` — fully-qualified source path (OS-native separators).
    /// - `rule_label`      — rule that fired for this document.
    /// - `placement`       — per-destination `PlacementResult` from W6.
    /// - `vault_path`      — vault path (used as `resolved_path` for vault dests).
    /// - `timestamp`       — ISO-8601 string; call `types::now_iso()` at the call site.
    pub fn from_placement(
        source_sha256: &str,
        source_filename: &str,
        rule_label: &str,
        destination_id: &str,
        destination_kind: &str,
        target_path: &str,   // resolved path for dir; vault_path for vault
        status_str: &str,    // "placed", "skipped-already-present", "error"
        detail: &str,
        timestamp: &str,
        model_spec: &str,    // G13: LLM model identifier (empty if none)
    ) -> Self {
        let event = match status_str {
            "placed" => "placement",
            "skipped-already-present" => "skipped",
            _ => "placement", // error rows still logged as placement events
        };
        let disposition = status_str;
        AuditRow {
            timestamp: timestamp.to_string(),
            event: event.to_string(),
            source_sha256: source_sha256.to_string(),
            source_filename: source_filename.to_string(),
            rule_label: rule_label.to_string(),
            destination_id: destination_id.to_string(),
            destination_kind: destination_kind.to_string(),
            resolved_path: target_path.to_string(),
            disposition: disposition.to_string(),
            detail: detail.to_string(),
            model_spec: model_spec.to_string(),
        }
    }

    /// Build `superseded` rows for a reprocess event.
    ///
    /// A reprocess clears a destination's prior placements; this function
    /// produces one `superseded` row documenting the clearing event.
    /// Individual prior-placement sha256 values are not available at clear
    /// time, so `source_sha256` is left as `"(cleared)"`.
    ///
    /// - `destination_id`   — destination that was reprocessed.
    /// - `destination_kind` — `"vault"` or `"directory"`.
    /// - `destination_path` — path of the destination.
    /// - `cleared_count`    — number of documents/files cleared.
    /// - `timestamp`        — ISO-8601 string.
    pub fn from_reprocess(
        destination_id: &str,
        destination_kind: &str,
        destination_path: &str,
        cleared_count: usize,
        timestamp: &str,
    ) -> Self {
        AuditRow {
            timestamp: timestamp.to_string(),
            event: "superseded".to_string(),
            source_sha256: "(cleared)".to_string(),
            source_filename: "(cleared)".to_string(),
            rule_label: String::new(),
            destination_id: destination_id.to_string(),
            destination_kind: destination_kind.to_string(),
            resolved_path: destination_path.to_string(),
            disposition: "superseded".to_string(),
            detail: format!("reprocess cleared {} item(s)", cleared_count),
            // No LLM involvement on reprocess clears.
            model_spec: String::new(),
        }
    }

    /// Serialise this row to a single CSV line (no trailing newline).
    ///
    /// All fields are quoted; internal `"` are doubled; newlines in values
    /// are replaced with a space to keep each row on one line.
    /// Serialise this row to its MCP wire-JSON shape. Single source of
    /// truth for the response shape returned by `minerva_scansort_audit_tail`
    /// so adding a new column at AuditRow doesn't silently get dropped by
    /// a hand-built handler-side map.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "timestamp":        self.timestamp,
            "event":            self.event,
            "source_sha256":    self.source_sha256,
            "source_filename":  self.source_filename,
            "rule_label":       self.rule_label,
            "destination_id":   self.destination_id,
            "destination_kind": self.destination_kind,
            "resolved_path":    self.resolved_path,
            "disposition":      self.disposition,
            "detail":           self.detail,
            "model_spec":       self.model_spec,
        })
    }

    pub fn to_csv_line(&self) -> String {
        let fields = [
            self.timestamp.as_str(),
            self.event.as_str(),
            self.source_sha256.as_str(),
            self.source_filename.as_str(),
            self.rule_label.as_str(),
            self.destination_id.as_str(),
            self.destination_kind.as_str(),
            self.resolved_path.as_str(),
            self.disposition.as_str(),
            self.detail.as_str(),
            self.model_spec.as_str(),
        ];
        fields
            .iter()
            .map(|f| csv_quote(f))
            .collect::<Vec<_>>()
            .join(",")
    }
}

// ---------------------------------------------------------------------------
// CSV quoting (RFC 4180)
// ---------------------------------------------------------------------------

/// Quote a single CSV field value.
///
/// Always wraps in `"..."`.  Internal `"` are doubled.  Embedded newlines
/// (`\n`, `\r`) are replaced with a space so each logical row stays on
/// one physical line — this is important for spreadsheet import.
fn csv_quote(value: &str) -> String {
    // Replace newlines with space, then double any embedded quotes.
    let cleaned = value.replace('\n', " ").replace('\r', " ");
    let escaped = cleaned.replace('"', "\"\"");
    format!("\"{}\"", escaped)
}

// ---------------------------------------------------------------------------
// Append to log file
// ---------------------------------------------------------------------------

/// Append one or more audit rows to the CSV log at `log_path`.
///
/// - If the file does not exist, it is created and the header row is written.
/// - If the file already exists, rows are appended (file is NEVER truncated).
/// - Returns `Err` (not a panic) if the file cannot be opened/written.
///   Callers MUST treat this as non-fatal.
pub fn append_rows(log_path: &Path, rows: &[AuditRow]) -> Result<(), VaultError> {
    if rows.is_empty() {
        return Ok(());
    }

    let needs_header = !log_path.exists();

    // Ensure parent directory exists.
    if let Some(parent) = log_path.parent() {
        if !parent.as_os_str().is_empty() && !parent.exists() {
            std::fs::create_dir_all(parent).map_err(|e| {
                VaultError::new(format!(
                    "audit log: cannot create parent directory '{}': {}",
                    parent.display(),
                    e
                ))
            })?;
        }
    }

    let file: File = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot open '{}' for append: {}",
                log_path.display(),
                e
            ))
        })?;

    let mut writer = BufWriter::new(file);

    if needs_header {
        writer.write_all(CSV_HEADER.as_bytes()).map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot write header to '{}': {}",
                log_path.display(),
                e
            ))
        })?;
    }

    for row in rows {
        let line = row.to_csv_line();
        writer.write_all(line.as_bytes()).map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot write row to '{}': {}",
                log_path.display(),
                e
            ))
        })?;
        writer.write_all(b"\n").map_err(|e| {
            VaultError::new(format!(
                "audit log: cannot write newline to '{}': {}",
                log_path.display(),
                e
            ))
        })?;
    }

    writer.flush().map_err(|e| {
        VaultError::new(format!(
            "audit log: cannot flush '{}': {}",
            log_path.display(),
            e
        ))
    })?;

    Ok(())
}

// ---------------------------------------------------------------------------
// CSV row parsing (inverse of to_csv_line)
// ---------------------------------------------------------------------------

/// Parse one CSV-encoded audit row written by [`AuditRow::to_csv_line`].
///
/// Inverse of `to_csv_line` — single source of truth for the on-disk schema.
/// Returns an error if the row does not have exactly 10 fields or if the
/// quoting is malformed (unterminated quote, stray chars between fields).
pub fn parse_row(line: &str) -> Result<AuditRow, VaultError> {
    let fields = split_csv_fields(line)?;
    // G13: schema bumped from 10 → 11 columns by adding model_spec at the
    // end. Accept both so old log files keep parsing — missing model_spec
    // becomes "" (no LLM attribution available).
    let model_spec = match fields.len() {
        11 => fields[10].clone(),
        10 => String::new(),
        n => return Err(VaultError::new(format!(
            "audit log: expected 10 or 11 CSV fields, got {} in row: {}",
            n, line
        ))),
    };
    Ok(AuditRow {
        timestamp:        fields[0].clone(),
        event:            fields[1].clone(),
        source_sha256:    fields[2].clone(),
        source_filename:  fields[3].clone(),
        rule_label:       fields[4].clone(),
        destination_id:   fields[5].clone(),
        destination_kind: fields[6].clone(),
        resolved_path:    fields[7].clone(),
        disposition:      fields[8].clone(),
        detail:           fields[9].clone(),
        model_spec,
    })
}

/// RFC 4180 (subset) field splitter for rows produced by `csv_quote`.
///
/// We always quote every field, so the parser only needs to handle quoted
/// fields with internal `""` escapes. An unquoted field is treated as an
/// error to keep round-trip behaviour strict.
fn split_csv_fields(line: &str) -> Result<Vec<String>, VaultError> {
    let mut fields: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut chars = line.chars().peekable();

    loop {
        match chars.next() {
            None => break,
            Some('"') => {
                // Quoted field — consume until the closing quote, doubling on "".
                loop {
                    match chars.next() {
                        Some('"') => {
                            if chars.peek() == Some(&'"') {
                                chars.next();
                                cur.push('"');
                            } else {
                                break;
                            }
                        }
                        Some(c) => cur.push(c),
                        None => return Err(VaultError::new(format!(
                            "audit log: unterminated quoted field in row: {}", line
                        ))),
                    }
                }
                fields.push(std::mem::take(&mut cur));
                match chars.next() {
                    None => return Ok(fields),
                    Some(',') => continue,
                    Some(c) => return Err(VaultError::new(format!(
                        "audit log: stray char {:?} after quoted field in row: {}", c, line
                    ))),
                }
            }
            Some(',') => {
                // Empty unquoted field — produce empty string and continue.
                fields.push(std::mem::take(&mut cur));
            }
            Some(c) => return Err(VaultError::new(format!(
                "audit log: unquoted field starting with {:?} in row: {}", c, line
            ))),
        }
    }
    Ok(fields)
}

// ---------------------------------------------------------------------------
// Tail read (last `limit` rows)
// ---------------------------------------------------------------------------

/// Read the last `limit` rows from a CSV audit log.
///
/// `limit` is clamped to [`TAIL_LIMIT_CAP`]. Returns rows in file order
/// (oldest of the tail first). The header row is skipped. Empty file → `[]`.
/// Missing file → `Err`. Malformed rows surface as `Err` from `parse_row`.
pub fn tail_rows(log_path: &Path, limit: usize) -> Result<Vec<AuditRow>, VaultError> {
    if !log_path.exists() {
        return Err(VaultError::new(format!(
            "audit log: no file at '{}'", log_path.display()
        )));
    }
    let limit = limit.min(TAIL_LIMIT_CAP);
    if limit == 0 {
        return Ok(Vec::new());
    }

    let file = File::open(log_path).map_err(|e| {
        VaultError::new(format!(
            "audit log: cannot open '{}' for read: {}", log_path.display(), e
        ))
    })?;
    let reader = BufReader::new(file);

    let mut tail: std::collections::VecDeque<String> =
        std::collections::VecDeque::with_capacity(limit);
    for (idx, line) in reader.lines().enumerate() {
        let line = line.map_err(|e| {
            VaultError::new(format!(
                "audit log: read error on '{}': {}", log_path.display(), e
            ))
        })?;
        // Header detection — match both the current (G13, 11-col) header
        // and the legacy (10-col) prefix to keep old log files parseable.
        if idx == 0
            && (line.starts_with(CSV_HEADER_LEGACY) || line.starts_with("timestamp,event,"))
        {
            continue;
        }
        if line.is_empty() {
            continue;
        }
        if tail.len() == limit {
            tail.pop_front();
        }
        tail.push_back(line);
    }

    let mut rows: Vec<AuditRow> = Vec::with_capacity(tail.len());
    for raw in tail.drain(..) {
        rows.push(parse_row(&raw)?);
    }
    Ok(rows)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_tmp(prefix: &str) -> std::path::PathBuf {
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir()
            .join(format!("scansort-audit-{prefix}-{pid}-{ts}-{n}"))
    }

    fn read_file(p: &Path) -> String {
        std::fs::read_to_string(p).unwrap_or_default()
    }

    // -----------------------------------------------------------------------
    // 1. First append creates file with header row.
    // -----------------------------------------------------------------------
    #[test]
    fn first_append_writes_header() {
        let dir = unique_tmp("header");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "abc123", "invoice.pdf", "Invoice", "dest1", "vault",
            "/archive.ssort", "placed", "doc_id=42",
            "2026-05-14T12:00:00Z",
        "",
        );

        append_rows(&log, &[row]).expect("append should succeed");

        let contents = read_file(&log);
        assert!(
            contents.starts_with("timestamp,event,"),
            "first line must be the header: {:?}",
            contents.lines().next()
        );

        // Should have header + 1 data row.
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(lines.len(), 2, "expected header + 1 data row");
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 2. Subsequent appends do NOT add another header.
    // -----------------------------------------------------------------------
    #[test]
    fn subsequent_appends_do_not_truncate_or_add_header() {
        let dir = unique_tmp("no-trunc");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row1 = AuditRow::from_placement(
            "sha1", "a.pdf", "Invoice", "d1", "directory",
            "/dest/a.pdf", "placed", "",
            "2026-05-14T10:00:00Z",
        "",
        );
        let row2 = AuditRow::from_placement(
            "sha2", "b.pdf", "Contract", "d2", "vault",
            "/vault.ssort", "placed", "doc_id=7",
            "2026-05-14T10:01:00Z",
        "",
        );

        append_rows(&log, &[row1]).expect("first append");
        append_rows(&log, &[row2]).expect("second append");

        let contents = read_file(&log);
        let lines: Vec<&str> = contents.lines().collect();

        // header + row1 + row2 = 3 lines
        assert_eq!(lines.len(), 3, "expected header + 2 data rows, got:\n{}", contents);

        // Only one header.
        let header_count = lines.iter().filter(|l| l.starts_with("timestamp,event")).count();
        assert_eq!(header_count, 1, "header must appear exactly once");

        // Both rows present.
        assert!(contents.contains("sha1"), "row1 missing");
        assert!(contents.contains("sha2"), "row2 missing");

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 3. CSV escaping: commas in a filename don't corrupt the row.
    // -----------------------------------------------------------------------
    #[test]
    fn csv_escaping_comma_in_filename() {
        let dir = unique_tmp("csv-comma");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "deadbeef", "invoice, 2026.pdf", "Invoice", "d1", "directory",
            "/dest/invoice.pdf", "placed", "",
            "2026-05-14T10:00:00Z",
        "",
        );
        append_rows(&log, &[row]).expect("append");

        let contents = read_file(&log);
        // The filename field with a comma must be quoted.
        assert!(
            contents.contains("\"invoice, 2026.pdf\""),
            "comma-containing filename must be quoted in CSV: {}",
            contents
        );
        // The row must parse into exactly 10 fields (not more).
        let data_line = contents.lines().nth(1).expect("data line");
        let field_count = count_csv_fields(data_line);
        assert_eq!(field_count, 11, "CSV row must have exactly 11 fields: {}", data_line);

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 4. CSV escaping: double-quote in a filename.
    // -----------------------------------------------------------------------
    #[test]
    fn csv_escaping_quote_in_filename() {
        let dir = unique_tmp("csv-quote");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "deadbeef", "invoice \"final\".pdf", "Invoice", "d1", "vault",
            "/vault.ssort", "placed", "",
            "2026-05-14T10:00:00Z",
        "",
        );
        append_rows(&log, &[row]).expect("append");

        let contents = read_file(&log);
        // Internal quotes are doubled: " → ""
        assert!(
            contents.contains("\"invoice \"\"final\"\".pdf\""),
            "double-quote must be escaped as \"\" in CSV: {}",
            contents
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 5. CSV escaping: newline in a filename does not produce extra rows.
    // -----------------------------------------------------------------------
    #[test]
    fn csv_escaping_newline_in_filename() {
        let dir = unique_tmp("csv-newline");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let row = AuditRow::from_placement(
            "deadbeef", "invoice\npart2.pdf", "Invoice", "d1", "vault",
            "/vault.ssort", "placed", "",
            "2026-05-14T10:00:00Z",
        "",
        );
        append_rows(&log, &[row]).expect("append");

        let contents = read_file(&log);
        // Must still be exactly 2 lines (header + 1 data row).
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(
            lines.len(), 2,
            "newline in filename must not produce extra rows: {:?}",
            lines
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 6. from_placement → row construction: event and disposition fields.
    // -----------------------------------------------------------------------
    #[test]
    fn placement_row_event_and_disposition() {
        let placed = AuditRow::from_placement(
            "sha", "doc.pdf", "Contract", "d1", "vault",
            "/v.ssort", "placed", "doc_id=3",
            "2026-05-14T00:00:00Z",
        "",
        );
        assert_eq!(placed.event, "placement");
        assert_eq!(placed.disposition, "placed");

        let skipped = AuditRow::from_placement(
            "sha", "doc.pdf", "Contract", "d1", "vault",
            "/v.ssort", "skipped-already-present", "",
            "2026-05-14T00:00:00Z",
        "",
        );
        assert_eq!(skipped.event, "skipped");
        assert_eq!(skipped.disposition, "skipped-already-present");
    }

    // -----------------------------------------------------------------------
    // 7. from_reprocess → superseded row construction.
    // -----------------------------------------------------------------------
    #[test]
    fn reprocess_row_superseded() {
        let row = AuditRow::from_reprocess(
            "dest_99", "directory", "/docs/output", 5,
            "2026-05-14T09:00:00Z",
        );
        assert_eq!(row.event, "superseded");
        assert_eq!(row.disposition, "superseded");
        assert!(row.detail.contains("5"), "detail should mention cleared count");
    }

    // -----------------------------------------------------------------------
    // 8. Unwritable path returns an error (not a panic).
    // -----------------------------------------------------------------------
    #[test]
    fn unwritable_path_returns_error_not_panic() {
        // Use a path under a non-existent parent with no write permission.
        // We simulate this by pointing at /proc/scansort-audit-test (never
        // writable from user space on Linux).
        let log = std::path::Path::new("/proc/scansort-audit-test-w9/audit.csv");
        let row = AuditRow::from_placement(
            "sha", "doc.pdf", "Invoice", "d1", "vault",
            "/v.ssort", "placed", "",
            "2026-05-14T00:00:00Z",
        "",
        );
        let result = append_rows(log, &[row]);
        assert!(
            result.is_err(),
            "append to unwritable path must return Err, not panic"
        );
        // Error message must be informative (not empty).
        let msg = result.unwrap_err().message;
        assert!(!msg.is_empty(), "error message must not be empty");
    }

    // -----------------------------------------------------------------------
    // 9. Batch append: multiple rows in one call.
    // -----------------------------------------------------------------------
    #[test]
    fn batch_append_writes_all_rows() {
        let dir = unique_tmp("batch");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let rows: Vec<AuditRow> = (0..5u64).map(|i| {
            AuditRow::from_placement(
                &format!("sha{i}"),
                &format!("doc{i}.pdf"),
                "Invoice",
                &format!("dest{i}"),
                "directory",
                &format!("/dest{i}/doc{i}.pdf"),
                "placed",
                "",
                "2026-05-14T00:00:00Z",
            "",
            )
        }).collect();

        append_rows(&log, &rows).expect("batch append");

        let contents = read_file(&log);
        let lines: Vec<&str> = contents.lines().collect();
        // header + 5 rows
        assert_eq!(lines.len(), 6, "expected 6 lines (header + 5 rows): {}", contents);

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 10. Empty batch is a no-op (file not created).
    // -----------------------------------------------------------------------
    #[test]
    fn empty_batch_is_noop() {
        let dir = unique_tmp("empty-batch");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        append_rows(&log, &[]).expect("empty batch should not error");
        assert!(!log.exists(), "empty batch must not create the log file");

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 11. parse_row: round-trip a row through to_csv_line + parse_row.
    // -----------------------------------------------------------------------
    #[test]
    fn parse_row_roundtrip() {
        let original = AuditRow::from_placement(
            "abc123", "invoice.pdf", "Invoice", "dest1", "vault",
            "/archive.ssort", "placed", "doc_id=42",
            "2026-05-14T12:00:00Z",
        "",
        );
        let line = original.to_csv_line();
        let parsed = parse_row(&line).expect("round-trip must succeed");
        assert_eq!(parsed.timestamp,        original.timestamp);
        assert_eq!(parsed.event,            original.event);
        assert_eq!(parsed.source_sha256,    original.source_sha256);
        assert_eq!(parsed.source_filename,  original.source_filename);
        assert_eq!(parsed.rule_label,       original.rule_label);
        assert_eq!(parsed.destination_id,   original.destination_id);
        assert_eq!(parsed.destination_kind, original.destination_kind);
        assert_eq!(parsed.resolved_path,    original.resolved_path);
        assert_eq!(parsed.disposition,      original.disposition);
        assert_eq!(parsed.detail,           original.detail);
    }

    #[test]
    fn parse_row_roundtrip_comma_quote_in_field() {
        let original = AuditRow::from_placement(
            "deadbeef",
            "invoice, \"final\".pdf",
            "Invoice",
            "d1",
            "directory",
            "/dest/path with, comma.pdf",
            "placed",
            "note: he said \"ship it\"",
            "2026-05-14T10:00:00Z",
        "",
        );
        let line = original.to_csv_line();
        let parsed = parse_row(&line).expect("comma + quote round-trip");
        assert_eq!(parsed.source_filename, original.source_filename);
        assert_eq!(parsed.resolved_path,   original.resolved_path);
        assert_eq!(parsed.detail,          original.detail);
    }

    #[test]
    fn parse_row_rejects_wrong_field_count() {
        let bad = "\"a\",\"b\",\"c\"";
        let result = parse_row(bad);
        assert!(result.is_err(), "3 fields must be rejected");
        assert!(result.unwrap_err().message.contains("10 or 11"));
    }

    // G13: legacy 10-column rows (written before the model_spec bump) must
    // keep parsing — model_spec defaults to empty string.
    #[test]
    fn parse_row_accepts_legacy_10_column_row() {
        let legacy = r#""2026-05-14T12:00:00Z","placement","abc","invoice.pdf","Invoice","dest1","vault","/archive.ssort","placed","doc_id=42""#;
        let parsed = parse_row(legacy).expect("legacy 10-col row must parse");
        assert_eq!(parsed.rule_label, "Invoice");
        assert_eq!(parsed.detail, "doc_id=42");
        assert_eq!(parsed.model_spec, "", "missing model_spec must default to empty string");
    }

    #[test]
    fn parse_row_carries_model_spec_on_11_column_row() {
        let new = r#""2026-05-14T12:00:00Z","placement","abc","invoice.pdf","Invoice","dest1","vault","/archive.ssort","placed","doc_id=42","claude-haiku-4-5""#;
        let parsed = parse_row(new).expect("11-col row must parse");
        assert_eq!(parsed.model_spec, "claude-haiku-4-5");
    }

    // tail_rows must skip both the new (11-col) header and the legacy
    // (10-col) header so old log files don't surface their header as a
    // spurious data row.
    #[test]
    fn tail_rows_skips_legacy_header() {
        let dir = unique_tmp("tail-legacy-header");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");
        // Write a legacy header + 1 legacy data row.
        let body = format!(
            "{}\n{}\n",
            CSV_HEADER_LEGACY,
            r#""2026-05-14T12:00:00Z","placement","abc","invoice.pdf","Invoice","dest1","vault","/v.ssort","placed","doc_id=42""#
        );
        std::fs::write(&log, body).unwrap();

        let tail = tail_rows(&log, 10).expect("tail");
        assert_eq!(tail.len(), 1, "legacy header must NOT count as a data row");
        assert_eq!(tail[0].rule_label, "Invoice");
        assert_eq!(tail[0].model_spec, "");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn parse_row_rejects_unterminated_quote() {
        let bad = "\"timestamp,\"event\"";
        let result = parse_row(bad);
        assert!(result.is_err(), "unterminated quote must be rejected");
    }

    // -----------------------------------------------------------------------
    // 12. tail_rows: basic happy path — returns last N rows in file order.
    // -----------------------------------------------------------------------
    #[test]
    fn tail_rows_returns_last_n_in_file_order() {
        let dir = unique_tmp("tail-basic");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");

        let rows: Vec<AuditRow> = (0..5u64).map(|i| {
            AuditRow::from_placement(
                &format!("sha{i}"),
                &format!("doc{i}.pdf"),
                "Invoice",
                &format!("dest{i}"),
                "directory",
                &format!("/dest{i}/doc{i}.pdf"),
                "placed",
                "",
                "2026-05-14T00:00:00Z",
            "",
            )
        }).collect();
        append_rows(&log, &rows).expect("seed");

        let tail = tail_rows(&log, 3).expect("tail");
        assert_eq!(tail.len(), 3);
        // Should be the last 3 in file (oldest-of-tail first).
        assert_eq!(tail[0].source_sha256, "sha2");
        assert_eq!(tail[1].source_sha256, "sha3");
        assert_eq!(tail[2].source_sha256, "sha4");

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 13. tail_rows: limit > total rows returns all rows.
    // -----------------------------------------------------------------------
    #[test]
    fn tail_rows_limit_exceeds_total() {
        let dir = unique_tmp("tail-over");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");
        let rows: Vec<AuditRow> = (0..2u64).map(|i| {
            AuditRow::from_placement(
                &format!("sha{i}"), "d.pdf", "R", "d1", "vault",
                "/v.ssort", "placed", "",
                "2026-05-14T00:00:00Z",
            "",
            )
        }).collect();
        append_rows(&log, &rows).expect("seed");

        let tail = tail_rows(&log, 50).expect("tail");
        assert_eq!(tail.len(), 2);
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 14. tail_rows: empty log (no append yet) → Err (file missing).
    // -----------------------------------------------------------------------
    #[test]
    fn tail_rows_missing_file_errs() {
        let log = std::env::temp_dir()
            .join(format!("scansort-tail-missing-{}.csv", std::process::id()));
        // Ensure absent.
        let _ = std::fs::remove_file(&log);
        let result = tail_rows(&log, 10);
        assert!(result.is_err());
        assert!(result.unwrap_err().message.contains("no file at"));
    }

    // -----------------------------------------------------------------------
    // 15. tail_rows: header-only file (no data rows) → empty vec.
    // -----------------------------------------------------------------------
    #[test]
    fn tail_rows_header_only_file() {
        let dir = unique_tmp("tail-header-only");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");
        // Write header only by appending then truncating to header.
        std::fs::write(&log, CSV_HEADER).unwrap();

        let tail = tail_rows(&log, 10).expect("tail");
        assert!(tail.is_empty(), "header-only file should yield empty vec");
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 16. tail_rows: cap clamps limit to TAIL_LIMIT_CAP.
    // -----------------------------------------------------------------------
    #[test]
    fn tail_rows_limit_clamped_to_cap() {
        // Write TAIL_LIMIT_CAP + 5 rows; ask for cap + 100; expect cap returned.
        let dir = unique_tmp("tail-cap");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");
        let rows: Vec<AuditRow> = (0..(TAIL_LIMIT_CAP + 5)).map(|i| {
            AuditRow::from_placement(
                &format!("sha{i}"), "d.pdf", "R", "d1", "vault",
                "/v.ssort", "placed", "", "2026-05-14T00:00:00Z",
            "",
            )
        }).collect();
        append_rows(&log, &rows).expect("seed");

        let tail = tail_rows(&log, TAIL_LIMIT_CAP + 100).expect("tail");
        assert_eq!(tail.len(), TAIL_LIMIT_CAP);
        // First row in tail is at index (total - cap).
        let first_expected = format!("sha{}", rows.len() - TAIL_LIMIT_CAP);
        assert_eq!(tail[0].source_sha256, first_expected);
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // 17. tail_rows: limit=0 returns empty vec (no error, no read).
    // -----------------------------------------------------------------------
    #[test]
    fn tail_rows_zero_limit() {
        let dir = unique_tmp("tail-zero");
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("audit.csv");
        std::fs::write(&log, CSV_HEADER).unwrap();
        let tail = tail_rows(&log, 0).expect("tail");
        assert!(tail.is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Helper: naively count CSV fields in a line by counting commas outside
    // of quoted strings. Handles the RFC 4180 subset we produce.
    // -----------------------------------------------------------------------
    fn count_csv_fields(line: &str) -> usize {
        let mut count = 1;
        let mut in_quotes = false;
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '"' => {
                    if in_quotes {
                        // Check for doubled quote (escaped).
                        if chars.peek() == Some(&'"') {
                            chars.next(); // consume second "
                        } else {
                            in_quotes = false;
                        }
                    } else {
                        in_quotes = true;
                    }
                }
                ',' if !in_quotes => {
                    count += 1;
                }
                _ => {}
            }
        }
        count
    }
}
