//! Document CRUD: insert, query, extract, update, get, inventory.
//!
//! Ported from vault.py / experiment documents.rs. All functions take a vault
//! path as the first argument. Uses db.rs helpers for row extraction and
//! types.rs structs for return values.

use crate::crypto;
use crate::db;
use crate::extract;
use crate::types::*;
use rusqlite::params;
use std::collections::HashMap;
use std::path::Path;

// ---------------------------------------------------------------------------
// Shared blob pipeline helpers
// ---------------------------------------------------------------------------

/// Compress raw bytes with zstd and optionally encrypt with the vault's key.
///
/// Returns `(stored_blob, encryption_iv, encryption_tag)` — iv/tag are
/// `Some(...)` when `password` is non-empty, `None` for plaintext storage.
/// Shared by `insert_document`, `replace_document_content`, and
/// `insert_document_with_metadata` so the compress→encrypt step has exactly
/// one implementation.
fn pack_blob_for_storage(
    path: &str,
    raw_data: &[u8],
    password: &str,
) -> VaultResult<(Vec<u8>, Option<Vec<u8>>, Option<Vec<u8>>)> {
    let compressed = zstd::encode_all(raw_data, 3)
        .map_err(|e| VaultError::new(format!("Compression failed: {e}")))?;
    if !password.is_empty() {
        let key = crypto::vault_key(path, password)?;
        let (ct, iv, tag) = crypto::encrypt_bytes(&key, &compressed)?;
        Ok((ct, Some(iv), Some(tag)))
    } else {
        Ok((compressed, None, None))
    }
}

// ---------------------------------------------------------------------------
// insert_document
// ---------------------------------------------------------------------------

/// Read a file from disk, compress with zstd, optionally encrypt with
/// AES-256-GCM, and insert into the documents and fingerprints tables.
///
/// `password` controls encryption: if non-empty the vault must already have a
/// password set (via `crypto::set_password`); the same KDF + salt stored in
/// the vault's project table is used to derive the key.  Ordering mirrors the
/// Python reference implementation: **compress → encrypt → store**.
///
/// Returns the new `doc_id` on success.
pub fn insert_document(
    path: &str,
    file_path: &str,
    category: &str,
    confidence: f64,
    issuer: &str,
    description: &str,
    doc_date: &str,
    status: &str,
    sha256: &str,
    simhash: &str,
    dhash: &str,
    source_path: &str,
    rule_snapshot: &str,
    password: &str,
    display_name: &str,
) -> VaultResult<i64> {
    let fp = Path::new(file_path);
    if !fp.exists() {
        return Err(VaultError::new(format!("File not found: {file_path}")));
    }

    // Read raw bytes
    let raw_data = std::fs::read(fp)?;
    let original_size = raw_data.len() as i64;

    // Compress + optionally encrypt via the shared blob pipeline.
    let (stored_data, enc_iv, enc_tag) = pack_blob_for_storage(path, &raw_data, password)?;
    let compressed_size = stored_data.len();

    // Compute SHA-256 if not provided
    let sha256_val = if sha256.is_empty() {
        use sha2::{Digest, Sha256};
        let hash = Sha256::digest(&raw_data);
        format!("{:x}", hash)
    } else {
        sha256.to_string()
    };

    // Extract filename and extension
    let original_filename = fp
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let file_ext = fp
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default();

    let effective_source = if source_path.is_empty() {
        file_path
    } else {
        source_path
    };
    let effective_status = if status.is_empty() {
        "classified"
    } else {
        status
    };

    let now = now_iso();

    let conn = db::connect(path)?;

    // Insert document row. display_name is stored when non-empty; vault_inventory
    // falls back to original_filename when the column is empty.
    let doc_id: i64 = match conn.execute(
        "INSERT INTO documents \
         (original_filename, file_ext, category, confidence, issuer, \
          description, doc_date, classified_at, sha256, simhash, dhash, \
          status, file_data, file_size, compression, encryption_iv, encryption_tag, \
          source_path, rule_snapshot, display_name) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'zstd', \
                 ?15, ?16, ?17, ?18, ?19)",
        params![
            original_filename,
            file_ext,
            category,
            confidence,
            issuer,
            description,
            doc_date,
            now,
            sha256_val,
            simhash,
            dhash,
            effective_status,
            stored_data,
            original_size,
            enc_iv,
            enc_tag,
            effective_source,
            rule_snapshot,
            display_name,
        ],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => {
            let msg = e.to_string();
            if msg.to_lowercase().contains("unique") || msg.to_lowercase().contains("sha256") {
                return Err(VaultError::new(format!(
                    "Duplicate document (SHA-256 already exists): {sha256_val}"
                )));
            }
            return Err(VaultError::new(format!("Failed to insert document: {e}")));
        }
    };

    // Insert fingerprints
    conn.execute(
        "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) \
         VALUES (?1, ?2, ?3, ?4)",
        params![sha256_val, simhash, dhash, doc_id],
    )?;

    // Log the insertion
    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            format!(
                "Imported {original_filename} ({original_size} bytes, \
                 compressed to {compressed_size} bytes)"
            ),
            doc_id,
        ],
    )?;

    Ok(doc_id)
}

// ---------------------------------------------------------------------------
// insert_document_with_metadata — bytes-based insert preserving full metadata
// ---------------------------------------------------------------------------

