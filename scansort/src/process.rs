//! B3 — Path-free process() pipeline.
//!
//! The `run()` function is the single entry point.  It reads all state from
//! the in-process session (open sources, open destinations) and the global
//! library (enabled rules), then iterates every file under every open source,
//! classifying and filing each one.
//!
//! ## Destination resolution
//!
//! Rules store destination **labels** in `copy_to` (new convention).  The
//! session holds `(label, path, kind)` for every open vault and directory.
//! `resolve_labels()` maps each label to a synthetic `Destination` whose `id`
//! equals its `label` — this lets us call `placement::fan_out` (which expects
//! registry IDs) without modifying it.
//!
//! ## Capability injection (classify step)
//!
//! `run()` receives mutable references to the I/O streams and a request-ID
//! counter so it can issue `host.providers.chat` capability requests exactly
//! as `handle_classify_document` does.
//!
//! ## Testing strategy (option a — piece-wise)
//!
//! Integration of the full pipeline (LLM call) is exercised in HITL.  Unit
//! tests here cover:
//!   - `resolve_labels` label-lookup logic
//!   - `apply_rule_engine` filtering (enabled vs disabled rules)
//!   - Catch-all outcomes (no rule match, no open destination)
//!   - `should_skip` delegation to source_state
//!
//! These tests construct Session + Library state in-process using the same
//! helpers used by real handlers, but do NOT exercise the LLM capability path.

use crate::audit;
use crate::classifier;
use crate::destinations::{Destination, DestinationRegistry};
use crate::doc_type_normalizer;
use crate::extract;
use crate::library;
use crate::placement::{self, DirHashCache, DocMeta, PlacementResult, PlacementStatus};
use crate::render;
use crate::rule_engine::{self, FileFacts};
use crate::rules_file::FileRule;
use crate::session;
use crate::source_state;
use crate::stage_walker::LlmCaller;
use crate::types::{Classification, Rule, VaultError, VaultResult};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io;
use std::path::Path;

// Vision-mode auto-fallback tuning. A doc is "image-only" when extracted text
// is essentially empty OR every page reported by the extractor is image-only.
// Threshold is intentionally conservative — a real text PDF will trivially
// exceed it after pdftotext, while OCR-less scans return <10 chars.
const VISION_FALLBACK_TEXT_THRESHOLD: usize = 50;
const VISION_MAX_PAGES: i32 = 3;
// 100 DPI letter-page renders to ~600 KB base64 (1100x850 PNG) — well inside
// what qwen2.5vl:7b accepts in a single call. Going higher costs latency
// without classification gains since vision models tile-tokenize at fixed
// resolution.
const VISION_DPI: i32 = 100;

/// Returns `true` when the extraction result indicates the document has no
/// usable text and should be handled via the multimodal/vision path.
///
/// Generalized — does NOT key off a particular file path or fixture. Two
/// independent signals: (1) trimmed full_text is below the threshold, OR
/// (2) extractor reports every counted page as image-only. Either suffices.
fn is_image_only(extracted: &crate::types::ExtractionResult) -> bool {
    if extracted.full_text.trim().chars().count() < VISION_FALLBACK_TEXT_THRESHOLD {
        return true;
    }
    let pc = extracted.page_count;
    if pc > 0 && extracted.image_only_pages.len() == pc as usize {
        return true;
    }
    false
}

/// W2-vision runtime entry: like `apply_rule_engine_with_llm` but threads
/// optional page-image content through to `rule_engine::run_with_stages_vision`.
pub fn apply_rule_engine_with_llm_vision(
    classification: &Classification,
    file_facts: &FileFacts,
    rules: &[FileRule],
    document_text: &str,
    page_images: Option<&[Value]>,
    llm: &mut dyn LlmCaller,
) -> rule_engine::RuleWalkOutcome {
    let rule_objs: Vec<Rule> = rules.iter().map(|r| r.clone().into_rule()).collect();
    rule_engine::run_with_stages_vision(
        classification,
        file_facts,
        &rule_objs,
        document_text,
        page_images,
        llm,
    )
}

// ---------------------------------------------------------------------------
// Public output types
// ---------------------------------------------------------------------------

/// Per-file outcome recorded in the process() result.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProcessItem {
    pub source_label: String,
    pub source_path_relative: String,
    pub status: String,
    pub rule_label: Option<String>,
    pub target_labels: Vec<String>,
    pub reason: Option<String>,
}

/// Aggregate result returned from `run()`.
#[derive(Debug, Default)]
pub struct ProcessResult {
    pub moved: u64,
    pub conflicts: u64,
    pub unprocessable: u64,
    pub skipped_already_processed: u64,
    pub by_rule: HashMap<String, u64>,
    pub by_destination: HashMap<String, u64>,
    pub items: Vec<ProcessItem>,
}

impl ProcessResult {
    fn bump_rule(&mut self, label: &str) {
        *self.by_rule.entry(label.to_string()).or_insert(0) += 1;
    }
    fn bump_dest(&mut self, label: &str) {
        *self.by_destination.entry(label.to_string()).or_insert(0) += 1;
    }
}

// ---------------------------------------------------------------------------
// Destination resolution
// ---------------------------------------------------------------------------

/// Resolve a list of destination labels from the session into a synthetic
/// `DestinationRegistry` whose `id` fields equal the labels.
///
/// Labels not open in the session produce no entry in the registry and are
/// returned in the `missing` vec instead.  Callers should audit-log the
/// missing entries.
pub fn resolve_labels(
    labels: &[String],
) -> (DestinationRegistry, Vec<String>) {
    let mut registry = DestinationRegistry {
        schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
        destinations: Vec::new(),
    };
    let mut missing = Vec::new();

    for label in labels {
        match session::resolve_label(label) {
            Some((lbl, path, kind)) => {
                let kind_str = match kind {
                    session::EntryKind::Vault => "vault",
                    session::EntryKind::Directory => "directory",
                    session::EntryKind::Source => "directory", // shouldn't happen
                };
                registry.destinations.push(Destination {
                    id: lbl.clone(),
                    kind: kind_str.to_string(),
                    path: path.to_string_lossy().into_owned(),
                    label: lbl,
                    locked: false,
                });
            }
            None => {
                missing.push(label.clone());
            }
        }
    }

    (registry, missing)
}

// ---------------------------------------------------------------------------
// Rule engine application (pure, testable helper)
// ---------------------------------------------------------------------------

/// Run the deterministic rule engine against a pre-computed classification
/// and file facts, using only enabled rules.
///
/// Legacy entry point preserved for tests that don't exercise the W2 stage
/// pipeline. The runtime path (`run` below) uses `apply_rule_engine_with_llm`
/// which threads a real `LlmCaller` through to `rule_engine::run_with_stages`.
pub fn apply_rule_engine(
    classification: &Classification,
    file_facts: &FileFacts,
    rules: &[FileRule],
) -> rule_engine::RuleWalkOutcome {
    let rule_objs: Vec<Rule> = rules.iter().map(|r| r.clone().into_rule()).collect();
    rule_engine::run(classification, file_facts, &rule_objs)
}

