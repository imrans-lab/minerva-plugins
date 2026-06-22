//! Multi-device sync engine.
//!
//! Cloud-canonical model: every save uploads a new immutable artifact tagged
//! `drive`, carrying a manifest (project id, version, parent, content hash,
//! device, mtime) in its description. The "current" state of a project is the
//! highest-version artifact for its project id; older versions are recoverable
//! history. Local state records, per tracked file, the project id plus the
//! version and hash it was last in sync with ("base").
//!
//! The engine diffs each tracked file against the cloud current:
//!   - neither changed -> nothing to do
//!   - only local changed -> push a new version
//!   - only cloud changed -> pull the cloud version
//!   - both changed (divergence) -> the cloud version becomes the canonical file
//!     and the local edit is preserved beside it as a conflict copy. This is
//!     last-writer-wins on the current pointer, and it never discards an edit.
//! Cloud projects with no local tracking are pulled into the drive directory.

#![allow(dead_code)] // public surface is consumed by the tool layer

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::artifact_client::ArtifactClient;

/// The tag marking an artifact as drive-managed (filters the owner's other
/// artifacts out of `list-mine`).
pub const DRIVE_TAG: &str = "drive";

/// Per-artifact sync manifest, serialized into the artifact description.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ArtifactManifest {
    pub proj_uuid: String,
    pub name: String,
    pub version: u64,
    pub parent_version: u64,
    pub content_hash: String,
    pub device: String,
    pub mtime: String,
}

/// One cloud artifact relevant to sync (its URI + parsed manifest).
#[derive(Clone, Debug)]
pub struct CloudArtifact {
    pub uri: String,
    pub manifest: ArtifactManifest,
}

/// What a tracked local file was last synced to.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct TrackedEntry {
    pub proj_uuid: String,
    pub name: String,
    pub base_version: u64,
    pub base_hash: String,
}

/// Persisted local sync state (serialized to JSON by the caller).
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub struct SyncState {
    pub device_id: String,
    /// Keyed by local file path.
    pub entries: HashMap<String, TrackedEntry>,
}

/// A divergence resolved by keeping the cloud version and saving the local edit.
#[derive(Serialize, Debug, PartialEq)]
pub struct Conflict {
    pub name: String,
    pub conflict_copy: String,
}

/// Outcome of one sync pass.
#[derive(Serialize, Default, Debug)]
pub struct SyncReport {
    pub pushed: Vec<String>,
    pub pulled: Vec<String>,
    pub conflicts: Vec<Conflict>,
    pub errors: Vec<String>,
}

/// Cloud side of sync, abstracted so the engine is testable without a network.
pub trait CloudStore {
    /// All drive-managed artifacts owned by the caller.
    fn list_drive(&mut self) -> Result<Vec<CloudArtifact>, String>;
    /// Upload `bytes` as a new version described by `manifest`; returns its URI.
    fn upload(&mut self, name: &str, bytes: &[u8], manifest: &ArtifactManifest) -> Result<String, String>;
    /// Fetch an artifact's bytes by URI.
    fn download(&mut self, uri: &str) -> Result<Vec<u8>, String>;
}

/// Local filesystem side of sync, abstracted for the same reason.
pub trait LocalStore {
    fn read(&self, path: &str) -> Result<Vec<u8>, String>;
    fn write(&self, path: &str, bytes: &[u8]) -> Result<(), String>;
    fn exists(&self, path: &str) -> bool;
}

/// Hex SHA-256 of `bytes`, the content identity used throughout sync.
pub fn content_hash(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    format!("{:x}", h.finalize())
}

