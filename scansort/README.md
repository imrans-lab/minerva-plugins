# Scansort Plugin

Scansort is a Minerva plugin for classifying scanned documents into encrypted
vaults using LLM-assisted rules.

## Build (local development)

```bash
cd scansort
cargo build --release
# Binary is target/release/scansort-plugin — side-load via the manifest path.
```

Run the test suite:

```bash
cargo test --release
```

## Release (per-platform binaries)

Push an annotated tag matching `scansort-v<MAJOR>.<MINOR>.<PATCH>`:

```bash
git tag -a scansort-v0.1.0 -m "scansort 0.1.0"
git push <remote> scansort-v0.1.0
```

GitHub Actions (`.github/workflows/scansort.yml`) builds for all 4 targets
(linux-x86_64, linux-arm64, macos-universal, windows-x86_64) and publishes a
GitHub Release with tarballs named `scansort-<version>-<target>.tar.gz`. Each
tarball contains the binary, `manifest.json`, and a `SHA256SUMS` sidecar.

After the release lands, regenerate the marketplace index and commit it:

```bash
python3 scripts/regen_registry.py
git add registry.json
git commit -m "registry: scansort 0.1.0"
```

The drift-check CI (`registry-check.yml`) verifies the committed
`registry.json` matches generator output.

## Install in Minerva

**Side-load (development):** point Minerva's Plugin Manager at the local
`manifest.json` path.

**Marketplace (end-users):** Minerva fetches
`raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json`,
locates the scansort entry, and downloads the matching tarball from the
GitHub Release. (Marketplace UI work tracked under a separate DCR.)

## Architecture

- `src/main.rs` — Rust JSON-RPC 2.0 MCP server (synchronous stdio transport)
- `ui/ScansortPanel.tscn` + `ui/ScansortPanel.gd` — Godot scene panel
- `manifest.json` — plugin manifest; `backend.entrypoint = "./scansort-plugin"`