/// W2 runtime entry: same as `apply_rule_engine` but invokes
/// `rule_engine::run_with_stages` so rules with `stages` populated run their
/// per-stage LLM pipelines through the supplied caller.
pub fn apply_rule_engine_with_llm(
    classification: &Classification,
    file_facts: &FileFacts,
    rules: &[FileRule],
    document_text: &str,
    llm: &mut dyn LlmCaller,
) -> rule_engine::RuleWalkOutcome {
    let rule_objs: Vec<Rule> = rules.iter().map(|r| r.clone().into_rule()).collect();
    rule_engine::run_with_stages(classification, file_facts, &rule_objs, document_text, llm)
}

/// `LlmCaller` adapter that issues `host.providers.chat` capability requests
/// through the same JSON-RPC out/stdin pipe `process::run` already uses for
/// Phase-1 classification. Holds mutable references to the IO streams + the
/// per-call config (model + optional spec).
struct CapabilityLlmCaller<'a, W: io::Write, I: Iterator<Item = Result<String, io::Error>>> {
    out: &'a mut W,
    lines: &'a mut I,
    next_id: &'a mut u64,
    model: &'a str,
    model_spec: Option<&'a Value>,
}

impl<'a, W: io::Write, I: Iterator<Item = Result<String, io::Error>>> LlmCaller
    for CapabilityLlmCaller<'a, W, I>
{
    fn call(&mut self, messages: Vec<Value>) -> Result<String, String> {
        let mut chat_args = json!({"messages": messages, "model": self.model});
        if let Some(spec) = self.model_spec {
            let is_empty_obj = spec.as_object().map_or(false, |o| o.is_empty());
            if !spec.is_null() && !is_empty_obj {
                chat_args["model_spec"] = spec.clone();
            }
        }
        let response = request_capability(
            self.out,
            self.lines,
            self.next_id,
            "host.providers.chat",
            chat_args,
        )?;
        let text = response
            .get("choices")
            .and_then(|v| v.as_array())
            .and_then(|arr| arr.first())
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
            .unwrap_or("")
            .to_string();
        if text.is_empty() {
            return Err("empty LLM response from stage call".into());
        }
        Ok(text)
    }
}

// ---------------------------------------------------------------------------
// Main pipeline entry point
// ---------------------------------------------------------------------------