/// Run one sync pass. `tracked_paths` are the local files drive manages this
/// run; `drive_dir` is where cloud-only projects are materialized. `device_id`
/// and `now_iso` are supplied by the caller (kept out of the engine so it stays
/// deterministic and unit-testable).
pub fn sync(
    cloud: &mut dyn CloudStore,
    local: &dyn LocalStore,
    state: &mut SyncState,
    tracked_paths: &[String],
    drive_dir: &str,
    device_id: &str,
    now_iso: &str,
) -> SyncReport {
    let mut report = SyncReport::default();

    // Cloud current = highest version per project id.
    let listed = match cloud.list_drive() {
        Ok(l) => l,
        Err(e) => {
            report.errors.push(format!("list cloud: {e}"));
            return report;
        }
    };
    let current = current_by_uuid(listed);

    let mut handled: HashSet<String> = HashSet::new();

    for path in tracked_paths {
        let bytes = match local.read(path) {
            Ok(b) => b,
            Err(e) => {
                report.errors.push(format!("read {path}: {e}"));
                continue;
            }
        };
        let lhash = content_hash(&bytes);
        let name = file_name_of(path);

        match state.entries.get(path).cloned() {
            None => {
                // A new local file becomes a new project at version 1.
                let proj_uuid = new_uuid();
                let manifest = ArtifactManifest {
                    proj_uuid: proj_uuid.clone(),
                    name: name.clone(),
                    version: 1,
                    parent_version: 0,
                    content_hash: lhash.clone(),
                    device: device_id.to_owned(),
                    mtime: now_iso.to_owned(),
                };
                match cloud.upload(&name, &bytes, &manifest) {
                    Ok(_uri) => {
                        handled.insert(proj_uuid.clone());
                        state.entries.insert(
                            path.clone(),
                            TrackedEntry { proj_uuid, name: name.clone(), base_version: 1, base_hash: lhash },
                        );
                        report.pushed.push(name);
                    }
                    Err(e) => report.errors.push(format!("push {name}: {e}")),
                }
            }
            Some(entry) => {
                handled.insert(entry.proj_uuid.clone());
                let cloud_cur = current.get(&entry.proj_uuid);
                let local_changed = lhash != entry.base_hash;
                let cloud_changed = match cloud_cur {
                    Some(c) => c.manifest.version > entry.base_version || c.manifest.content_hash != entry.base_hash,
                    None => false,
                };

                match (local_changed, cloud_changed) {
                    (false, false) => {} // synced
                    (true, false) => {
                        let next = cloud_cur.map(|c| c.manifest.version).unwrap_or(entry.base_version) + 1;
                        let manifest = ArtifactManifest {
                            proj_uuid: entry.proj_uuid.clone(),
                            name: name.clone(),
                            version: next,
                            parent_version: entry.base_version,
                            content_hash: lhash.clone(),
                            device: device_id.to_owned(),
                            mtime: now_iso.to_owned(),
                        };
                        match cloud.upload(&name, &bytes, &manifest) {
                            Ok(_uri) => {
                                set_base(state, path, next, &lhash);
                                report.pushed.push(name);
                            }
                            Err(e) => report.errors.push(format!("push {name}: {e}")),
                        }
                    }
                    (false, true) => {
                        let c = cloud_cur.expect("cloud_changed implies a current version");
                        match cloud.download(&c.uri) {
                            Ok(cb) => match local.write(path, &cb) {
                                Ok(()) => {
                                    set_base(state, path, c.manifest.version, &c.manifest.content_hash);
                                    report.pulled.push(name);
                                }
                                Err(e) => report.errors.push(format!("write {path}: {e}")),
                            },
                            Err(e) => report.errors.push(format!("pull {name}: {e}")),
                        }
                    }
                    (true, true) => {
                        let c = cloud_cur.expect("cloud_changed implies a current version");
                        match cloud.download(&c.uri) {
                            Ok(cb) => {
                                // Preserve the local edit before the cloud version
                                // overwrites the canonical path.
                                let copy = conflict_path(path, device_id, now_iso);
                                if let Err(e) = local.write(&copy, &bytes) {
                                    report.errors.push(format!("save conflict copy {copy}: {e}"));
                                }
                                match local.write(path, &cb) {
                                    Ok(()) => {
                                        set_base(state, path, c.manifest.version, &c.manifest.content_hash);
                                        report.conflicts.push(Conflict { name, conflict_copy: copy });
                                    }
                                    Err(e) => report.errors.push(format!("write {path}: {e}")),
                                }
                            }
                            Err(e) => report.errors.push(format!("pull {name}: {e}")),
                        }
                    }
                }
            }
        }
    }

    // Cloud projects with no local tracking are materialized into drive_dir.
    let mut cloud_only: Vec<&CloudArtifact> = current
        .iter()
        .filter(|(uuid, _)| !handled.contains(*uuid) && !state.entries.values().any(|e| &e.proj_uuid == *uuid))
        .map(|(_, art)| art)
        .collect();
    cloud_only.sort_by(|a, b| a.manifest.name.cmp(&b.manifest.name)); // stable order
    for art in cloud_only {
        let dest = join_path(drive_dir, &art.manifest.name);
        match cloud.download(&art.uri) {
            Ok(cb) => match local.write(&dest, &cb) {
                Ok(()) => {
                    state.entries.insert(
                        dest,
                        TrackedEntry {
                            proj_uuid: art.manifest.proj_uuid.clone(),
                            name: art.manifest.name.clone(),
                            base_version: art.manifest.version,
                            base_hash: art.manifest.content_hash.clone(),
                        },
                    );
                    report.pulled.push(art.manifest.name.clone());
                }
                Err(e) => report.errors.push(format!("write {}: {e}", art.manifest.name)),
            },
            Err(e) => report.errors.push(format!("pull {}: {e}", art.manifest.name)),
        }
    }

    report
}

