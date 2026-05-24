//! C1 — DCR `019e564809a9` Option C: batch model for the redesigned
//! process pipeline.
//!
//! A **batch** is the user-facing unit of work: "I clicked Start" or "I
//! asked the agent to process these 7 files." A batch has a frozen
//! scope enumerated at plan time, and accumulates per-file disposition
//! as `process_run` iterations execute against it.
//!
//! See the C0 plan card (`019e581318cb`) for the cycle context and
//! bug `019e5802d5d8` for the failure mode this replaces.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// ProcessPlan — immutable for the life of the batch.
// ---------------------------------------------------------------------------

/// Scope of work the batch was created against. Distinguishes the 3
/// user-facing scenarios.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ProcessScope {
    /// Scenario 1: every file under every currently-open source.
    AllSources,
    /// Scenario 2: files in open sources whose SHA-256 is NOT already in
    /// the named vault. Vault-aware dedup applied at plan time.
    UnprocessedOnly { vault: String },
    /// Scenario 3: an explicit list of absolute file paths. Bypasses the
    /// open-source walk; useful for "process this one doc" agent UX.
    ExplicitFiles { paths: Vec<String> },
}

/// One file enumerated at plan time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlannedFile {
    pub source_label: String,
    pub abs_path: String,
    pub rel_path: String,
    pub size: u64,
    pub extension: String,
    /// SHA-256 fingerprint lookup against the vault at plan time. Used
    /// by UnprocessedOnly to compute `eligible`; True ⇒ file would
    /// trigger the dedup-skip path during execution.
    pub already_in_vault: bool,
}

/// Immutable enumeration of work to do. Created by `process_plan` and
/// referenced by every subsequent `process_run` / `process_status` /
/// `process_cancel` call via `batch_id`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessPlan {
    pub batch_id: String,
    pub created_at: String,
    pub scope: ProcessScope,
    pub files: Vec<PlannedFile>,
    /// Convenience: `files.len()`. Surfaced so callers don't have to peek
    /// into `files[]` just to render "Filing N of M".
    pub total: usize,
    /// Per-extension count: `{".pdf": 7, ".docx": 2}`. Lowercase, with
    /// leading dot. Files with no extension contribute to key `""`.
    pub type_breakdown: BTreeMap<String, usize>,
    /// Count of files where `already_in_vault == true` at plan time.
    /// `process_run` will report these as `skipped` unless the panel
    /// overrides dedup.
    pub already_in_vault: usize,
    /// `total - already_in_vault` — the count an agent should expect
    /// `process_run` to actually place.
    pub eligible: usize,
}

impl ProcessPlan {
    /// Build the type breakdown from a `files` slice. Single source of
    /// truth so callers don't roll their own histogram.
    pub fn compute_type_breakdown(files: &[PlannedFile]) -> BTreeMap<String, usize> {
        let mut bd: BTreeMap<String, usize> = BTreeMap::new();
        for f in files {
            *bd.entry(f.extension.clone()).or_insert(0) += 1;
        }
        bd
    }
}

// ---------------------------------------------------------------------------
// ProcessBatch — mutable run-state.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BatchState {
    /// Plan created; no `process_run` calls yet.
    Pending,
    /// At least one `process_run` has started; not finished yet.
    Running,
    /// All eligible files have been attempted (or skipped).
    Completed,
    /// `process_cancel` requested AND honoured at an inter-file gate.
    Cancelled,
    /// A run-fatal error fired (rare; per-file errors live in `errors[]`).
    Errored,
}

impl BatchState {
    pub fn as_str(self) -> &'static str {
        match self {
            BatchState::Pending   => "pending",
            BatchState::Running   => "running",
            BatchState::Completed => "completed",
            BatchState::Cancelled => "cancelled",
            BatchState::Errored   => "errored",
        }
    }
}

/// Per-file error recorded during a run. `rel_path` matches the
/// corresponding `PlannedFile.rel_path`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BatchError {
    pub rel_path: String,
    pub message: String,
}

/// Mutable progress envelope around a `ProcessPlan`. Lives in the
/// per-process singleton (see [`crate::process::controller`]).
#[derive(Debug, Clone)]
pub struct ProcessBatch {
    pub plan: ProcessPlan,
    pub state: BatchState,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    /// Index INTO `plan.files` of the file currently being processed
    /// (None when no run is mid-flight on this batch — i.e. Pending /
    /// between iterations / terminal).
    pub current_index: Option<usize>,
    pub placed: usize,
    pub skipped: usize,
    pub errored: usize,
    pub errors: Vec<BatchError>,
    /// G12: when true, the next inter-file gate in process_run will bail
    /// and set state=Cancelled. Cleared by [`crate::process::controller`]
    /// at the start of every NEW batch (`set_current_batch`).
    pub cancel_requested: bool,
}

impl ProcessBatch {
    pub fn new(plan: ProcessPlan) -> Self {
        ProcessBatch {
            plan,
            state: BatchState::Pending,
            started_at: None,
            finished_at: None,
            current_index: None,
            placed: 0,
            skipped: 0,
            errored: 0,
            errors: Vec::new(),
            cancel_requested: false,
        }
    }

    /// Files-done-so-far in this batch (across all process_run iterations).
    pub fn files_done(&self) -> usize {
        self.placed + self.skipped + self.errored
    }

    /// True when every planned file has been attempted. Used by
    /// `process_run` to decide when to flip state to Completed.
    pub fn is_drained(&self) -> bool {
        self.files_done() >= self.plan.total
    }