/// Insert a document from in-memory bytes + a populated `Document` struct.
///
/// Used by cross-vault transfer (`transfer::move_document_to_vault`) to avoid
/// a cleartext-on-disk pivot. Carries every metadata field from the source
/// (including classified_at, tags, rule_snapshot) and writes the new
/// `doc_id` for the destination vault. Bytes run through the shared
/// `pack_blob_for_storage` pipeline. The destination's UNIQUE sha256
/// constraint surfaces as a structured duplicate error.
pub(crate) fn insert_document_with_metadata(
    path: &str,
    doc: &Document,
    raw_data: &[u8],
    password: &str,
) -> VaultResult<i64> {
    let original_size = raw_data.len() as i64;
    let (stored_data, enc_iv, enc_tag) = pack_blob_for_storage(path, raw_data, password)?;

    let sha256_val = if doc.sha256.is_empty() {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(raw_data))
    } else {
        doc.sha256.clone()
    };

    let now = now_iso();
    let classified_at = if doc.classified_at.is_empty() {
        now.clone()
    } else {
        doc.classified_at.clone()
    };
    let tags_json = db::to_json_array(&doc.tags);

    let conn = db::connect(path)?;

    let doc_id: i64 = match conn.execute(
        "INSERT INTO documents \
         (original_filename, file_ext, category, confidence, issuer, \
          description, doc_date, classified_at, sha256, simhash, dhash, \
          status, file_data, file_size, compression, encryption_iv, encryption_tag, \
          source_path, rule_snapshot, display_name, tags) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'zstd', \
                 ?15, ?16, ?17, ?18, ?19, ?20)",
        params![
            doc.original_filename,
            doc.file_ext,
            doc.category,
            doc.confidence,
            doc.issuer,
            doc.description,
            doc.doc_date,
            classified_at,
            sha256_val,
            doc.simhash,
            doc.dhash,
            doc.status,
            stored_data,
            original_size,
            enc_iv,
            enc_tag,
            doc.source_path,
            doc.rule_snapshot,
            doc.display_name,
            tags_json,
        ],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => {
            let msg = e.to_string();
            if msg.to_lowercase().contains("unique") || msg.to_lowercase().contains("sha256") {
                return Err(VaultError::new(format!(
                    "Duplicate document (SHA-256 already exists in destination vault): {sha256_val}"
                )));
            }
            return Err(VaultError::new(format!("Failed to insert document: {e}")));
        }
    };

    conn.execute(
        "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) \
         VALUES (?1, ?2, ?3, ?4)",
        params![sha256_val, doc.simhash, doc.dhash, doc_id],
    )?;

    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now,
            format!(
                "Imported {} ({} bytes via in-memory transfer)",
                doc.original_filename, original_size
            ),
            doc_id,
        ],
    )?;

    Ok(doc_id)
}

// ---------------------------------------------------------------------------
// query_documents
// ---------------------------------------------------------------------------

/// Query documents with optional filters.
///
/// Supports filtering by category, sender, status, date range, text pattern,
/// tag, and specific doc_id.
pub fn query_documents(path: &str, filter: &DocumentFilter) -> VaultResult<Vec<Document>> {
    let conn = db::connect(path)?;

    let mut clauses: Vec<String> = Vec::new();
    let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    if let Some(ref cat) = filter.category {
        clauses.push("category = ?".to_string());
        param_values.push(Box::new(cat.clone()));
    }

    if let Some(ref issuer) = filter.issuer {
        clauses.push("issuer LIKE ?".to_string());
        param_values.push(Box::new(format!("%{issuer}%")));
    }

    if let Some(ref status) = filter.status {
        clauses.push("status = ?".to_string());
        param_values.push(Box::new(status.clone()));
    }

    if let Some(ref date_from) = filter.date_from {
        clauses.push("doc_date >= ?".to_string());
        param_values.push(Box::new(date_from.clone()));
    }

    if let Some(ref date_to) = filter.date_to {
        clauses.push("doc_date <= ?".to_string());
        param_values.push(Box::new(date_to.clone()));
    }

    if let Some(ref pattern) = filter.pattern {
        let p = format!("%{pattern}%");
        clauses.push(
            "(description LIKE ? OR original_filename LIKE ? \
             OR display_name LIKE ? OR tags LIKE ? OR issuer LIKE ?)"
                .to_string(),
        );
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p.clone()));
        param_values.push(Box::new(p));
    }

    if let Some(ref tag) = filter.tag {
        clauses.push("tags LIKE ?".to_string());
        param_values.push(Box::new(format!("%\"{tag}\"%")));
    }

    if let Some(doc_id) = filter.doc_id {
        clauses.push("doc_id = ?".to_string());
        param_values.push(Box::new(doc_id));
    }

    let where_clause = if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    };

    let sql = format!(
        "SELECT doc_id, original_filename, file_ext, category, confidence, issuer, \
         description, doc_date, classified_at, sha256, simhash, dhash, \
         status, file_size, compression, encryption_iv, source_path, \
         display_name, tags, rule_snapshot \
         FROM documents {where_clause} ORDER BY classified_at DESC"
    );

    let mut stmt = conn.prepare(&sql)?;
    let params_refs: Vec<&dyn rusqlite::types::ToSql> =
        param_values.iter().map(|p| p.as_ref()).collect();

    let rows = stmt.query_map(params_refs.as_slice(), |row| {
        let tags_raw = db::get_string(row, "tags");
        let tags = db::parse_json_array(&tags_raw);
        let display_name_raw = db::get_string(row, "display_name");
        let original_filename = db::get_string(row, "original_filename");
        let display_name = if display_name_raw.is_empty() {
            original_filename.clone()
        } else {
            display_name_raw
        };
        let encrypted = db::get_blob(row, "encryption_iv").is_some();

        Ok(Document {
            doc_id: db::get_i64(row, "doc_id"),
            original_filename,
            display_name,
            file_ext: db::get_string(row, "file_ext"),
            category: db::get_string(row, "category"),
            confidence: db::get_f64(row, "confidence"),
            issuer: db::get_string(row, "issuer"),
            description: db::get_string(row, "description"),
            doc_date: db::get_string(row, "doc_date"),
            classified_at: db::get_string(row, "classified_at"),
            sha256: db::get_string(row, "sha256"),
            simhash: db::get_string(row, "simhash"),
            dhash: db::get_string(row, "dhash"),
            status: db::get_string(row, "status"),
            file_size: db::get_i64(row, "file_size"),
            compression: db::get_string(row, "compression"),
            encrypted,
            tags,
            source_path: db::get_string(row, "source_path"),
            rule_snapshot: db::get_string(row, "rule_snapshot"),
        })
    })?;

    let mut docs = Vec::new();
    for row_result in rows {
        docs.push(row_result?);
    }

    Ok(docs)
}

// ---------------------------------------------------------------------------
// get_document
// ---------------------------------------------------------------------------

/// Get a single document's metadata by doc_id.
///
/// Returns the Document on success, or an error if not found.
pub fn get_document(path: &str, doc_id: i64) -> VaultResult<Document> {
    let filter = DocumentFilter {
        doc_id: Some(doc_id),
        ..Default::default()
    };
    let mut docs = query_documents(path, &filter)?;
    if docs.is_empty() {
        Err(VaultError::new(format!("Document not found: id={doc_id}")))
    } else {
        Ok(docs.remove(0))
    }
}