/// Run the process() pipeline.
///
/// # Parameters
/// - `out`     — stdout writer (for host.providers.chat capability requests).
/// - `lines`   — stdin line iterator (for capability responses).
/// - `next_id` — monotonically-increasing request-id counter.
/// - `model`   — model name to pass to host.providers.chat (default "default").
/// - `model_spec` — optional structured provider spec (wins over `model` when present).
/// - `doc_type_strategy` — B8 doc_type normalization: `"none" | "enum" | "canonicalize" | "both"`.
/// - `audit_enabled` — when true AND `audit_path` is non-empty, append one
///   audit-log CSV row per `PlacementResult` after each successful fan-out.
///   Matches the W9 / panel batch-pipeline audit row shape (same column names,
///   same `event` enum, same `disposition` values produced by
///   [`audit::AuditRow::from_placement`]).
/// - `audit_path` — absolute path to the CSV log file. Ignored when
///   `audit_enabled` is false. Audit-write failures are NON-fatal: a warning
///   is logged and the pipeline continues. NEVER panics, NEVER aborts the run.
///
/// # Returns
/// `Ok(ProcessResult)` on success.  Individual file errors are recorded in
/// the result's `items` list rather than propagated as Err.
pub fn run(
    out: &mut impl io::Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    model: &str,
    model_spec: Option<Value>,
    doc_type_strategy: &str,
    audit_enabled: bool,
    audit_path: &str,
) -> VaultResult<ProcessResult> {
    let mut result = ProcessResult::default();

    // 1. Get open sources (sorted by label for deterministic order).
    let open_sources = session::open_sources_sorted();
    if open_sources.is_empty() {
        return Ok(result);
    }

    // 2. Load enabled rules from the global library, sorted by order asc.
    let all_rules = library::library_list()?;
    let mut enabled_rules: Vec<FileRule> = all_rules.into_iter().filter(|r| r.enabled).collect();
    enabled_rules.sort_by_key(|r| r.order);

    // 3. Build current open-destination label set for skip checks.
    let open_dest_labels: HashSet<String> = session::open_destination_labels();

    // 4. Iterate sources.
    for (source_label, source_path) in &open_sources {
        // Load (or init) per-source manifest.
        let mut src_state = source_state::load_or_init(source_path);

        // List files in the source directory.
        let files = match list_source_files_for_path(source_path) {
            Ok(f) => f,
            Err(e) => {
                log::warn!("process: cannot list files in source '{source_label}': {e}");
                continue;
            }
        };

        let mut dir_cache = DirHashCache::new();

        for (abs_path, rel_path, file_size) in &files {
            // Compute sha256.
            let sha256 = match crate::types::compute_sha256(Path::new(abs_path)) {
                Ok(h) => h,
                Err(e) => {
                    log::warn!("process: sha256 failed for {abs_path}: {e}");
                    result.unprocessable += 1;
                    result.items.push(ProcessItem {
                        source_label: source_label.clone(),
                        source_path_relative: rel_path.clone(),
                        status: "unprocessable".to_string(),
                        rule_label: None,
                        target_labels: vec![],
                        reason: Some(format!("sha256_error: {e}")),
                    });
                    continue;
                }
            };

            // Check skip.
            if source_state::should_skip(&src_state, &sha256, &open_dest_labels) {
                result.skipped_already_processed += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "skipped_already_processed".to_string(),
                    rule_label: None,
                    target_labels: vec![],
                    reason: None,
                });
                continue;
            }

            // Extract text. Keep the whole result so we can decide image-only.
            let extracted = match extract::extract_file(abs_path) {
                Ok(res) => res,
                Err(e) => {
                    log::warn!("process: extract failed for {abs_path}: {e}");
                    let entry = source_state::make_entry(
                        rel_path.clone(),
                        "unprocessable",
                        Some(format!("extract_error: {e}")),
                        None,
                        vec![],
                    );
                    source_state::upsert(&mut src_state, &sha256, entry);
                    result.unprocessable += 1;
                    result.items.push(ProcessItem {
                        source_label: source_label.clone(),
                        source_path_relative: rel_path.clone(),
                        status: "unprocessable".to_string(),
                        rule_label: None,
                        target_labels: vec![],
                        reason: Some(format!("extract_error: {e}")),
                    });
                    continue;
                }
            };

            let full_text = extracted.full_text.clone();

            // Decide vision-mode auto-fallback. When the doc has effectively
            // no extractable text, render its first few pages once and reuse
            // those images for both Phase-1 classification and per-rule stage
            // walks. Render failures fall back to the text path with whatever
            // text we did get (which the LLM will see as near-empty).
            let use_vision = is_image_only(&extracted);
            let page_images: Option<Vec<Value>> = if use_vision {
                match render::render_pages(abs_path, VISION_MAX_PAGES, VISION_DPI) {
                    Ok(rr) => {
                        if rr.pages.is_empty() {
                            log::warn!("process: vision render produced 0 pages for {abs_path}; falling back to text");
                            None
                        } else {
                            Some(
                                rr.pages
                                    .into_iter()
                                    .map(|p| json!({"page_num": p.page_num, "base64": p.base64}))
                                    .collect(),
                            )
                        }
                    }
                    Err(e) => {
                        log::warn!("process: vision render failed for {abs_path}: {e}; falling back to text");
                        None
                    }
                }
            } else {
                None
            };

            // Classify via host.providers.chat. Vision path uses multimodal
            // messages; text path keeps the original strategy-driven prompt.
            let rule_objs: Vec<Rule> = enabled_rules.iter().map(|r| r.clone().into_rule()).collect();
            let messages = match &page_images {
                Some(imgs) => classifier::build_vision_messages(imgs, &rule_objs),
                None => classifier::build_messages_with_strategy(
                    &full_text, 4000, &rule_objs, doc_type_strategy,
                ),
            };

            let mut chat_args = json!({
                "messages": messages,
                "model": model,
            });
            // Forward model_spec when caller supplied a non-empty object.
            // Broker rejects empty {} as 'unknown kind', so guard here.
            if let Some(ref spec) = model_spec {
                let is_empty_obj = spec.as_object().map_or(false, |o| o.is_empty());
                if !spec.is_null() && !is_empty_obj {
                    chat_args["model_spec"] = spec.clone();
                }
            }

            // Live progress for panel: classifying… (~5-10s LLM call).
            emit_doc_event(out, rel_path, "classifying", None, None);

            let chat_response = match request_capability(out, lines, next_id, "host.providers.chat", chat_args) {
                Ok(v) => v,
                Err(e) => {
                    log::warn!("process: classify failed for {abs_path}: {e}");
                    let entry = source_state::make_entry(
                        rel_path.clone(),
                        "unprocessable",
                        Some(format!("classify_error: {e}")),
                        None,
                        vec![],
                    );
                    source_state::upsert(&mut src_state, &sha256, entry);
                    result.unprocessable += 1;
                    emit_doc_event(out, rel_path, "unprocessable", None, Some(&format!("classify_error: {e}")));
                    result.items.push(ProcessItem {
                        source_label: source_label.clone(),
                        source_path_relative: rel_path.clone(),
                        status: "unprocessable".to_string(),
                        rule_label: None,
                        target_labels: vec![],
                        reason: Some(format!("classify_error: {e}")),
                    });
                    continue;
                }
            };

            let response_text = chat_response
                .get("choices")
                .and_then(|v| v.as_array())
                .and_then(|arr| arr.first())
                .and_then(|c| c.get("message"))
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
                .unwrap_or("");

            if response_text.is_empty() {
                // Surface the broker error envelope when present so per-file reasons
                // point at the real failure (schema, model not found, provider crash)
                // instead of the generic "empty LLM response".
                let reason_str = if chat_response.get("success").and_then(|v| v.as_bool()) == Some(false) {
                    let msg = chat_response.get("error_message").and_then(|v| v.as_str()).unwrap_or("broker error");
                    let detail = chat_response.get("detail").and_then(|v| v.as_str()).unwrap_or("");
                    let code = chat_response.get("error_code").and_then(|v| v.as_str()).unwrap_or("");
                    let suffix = if detail.is_empty() { String::new() } else { format!(": {detail}") };
                    let code_prefix = if code.is_empty() { String::new() } else { format!("[{code}] ") };
                    format!("classify_error: {code_prefix}{msg}{suffix}")
                } else if let Some(err_val) = chat_response.get("error") {
                    let err_str = err_val.as_str().map(String::from).unwrap_or_else(|| err_val.to_string());
                    format!("classify_error: LLM error: {err_str}")
                } else {
                    "classify_error: empty LLM response".to_string()
                };
                let entry = source_state::make_entry(
                    rel_path.clone(),
                    "unprocessable",
                    Some(reason_str.clone()),
                    None,
                    vec![],
                );
                source_state::upsert(&mut src_state, &sha256, entry);
                result.unprocessable += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "unprocessable".to_string(),
                    rule_label: None,
                    target_labels: vec![],
                    reason: Some(reason_str),
                });
                continue;
            }

            let mut classification = classifier::parse_response(response_text, &rule_objs);

            // Run rule engine.
            let ext = Path::new(abs_path)
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_string();
            let fname = Path::new(abs_path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            let file_facts = FileFacts {
                filename: fname,
                extension: ext,
                size: *file_size as i64,
            };

            // W2: run rule engine with the stage pipeline. CapabilityLlmCaller
            // borrows the same IO streams and request-id counter that the Phase-1
            // chat above used, so per-stage LLM calls reuse the existing channel.
            let outcome = {
                let mut caller = CapabilityLlmCaller {
                    out,
                    lines,
                    next_id,
                    model: &model,
                    model_spec: model_spec.as_ref(),
                };
                apply_rule_engine_with_llm_vision(
                    &classification,
                    &file_facts,
                    &enabled_rules,
                    &full_text,
                    page_images.as_deref(),
                    &mut caller,
                )
            };

            if !outcome.matched {
                // No rule fired.
                let entry = source_state::make_entry(
                    rel_path.clone(),
                    "unprocessable",
                    Some("no_rule_match".to_string()),
                    None,
                    vec![],
                );
                source_state::upsert(&mut src_state, &sha256, entry);
                result.unprocessable += 1;
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "unprocessable".to_string(),
                    rule_label: None,
                    target_labels: vec![],
                    reason: Some("no_rule_match".to_string()),
                });
                continue;
            }

            // Collect all copy_to labels from fired rules and resolve them.
            let mut all_labels: Vec<String> = Vec::new();
            let mut first_rule_label: Option<String> = None;
            let mut first_action = None;

            for action in &outcome.fired {
                if first_rule_label.is_none() {
                    first_rule_label = Some(action.category.clone());
                    first_action = Some(action.clone());
                }
                for lbl in &action.copy_to {
                    if !all_labels.contains(lbl) {
                        all_labels.push(lbl.clone());
                    }
                }
            }

            // B8: canonicalize doc_type against the winning rule's subtypes.
            // Applied for `canonicalize` and `both` strategies. No-op when the
            // winning rule has no subtypes or no token matches.
            let canon_active = doc_type_strategy == "canonicalize" || doc_type_strategy == "both";
            if canon_active {
                if let Some(ref winning_label) = first_rule_label {
                    if let Some(winning_rule) = enabled_rules.iter().find(|r| &r.label == winning_label) {
                        classification.doc_type = doc_type_normalizer::canonicalize(
                            &classification.doc_type,
                            &winning_rule.subtypes,
                        );
                    }
                }
            }

            let (registry, missing_labels) = resolve_labels(&all_labels);

            // Audit missing labels.
            for missing in &missing_labels {
                log::info!(
                    "process: label '{}' not open in session — skipped for {}",
                    missing,
                    rel_path
                );
            }

            // DCR 019e4291: empty copy_to — or a copy_to whose labels name no
            // open destination — falls back to every open session vault, so the
            // path-free pipeline routes identically to handle_place_fanout's
            // resolve_copy_to (DCR 019e4281). Directories are never auto-targeted.
            let (registry, resolved_labels) = {
                let resolved: Vec<String> =
                    registry.destinations.iter().map(|d| d.label.clone()).collect();
                if resolved.is_empty() {
                    let open_vault_labels: Vec<String> = session::entries_full()
                        .0
                        .into_iter()
                        .map(|(label, _path)| label)
                        .collect();
                    let (fb_reg, _) = resolve_labels(&open_vault_labels);
                    let fb_labels: Vec<String> =
                        fb_reg.destinations.iter().map(|d| d.label.clone()).collect();
                    (fb_reg, fb_labels)
                } else {
                    (registry, resolved)
                }
            };

            if resolved_labels.is_empty() {
                // No destinations resolved.
                let entry = source_state::make_entry(
                    rel_path.clone(),
                    "unprocessable",
                    Some("no_open_destination".to_string()),
                    first_rule_label.clone(),
                    vec![],
                );
                source_state::upsert(&mut src_state, &sha256, entry);
                result.unprocessable += 1;
                emit_doc_event(out, rel_path, "unprocessable", first_rule_label.as_deref(), Some("no_open_destination"));
                result.items.push(ProcessItem {
                    source_label: source_label.clone(),
                    source_path_relative: rel_path.clone(),
                    status: "unprocessable".to_string(),
                    rule_label: first_rule_label,
                    target_labels: vec![],
                    reason: Some("no_open_destination".to_string()),
                });
                continue;
            }

            // Fan out to resolved destinations.
            let action = first_action.as_ref().unwrap();
            let meta = DocMeta {
                category: classification.category.clone(),
                confidence: classification.confidence,
                issuer: classification.issuer.clone(),
                description: classification.description.clone(),
                doc_date: classification.doc_date.clone(),
                status: "classified".to_string(),
                simhash: "0000000000000000".to_string(),
                dhash: "0000000000000000".to_string(),
                source_path: abs_path.clone(),
                rule_snapshot: String::new(),
                sha256: sha256.clone(),
                doc_type: classification.doc_type.clone(),
                amount: classification.amount.clone(),
            };

            let placements = placement::fan_out(
                abs_path,
                &resolved_labels,
                &action.resolved_subfolder,
                &action.resolved_rename_pattern,
                action.encrypt,
                &registry,
                &meta,
                Some(&mut dir_cache),
            );

            // W9 / DCR 019e3ce069b6 — write audit rows for this fan-out.
            // One row per PlacementResult so the log is interchangeable with
            // the panel batch pipeline (which also emits per-placement).
            // Non-fatal on failure: log a warning and continue.
            //
            // `source_filename` carries the fully-qualified path of the source
            // file (OS-native separators preserved — Windows backslashes /
            // POSIX slashes — so the log is locator-style on every platform).
            if audit_enabled && !audit_path.is_empty() && !placements.is_empty() {
                let rule_label_str = first_rule_label.clone().unwrap_or_default();
                let audit_rows = build_audit_rows_for_placements(
                    &placements,
                    &registry,
                    &sha256,
                    abs_path,
                    &rule_label_str,
                );
                if !audit_rows.is_empty() {
                    if let Err(e) = audit::append_rows(Path::new(audit_path), &audit_rows) {
                        log::warn!(
                            "process: audit append failed for '{}' at '{}': {} (continuing, non-fatal)",
                            rel_path,
                            audit_path,
                            e.message
                        );
                    }
                }
            }

            // Determine overall outcome.
            let any_placed = placements.iter().any(|p| p.status == PlacementStatus::Placed);
            let any_conflict = placements.iter().any(|p| p.status == PlacementStatus::SkippedAlreadyPresent);

            let status = if any_placed {
                "moved"
            } else if any_conflict {
                "conflict"
            } else {
                "unprocessable"
            };

            // Bump counters.
            if any_placed {
                result.moved += 1;
                if let Some(ref rl) = first_rule_label {
                    result.bump_rule(rl);
                }
                for lbl in &resolved_labels {
                    result.bump_dest(lbl);
                }
            } else if any_conflict {
                result.conflicts += 1;
            } else {
                result.unprocessable += 1;
            }

            let reason = if status == "unprocessable" {
                Some("placement_error".to_string())
            } else {
                None
            };

            let entry = source_state::make_entry(
                rel_path.clone(),
                status,
                reason.clone(),
                first_rule_label.clone(),
                resolved_labels.clone(),
            );
            source_state::upsert(&mut src_state, &sha256, entry);

            // Per-file terminal emit for panel source pane. Use rule_label as
            // the target since copy_to may have fanned out to multiple labels
            // — rule_label is the categorization the user actually cares about.
            emit_doc_event(out, rel_path, status, first_rule_label.as_deref(), reason.as_deref());

            result.items.push(ProcessItem {
                source_label: source_label.clone(),
                source_path_relative: rel_path.clone(),
                status: status.to_string(),
                rule_label: first_rule_label,
                target_labels: resolved_labels,
                reason,
            });

            // Per-doc manifest checkpoint. Lets external watchdogs measure
            // per-file latency and recovers progress on crash. source_state::save
            // is atomic (tmp+rename), and the manifest is small (~hundreds of
            // bytes/doc) so the cost is negligible vs each LLM call.
            if let Err(e) = source_state::save(source_path, &src_state) {
                log::warn!(
                    "process: could not checkpoint manifest for '{source_label}' after {rel_path}: {e}"
                );
            }
        }

        // Final write for symmetry — also covers the empty-files case where
        // the per-doc checkpoint never ran.
        if let Err(e) = source_state::save(source_path, &src_state) {
            log::warn!("process: could not save manifest for '{source_label}': {e}");
        }
    }

    Ok(result)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Build the audit-log rows for one fan-out's `placements` slice.