/// A project's sync state for display, without mutating anything.
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct ProjectStatus {
    pub name: String,
    pub proj_uuid: String,
    pub status: String,
    pub local_version: u64,
    pub cloud_version: u64,
}

/// Read-only status view used by the list tool. `local_hashes` maps each tracked
/// local path to its current content hash (a path absent from the map means the
/// file is gone and is treated as unchanged — status never implies a deletion).
/// Source `local_hashes` from the same scan that feeds `sync`'s tracked paths so
/// the displayed status and the next sync pass agree on what is tracked.
pub fn compute_status(
    listed: Vec<CloudArtifact>,
    state: &SyncState,
    local_hashes: &HashMap<String, String>,
) -> Vec<ProjectStatus> {
    let current = current_by_uuid(listed);
    let mut rows: Vec<ProjectStatus> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    for (path, entry) in &state.entries {
        seen.insert(entry.proj_uuid.clone());
        let cloud_cur = current.get(&entry.proj_uuid);
        let cloud_version = cloud_cur.map(|c| c.manifest.version).unwrap_or(0);
        let cloud_changed = cloud_cur
            .map(|c| c.manifest.version > entry.base_version || c.manifest.content_hash != entry.base_hash)
            .unwrap_or(false);
        let local_changed = local_hashes.get(path).map(|h| h != &entry.base_hash).unwrap_or(false);
        let status = match (local_changed, cloud_changed) {
            (true, true) => "conflict",
            (true, false) => "local_ahead",
            (false, true) => "cloud_ahead",
            (false, false) => "synced",
        };
        rows.push(ProjectStatus {
            name: entry.name.clone(),
            proj_uuid: entry.proj_uuid.clone(),
            status: status.to_owned(),
            local_version: entry.base_version,
            cloud_version,
        });
    }

    for path in local_hashes.keys() {
        if state.entries.contains_key(path) {
            continue;
        }
        rows.push(ProjectStatus {
            name: file_name_of(path),
            proj_uuid: String::new(),
            status: "local_only".to_owned(),
            local_version: 0,
            cloud_version: 0,
        });
    }

    for (uuid, art) in &current {
        if seen.contains(uuid) {
            continue;
        }
        rows.push(ProjectStatus {
            name: art.manifest.name.clone(),
            proj_uuid: uuid.clone(),
            status: "cloud_only".to_owned(),
            local_version: 0,
            cloud_version: art.manifest.version,
        });
    }

    rows.sort_by(|a, b| a.name.cmp(&b.name));
    rows
}

/// Reduce a flat artifact list to the current (highest-version) one per project.
fn current_by_uuid(listed: Vec<CloudArtifact>) -> HashMap<String, CloudArtifact> {
    let mut current: HashMap<String, CloudArtifact> = HashMap::new();
    for art in listed {
        current
            .entry(art.manifest.proj_uuid.clone())
            .and_modify(|cur| {
                if art.manifest.version > cur.manifest.version {
                    *cur = art.clone();
                }
            })
            .or_insert(art);
    }
    current
}

