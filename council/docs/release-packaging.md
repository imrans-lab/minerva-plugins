# Council — the release archive and how it gets advertised

This is the packaging lane: what CI builds, what the archive holds, and the
order the tag, the release and the registry have to happen in. It is a
procedure, not an evidence record — the evidence lives in
`release-validation.md`.

---

## 1. The two install lanes

| Lane | What the user needs | What the manifest contributes |
|---|---|---|
| Source (development) | A checkout, Go 1.22+ | `setup` runs `go build -o council-plugin ./` beside the manifest |
| Marketplace | Nothing but Minerva | The archive carries the built binary; the packed manifest has **no** `setup` |

They are independent on purpose. The repository manifest describes how to build
Council from source; the archive ships that build's output and no source, so a
host that ran the `setup` stanza against an extracted archive would try to
compile a package that was never packed. `scripts/pack-release.sh` removes
`setup` **before** `SHA256SUMS` is written, so the checksum covers the file that
actually ships and a recipient can verify the manifest they will run.

## 2. What is in the archive

`council-<manifest.version>-<target>.tar.gz`, every member at the archive
**root** — the host extracts it straight into the plugin directory, so a
wrapping folder would put `manifest.json` one level below where the installer
looks.

| Archive path | Where it comes from | Why it ships |
|---|---|---|
| `council-plugin` | the target's `go build` output | `backend.entrypoint`, verbatim. The host starts exactly this path. |
| `manifest.json` | the repository manifest, minus `setup` | what the host mounts the plugin from |
| `ui/CouncilPanel.tscn` | `ui.panels[0].entry_scene` | the scene the panel instantiates |
| `ui/council_panel.gd`, `council_record.gd`, `council_backend.gd`, `council_bridge.gd` | `ui.panels[0].scripts` | the host audits the scene against this list; an undeclared script makes the panel refuse to instantiate |
| `ui/panel.html` | generated from `ui/src` by `ui/build.mjs` | the page `council_bridge.gd` stages and loads as a `file://` URL. The manifest does not name it file-by-file, so the pack script names it. |
| `schemas/*.json` | `council/schemas` | also embedded in the binary; shipped beside it so the record format can be read and checked without running anything |
| `presets/*.json` | `council/presets` | the shipped councils, likewise embedded and likewise readable |
| `docs/architecture.md`, `README.md` | `council/docs`, `council/README.md` | the text a recipient needs and cannot get from a checkout they do not have. docs/ is an explicit list, not a glob: the rest of it — this file, the validation record — is maintainer text with no reader on an installed machine, and `verify-archive.py` asserts the shipped set exactly. |
| `LICENSE.md` | the repository root | covers all of the above; there is no third-party notice to carry, because the backend depends on nothing outside the Go standard library and the page loads nothing at runtime |
| `SHA256SUMS` | generated last | one `<sha256>  <path>` line for every other file, in `sha256sum -c` format |

The tarball is **reproducible** — the same tree packs to the same bytes on any
machine at any time, so two builds of one commit can be compared rather than
trusted. Every flag closes one channel by which the build machine leaks in:

| | |
|---|---|
| `LC_ALL=C` on the `find`/`sort`/`xargs` pipeline **and** on `tar` | both `sort` and `--sort=name` collate by locale, so `en_US.UTF-8` and `C` produce different `SHA256SUMS` line orders and different member orders — and `SHA256SUMS` is itself hashed into the archive |
| `--sort=name` | fixes member order against readdir order |
| `--mtime=@0` | erases the staging tree's timestamps |
| `--owner=0 --group=0 --numeric-owner` | erases the building user |
| `--mode=u+rwX,go+rX,go-w` | erases the checkout's umask — a file copied out of a working tree is 664 under `umask 002` and 644 under `022`, and tar records the mode. `X` keeps the entrypoint executable. |
| `gzip -n` rather than `tar -z` | `-z` writes the filename and the current time into the gzip header, which on its own makes every archive unique |
| `go build -trimpath` | keeps the builder's absolute module path out of the binary, so the payload is comparable too |

**Not** in the archive: `ui/src/` and `ui/tests/` (the panel's build sources and
its screenshot harness — roughly 3 MB the panel never reads), any `.go` file,
and the maintainer documents above. The panel's own files are taken from the manifest rather than listed, so a
newly declared script ships without editing the pack script, and a file that
merely sits in `ui/` cannot ship by accident.