// ---------------------------------------------------------------------------
// read_document_bytes — decrypt + decompress in memory (no disk pivot)
// ---------------------------------------------------------------------------

/// Read a stored document's content, decrypt (if encrypted), and decompress.
///
/// Returns `(original_filename, plaintext_bytes)`. Used by `extract_document`
/// (writes to disk) and `transfer::move_document_to_vault` (keeps the bytes
/// in memory). Mirrors the inverse of `pack_blob_for_storage`. Single source
/// of truth for the decrypt + decompress step.
pub(crate) fn read_document_bytes(
    path: &str,
    doc_id: i64,
    password: &str,
) -> VaultResult<(String, Vec<u8>)> {
    let conn = db::connect(path)?;

    let (original_filename, file_data, compression, enc_iv, enc_tag): (
        String,
        Option<Vec<u8>>,
        String,
        Option<Vec<u8>>,
        Option<Vec<u8>>,
    ) = conn
        .prepare(
            "SELECT original_filename, file_data, compression, encryption_iv, encryption_tag \
             FROM documents WHERE doc_id = ?",
        )?
        .query_row(params![doc_id], |row| {
            Ok((
                db::get_string(row, "original_filename"),
                db::get_blob(row, "file_data"),
                db::get_string(row, "compression"),
                db::get_blob(row, "encryption_iv"),
                db::get_blob(row, "encryption_tag"),
            ))
        })
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                VaultError::new(format!("Document not found: id={doc_id}"))
            }
            other => VaultError::from(other),
        })?;

    let raw_blob = file_data.ok_or_else(|| VaultError::new("Document has no file data"))?;

    // Decrypt if the document was stored encrypted (insert order: compress → encrypt).
    let decompressable: Vec<u8> = if let (Some(iv), Some(tag)) = (enc_iv, enc_tag) {
        if password.is_empty() {
            return Err(VaultError::new(
                "Document is encrypted — a vault password is required to open it.",
            ));
        }
        let key = crypto::vault_key(path, password).map_err(|e| {
            VaultError::new(format!("Failed to derive vault key: {}", e.message))
        })?;
        crypto::decrypt_bytes(&key, &raw_blob, &iv, &tag).map_err(|_| {
            VaultError::new("Incorrect vault password — could not decrypt the document.")
        })?
    } else {
        raw_blob
    };

    let decompressed = if compression == "zstd" {
        zstd::decode_all(decompressable.as_slice())
            .map_err(|e| VaultError::new(format!("Decompression failed: {e}")))?
    } else {
        decompressable
    };

    Ok((original_filename, decompressed))
}

// ---------------------------------------------------------------------------
// extract_document
// ---------------------------------------------------------------------------

/// Extract a document from the vault to the filesystem.
///
/// Reads the file_data blob, decrypts if the document is encrypted (requires
/// `password`), decompresses zstd, and writes to `dest`.  If `dest` is a
/// directory the original filename is appended.
///
/// Ordering mirrors the Python reference implementation (and the inverse of
/// `insert_document`): stored blob = encrypt(compress(raw)), so extract does
/// **decrypt → decompress → write**.
///
/// * Plaintext doc + any password: works (password ignored).
/// * Encrypted doc + correct password: decrypts and extracts.
/// * Encrypted doc + empty password: returns a clear "password required" error.
/// * Encrypted doc + wrong password: returns a clear "incorrect password" error,
///   never panics (GCM tag mismatch is caught).
///
/// Returns the final output path on success.
pub fn extract_document(path: &str, doc_id: i64, dest: &str, password: &str) -> VaultResult<String> {
    let (original_filename, decompressed) = read_document_bytes(path, doc_id, password)?;

    let dest_path = Path::new(dest);
    let final_path = if dest_path.is_dir() {
        dest_path.join(&original_filename)
    } else {
        dest_path.to_path_buf()
    };
    if let Some(parent) = final_path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(&final_path, &decompressed)?;

    let conn = db::connect(path)?;
    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            format!("Extracted to {}", final_path.display()),
            doc_id,
        ],
    )?;

    Ok(final_path.to_string_lossy().to_string())
}

// ---------------------------------------------------------------------------
// set_document_encrypted — toggle a document's at-rest encryption in place
// ---------------------------------------------------------------------------

/// Toggle whether a document's stored blob is encrypted, in place.
///
/// The stored blob is always `compress(raw)`; an *encrypted* document
/// additionally has that compressed blob AES-256-GCM encrypted
/// (`encrypt(compress(raw))`) with `encryption_iv` / `encryption_tag` set.
/// Encryption state is identified by iv/tag presence — the same convention
/// `extract_document` and `query_documents` use.
///
/// * `encrypt == true` on a plaintext doc  → `encrypt(compress(raw))`, sets iv/tag.
/// * `encrypt == false` on an encrypted doc → decrypts back to `compress(raw)`,
///   clears iv/tag.
/// * Already in the requested state → no-op (`Ok`).
/// * A state change requires a non-empty `password`; a wrong password on
///   decrypt returns a clear error and never panics (GCM tag mismatch).
pub fn set_document_encrypted(
    path: &str,
    doc_id: i64,
    encrypt: bool,
    password: &str,
) -> VaultResult<()> {
    let conn = db::connect(path)?;

    let (file_data, enc_iv, enc_tag): (Option<Vec<u8>>, Option<Vec<u8>>, Option<Vec<u8>>) = conn
        .prepare(
            "SELECT file_data, encryption_iv, encryption_tag FROM documents WHERE doc_id = ?",
        )?
        .query_row(params![doc_id], |row| {
            Ok((
                db::get_blob(row, "file_data"),
                db::get_blob(row, "encryption_iv"),
                db::get_blob(row, "encryption_tag"),
            ))
        })
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => {
                VaultError::new(format!("Document not found: id={doc_id}"))
            }
            other => VaultError::from(other),
        })?;

    let blob = file_data.ok_or_else(|| VaultError::new("Document has no file data"))?;
    let currently_encrypted = enc_iv.is_some() && enc_tag.is_some();

    // Already in the requested state — nothing to do.
    if currently_encrypted == encrypt {
        return Ok(());
    }

    if password.is_empty() {
        return Err(VaultError::new(
            "A vault password is required to change a document's encryption.",
        ));
    }
    let key = crypto::vault_key(path, password).map_err(|e| {
        VaultError::new(format!("Failed to derive vault key: {}", e.message))
    })?;

    let (new_blob, new_iv, new_tag): (Vec<u8>, Option<Vec<u8>>, Option<Vec<u8>>) = if encrypt {
        // Plaintext → encrypted: encrypt the (already compressed) blob.
        let (ct, iv, tag) = crypto::encrypt_bytes(&key, &blob)?;
        (ct, Some(iv), Some(tag))
    } else {
        // Encrypted → plaintext: decrypt back to the compressed blob.
        let iv = enc_iv.unwrap();
        let tag = enc_tag.unwrap();
        let compressed = crypto::decrypt_bytes(&key, &blob, &iv, &tag).map_err(|_| {
            VaultError::new("Incorrect vault password — could not decrypt the document.")
        })?;
        (compressed, None, None)
    };

    conn.execute(
        "UPDATE documents SET file_data = ?1, encryption_iv = ?2, encryption_tag = ?3 \
         WHERE doc_id = ?4",
        params![new_blob, new_iv, new_tag, doc_id],
    )?;

    conn.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            if encrypt {
                "Document encrypted at rest"
            } else {
                "Document decrypted at rest"
            },
            doc_id,
        ],
    )?;

    Ok(())
}

