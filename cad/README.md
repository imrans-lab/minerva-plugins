# CAD Plugin for Minerva

The CAD plugin brings parametric boundary-representation modeling to Minerva
via the `.mcad` DSL. A Go MCP shim wraps a Python worker (build123d + OCCT)
that evaluates CAD scripts and returns B-Rep geometry. The Godot-based
CADPanel provides a 4-view editor with orbit camera, mesh display, and CAD
annotation host.

## Build (local development)

Source installs require Go 1.22+ and CPython 3.12. The worker currently declares
`>=3.12,<3.13`, so point Minerva's `python` toolchain override at a 3.12
interpreter when another Python is first on the GUI application's search path.

```bash
cd cad
python3.12 -m venv worker/.venv
worker/.venv/bin/python -m pip install -e worker
CGO_ENABLED=0 go build -o cad-plugin .
```

Normally Minerva performs those steps: side-loading `cad/manifest.json` creates
or refreshes the editable `worker/.venv`, then builds `cad-plugin`. The setup
pipeline runs on every manifest reinstall; pip and Go retain their own caches,
so unchanged reinstalls are incremental. The first worker install downloads
build123d and its compiled OCCT dependencies and can take several minutes.

The source-built wrapper deliberately prefers `worker/.venv` when it exists,
even if an embedded runtime from the same plugin version is already cached.
This makes a reinstall use the worker in the selected checkout. Marketplace
archives contain no source worker or setup stanza and continue to use the
runtime embedded in their release binary.

Run the test suite:

```bash
go test ./...
```

The bridge tests exercise the subprocess lifecycle and take ~20 seconds.

## Release (per-platform binaries)

Push an annotated tag matching `cad-v<MAJOR>.<MINOR>.<PATCH>`:

```bash
git tag -a cad-v0.2.0 -m "cad 0.2.0"
git push <remote> cad-v0.2.0
```

GitHub Actions (`.github/workflows/cad.yml`) builds for all 4 targets
(linux-x86_64, linux-arm64, macos-universal, windows-x86_64) and publishes a
GitHub Release with tarballs named `cad-<version>-<target>.tar.gz`. Each
tarball contains the binary, `manifest.json`, and a `SHA256SUMS` sidecar.

After the release lands, regenerate the marketplace index and commit it:

```bash
python3 scripts/regen_registry.py
git add registry.json
git commit -m "registry: cad 0.2.0"
```

## Install in Minerva

**Side-load (development):** install the local `cad/manifest.json` in Minerva's
Plugin Manager. Resolve any Go/Python preflight error, then wait for both setup
steps to finish before starting the plugin.

**Marketplace (end-users):** Minerva fetches
`raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json`
and downloads the matching tarball from the GitHub Release.

## Architecture

- **Go shim** (`internal/bridge/`) — MCP stdio server that launches and
  supervises the Python worker subprocess. Process-group teardown is split
  across `process_group_unix.go` and `process_group_windows.go` for
  cross-platform support.
- **Python worker** (`worker/mcad_worker/`) — build123d/OCCT evaluator;
  parses `.mcad` script, returns B-Rep mesh + metadata.
- **Godot UI panel** (`ui/CADPanel.gd`) — 4-view canvas with orbit camera,
  mesh display, and CAD annotation host.
- Full design: `Docs/design/Go-python-bridge-design.md` in the Minerva repo.

## License

See `../LICENSE.md` at the repository root.