///
/// One row is produced per `PlacementResult`, mirroring the panel batch
/// pipeline (`ui/ScansortPanel.gd:_run_batch_pipeline`) which also emits
/// one audit row per `PlacementResult`. The `destination_kind` is looked
/// up from `registry`; rows whose destination is not in the registry are
/// stamped with an empty `kind` (same behaviour as the panel which reads
/// `pr.get("kind", "")`).
///
/// Status → event mapping is delegated to [`audit::AuditRow::from_placement`]:
///   - `Placed`                 → event=`placement`, disposition=`placed`
///   - `SkippedAlreadyPresent`  → event=`skipped`,  disposition=`skipped-already-present`
///   - `Error`                  → event=`placement`, disposition=`error`
///
/// `resolved_path` semantics (per [`audit::AuditRow`] docstring):
///   - Directory destination → `pr.target_path` (the placed file path)
///   - Vault destination     → vault file path from registry (includes `.ssort`)
///
/// `detail` enrichment for the happy path:
///   - Vault placed → `"doc_id=N"` so the audit log carries provenance into
///     the vault DB without requiring an external lookup.
///   - All other cases → `pr.message` verbatim (carries error / skip reason).
///
/// `timestamp` is sampled per-row via [`crate::types::now_iso`].
fn build_audit_rows_for_placements(
    placements: &[PlacementResult],
    registry: &DestinationRegistry,
    source_sha256: &str,
    source_filename: &str,
    rule_label: &str,
) -> Vec<audit::AuditRow> {
    let mut rows: Vec<audit::AuditRow> = Vec::with_capacity(placements.len());
    for pr in placements {
        let status_str = match pr.status {
            PlacementStatus::Placed => "placed",
            PlacementStatus::SkippedAlreadyPresent => "skipped-already-present",
            PlacementStatus::Error => "error",
        };
        // Resolve destination kind + path from the registry; fall back to the
        // PlacementResult's own `kind` field (set by fan_out), then "".
        let registry_dest = crate::destinations::find_by_id(registry, &pr.destination_id);
        let dest_kind = registry_dest
            .map(|d| d.kind.as_str().to_string())
            .unwrap_or_else(|| pr.kind.clone());

        // For vaults, target_path is empty (vault DB writes have no on-disk
        // path per file); use the vault file path from the registry so the
        // audit row is interpretable standalone. For directories,
        // target_path is the placed file path.
        let resolved_path = if dest_kind == "vault" {
            registry_dest
                .map(|d| d.path.clone())
                .unwrap_or_else(|| pr.target_path.clone())
        } else {
            pr.target_path.clone()
        };

        // Happy-path enrichment: for placed vault rows, record the doc_id so
        // the audit log can be cross-referenced against the vault DB without
        // an external lookup. Other cases keep pr.message verbatim (error
        // text or skip reason).
        let detail = if pr.status == PlacementStatus::Placed
            && dest_kind == "vault"
            && pr.doc_id != 0
        {
            format!("doc_id={}", pr.doc_id)
        } else {
            pr.message.clone()
        };

        let now = crate::types::now_iso();
        rows.push(audit::AuditRow::from_placement(
            source_sha256,
            source_filename,
            rule_label,
            &pr.destination_id,
            &dest_kind,
            &resolved_path,
            status_str,
            &detail,
            &now,
        ));
    }
    rows
}