// ---------------------------------------------------------------------------
// update_document
// ---------------------------------------------------------------------------

/// Update document fields by doc_id.
///
/// Allowed fields: status, category, display_name, description, tags, issuer, doc_date.
/// Tags should be provided as a JSON array value (e.g. `["tax", "2024"]`).
pub fn update_document(
    path: &str,
    doc_id: i64,
    updates: &HashMap<String, serde_json::Value>,
) -> VaultResult<()> {
    const ALLOWED: &[&str] = &[
        "status", "category", "display_name", "description", "tags", "issuer", "doc_date",
    ];

    let mut set_parts: Vec<String> = Vec::new();
    let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

    for key in ALLOWED {
        if let Some(val) = updates.get(*key) {
            set_parts.push(format!("{key} = ?"));
            if *key == "tags" {
                // Accept array → serialise to JSON string; accept string as-is
                match val {
                    serde_json::Value::Array(arr) => {
                        let strings: Vec<String> = arr
                            .iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect();
                        values.push(Box::new(db::to_json_array(&strings)));
                    }
                    serde_json::Value::String(s) => {
                        values.push(Box::new(s.clone()));
                    }
                    _ => {
                        values.push(Box::new(val.to_string()));
                    }
                }
            } else {
                // All other fields stored as text
                let text = match val {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                values.push(Box::new(text));
            }
        }
    }

    if set_parts.is_empty() {
        return Err(VaultError::new("No valid fields to update"));
    }

    let sql = format!(
        "UPDATE documents SET {} WHERE doc_id = ?",
        set_parts.join(", ")
    );
    values.push(Box::new(doc_id));

    let conn = db::connect(path)?;
    let params_refs: Vec<&dyn rusqlite::types::ToSql> =
        values.iter().map(|p| p.as_ref()).collect();

    let rows_changed = conn.execute(&sql, params_refs.as_slice())?;
    if rows_changed == 0 {
        return Err(VaultError::new(format!("Document not found: id={doc_id}")));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// replace_document_content — swap a document's stored bytes in place
// ---------------------------------------------------------------------------

/// Replace a document's stored content with a new file, in place.
///
/// Re-reads `file_path`, recompresses (zstd), re-encrypts when `password` is
/// non-empty, and recomputes the sha256 + simhash fingerprints via the same
/// `extract_file` pipeline used at classify/insert time. The documents row's
/// blob columns (file_data, file_size, compression, encryption_iv,
/// encryption_tag, sha256, simhash) and the fingerprints row are updated in a
/// single transaction — doc_id and every metadata field (category, issuer,
/// doc_date, description, tags, …) are deliberately left untouched.
pub fn replace_document_content(
    path: &str,
    doc_id: i64,
    file_path: &str,
    password: &str,
) -> VaultResult<()> {
    let fp = Path::new(file_path);
    if !fp.exists() {
        return Err(VaultError::new(format!("File not found: {file_path}")));
    }

    // Recompute fingerprints from the new content (same pipeline as insert).
    let extraction = extract::extract_file(file_path)?;

    // Read → compress → optionally encrypt via the shared blob pipeline.
    let raw_data = std::fs::read(fp)?;
    let original_size = raw_data.len() as i64;
    let (stored_data, enc_iv, enc_tag) = pack_blob_for_storage(path, &raw_data, password)?;

    let mut conn = db::connect(path)?;
    let tx = conn.transaction()?;

    // In-place blob swap. Metadata columns are deliberately not in this SET.
    let rows_changed = tx
        .execute(
            "UPDATE documents SET file_data = ?1, file_size = ?2, compression = 'zstd', \
             encryption_iv = ?3, encryption_tag = ?4, sha256 = ?5, simhash = ?6 \
             WHERE doc_id = ?7",
            params![
                stored_data,
                original_size,
                enc_iv,
                enc_tag,
                extraction.sha256,
                extraction.simhash,
                doc_id,
            ],
        )
        .map_err(|e| {
            let msg = e.to_string().to_lowercase();
            if msg.contains("unique") || msg.contains("sha256") {
                VaultError::new(format!(
                    "Cannot replace content: the new file is an exact duplicate of \
                     another document already in this vault (sha256 {})",
                    extraction.sha256
                ))
            } else {
                VaultError::from(e)
            }
        })?;
    if rows_changed == 0 {
        // tx drops here → rollback; the vault is left untouched.
        return Err(VaultError::new(format!("Document not found: id={doc_id}")));
    }

    // Refresh the fingerprints row. sha256 is its PRIMARY KEY, so the stale
    // row is keyed by the old hash — delete by doc_id, then re-insert.
    tx.execute("DELETE FROM fingerprints WHERE doc_id = ?1", params![doc_id])?;
    tx.execute(
        "INSERT OR REPLACE INTO fingerprints (sha256, simhash, dhash, doc_id) \
         VALUES (?1, ?2, ?3, ?4)",
        params![extraction.sha256, extraction.simhash, extraction.dhash, doc_id],
    )?;

    tx.execute(
        "INSERT INTO log (timestamp, level, component, message, doc_id) \
         VALUES (?1, 'info', 'vault', ?2, ?3)",
        params![
            now_iso(),
            format!("Document content replaced from {file_path}"),
            doc_id,
        ],
    )?;

    tx.commit()?;
    Ok(())
}

// ---------------------------------------------------------------------------
// delete_document — hard-delete a document and its fingerprint
// ---------------------------------------------------------------------------

/// Hard-delete a document: removes the `documents` row and its `fingerprints`
/// row in one transaction. `log` rows are intentionally kept as historical
/// audit (their `doc_id` is allowed to dangle).
///
/// Returns an error if `doc_id` does not exist — never a silent no-op.
pub fn delete_document(path: &str, doc_id: i64) -> VaultResult<()> {
    let mut conn = db::connect(path)?;

    // FK enforcement must be toggled outside the transaction (SQLite ignores
    // the pragma inside one). Mirrors reprocess.rs's whole-table delete: the
    // surviving log rows are allowed to reference a now-deleted doc_id.
    conn.pragma_update(None, "foreign_keys", "OFF")?;
    let doc_deleted = {
        let tx = conn.transaction()?;
        // Child row first, then the document.
        tx.execute("DELETE FROM fingerprints WHERE doc_id = ?1", params![doc_id])?;
        let doc_deleted =
            tx.execute("DELETE FROM documents WHERE doc_id = ?1", params![doc_id])?;
        if doc_deleted > 0 {
            tx.execute(
                "INSERT INTO log (timestamp, level, component, message, doc_id) \
                 VALUES (?1, 'info', 'vault', ?2, NULL)",
                params![now_iso(), format!("Deleted document id={doc_id}")],
            )?;
        }
        tx.commit()?;
        doc_deleted
    };
    conn.pragma_update(None, "foreign_keys", "ON")?;

    if doc_deleted == 0 {
        return Err(VaultError::new(format!("Document not found: id={doc_id}")));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// vault_inventory
// ---------------------------------------------------------------------------

/// List all documents with metadata (no file_data blob).
///
/// Returns every document's metadata fields for display/export purposes.
pub fn vault_inventory(path: &str) -> VaultResult<Vec<Document>> {
    let conn = db::connect(path)?;

    let mut stmt = conn.prepare(
        "SELECT doc_id, original_filename, file_ext, category, confidence, issuer, \
         description, doc_date, classified_at, sha256, simhash, dhash, \
         status, file_size, compression, encryption_iv, source_path, \
         display_name, tags, rule_snapshot \
         FROM documents ORDER BY doc_id",
    )?;

    let rows = stmt.query_map([], |row| {
        let tags_raw = db::get_string(row, "tags");
        let tags = db::parse_json_array(&tags_raw);
        let display_name_raw = db::get_string(row, "display_name");
        let original_filename = db::get_string(row, "original_filename");
        let display_name = if display_name_raw.is_empty() {
            original_filename.clone()
        } else {
            display_name_raw
        };
        let encrypted = db::get_blob(row, "encryption_iv").is_some();

        Ok(Document {
            doc_id: db::get_i64(row, "doc_id"),
            original_filename,
            display_name,
            file_ext: db::get_string(row, "file_ext"),
            category: db::get_string(row, "category"),
            confidence: db::get_f64(row, "confidence"),
            issuer: db::get_string(row, "issuer"),
            description: db::get_string(row, "description"),
            doc_date: db::get_string(row, "doc_date"),
            classified_at: db::get_string(row, "classified_at"),
            sha256: db::get_string(row, "sha256"),
            simhash: db::get_string(row, "simhash"),
            dhash: db::get_string(row, "dhash"),
            status: db::get_string(row, "status"),
            file_size: db::get_i64(row, "file_size"),
            compression: db::get_string(row, "compression"),
            encrypted,
            tags,
            source_path: db::get_string(row, "source_path"),
            rule_snapshot: db::get_string(row, "rule_snapshot"),
        })
    })?;

    let mut docs = Vec::new();
    for row_result in rows {
        docs.push(row_result?);
    }

    Ok(docs)
}

// ===========================================================================
// Tests (W5f) — encrypted-document round-trip via insert_document /
// extract_document.
// ===========================================================================
#[cfg(test)]
mod tests {
    use crate::crypto;
    use crate::documents::{
        delete_document, extract_document, get_document, insert_document,
        replace_document_content, set_document_encrypted, update_document,
    };
    use std::collections::HashMap;
    use crate::transfer;
    use crate::vault_lifecycle;
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
        std::env::temp_dir().join(format!("scansort-documents-{prefix}-{pid}-{ts}-{n}"))
    }

    /// Build a vault + a source file, returning (dir, vault_path, src_file).
    fn setup(prefix: &str, body: &[u8]) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        let dir = unique_tmp(prefix);
        std::fs::create_dir_all(&dir).unwrap();
        let vault_path = dir.join("archive.ssort");
        vault_lifecycle::create_vault(vault_path.to_str().unwrap(), "TestArchive")
            .expect("create vault");
        let src_file = dir.join("sample.txt");
        std::fs::write(&src_file, body).unwrap();
        (dir, vault_path, src_file)
    }

    fn insert(
        vault_path: &std::path::Path,
        src_file: &std::path::Path,
        password: &str,
    ) -> i64 {
        insert_document(
            vault_path.to_str().unwrap(),
            src_file.to_str().unwrap(),
            "test",
            0.9,
            "tester",
            "test doc",
            "2024-01-01",
            "classified",
            "",
            "0000000000000000",
            "0000000000000000",
            "",
            "",
            password,
            "",
        )
        .expect("insert_document")
    }

    // -----------------------------------------------------------------------
    // 1. Encrypted doc + correct password → round-trips, bytes match.
    // -----------------------------------------------------------------------
    #[test]
    fn encrypted_doc_correct_password_round_trips() {
        let body = b"top secret contents for the encrypted round trip test";
        let (dir, vault_path, src_file) = setup("enc-ok", body);
        let pw = "correct horse battery staple";

        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);
        assert!(doc_id > 0);

        let out = dir.join("extracted.txt");
        let out_path = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            pw,
        )
        .expect("extract_document with correct password");

        let got = std::fs::read(&out_path).expect("read extracted file");
        assert_eq!(got.as_slice(), body, "decrypted bytes must match original");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 2. Encrypted doc + wrong password → clear error, no panic.
    // -----------------------------------------------------------------------
    #[test]
    fn encrypted_doc_wrong_password_clear_error() {
        let body = b"contents guarded by a password";
        let (dir, vault_path, src_file) = setup("enc-wrong", body);
        let pw = "the real password";

        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);

        let out = dir.join("extracted.txt");
        let res = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            "the WRONG password",
        );
        assert!(res.is_err(), "wrong password must return Err, not panic");
        let msg = res.unwrap_err().message.to_lowercase();
        assert!(
            msg.contains("password") || msg.contains("decrypt"),
            "error should mention password/decrypt, got: {msg}"
        );
        assert!(!out.exists(), "no output file should be written on failure");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 3. Encrypted doc + empty password → "password required" error.
    // -----------------------------------------------------------------------
    #[test]
    fn encrypted_doc_empty_password_required_error() {
        let body = b"contents that need a password to read";
        let (dir, vault_path, src_file) = setup("enc-empty", body);
        let pw = "a vault password";

        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);

        let out = dir.join("extracted.txt");
        let res = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            "",
        );
        assert!(res.is_err(), "empty password on encrypted doc must return Err");
        let msg = res.unwrap_err().message.to_lowercase();
        assert!(
            msg.contains("password") && msg.contains("required"),
            "error should say a password is required, got: {msg}"
        );
        assert!(!out.exists(), "no output file should be written on failure");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 4. Plaintext doc still extracts (password ignored).
    // -----------------------------------------------------------------------
    #[test]
    fn plaintext_doc_still_extracts() {
        let body = b"ordinary unencrypted document body";
        let (dir, vault_path, src_file) = setup("plain", body);

        // No set_password, no password passed to insert → stored compressed-only.
        let doc_id = insert(&vault_path, &src_file, "");
        assert!(doc_id > 0);

        // Extract with empty password works.
        let out = dir.join("extracted-empty.txt");
        let out_path = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out.to_str().unwrap(),
            "",
        )
        .expect("extract plaintext doc with empty password");
        assert_eq!(
            std::fs::read(&out_path).unwrap().as_slice(),
            body,
            "plaintext extract must match original"
        );

        // Extract with a non-empty password also works (password ignored).
        let out2 = dir.join("extracted-pw.txt");
        let out_path2 = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            out2.to_str().unwrap(),
            "irrelevant password",
        )
        .expect("extract plaintext doc with a password (ignored)");
        assert_eq!(
            std::fs::read(&out_path2).unwrap().as_slice(),
            body,
            "plaintext extract must match original even when a password is supplied"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // 5. W5h: set_document_encrypted toggles encryption in place, round-trips.
    // -----------------------------------------------------------------------
    #[test]
    fn set_document_encrypted_round_trips_plaintext_to_encrypted_and_back() {
        let body = b"a document that starts plaintext and gets encrypted in place";
        let (dir, vault_path, src_file) = setup("setenc-rt", body);
        let pw = "vault password for in-place encryption";
        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");

        // Insert as PLAINTEXT (no password to insert).
        let doc_id = insert(&vault_path, &src_file, "");

        // Encrypt in place.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, true, pw)
            .expect("encrypt in place");
        // Now it must require the password to extract...
        let no_pw = extract_document(
            vault_path.to_str().unwrap(),
            doc_id,
            dir.join("x1.txt").to_str().unwrap(),
            "",
        );
        assert!(no_pw.is_err(), "encrypted doc must need a password");
        // ...and decrypt correctly with it.
        let out = dir.join("enc-extract.txt");
        extract_document(vault_path.to_str().unwrap(), doc_id, out.to_str().unwrap(), pw)
            .expect("extract after in-place encrypt");
        assert_eq!(std::fs::read(&out).unwrap().as_slice(), body);

        // Decrypt in place — now it extracts with an empty password again.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, false, pw)
            .expect("decrypt in place");
        let out2 = dir.join("dec-extract.txt");
        extract_document(vault_path.to_str().unwrap(), doc_id, out2.to_str().unwrap(), "")
            .expect("extract after in-place decrypt");
        assert_eq!(std::fs::read(&out2).unwrap().as_slice(), body);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn set_document_encrypted_is_idempotent_and_guards_password() {
        let body = b"idempotency + password-guard checks";
        let (dir, vault_path, src_file) = setup("setenc-guard", body);
        let pw = "the vault password";
        crypto::set_password(vault_path.to_str().unwrap(), pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, "");

        // Already plaintext → encrypt:false is a no-op, even with empty password.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, false, "")
            .expect("no-op when already in the requested state");

        // Plaintext → encrypt:true with EMPTY password → clear error.
        let err = set_document_encrypted(vault_path.to_str().unwrap(), doc_id, true, "")
            .expect_err("a state change needs a password");
        assert!(err.message.to_lowercase().contains("password"));

        // Encrypt for real, then decrypt with the WRONG password → clear error, no panic.
        set_document_encrypted(vault_path.to_str().unwrap(), doc_id, true, pw)
            .expect("encrypt");
        let werr = set_document_encrypted(vault_path.to_str().unwrap(), doc_id, false, "wrong pw")
            .expect_err("wrong password must error");
        assert!(
            werr.message.to_lowercase().contains("password")
                || werr.message.to_lowercase().contains("decrypt"),
            "got: {}",
            werr.message
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // T3a — update_document accepts the widened issuer / doc_date fields.
    // -----------------------------------------------------------------------
    #[test]
    fn update_document_widens_to_issuer_and_doc_date() {
        let (dir, vault_path, src_file) = setup("update-widen", b"misclassified issuer doc");
        let vp = vault_path.to_str().unwrap();
        let doc_id = insert(&vault_path, &src_file, "");

        let mut updates: HashMap<String, serde_json::Value> = HashMap::new();
        updates.insert("issuer".into(), serde_json::json!("Corrected Issuer LLC"));
        updates.insert("doc_date".into(), serde_json::json!("2025-12-31"));
        update_document(vp, doc_id, &updates).expect("update issuer + doc_date");

        let doc = get_document(vp, doc_id).expect("get");
        assert_eq!(doc.issuer, "Corrected Issuer LLC");
        assert_eq!(doc.doc_date, "2025-12-31");

        // Error path: a non-whitelisted field alone yields no valid updates.
        let mut bad: HashMap<String, serde_json::Value> = HashMap::new();
        bad.insert("sha256".into(), serde_json::json!("deadbeef"));
        assert!(
            update_document(vp, doc_id, &bad).is_err(),
            "a non-whitelisted field must not be accepted"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // T3b — replace_document_content swaps the bytes + fingerprint in place,
    // preserving doc_id; a missing source file errors.
    // -----------------------------------------------------------------------
    #[test]
    fn replace_document_content_swaps_bytes_and_fingerprint() {
        let (dir, vault_path, src_file) = setup("replace-content", b"the original contents");
        let vp = vault_path.to_str().unwrap();
        let doc_id = insert(&vault_path, &src_file, "");
        let before = get_document(vp, doc_id).expect("get before");

        let new_file = dir.join("corrected.txt");
        let new_body = b"the corrected contents that should now be stored instead";
        std::fs::write(&new_file, new_body).unwrap();
        replace_document_content(vp, doc_id, new_file.to_str().unwrap(), "")
            .expect("replace content");

        let after = get_document(vp, doc_id).expect("get after");
        assert_ne!(before.sha256, after.sha256, "sha256 must change with content");
        assert_eq!(after.doc_id, before.doc_id, "doc_id is preserved");

        let out = dir.join("extracted.txt");
        let out_path = extract_document(vp, doc_id, out.to_str().unwrap(), "")
            .expect("extract replaced");
        let got = std::fs::read(&out_path).expect("read extracted");
        assert_eq!(got.as_slice(), new_body, "extracted bytes must be the new content");

        // Error path: a missing source file.
        assert!(
            replace_document_content(vp, doc_id, "/nonexistent-scansort/missing.txt", "").is_err(),
            "replacing from a non-existent file must error"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // T3b — replace_document_content keeps an encrypted document encrypted and
    // the new bytes decrypt with the vault password.
    // -----------------------------------------------------------------------
    #[test]
    fn replace_document_content_encrypted_round_trips() {
        let (dir, vault_path, src_file) = setup("replace-enc", b"plain original");
        let vp = vault_path.to_str().unwrap();
        let pw = "correct horse battery staple";
        crypto::set_password(vp, pw).expect("set_password");
        let doc_id = insert(&vault_path, &src_file, pw);

        let new_file = dir.join("new-secret.txt");
        let new_body = b"the new secret contents stored encrypted at rest";
        std::fs::write(&new_file, new_body).unwrap();
        replace_document_content(vp, doc_id, new_file.to_str().unwrap(), pw)
            .expect("replace encrypted");

        let doc = get_document(vp, doc_id).expect("get");
        assert!(doc.encrypted, "document must remain encrypted after replace");

        let out = dir.join("ex.txt");
        let out_path = extract_document(vp, doc_id, out.to_str().unwrap(), pw)
            .expect("extract with password");
        assert_eq!(std::fs::read(&out_path).unwrap().as_slice(), new_body);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // T1 — delete_document hard-deletes the documents row + fingerprints row;
    // a missing doc_id errors.
    // -----------------------------------------------------------------------
    #[test]
    fn delete_document_hard_deletes_doc_and_fingerprint() {
        let (dir, vault_path, src_file) = setup("delete-doc", b"a misfiled document to remove");
        let vp = vault_path.to_str().unwrap();
        let doc_id = insert(&vault_path, &src_file, "");
        assert!(get_document(vp, doc_id).is_ok(), "sanity: document exists");

        delete_document(vp, doc_id).expect("delete");

        // The documents row is gone.
        assert!(get_document(vp, doc_id).is_err(), "deleted doc must not be found");
        // The fingerprints row is gone too.
        let conn = crate::db::connect(vp).unwrap();
        let fp_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM fingerprints WHERE doc_id = ?",
                [doc_id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(fp_count, 0, "fingerprints row must be deleted");

        // Error path: deleting a non-existent doc_id.
        assert!(
            delete_document(vp, 999_999).is_err(),
            "deleting a missing doc_id must error"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // T2 — move_document_to_vault covers clear→clear and clear→enc.
    // -----------------------------------------------------------------------
    #[test]
    fn move_document_clear_source_to_clear_and_encrypted_destinations() {
        let body1 = b"docs that move from a plaintext source vault";
        let (src_dir, src_vault, src_file) = setup("move-clr-src", body1);
        let svp = src_vault.to_str().unwrap();
        let doc_id1 = insert(&src_vault, &src_file, "");

        // Build a plaintext destination vault.
        let dst_dir1 = unique_tmp("move-clr-dst1");
        std::fs::create_dir_all(&dst_dir1).unwrap();
        let dst_vault1 = dst_dir1.join("dst_plain.ssort");
        vault_lifecycle::create_vault(dst_vault1.to_str().unwrap(), "DstPlain").unwrap();
        let dvp1 = dst_vault1.to_str().unwrap();

        // clear → clear.
        let new_id1 = transfer::move_document_to_vault(svp, doc_id1, dvp1, "", "", false)
            .expect("clear→clear move");
        assert!(get_document(svp, doc_id1).is_err(), "src must no longer have the doc");
        let dst_doc1 = get_document(dvp1, new_id1).expect("dst has the doc");
        assert!(!dst_doc1.encrypted, "dst doc must be plaintext");
        let out1 = src_dir.join("ex1.txt");
        let p1 = extract_document(dvp1, new_id1, out1.to_str().unwrap(), "").unwrap();
        assert_eq!(std::fs::read(&p1).unwrap().as_slice(), body1);

        // Now move a second doc from src into an encrypted dst (clear → enc).
        let body2 = b"the second document, destined for an encrypted dst";
        let src_file2 = src_dir.join("second.txt");
        std::fs::write(&src_file2, body2).unwrap();
        let doc_id2 = insert(&src_vault, &src_file2, "");

        let dst_dir2 = unique_tmp("move-clr-dst2");
        std::fs::create_dir_all(&dst_dir2).unwrap();
        let dst_vault2 = dst_dir2.join("dst_enc.ssort");
        vault_lifecycle::create_vault(dst_vault2.to_str().unwrap(), "DstEnc").unwrap();
        let dvp2 = dst_vault2.to_str().unwrap();
        crypto::set_password(dvp2, "destination-secret").unwrap();

        let new_id2 =
            transfer::move_document_to_vault(svp, doc_id2, dvp2, "", "destination-secret", false)
                .expect("clear→enc move");
        let dst_doc2 = get_document(dvp2, new_id2).expect("dst has the new doc");
        assert!(dst_doc2.encrypted, "doc must be encrypted in dst");
        let out2 = src_dir.join("ex2.txt");
        let p2 =
            extract_document(dvp2, new_id2, out2.to_str().unwrap(), "destination-secret").unwrap();
        assert_eq!(std::fs::read(&p2).unwrap().as_slice(), body2);

        let _ = std::fs::remove_dir_all(&src_dir);
        let _ = std::fs::remove_dir_all(&dst_dir1);
        let _ = std::fs::remove_dir_all(&dst_dir2);
    }

    // -----------------------------------------------------------------------
    // T2 — move_document_to_vault between encrypted vaults, same and
    // different passwords.
    // -----------------------------------------------------------------------
    #[test]
    fn move_document_encrypted_to_encrypted_same_and_different_passwords() {
        let body1 = b"an encrypted document that survives a same-password move";
        let (src_dir, src_vault, src_file) = setup("move-enc-src", body1);
        let svp = src_vault.to_str().unwrap();
        let pw_src = "src-vault-pw";
        crypto::set_password(svp, pw_src).unwrap();
        let doc_id1 = insert(&src_vault, &src_file, pw_src);

        // enc → enc same password.
        let dst_dir1 = unique_tmp("move-enc-same");
        std::fs::create_dir_all(&dst_dir1).unwrap();
        let dst_vault1 = dst_dir1.join("dst_same.ssort");
        vault_lifecycle::create_vault(dst_vault1.to_str().unwrap(), "DstSame").unwrap();
        let dvp1 = dst_vault1.to_str().unwrap();
        crypto::set_password(dvp1, pw_src).unwrap();

        let new_id1 = transfer::move_document_to_vault(svp, doc_id1, dvp1, pw_src, pw_src, false)
            .expect("enc→enc same pw");
        let dst_doc1 = get_document(dvp1, new_id1).unwrap();
        assert!(dst_doc1.encrypted);
        let out1 = src_dir.join("ex_same.txt");
        let p1 = extract_document(dvp1, new_id1, out1.to_str().unwrap(), pw_src).unwrap();
        assert_eq!(std::fs::read(&p1).unwrap().as_slice(), body1);

        // A second doc, moved to a DIFFERENT-password dst.
        let body2 = b"a second encrypted document for the different-password leg";
        let src_file2 = src_dir.join("two.txt");
        std::fs::write(&src_file2, body2).unwrap();
        let doc_id2 = insert(&src_vault, &src_file2, pw_src);

        let dst_dir2 = unique_tmp("move-enc-diff");
        std::fs::create_dir_all(&dst_dir2).unwrap();
        let dst_vault2 = dst_dir2.join("dst_diff.ssort");
        vault_lifecycle::create_vault(dst_vault2.to_str().unwrap(), "DstDiff").unwrap();
        let dvp2 = dst_vault2.to_str().unwrap();
        let pw_dst = "different-destination-pw";
        crypto::set_password(dvp2, pw_dst).unwrap();

        let new_id2 = transfer::move_document_to_vault(svp, doc_id2, dvp2, pw_src, pw_dst, false)
            .expect("enc→enc different pw");
        let p2 = extract_document(
            dvp2,
            new_id2,
            src_dir.join("ex_diff.txt").to_str().unwrap(),
            pw_dst,
        )
        .unwrap();
        assert_eq!(std::fs::read(&p2).unwrap().as_slice(), body2);

        let _ = std::fs::remove_dir_all(&src_dir);
        let _ = std::fs::remove_dir_all(&dst_dir1);
        let _ = std::fs::remove_dir_all(&dst_dir2);
    }

    // -----------------------------------------------------------------------
    // T2 — encryption-downgrade gate: refused without the explicit flag,
    // allowed (and the source is consumed) with it.
    // -----------------------------------------------------------------------
    #[test]
    fn move_document_encrypted_to_clear_downgrade_gate() {
        let body = b"a secret that we may or may not be allowed to downgrade";
        let (src_dir, src_vault, src_file) = setup("move-downgrade", body);
        let svp = src_vault.to_str().unwrap();
        let pw = "secret-vault-pw";
        crypto::set_password(svp, pw).unwrap();
        let doc_id = insert(&src_vault, &src_file, pw);

        let dst_dir = unique_tmp("move-downgrade-dst");
        std::fs::create_dir_all(&dst_dir).unwrap();
        let dst_vault = dst_dir.join("dst_plain.ssort");
        vault_lifecycle::create_vault(dst_vault.to_str().unwrap(), "DstPlain").unwrap();
        let dvp = dst_vault.to_str().unwrap();

        // Without the downgrade flag → refused; src untouched.
        let err = transfer::move_document_to_vault(svp, doc_id, dvp, pw, "", false)
            .expect_err("downgrade must be refused without the explicit flag");
        assert!(
            err.message.to_lowercase().contains("downgrade"),
            "expected a downgrade refusal, got: {}",
            err.message
        );
        assert!(
            get_document(svp, doc_id).is_ok(),
            "src doc must be untouched after a refused move"
        );

        // With the flag set → allowed; dst doc is plaintext, src deleted.
        let new_id = transfer::move_document_to_vault(svp, doc_id, dvp, pw, "", true)
            .expect("downgrade with explicit flag must succeed");
        let dst_doc = get_document(dvp, new_id).unwrap();
        assert!(!dst_doc.encrypted, "downgraded dst doc must be plaintext");
        assert!(
            get_document(svp, doc_id).is_err(),
            "src doc must be deleted after a verified move"
        );

        let _ = std::fs::remove_dir_all(&src_dir);
        let _ = std::fs::remove_dir_all(&dst_dir);
    }
}
