# Presentation Plugin for Minerva

The presentation plugin provides a slide-deck editor for Minerva, backed by
the `.mdeck` document format. A Go MCP server handles document state and
exposes editing tools; the Godot UI is a slide canvas with text, image, and
spreadsheet tiles plus per-tile annotations.

## Build (local development)

```bash
cd presentation
CGO_ENABLED=0 go build -o presentation-plugin .
# Side-load via the manifest path.
```

Run the test suite:

```bash
go test ./...
```

## Release (per-platform binaries)

Push an annotated tag matching `presentation-v<MAJOR>.<MINOR>.<PATCH>`:

```bash
git tag -a presentation-v0.1.0 -m "presentation 0.1.0"
git push <remote> presentation-v0.1.0
```

GitHub Actions (`.github/workflows/presentation.yml`) builds for all 4
targets (linux-x86_64, linux-arm64, macos-universal, windows-x86_64) and
publishes a GitHub Release with tarballs named
`presentation-<version>-<target>.tar.gz`. Each tarball contains the binary,
`manifest.json`, and a `SHA256SUMS` sidecar.

After the release lands, regenerate the marketplace index and commit it:

```bash
python3 scripts/regen_registry.py
git add registry.json
git commit -m "registry: presentation 0.1.0"
```

## Install in Minerva

**Side-load (development):** point Minerva's Plugin Manager at the local
`manifest.json` path.

**Marketplace (end-users):** Minerva fetches
`raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json`
and downloads the matching tarball from the GitHub Release.

## Architecture

- **Go MCP server** (`main.go`, `internal/`) — stdio JSON-RPC 2.0; tools for
  deck/slide/tile mutation.
- **Godot UI panel** (`ui/SlideEditorPanel.gd`) — slide canvas + tile
  inspector + annotation host.
- `.mdeck` documents — host-owned save format; opens via Minerva's editor
  framework.
- `manifest.json` — plugin manifest; `backend.entrypoint = "./presentation-plugin"`.

## License

See `../LICENSE.md` at the repository root.
