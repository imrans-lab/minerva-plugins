# plugins

A repo of plugins for [Minerva](https://github.com/turnrocklabs/Minerva) and other agentic platforms that speak the same plugin manifest contract.

## Layout

Each plugin lives in its own top-level directory containing a `manifest.json` and whatever code/assets the plugin needs.

```
plugins/
├── LICENSE.md
├── README.md
└── <plugin_id>/
    ├── manifest.json
    └── ...
```

## Installing a plugin into Minerva

Minerva discovers plugins by manifest path — no in-tree presence required:

```gdscript
PluginDB.install("/absolute/path/to/plugins/<plugin_id>/manifest.json")
```

The plugin's `data_directory` is derived from the manifest's parent directory.

## Plugins

_None yet — this repo is freshly initialized._

| Plugin | Status | Description |
| --- | --- | --- |
| `cad` | planned | Parametric B-Rep CAD via the `.mcad` DSL. Go MCP shim + Python (build123d/OCCT) worker; 4-view CADEditor panel. Tracking: Minerva DCR `019dc054a4`. |

## Before pushing

Scan the exact outgoing commit range for credentials. This catches a secret that
was committed and removed again inside the same range, which a working-tree scan
cannot see:

```bash
scripts/scan-secret-history.sh --range "$(git merge-base origin/main HEAD)..HEAD"
```

The same scan runs in CI on every pull request and on pushes to `main`;
`--all-history` re-scans everything and is also what a manual CI run does.

## Dependency updates

`.github/dependabot.yml` schedules weekly update PRs for GitHub Actions (the
workflows and the `pcb-setup` composite action) and the first-party Go, Rust,
and Python manifests. GitHub activates the schedule when the configuration
reaches the default branch. Updates go through normal PR review and the
applicable existing CI workflows; they are not auto-merged.

Dependabot does not update our custom `*/scripts/runtime-bundle.lock` files,
download URLs or versions embedded in scripts, or copied third-party source
under `vendored/`. When reviewing Python updates, reconcile the worker's
`pyproject.toml` with its release runtime-bundle pins and validate the bundled
runtime before merging. Updating the development manifest alone does not
update the shipped runtime. Review intentional geometry and output-format
pins against their compatibility tests and golden files. Dependabot updates
each Go module on its own and does not read `go.work`, so a bump in `shared`
may need matching bumps in the modules that use it.

Add new first-party manifest directories, and the directory of any new
composite action, to the configuration as they are introduced. Upstream
source vendored as a Git submodule can use Dependabot's `gitsubmodule`
ecosystem once such a submodule exists; plain copied source needs a separate
upstream-update process.

## License

See [LICENSE.md](LICENSE.md).