/// Emit a per-file document progress event for the panel source pane.
/// Wraps notify_state_changed_with so process() doesn't have to build the
/// extras map at every site. status ∈ {"classifying","moved","conflict",
/// "unprocessable"}; target = destination/rule label when relevant; reason =
/// error category when status=unprocessable.
fn emit_doc_event<W: io::Write>(
    out: &mut W,
    rel_path: &str,
    status: &str,
    target: Option<&str>,
    reason: Option<&str>,
) {
    let mut extras = serde_json::Map::new();
    extras.insert("file_path".to_string(), json!(rel_path));
    extras.insert("status".to_string(), json!(status));
    if let Some(t) = target { extras.insert("target".to_string(), json!(t)); }
    if let Some(r) = reason { extras.insert("reason".to_string(), json!(r)); }
    crate::notify_state_changed_with(out, "document", Some(&Value::Object(extras)));
}

/// List supported files under `source_path` as `(abs_path, rel_path, size)`.
fn list_source_files_for_path(
    source_path: &Path,
) -> VaultResult<Vec<(String, String, u64)>> {
    let mut files = Vec::new();
    collect_files_inner(source_path, source_path, &mut files)?;
    files.sort_by(|a, b| a.1.cmp(&b.1));
    Ok(files)
}

const SUPPORTED_EXTS: &[&str] = &[".pdf", ".docx", ".xlsx", ".xls"];

fn is_supported_ext(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_lowercase()))
        .unwrap_or_default();
    SUPPORTED_EXTS.contains(&ext.as_str())
}

fn collect_files_inner(
    base: &Path,
    dir: &Path,
    out: &mut Vec<(String, String, u64)>,
) -> VaultResult<()> {
    let entries = std::fs::read_dir(dir).map_err(|e| {
        VaultError::new(format!(
            "process: cannot read directory {}: {e}",
            dir.display()
        ))
    })?;
    for entry_result in entries {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        // Skip hidden files and the manifest itself.
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if file_name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect_files_inner(base, &path, out)?;
            continue;
        }
        if !is_supported_ext(&path) {
            continue;
        }
        let abs = path
            .canonicalize()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());
        let rel = path
            .strip_prefix(base)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| file_name.to_string());
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        out.push((abs, rel, size));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// W4 (DCR 019e33bf): dryrun_one — pre-placement trace for a single doc
// ---------------------------------------------------------------------------

/// Run extract → Phase-1 classify → per-rule stage walk → template resolve
/// for one document, WITHOUT placing it anywhere. Returns a structured trace
/// the UI's "Test on…" affordance and dryrun MCP tool consume.
///
/// `rule_label` filter: when Some, only evaluate that single enabled rule;
/// when None, evaluate every enabled rule. The function does NOT short-circuit
/// on `stop_processing` since the dry-run shows "what would each rule do".
///
/// Trace-log emission: DCR 019e33a2 phases 1+2 (`rule_evaluated`,
/// `stage_executed`, `template_resolved`) are intended to come from here. They
/// are NOT yet emitted (trace log unlanded — see pickup §"Stop conditions" #8);
/// the same data appears in the return value, so consumers can switch from
/// reading return-shape → reading the trace log without losing information.
pub fn dryrun_one(
    out: &mut impl io::Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    doc_path: &str,
    rule_label_filter: Option<&str>,
    model: &str,
    model_spec: Option<&Value>,
) -> Result<Value, String> {
    use std::path::Path;
    let path = Path::new(doc_path);
    if !path.exists() {
        return Err(format!("doc_path does not exist: {doc_path}"));
    }

    // 1. SHA-256 (so traces are correlatable to placement later).
    let sha256 = crate::types::compute_sha256(path).map_err(|e| e.message)?;

    // 2. Text extraction.
    let extracted = extract::extract_file(doc_path).map_err(|e| e.message)?;
    let full_text = extracted.full_text;

    // 3. Load enabled rules; optionally filter to a single label.
    let lib_rules = library::library_list().map_err(|e| e.message)?;
    let mut enabled_rules: Vec<FileRule> = lib_rules.into_iter().filter(|r| r.enabled).collect();
    if let Some(filter) = rule_label_filter {
        enabled_rules.retain(|r| r.label == filter);
        if enabled_rules.is_empty() {
            return Err(format!("rule '{filter}' not found or not enabled"));
        }
    }
    if enabled_rules.is_empty() {
        return Ok(json!({
            "ok": true,
            "doc_path": doc_path,
            "doc_sha256": sha256,
            "rules_evaluated": [],
            "note": "no enabled rules in library",
        }));
    }

    let rule_objs: Vec<Rule> = enabled_rules.iter().map(|r| r.clone().into_rule()).collect();

    // 4. Phase 1 — single chat to score every enabled rule + extract facts.
    let messages = classifier::build_messages_with_strategy(&full_text, 4000, &rule_objs, "none");
    let mut chat_args = json!({"messages": messages, "model": model});
    if let Some(spec) = model_spec {
        let is_empty_obj = spec.as_object().map_or(false, |o| o.is_empty());
        if !spec.is_null() && !is_empty_obj {
            chat_args["model_spec"] = spec.clone();
        }
    }
    let chat_response =
        request_capability(out, lines, next_id, "host.providers.chat", chat_args)?;
    let response_text = chat_response
        .get("choices")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();
    if response_text.is_empty() {
        return Err("empty Phase-1 LLM response".into());
    }
    let classification = classifier::parse_response(&response_text, &rule_objs);

    // 5. File facts.
    let file_facts = FileFacts {
        filename: path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string(),
        extension: path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_string(),
        size: std::fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0),
    };

    // 6. Per-rule walk. Use stage_walker directly (not run_with_stages) so we
    //    can record per-rule outcomes for filtered/below-threshold rules too.
    let mut caller = CapabilityLlmCaller {
        out,
        lines,
        next_id,
        model,
        model_spec,
    };

    let mut rules_evaluated: Vec<Value> = Vec::with_capacity(rule_objs.len());
    for rule in &rule_objs {
        let score = classification
            .rule_signals
            .iter()
            .find(|s| s.label == rule.label)
            .map(|s| s.score)
            .unwrap_or(0.0);
        let passes_threshold = score >= rule.confidence_threshold;

        if !passes_threshold {
            rules_evaluated.push(json!({
                "rule_label": rule.label,
                "score": score,
                "threshold": rule.confidence_threshold,
                "fired": false,
                "reason": "below_threshold",
                "stages": [],
                "resolved_subfolder": Value::Null,
                "resolved_filename": Value::Null,
                "would_copy_to": [],
            }));
            continue;
        }

        // Walk the stages. Empty-stages rules return a no-op outcome and we
        // resolve templates against the Phase-1 facts (legacy back-compat).
        let walk = crate::stage_walker::walk(rule, &full_text, &mut caller);

        if walk.filtered {
            rules_evaluated.push(json!({
                "rule_label": rule.label,
                "score": score,
                "threshold": rule.confidence_threshold,
                "fired": false,
                "reason": "filtered",
                "stages": walk.stages_executed,
                "resolved_subfolder": Value::Null,
                "resolved_filename": Value::Null,
                "would_copy_to": [],
            }));
            continue;
        }

        let (subfolder, filename) = if !walk.slots.is_empty() {
            (
                rule_engine::resolve_template_from_slots(&rule.subfolder, &walk.slots),
                rule_engine::resolve_template_from_slots(&rule.rename_pattern, &walk.slots),
            )
        } else {
            (
                rule_engine::resolve_template(&rule.subfolder, &classification),
                rule_engine::resolve_template(&rule.rename_pattern, &classification),
            )
        };

        rules_evaluated.push(json!({
            "rule_label": rule.label,
            "score": score,
            "threshold": rule.confidence_threshold,
            "fired": true,
            "stages": walk.stages_executed,
            "resolved_subfolder": subfolder,
            "resolved_filename": filename,
            "would_copy_to": rule.copy_to,
        }));
    }

    Ok(json!({
        "ok": true,
        "doc_path": doc_path,
        "doc_sha256": sha256,
        "rules_evaluated": rules_evaluated,
    }))
}

