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

## License

See [LICENSE.md](LICENSE.md).
