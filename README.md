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

Before every commit run `scripts/check-fast` locally (Python/PyYAML and the pinned Go toolchain; no application builds, full suites or GATE-W).

After publishing, fetch tags and run `python3 scripts/verify-release.py <plugin-id> <tag>` to verify every target's GitHub digest, internal checksums and packed manifest against the tagged source. Use `--download-dir <directory>` to retain inputs, or `--local-dir <directory>` to verify saved `source.json`, GitHub `release.json` and archives offline. The default download directory is temporary. Docket's separate repository, sidecars and manifest transform are out of scope for v1. This command does not change the registry or publish anything.

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

## CI lanes

Branch pushes run build/import/link checks and a redacted outgoing-range secret
scan. Each concrete job has an explicit positive deadline. Ten minutes is the
branch timing optimization target, measured against actual runs.
`scripts/ci/check_push_lanes.py` checks every push workflow and local reusable
callee; functional suites and packaged-product probes are dispatch-only.

After review and outgoing-range scans, dispatch retained functional workflows
on the exact candidate alongside integration. Record results and fix failures
forward. Plain dispatches do not publish: release inputs default to false. For
example:

```sh
gh workflow run WORKFLOW.yml --ref CANDIDATE_BRANCH
```

Manual scans use a commit range (default `HEAD^..HEAD`, with explicit
`SECRET_SCAN_BASE`/`SECRET_SCAN_HEAD` available to the CI scan wrapper); they
never scan all history. Push scans use the event's before/after commits. New
branch scans start at the merge base with the target branch.

Dispatch each plugin workflow for its retained functional/package gates.
Runtime-producing packaging jobs stay on demand; their push source-build jobs
compile/link without executing the packaged worker. Compile-only bundle
placeholders are used where the module's existing developer recipe requires
them; real bundle construction and its probes remain mandatory on demand.

Tag-only release wrappers do not use the branch timing target and call the
same reusable build/package lane. Existing tag publication remains available;
branch pushes never execute those functional or publishing jobs. The lint also
checks local composite actions and warns when declared branch dependency
budgets exceed ten minutes. These timing warnings do not block release; FCIB,
functional-lane separation and secret scans remain enforced.
