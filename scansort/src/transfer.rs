//! Cross-vault document transfer.
//!
//! `move_document_to_vault` copies a document from one .ssort vault to
//! another, decrypting and re-encrypting in memory (no cleartext-on-disk
//! pivot), verifying the round-trip, and only then deleting the source row.

use crate::documents;
use crate::types::{VaultError, VaultResult};

/// Move a document from `src_vault` to `dst_vault`.
///
/// Steps: (1) read the source's metadata + bytes in memory; (2) refuse if
/// the source is encrypted and the destination would be plaintext unless
/// `allow_encryption_downgrade` is true; (3) insert into the destination
/// (re-encrypting under `dst_password` when given) via
/// `insert_document_with_metadata`; (4) verify the destination's sha256
/// matches the source's; (5) only on a verified insert, hard-delete the
/// source via `delete_document`. Returns the destination's new `doc_id`.
///
/// Atomicity note: each side of the transfer is its own vault (separate
/// SQLite DBs), so the operation is "verify-then-delete" rather than
/// cross-vault atomic. A failure between a verified insert and the source
/// delete leaves the document in both vaults (no data loss); the agent can
/// retry `delete_document(src_vault, doc_id)` to converge.
pub fn move_document_to_vault(
    src_vault: &str,
    doc_id: i64,
    dst_vault: &str,
    src_password: &str,
    dst_password: &str,
    allow_encryption_downgrade: bool,
) -> VaultResult<i64> {
    // 1. Read source metadata.
    let src_doc = documents::get_document(src_vault, doc_id)?;

    // 2. Encryption-downgrade gate — explicit refusal, never silent.
    if src_doc.encrypted && dst_password.is_empty() && !allow_encryption_downgrade {
        return Err(VaultError::new(
            "Refusing to move an encrypted document into a plaintext destination \
             (encryption-at-rest downgrade). Pass allow_encryption_downgrade=true \
             to confirm a deliberate downgrade.",
        ));
    }

    // 3. Read source bytes in memory — decrypt + decompress; no disk pivot.
    let (_orig_filename, raw_bytes) =
        documents::read_document_bytes(src_vault, doc_id, src_password)?;

    // 4. Insert into destination, packing through the shared pipeline. A
    //    UNIQUE-sha256 collision in the destination surfaces here, before
    //    the source has been touched.
    let new_doc_id =
        documents::insert_document_with_metadata(dst_vault, &src_doc, &raw_bytes, dst_password)?;

    // 5. Verify the round-trip — the destination's sha256 must match the
    //    source's. They are computed over the SAME raw bytes, so a mismatch
    //    means something went wrong on the write side.
    let dst_doc = documents::get_document(dst_vault, new_doc_id)?;
    if dst_doc.sha256 != src_doc.sha256 {
        // Roll back the destination insert; surface the verification failure.
        let _ = documents::delete_document(dst_vault, new_doc_id);
        return Err(VaultError::new(format!(
            "Move verification failed: destination sha256 ({}) does not match source ({})",
            dst_doc.sha256, src_doc.sha256
        )));
    }

    // 6. Verified — hard-delete from source (T1's delete_document).
    documents::delete_document(src_vault, doc_id)?;
    Ok(new_doc_id)
}