/// Inline capability request helper (same contract as in main.rs).
fn request_capability(
    out: &mut impl io::Write,
    lines: &mut impl Iterator<Item = Result<String, io::Error>>,
    next_id: &mut u64,
    capability: &str,
    args: Value,
) -> Result<Value, String> {
    *next_id += 1;
    let id = format!("cap-{}", next_id);
    let req = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "minerva/capability",
        "params": { "capability": capability, "args": args }
    });
    let line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
    out.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    out.write_all(b"\n").map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())?;

    for line_result in lines.by_ref() {
        let line = line_result.map_err(|e| format!("stdin read error: {e}"))?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let msg_id = msg.get("id").cloned().unwrap_or(Value::Null);
        if msg_id.as_str() != Some(&id) {
            continue;
        }
        if let Some(err) = msg.get("error") {
            return Err(format!("capability error: {err}"));
        }
        return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
    }
    Err("stdin closed waiting for capability response".into())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules_file::FileRule;
    use crate::source_state::SourceState;
    use crate::session;
    use crate::types::{Classification, RuleSignal};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_tmp(prefix: &str) -> PathBuf {
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir()
            .join(format!("scansort-process-{prefix}-{pid}-{ts}-{n}"))
    }

    fn make_file_rule(label: &str, enabled: bool, copy_to: Vec<&str>) -> FileRule {
        FileRule {
            label: label.to_string(),
            name: label.to_string(),
            instruction: format!("Match {label} documents"),
            signals: vec![label.to_string()],
            subfolder: String::new(),
            rename_pattern: String::new(),
            confidence_threshold: 0.5,
            encrypt: false,
            enabled,
            is_default: false,
            conditions: None,
            exceptions: None,
            order: 0,
            stop_processing: false,
            copy_to: copy_to.into_iter().map(String::from).collect(),
            subtypes: Vec::new(),
            stages: Vec::new(),
        }
    }

    fn make_classification_with_signal(rule_label: &str, score: f64) -> Classification {
        Classification {
            category: rule_label.to_string(),
            confidence: score,
            issuer: String::new(),
            description: String::new(),
            doc_date: String::new(),
            tags: vec![],
            raw_response: String::new(),
            fallback_reason: None,
            doc_type: String::new(),
            amount: String::new(),
            year: 0,
            rule_signals: vec![RuleSignal {
                label: rule_label.to_string(),
                score,
            }],
        }
    }

    // -----------------------------------------------------------------------
    // Label resolver: known vault and dir labels resolve; unknown misses
    // -----------------------------------------------------------------------
    #[test]
    fn resolve_labels_vault_and_dir() {
        // Build a synthetic registry directly — don't touch the global SESSION
        // singleton which could interfere with other tests.
        let mut registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![
                Destination {
                    id: "vault-a".to_string(),
                    kind: "vault".to_string(),
                    path: "/fake/vault-a.ssort".to_string(),
                    label: "vault-a".to_string(),
                    locked: false,
                },
                Destination {
                    id: "dir-b".to_string(),
                    kind: "directory".to_string(),
                    path: "/fake/dir-b".to_string(),
                    label: "dir-b".to_string(),
                    locked: false,
                },
            ],
        };

        // Simulate resolve_labels by calling find_by_id on the synthetic reg.
        let found_a = crate::destinations::find_by_id(&registry, "vault-a");
        let found_b = crate::destinations::find_by_id(&registry, "dir-b");
        let found_c = crate::destinations::find_by_id(&registry, "no-such-label");

        assert!(found_a.is_some(), "vault-a must resolve");
        assert_eq!(found_a.unwrap().kind, "vault");
        assert!(found_b.is_some(), "dir-b must resolve");
        assert_eq!(found_b.unwrap().kind, "directory");
        assert!(found_c.is_none(), "no-such-label must not resolve");

        // Verify the id=label invariant that resolve_labels() guarantees.
        for dest in &registry.destinations {
            assert_eq!(dest.id, dest.label, "id must equal label in synthetic registry");
        }
        // Suppress unused-mut warning.
        registry.destinations.clear();
    }

    // -----------------------------------------------------------------------
    // Rule engine filter: only enabled rules fire
    // -----------------------------------------------------------------------
    #[test]
    fn apply_rule_engine_skips_disabled_rules() {
        let classification = make_classification_with_signal("invoice", 0.9);
        let file_facts = FileFacts {
            filename: "inv.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 1000,
        };

        let rules = vec![
            make_file_rule("invoice", true,  vec!["dest-a"]),
            make_file_rule("tax",     false, vec!["dest-b"]), // disabled
        ];

        let outcome = apply_rule_engine(&classification, &file_facts, &rules);
        assert!(outcome.matched, "enabled rule must fire");
        assert_eq!(outcome.fired.len(), 1);
        assert_eq!(outcome.fired[0].category, "invoice");
    }

    // -----------------------------------------------------------------------
    // Catch-all: no rule matches → unprocessable/no_rule_match
    // -----------------------------------------------------------------------
    #[test]
    fn no_rule_match_outcome() {
        let classification = make_classification_with_signal("invoice", 0.1); // below threshold
        let file_facts = FileFacts {
            filename: "unknown.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 500,
        };

        let rules = vec![make_file_rule("invoice", true, vec!["dest-a"])];
        let outcome = apply_rule_engine(&classification, &file_facts, &rules);
        assert!(!outcome.matched, "low score must not fire");
        assert!(outcome.fired.is_empty());
    }

    // -----------------------------------------------------------------------
    // Catch-all: rule fired but copy_to label not open → no destinations
    // -----------------------------------------------------------------------
    #[test]
    fn fired_rule_missing_labels_yields_empty_resolved() {
        // Build a label list with one unknown label.
        let labels = vec!["missing-label".to_string()];

        // Don't use the global session — call resolve_labels which internally
        // calls session::resolve_label.  Since we're in a test and "missing-label"
        // is not in the global session, it should come back as missing.
        let (registry, missing) = resolve_labels(&labels);
        assert!(registry.destinations.is_empty(), "no destinations must resolve");
        assert_eq!(missing, vec!["missing-label"]);
    }

    // -----------------------------------------------------------------------
    // should_skip delegation: matches source_state module behaviour
    // -----------------------------------------------------------------------
    #[test]
    fn should_skip_delegates_correctly() {
        let mut state = SourceState::default();
        let sha = "cafebabe";
        let open: HashSet<String> = ["dest-x".to_string()].into_iter().collect();

        // No entry yet → do NOT skip.
        assert!(!source_state::should_skip(&state, sha, &open));

        // Add a moved entry with dest-x.
        source_state::upsert(
            &mut state,
            sha,
            source_state::make_entry(
                "f.pdf".to_string(),
                "moved",
                None,
                Some("rule-x".to_string()),
                vec!["dest-x".to_string()],
            ),
        );

        // dest-x is open → should skip.
        assert!(source_state::should_skip(&state, sha, &open));

        // Close dest-x → should NOT skip.
        let empty_open: HashSet<String> = HashSet::new();
        assert!(!source_state::should_skip(&state, sha, &empty_open));
    }

    // -----------------------------------------------------------------------
    // Multiple enabled rules all fire; copy_to union collected correctly
    // -----------------------------------------------------------------------
    #[test]
    fn multi_fired_rules_copy_to_union() {
        let mut classification = make_classification_with_signal("rule_a", 0.9);
        classification.rule_signals.push(RuleSignal {
            label: "rule_b".to_string(),
            score: 0.8,
        });

        let file_facts = FileFacts {
            filename: "doc.pdf".to_string(),
            extension: "pdf".to_string(),
            size: 1000,
        };

        let rules = vec![
            make_file_rule("rule_a", true, vec!["dest-1", "dest-2"]),
            make_file_rule("rule_b", true, vec!["dest-2", "dest-3"]),
        ];

        let outcome = apply_rule_engine(&classification, &file_facts, &rules);
        assert!(outcome.matched);
        assert_eq!(outcome.fired.len(), 2);

        // Collect union of copy_to from all fired rules.
        let mut all_labels: Vec<String> = Vec::new();
        for action in &outcome.fired {
            for lbl in &action.copy_to {
                if !all_labels.contains(lbl) {
                    all_labels.push(lbl.clone());
                }
            }
        }
        // dest-2 appears in both rules but should appear once in the union.
        assert_eq!(all_labels.len(), 3);
        assert!(all_labels.contains(&"dest-1".to_string()));
        assert!(all_labels.contains(&"dest-2".to_string()));
        assert!(all_labels.contains(&"dest-3".to_string()));
    }

    // -----------------------------------------------------------------------
    // DCR 019e3ce069b6 — audit row construction from placements.
    //
    // The full process::run() pipeline requires the global session, the
    // library, real files on disk, and an LLM JSON-RPC pump — too heavy for
    // a unit test. Instead we test the helper that the run() loop calls,
    // then write its output through the real audit::append_rows path so the
    // on-disk file contents are exercised end-to-end.
    // -----------------------------------------------------------------------
    #[test]
    fn dcr_019e3ce0_audit_rows_match_panel_shape_and_write_to_log() {
        use crate::placement::PlacementResult;

        // Synthetic registry — `id == label` invariant matches what
        // resolve_labels() produces inside the real run() loop.
        let registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![
                Destination {
                    id: "vault-archive".to_string(),
                    kind: "vault".to_string(),
                    path: "/fake/vault-archive.ssort".to_string(),
                    label: "vault-archive".to_string(),
                    locked: false,
                },
                Destination {
                    id: "dir-invoices".to_string(),
                    kind: "directory".to_string(),
                    path: "/fake/dir-invoices".to_string(),
                    label: "dir-invoices".to_string(),
                    locked: false,
                },
            ],
        };

        // Two placements — one Placed (directory), one SkippedAlreadyPresent
        // (vault) — covers both event branches in from_placement.
        let placements = vec![
            PlacementResult {
                destination_id: "dir-invoices".to_string(),
                kind: "directory".to_string(),
                target_path: "/fake/dir-invoices/2026/inv-001.pdf".to_string(),
                doc_id: 0,
                status: PlacementStatus::Placed,
                message: String::new(),
            },
            PlacementResult {
                destination_id: "vault-archive".to_string(),
                kind: "vault".to_string(),
                target_path: "/fake/vault-archive.ssort".to_string(),
                doc_id: 42,
                status: PlacementStatus::SkippedAlreadyPresent,
                message: "doc_id=42 already present".to_string(),
            },
        ];

        let rows = build_audit_rows_for_placements(
            &placements,
            &registry,
            "deadbeefcafe",
            "/srv/inbox/invoice-001.pdf",
            "Invoice",
        );
        assert_eq!(rows.len(), 2, "one row per PlacementResult");

        // Row 0 — Placed → event=placement, disposition=placed.
        assert_eq!(rows[0].event, "placement");
        assert_eq!(rows[0].disposition, "placed");
        assert_eq!(rows[0].source_sha256, "deadbeefcafe");
        // source_filename is fully-qualified path; caller passed it through.
        assert_eq!(rows[0].source_filename, "/srv/inbox/invoice-001.pdf");
        assert_eq!(rows[0].rule_label, "Invoice");
        assert_eq!(rows[0].destination_id, "dir-invoices");
        assert_eq!(rows[0].destination_kind, "directory");
        assert_eq!(rows[0].resolved_path, "/fake/dir-invoices/2026/inv-001.pdf");
        assert!(!rows[0].timestamp.is_empty(), "timestamp must be stamped");

        // Row 1 — SkippedAlreadyPresent → event=skipped.
        assert_eq!(rows[1].event, "skipped");
        assert_eq!(rows[1].disposition, "skipped-already-present");
        assert_eq!(rows[1].destination_id, "vault-archive");
        assert_eq!(rows[1].destination_kind, "vault");
        // Vault dest: resolved_path comes from registry (includes .ssort),
        // NOT from pr.target_path (which is empty for vaults in fan_out).
        assert_eq!(rows[1].resolved_path, "/fake/vault-archive.ssort");
        // Skipped-vault keeps pr.message verbatim — doc_id enrichment only
        // applies to Placed rows, not skipped ones.
        assert_eq!(rows[1].detail, "doc_id=42 already present");

        // Now drive the log file end-to-end — same call the run() loop makes.
        let dir = unique_tmp("audit-e2e");
        std::fs::create_dir_all(&dir).unwrap();
        let log_path = dir.join("process-audit.csv");
        audit::append_rows(&log_path, &rows).expect("audit append must succeed");

        let contents = std::fs::read_to_string(&log_path).expect("log file must exist");
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(lines.len(), 3, "expected header + 2 rows, got:\n{}", contents);
        assert!(
            lines[0].starts_with("timestamp,event,source_sha256,source_filename,rule_label,destination_id,destination_kind,resolved_path,disposition,detail"),
            "header must match the W9 column order: {}",
            lines[0]
        );
        // Row 1 (data) — placement / placed / Invoice / dir-invoices.
        assert!(lines[1].contains("\"placement\""), "row1 event=placement: {}", lines[1]);
        assert!(lines[1].contains("\"placed\""),    "row1 disposition=placed: {}", lines[1]);
        assert!(lines[1].contains("\"Invoice\""),   "row1 rule_label: {}", lines[1]);
        assert!(lines[1].contains("\"dir-invoices\""), "row1 dest id: {}", lines[1]);
        // Row 2 — skipped / skipped-already-present / vault.
        assert!(lines[2].contains("\"skipped\""), "row2 event=skipped: {}", lines[2]);
        assert!(lines[2].contains("\"skipped-already-present\""), "row2 disposition: {}", lines[2]);
        assert!(lines[2].contains("\"vault-archive\""),           "row2 vault dest: {}", lines[2]);

        std::fs::remove_dir_all(&dir).ok();
    }

    // -----------------------------------------------------------------------
    // Placed vault row → resolved_path comes from registry (.ssort path),
    // and detail carries doc_id=N for cross-reference with the vault DB.
    // -----------------------------------------------------------------------
    #[test]
    fn dcr_019e3ce0_placed_vault_uses_registry_path_and_doc_id_in_detail() {
        use crate::placement::PlacementResult;

        let registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![Destination {
                id: "test".to_string(),
                kind: "vault".to_string(),
                path: "/home/user/test.ssort".to_string(),
                label: "test".to_string(),
                locked: false,
            }],
        };
        let placements = vec![PlacementResult {
            destination_id: "test".to_string(),
            kind: "vault".to_string(),
            target_path: String::new(), // fan_out leaves this empty for vault
            doc_id: 17,
            status: PlacementStatus::Placed,
            message: String::new(), // happy path: no error message
        }];

        let rows = build_audit_rows_for_placements(
            &placements, &registry, "sha", "doc.pdf", "tax",
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].event, "placement");
        assert_eq!(rows[0].disposition, "placed");
        assert_eq!(
            rows[0].resolved_path, "/home/user/test.ssort",
            "vault placed row must carry the .ssort path from registry"
        );
        assert_eq!(
            rows[0].detail, "doc_id=17",
            "vault placed row must carry doc_id in detail for vault-DB cross-ref"
        );
    }

    // -----------------------------------------------------------------------
    // Placed vault row with doc_id=0 (defensive: never seen in real fan_out,
    // but guard against it) → no doc_id enrichment, detail stays empty.
    // -----------------------------------------------------------------------
    #[test]
    fn dcr_019e3ce0_placed_vault_doc_id_zero_does_not_enrich_detail() {
        use crate::placement::PlacementResult;

        let registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![Destination {
                id: "test".to_string(),
                kind: "vault".to_string(),
                path: "/home/user/test.ssort".to_string(),
                label: "test".to_string(),
                locked: false,
            }],
        };
        let placements = vec![PlacementResult {
            destination_id: "test".to_string(),
            kind: "vault".to_string(),
            target_path: String::new(),
            doc_id: 0, // defensive: shouldn't happen on success but guard anyway
            status: PlacementStatus::Placed,
            message: String::new(),
        }];

        let rows = build_audit_rows_for_placements(
            &placements, &registry, "sha", "doc.pdf", "tax",
        );
        assert_eq!(rows[0].resolved_path, "/home/user/test.ssort");
        assert_eq!(rows[0].detail, "", "doc_id=0 must not produce \"doc_id=0\" noise");
    }

    // -----------------------------------------------------------------------
    // DCR 019e3ce069b6 — error status maps to event=placement, disposition=error.
    // -----------------------------------------------------------------------
    #[test]
    fn dcr_019e3ce0_error_placement_logged_as_error_disposition() {
        use crate::placement::PlacementResult;

        let registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![Destination {
                id: "dir-x".to_string(),
                kind: "directory".to_string(),
                path: "/fake/dir-x".to_string(),
                label: "dir-x".to_string(),
                locked: false,
            }],
        };
        let placements = vec![PlacementResult {
            destination_id: "dir-x".to_string(),
            kind: "directory".to_string(),
            target_path: String::new(),
            doc_id: 0,
            status: PlacementStatus::Error,
            message: "permission denied".to_string(),
        }];

        let rows = build_audit_rows_for_placements(
            &placements, &registry, "sha", "doc.pdf", "Rule",
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].event, "placement", "error rows are still placement events");
        assert_eq!(rows[0].disposition, "error");
        assert_eq!(rows[0].detail, "permission denied");
    }

    // -----------------------------------------------------------------------
    // DCR 019e3ce069b6 — unknown destination id falls back to PlacementResult's
    // own kind (defensive — registry lookup miss shouldn't blank the field).
    // -----------------------------------------------------------------------
    #[test]
    fn dcr_019e3ce0_unknown_dest_falls_back_to_placement_kind() {
        use crate::placement::PlacementResult;

        // Empty registry — every lookup misses.
        let registry = DestinationRegistry {
            schema_version: crate::destinations::CURRENT_SCHEMA_VERSION,
            destinations: vec![],
        };
        let placements = vec![PlacementResult {
            destination_id: "ghost-dest".to_string(),
            kind: "vault".to_string(), // fall-back source
            target_path: "/fake/v.ssort".to_string(),
            doc_id: 7,
            status: PlacementStatus::Placed,
            message: String::new(),
        }];
        let rows = build_audit_rows_for_placements(
            &placements, &registry, "sha", "doc.pdf", "Rule",
        );
        assert_eq!(rows[0].destination_kind, "vault", "must fall back to PlacementResult.kind");
    }
}
