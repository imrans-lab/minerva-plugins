# CAD Plugin for Minerva

The CAD plugin brings parametric boundary-representation modeling to Minerva
via the `.mcad` DSL. A Go MCP shim wraps a Python worker (build123d + OCCT)
that evaluates CAD scripts and returns B-Rep geometry. The Godot-based
CADPanel provides a 4-view editor with orbit camera, mesh display, and CAD
annotation host.

## Build (local development)

```bash
cd cad
CGO_ENABLED=0 go build -o cad-plugin .
# Side-load via the manifest path.
```

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

**Side-load (development):** point Minerva's Plugin Manager at the local
`manifest.json` path.

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