    /// Build the wire-JSON snapshot used by `process_status`. Single
    /// source of truth so the handler-side projection doesn't drift.
    pub fn to_status_json(&self) -> Value {
        let current_file = self.current_index
            .and_then(|i| self.plan.files.get(i))
            .map(|f| json!({
                "source_label": f.source_label,
                "rel_path":     f.rel_path,
                "extension":    f.extension,
                "size":         f.size,
            }));
        json!({
            "batch_id":  self.plan.batch_id,
            "state":     self.state.as_str(),
            "scope":     self.plan.scope,
            "plan": {
                "total":             self.plan.total,
                "type_breakdown":    self.plan.type_breakdown,
                "already_in_vault":  self.plan.already_in_vault,
                "eligible":          self.plan.eligible,
                "created_at":        self.plan.created_at,
            },
            "progress": {
                "current_file":         current_file,
                "current_index":        self.current_index,
                "files_done_in_batch":  self.files_done(),
            },
            "totals": {
                "placed":  self.placed,
                "skipped": self.skipped,
                "errored": self.errored,
                "total":   self.files_done(),
            },
            "errors":          self.errors,
            "started_at":      self.started_at,
            "finished_at":     self.finished_at,
            "cancel_requested": self.cancel_requested,
        })
    }
}

// ---------------------------------------------------------------------------
// Tests — JSON round-trip + helpers.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_file(rel: &str, ext: &str) -> PlannedFile {
        PlannedFile {
            source_label: "Inbox".into(),
            abs_path: format!("/src/{rel}"),
            rel_path: rel.into(),
            size: 100,
            extension: ext.into(),
            already_in_vault: false,
        }
    }

    #[test]
    fn type_breakdown_groups_by_extension() {
        let files = vec![
            sample_file("a.pdf",  ".pdf"),
            sample_file("b.pdf",  ".pdf"),
            sample_file("c.docx", ".docx"),
        ];
        let bd = ProcessPlan::compute_type_breakdown(&files);
        assert_eq!(bd.get(".pdf"),  Some(&2));
        assert_eq!(bd.get(".docx"), Some(&1));
        assert_eq!(bd.len(), 2);
    }

    #[test]
    fn scope_serialises_with_tag_discriminator() {
        let s = serde_json::to_value(ProcessScope::AllSources).unwrap();
        assert_eq!(s, json!({"kind": "all_sources"}));
        let u = serde_json::to_value(ProcessScope::UnprocessedOnly {
            vault: "test-4".into(),
        }).unwrap();
        assert_eq!(u, json!({"kind": "unprocessed_only", "vault": "test-4"}));
        let e = serde_json::to_value(ProcessScope::ExplicitFiles {
            paths: vec!["/a.pdf".into()],
        }).unwrap();
        assert_eq!(e, json!({"kind": "explicit_files", "paths": ["/a.pdf"]}));
    }

    #[test]
    fn plan_round_trips_via_json() {
        let plan = ProcessPlan {
            batch_id: "batch-1".into(),
            created_at: "2026-05-24T00:00:00Z".into(),
            scope: ProcessScope::AllSources,
            files: vec![sample_file("a.pdf", ".pdf")],
            total: 1,
            type_breakdown: ProcessPlan::compute_type_breakdown(&[sample_file("a.pdf", ".pdf")]),
            already_in_vault: 0,
            eligible: 1,
        };
        let v = serde_json::to_value(&plan).unwrap();
        let back: ProcessPlan = serde_json::from_value(v).unwrap();
        assert_eq!(back.batch_id, "batch-1");
        assert_eq!(back.files.len(), 1);
        assert_eq!(back.scope, ProcessScope::AllSources);
    }

    #[test]
    fn batch_files_done_matches_sum_of_totals() {
        let plan = ProcessPlan {
            batch_id: "b".into(),
            created_at: "t".into(),
            scope: ProcessScope::AllSources,
            files: vec![],
            total: 5,
            type_breakdown: BTreeMap::new(),
            already_in_vault: 0,
            eligible: 5,
        };
        let mut b = ProcessBatch::new(plan);
        b.placed = 3;
        b.skipped = 1;
        b.errored = 1;
        assert_eq!(b.files_done(), 5);
        assert!(b.is_drained());
    }

    #[test]
    fn batch_to_status_json_carries_all_fields() {
        let plan = ProcessPlan {
            batch_id: "batch-x".into(),
            created_at: "t".into(),
            scope: ProcessScope::ExplicitFiles { paths: vec!["/a.pdf".into()] },
            files: vec![sample_file("a.pdf", ".pdf")],
            total: 1,
            type_breakdown: ProcessPlan::compute_type_breakdown(&[sample_file("a.pdf", ".pdf")]),
            already_in_vault: 0,
            eligible: 1,
        };
        let mut b = ProcessBatch::new(plan);
        b.state = BatchState::Running;
        b.current_index = Some(0);
        let snap = b.to_status_json();
        assert_eq!(snap["batch_id"], "batch-x");
        assert_eq!(snap["state"],    "running");
        assert_eq!(snap["progress"]["current_index"], 0);
        assert_eq!(snap["progress"]["current_file"]["rel_path"], "a.pdf");
        assert_eq!(snap["plan"]["total"], 1);
        assert_eq!(snap["totals"]["total"], 0);
        assert!(snap["scope"]["kind"].is_string());
    }
}