fn set_base(state: &mut SyncState, path: &str, version: u64, hash: &str) {
    if let Some(e) = state.entries.get_mut(path) {
        e.base_version = version;
        e.base_hash = hash.to_owned();
    }
}

fn file_name_of(path: &str) -> String {
    path.rsplit(['/', '\\']).next().unwrap_or(path).to_owned()
}

fn join_path(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_owned()
    } else if dir.ends_with('/') || dir.ends_with('\\') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

fn conflict_path(path: &str, device_id: &str, now_iso: &str) -> String {
    let stamp = now_iso.replace(':', "-");
    format!("{path}.conflict-{device_id}-{stamp}")
}

fn new_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// Real adapters bridging the engine traits to the artifact client and disk.
// ─────────────────────────────────────────────────────────────────────────────

/// `CloudStore` backed by a live `ArtifactClient`. The manifest rides in the
/// artifact description; the `drive` tag scopes `list-mine` to managed files.
pub struct ArtifactCloudStore<'a> {
    pub client: &'a mut ArtifactClient,
}

impl CloudStore for ArtifactCloudStore<'_> {
    fn list_drive(&mut self) -> Result<Vec<CloudArtifact>, String> {
        let metas = self.client.list_mine().map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for m in metas {
            if !m.tags.iter().any(|t| t == DRIVE_TAG) {
                continue;
            }
            let parsed: Result<ArtifactManifest, _> = serde_json::from_str(&m.description);
            if let Ok(manifest) = parsed {
                out.push(CloudArtifact { uri: m.artifact_uri, manifest });
            }
        }
        Ok(out)
    }

    fn upload(&mut self, name: &str, bytes: &[u8], manifest: &ArtifactManifest) -> Result<String, String> {
        let description = serde_json::to_string(manifest).map_err(|e| e.to_string())?;
        let tags = vec![DRIVE_TAG.to_owned()];
        self.client
            .upload(name, bytes, "private", &tags, &description)
            .map(|r| r.uri)
            .map_err(|e| e.to_string())
    }

    fn download(&mut self, uri: &str) -> Result<Vec<u8>, String> {
        self.client.download(uri).map(|d| d.bytes).map_err(|e| e.to_string())
    }
}

/// `LocalStore` backed by the real filesystem.
pub struct DiskLocalStore;