## 3. The gate

`scripts/verify-archive.py` is the only thing standing between a packed archive
and a published one, so it carries its own falsifiers: having verified the
extracted tree, it corrupts one byte and deletes one file, and fails if either
goes unnoticed. It refuses a member that walks out of its
destination, and proves that refusal on `../evil`, `./../evil`, `/etc/evil` and
`ui/../../evil` — a naive `lstrip("./")` rewrites the first into a valid-looking
name while tar still writes it by its original one. It also drives the shared
MCP smoke against the **packed** binary from a directory holding nothing but the
extracted archive, with `go` and `node` off `PATH` — which is the claim the
marketplace lane actually makes.

Locally:

```bash
cd council
go build -trimpath -o build/council-plugin .
bash scripts/pack-release.sh linux-x86_64 build/council-plugin dist
python3 scripts/verify-archive.py \
  "dist/$(bash scripts/pack-release.sh --print-name linux-x86_64)" \
  --smoke ../scripts/smoke/mcp_smoke.py
```

## 3a. What CI runs

`.github/workflows/council.yml` has four jobs. `test` (gofmt, `go vet`,
`go test -race`, `node ui/build.mjs --check`, and the release-parity tests from
`scripts/test_registry.py`), `package` (build, pack, verify), `panel` (the GD
suite-registry preflight against a pinned Minerva — it executes nothing) and
`release`, which needs all three.

The parity tests run in `test` and not only in `registry-check`, because
`registry-check`'s path filters cover `registry.json`, `*/manifest.json` and
`scripts/*registry*.py` — so an edit to this workflow's matrix or to
`pack-release.sh`, the two things those tests exist to hold, would never trigger
the job that runs them.

## 4. Targets

`release_targets` in `manifest.json` declares **linux-x86_64 only**, and
`.github/workflows/council.yml`'s matrix builds exactly that.
`scripts/test_registry.py` holds the two to each other in both directions: the
registry advertises one download URL per declared target, so a target declared
and not built is a 404 at install time, and a target built and not declared is
an asset nothing points at.

Adding a target is not an edit to either list. Council's panel is a CEF surface
and its binary has been exercised on Linux alone; a second target needs the
archive verified and the panel opened on that platform first.

## 5. The tag → release → registry sequence

`registry.json` is generated **from tags**, so it can only ever describe a
release that already exists. The order is fixed:

1. **Merge to `main`.** The `council` workflow runs `test` and `package` on the
   push. Nothing is tagged yet.
2. **CI computes the tag** in the `release` job. While
   `COUNCIL_STABLE_RELEASE` is `false`, every push (including `main`) produces
   `council-v<version>-branch-<branch>` with `prerelease: true`. Artifacts and
   staging installs remain available; the public registry skips these tags.
   Enable the checked-in gate only after T13 and real-model/desktop acceptance
   are recorded. Then `main` publishes `council-v<manifest.version>`; other
   branches remain prereleases. `scripts/release-publish-guard.sh` refuses to move an existing
   stable tag — a re-run of the same commit keeps the release it already
   published, and a new release means bumping `version` in the manifest.
3. **CI publishes the GitHub Release** and uploads
   `council-<version>-linux-x86_64.tar.gz` to it. This is the point at which the
   tag exists.
4. **Regenerate the registry, locally, afterwards:**

   ```bash
   git fetch --tags
   python3 scripts/regen_registry.py
   git add registry.json && git commit
   ```

5. **`registry-check` validates the committed selection** —
   `regen_registry.py --check --published` re-derives every entry from its
   tagged manifest and asks GitHub whether each advertised asset is uploaded and
   non-empty.

Two properties make this ordering survivable, and both are held by tests:

- **A branch build can never be advertised.** `latest_tag_for` skips any tag
  containing `-branch-`, and `build_plugin_entry` refuses one outright.
- **Council being in `PLUGIN_DIRS` before its first tag exists is not an error.**
  `build_plugin_entry` returns `None` for a plugin with no tag, so
  `build_registry` skips it and `check_registry` — which walks the *committed
  registry*, not the directory list — never looks for it. That is what stops the
  window between "council joins the generator" and "council's first release
  exists" from being a permanently red drift check. `registry.json` is therefore
  **not** edited as part of adding the workflow; it is regenerated at step 4,
  once, after the first release.