impl LocalStore for DiskLocalStore {
    fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        std::fs::read(path).map_err(|e| e.to_string())
    }

    fn write(&self, path: &str, bytes: &[u8]) -> Result<(), String> {
        if let Some(parent) = std::path::Path::new(path).parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
        }
        std::fs::write(path, bytes).map_err(|e| e.to_string())
    }

    fn exists(&self, path: &str) -> bool {
        std::path::Path::new(path).exists()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct FakeCloud {
        arts: Vec<CloudArtifact>,
        blobs: HashMap<String, Vec<u8>>,
        uploads: usize,
    }

    impl FakeCloud {
        fn preload(&mut self, uri: &str, bytes: &[u8], m: ArtifactManifest) {
            self.blobs.insert(uri.to_owned(), bytes.to_vec());
            self.arts.push(CloudArtifact { uri: uri.to_owned(), manifest: m });
        }
    }

    impl CloudStore for FakeCloud {
        fn list_drive(&mut self) -> Result<Vec<CloudArtifact>, String> {
            Ok(self.arts.clone())
        }
        fn upload(&mut self, _name: &str, bytes: &[u8], manifest: &ArtifactManifest) -> Result<String, String> {
            self.uploads += 1;
            let uri = format!("artifact://{}/{}", new_uuid(), manifest.name);
            self.blobs.insert(uri.clone(), bytes.to_vec());
            self.arts.push(CloudArtifact { uri: uri.clone(), manifest: manifest.clone() });
            Ok(uri)
        }
        fn download(&mut self, uri: &str) -> Result<Vec<u8>, String> {
            self.blobs.get(uri).cloned().ok_or_else(|| format!("no blob {uri}"))
        }
    }

    #[derive(Default)]
    struct FakeLocal {
        files: RefCell<HashMap<String, Vec<u8>>>,
    }

    impl FakeLocal {
        fn set(&self, path: &str, bytes: &[u8]) {
            self.files.borrow_mut().insert(path.to_owned(), bytes.to_vec());
        }
        fn get(&self, path: &str) -> Option<Vec<u8>> {
            self.files.borrow().get(path).cloned()
        }
    }

    impl LocalStore for FakeLocal {
        fn read(&self, path: &str) -> Result<Vec<u8>, String> {
            self.get(path).ok_or_else(|| format!("no file {path}"))
        }
        fn write(&self, path: &str, bytes: &[u8]) -> Result<(), String> {
            self.set(path, bytes);
            Ok(())
        }
        fn exists(&self, path: &str) -> bool {
            self.files.borrow().contains_key(path)
        }
    }

    fn manifest(uuid: &str, name: &str, ver: u64, bytes: &[u8]) -> ArtifactManifest {
        ArtifactManifest {
            proj_uuid: uuid.to_owned(),
            name: name.to_owned(),
            version: ver,
            parent_version: ver.saturating_sub(1),
            content_hash: content_hash(bytes),
            device: "other".to_owned(),
            mtime: "2026-01-01T00:00:00".to_owned(),
        }
    }

    #[test]
    fn new_local_file_is_pushed_as_v1() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        local.set("/p/a.txt", b"hello");
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };

        let r = sync(&mut cloud, &local, &mut state, &["/p/a.txt".into()], "/p", "dev1", "2026-06-22T00:00:00");

        assert_eq!(r.pushed, vec!["a.txt"]);
        assert!(r.conflicts.is_empty() && r.errors.is_empty());
        assert_eq!(cloud.uploads, 1);
        let entry = state.entries.get("/p/a.txt").unwrap();
        assert_eq!(entry.base_version, 1);
        assert_eq!(entry.base_hash, content_hash(b"hello"));
    }

    #[test]
    fn unchanged_is_noop() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        local.set("/p/a.txt", b"hello");
        cloud.preload("artifact://x/a.txt", b"hello", manifest("u1", "a.txt", 1, b"hello"));
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };
        state.entries.insert(
            "/p/a.txt".into(),
            TrackedEntry { proj_uuid: "u1".into(), name: "a.txt".into(), base_version: 1, base_hash: content_hash(b"hello") },
        );

        let r = sync(&mut cloud, &local, &mut state, &["/p/a.txt".into()], "/p", "dev1", "2026-06-22T00:00:00");

        assert!(r.pushed.is_empty() && r.pulled.is_empty() && r.conflicts.is_empty() && r.errors.is_empty());
        assert_eq!(cloud.uploads, 0);
    }

    #[test]
    fn local_ahead_pushes_next_version() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        local.set("/p/a.txt", b"edited");
        cloud.preload("artifact://x/a.txt", b"hello", manifest("u1", "a.txt", 1, b"hello"));
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };
        state.entries.insert(
            "/p/a.txt".into(),
            TrackedEntry { proj_uuid: "u1".into(), name: "a.txt".into(), base_version: 1, base_hash: content_hash(b"hello") },
        );

        let r = sync(&mut cloud, &local, &mut state, &["/p/a.txt".into()], "/p", "dev1", "2026-06-22T00:00:00");

        assert_eq!(r.pushed, vec!["a.txt"]);
        assert_eq!(cloud.uploads, 1);
        let entry = state.entries.get("/p/a.txt").unwrap();
        assert_eq!(entry.base_version, 2);
        assert_eq!(entry.base_hash, content_hash(b"edited"));
    }

    #[test]
    fn cloud_ahead_pulls() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        local.set("/p/a.txt", b"hello");
        // Cloud has a newer version 2.
        cloud.preload("artifact://x2/a.txt", b"newer", manifest("u1", "a.txt", 2, b"newer"));
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };
        state.entries.insert(
            "/p/a.txt".into(),
            TrackedEntry { proj_uuid: "u1".into(), name: "a.txt".into(), base_version: 1, base_hash: content_hash(b"hello") },
        );

        let r = sync(&mut cloud, &local, &mut state, &["/p/a.txt".into()], "/p", "dev1", "2026-06-22T00:00:00");

        assert_eq!(r.pulled, vec!["a.txt"]);
        assert_eq!(local.get("/p/a.txt").unwrap(), b"newer");
        let entry = state.entries.get("/p/a.txt").unwrap();
        assert_eq!(entry.base_version, 2);
        assert_eq!(entry.base_hash, content_hash(b"newer"));
    }

    #[test]
    fn divergence_keeps_cloud_and_saves_conflict_copy() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        local.set("/p/a.txt", b"local-edit"); // local changed
        cloud.preload("artifact://x2/a.txt", b"cloud-edit", manifest("u1", "a.txt", 2, b"cloud-edit")); // cloud changed
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };
        state.entries.insert(
            "/p/a.txt".into(),
            TrackedEntry { proj_uuid: "u1".into(), name: "a.txt".into(), base_version: 1, base_hash: content_hash(b"base") },
        );

        let r = sync(&mut cloud, &local, &mut state, &["/p/a.txt".into()], "/p", "dev1", "2026-06-22T00:00:00");

        assert_eq!(r.conflicts.len(), 1);
        assert!(r.pushed.is_empty());
        // Canonical path now holds the cloud version.
        assert_eq!(local.get("/p/a.txt").unwrap(), b"cloud-edit");
        // The local edit is preserved as a conflict copy.
        let copy = &r.conflicts[0].conflict_copy;
        assert_eq!(local.get(copy).unwrap(), b"local-edit");
        let entry = state.entries.get("/p/a.txt").unwrap();
        assert_eq!(entry.base_version, 2);
        assert_eq!(entry.base_hash, content_hash(b"cloud-edit"));
    }

    #[test]
    fn cloud_only_project_is_materialized() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        cloud.preload("artifact://z/b.txt", b"remote", manifest("u9", "b.txt", 3, b"remote"));
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };

        let r = sync(&mut cloud, &local, &mut state, &[], "/drive", "dev1", "2026-06-22T00:00:00");

        assert_eq!(r.pulled, vec!["b.txt"]);
        assert_eq!(local.get("/drive/b.txt").unwrap(), b"remote");
        let entry = state.entries.get("/drive/b.txt").unwrap();
        assert_eq!(entry.proj_uuid, "u9");
        assert_eq!(entry.base_version, 3);
    }

    #[test]
    fn compute_status_classifies_each_case() {
        // Cloud has u1 (current v2) and a cloud-only u9.
        let listed = vec![
            CloudArtifact { uri: "a".into(), manifest: manifest("u1", "a.txt", 2, b"cloudv2") },
            CloudArtifact { uri: "b".into(), manifest: manifest("u9", "remote.txt", 5, b"remote") },
        ];
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };
        // a.txt: base v1/hash(base) — local edited and cloud advanced -> conflict.
        state.entries.insert(
            "/p/a.txt".into(),
            TrackedEntry { proj_uuid: "u1".into(), name: "a.txt".into(), base_version: 1, base_hash: content_hash(b"base") },
        );

        let mut local_hashes = HashMap::new();
        local_hashes.insert("/p/a.txt".to_owned(), content_hash(b"localedit")); // != base -> local changed
        local_hashes.insert("/p/new.txt".to_owned(), content_hash(b"fresh")); // untracked -> local_only

        let rows = compute_status(listed, &state, &local_hashes);
        let by_name = |n: &str| rows.iter().find(|r| r.name == n).cloned();

        let a = by_name("a.txt").expect("a.txt row");
        assert_eq!(a.status, "conflict");
        assert_eq!(a.local_version, 1);
        assert_eq!(a.cloud_version, 2);

        assert_eq!(by_name("new.txt").unwrap().status, "local_only");

        let remote = by_name("remote.txt").expect("cloud-only row");
        assert_eq!(remote.status, "cloud_only");
        assert_eq!(remote.cloud_version, 5);
    }

    // Live end-to-end check of the real cloud adapter against the artifact
    // service. Opt-in via DRIVE_LIVE_TEST=1 so the default suite stays offline.
    // Proves the manifest round-trips through the artifact description and that
    // the drive tag scopes list-mine; cleans up the artifact it creates.
    #[test]
    fn live_cloud_store_round_trip() {
        if std::env::var("DRIVE_LIVE_TEST").is_err() {
            return;
        }
        use crate::artifact_client::{ArtifactClient, Credentials};
        use std::time::Duration;

        let login_url = env_or("DRIVE_LOGIN_URL", "https://www.turnrock.ai:4040/v1/login");
        let ws_url = env_or("DRIVE_WS_URL", "wss://www.turnrock.ai:27500/connect");
        let user = env_or("DRIVE_USER", "test");
        let pass = env_or("DRIVE_PASS", "test");

        let body = serde_json::json!({ "username": user, "password": pass }).to_string();
        let resp = ureq::post(&login_url)
            .set("Content-Type", "application/json")
            .send_string(&body)
            .expect("login request");
        let login: serde_json::Value = resp.into_json().expect("login json");
        let token = login["data"]["token"].as_str().expect("token").to_owned();
        let client_id = jwt_sub(&token);

        let creds = Credentials { ws_url, token, client_id };
        let mut client =
            ArtifactClient::connect(creds, Duration::from_secs(30), Duration::from_secs(10)).expect("connect");

        let proj = new_uuid();
        let name = format!("drive-e2e-{proj}.txt");
        let bytes = format!("e2e {proj}").into_bytes();
        let m = ArtifactManifest {
            proj_uuid: proj.clone(),
            name: name.clone(),
            version: 1,
            parent_version: 0,
            content_hash: content_hash(&bytes),
            device: "e2e".to_owned(),
            mtime: "0".to_owned(),
        };

        // Drive the engine's cloud interface, then drop the borrow before cleanup.
        let uri = {
            let mut store = ArtifactCloudStore { client: &mut client };
            let uri = store.upload(&name, &bytes, &m).expect("upload");
            let listed = store.list_drive().expect("list_drive");
            let found = listed.iter().find(|a| a.uri == uri).expect("uploaded artifact in list_drive");
            assert_eq!(found.manifest.proj_uuid, proj);
            assert_eq!(found.manifest.content_hash, content_hash(&bytes));
            let got = store.download(&uri).expect("download");
            assert_eq!(got, bytes, "downloaded bytes must match uploaded");
            uri
        };

        client.delete(&uri).expect("delete");
        println!("live_cloud_store_round_trip OK — uri={uri}");
    }

    fn env_or(key: &str, default: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| default.to_owned())
    }

    fn jwt_sub(token: &str) -> String {
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        use base64::Engine as _;
        let payload = token.split('.').nth(1).expect("jwt payload segment");
        let bytes = URL_SAFE_NO_PAD.decode(payload).expect("jwt base64");
        let claims: serde_json::Value = serde_json::from_slice(&bytes).expect("jwt claims");
        claims["sub"].as_str().expect("sub claim").to_owned()
    }

    #[test]
    fn highest_version_wins_as_current() {
        let mut cloud = FakeCloud::default();
        let local = FakeLocal::default();
        local.set("/p/a.txt", b"hello");
        // Two versions present out of order; v2 is current.
        cloud.preload("artifact://v2/a.txt", b"v2", manifest("u1", "a.txt", 2, b"v2"));
        cloud.preload("artifact://v1/a.txt", b"v1", manifest("u1", "a.txt", 1, b"v1"));
        let mut state = SyncState { device_id: "dev1".into(), ..Default::default() };
        state.entries.insert(
            "/p/a.txt".into(),
            TrackedEntry { proj_uuid: "u1".into(), name: "a.txt".into(), base_version: 1, base_hash: content_hash(b"hello") },
        );

        let r = sync(&mut cloud, &local, &mut state, &["/p/a.txt".into()], "/p", "dev1", "2026-06-22T00:00:00");

        assert_eq!(r.pulled, vec!["a.txt"]);
        assert_eq!(local.get("/p/a.txt").unwrap(), b"v2");
    }
}
