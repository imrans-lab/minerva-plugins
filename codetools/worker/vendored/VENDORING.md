# Vendored sources

Third-party / external code snapshotted into this directory at a pinned upstream
SHA. **Do not edit files under `vendored/`** — patches are tracked separately
(out-of-tree) so a refresh is a clean re-snapshot.

The codetools adapter handlers live in `worker/codetools_worker/` and import
*into* `vendored/...`; vendored modules are never edited to fit our envelope —
the adapter is what bridges shapes.

| Subtree | Upstream | Pinned SHA | Filed under | Snapshot date |
|---|---|---|---|---|
| `code_visualizer/` | `~/gitlab/ccsandbox/experiments/code-magic` (private repo) | `9cc9403aade51d15837225ee913554bc5a5d110e` | DCR `019e7b6609` / P1.3 `019e7b870f` | 2026-05-31 |
| `sightline/` | `~/gitlab/minervaservices/experiments/sightline` (private repo) | `8b2baa7` | DCR `019e7b6609` / P3.1 `019e8faa199f` | 2026-06-03 |

## `code_visualizer/`

The code-magic semantic-graph + explainability MCP server. Three sub-trees:

- `analyzer/` — pure SQLite-backed indexer (`store.py`, `extract.py`,
  `edges.py`, `index.py`). No MCP, no FastMCP. The adapter calls these.
- `server/mcp_server.py` — original FastMCP-decorated tool functions. Kept for
  reference; the codetools adapter re-implements the same surface against the
  unified envelope and does NOT import from `server/`.
- `vendor/tree-sitter-gdscript/` — Tree-sitter GDScript grammar (Python +
  C extension). **Not on PyPI** despite the name; `pip install <this dir>` builds
  the C extension from `bindings/python/tree_sitter_gdscript/binding.c` + `src/parser.c`
  + `src/scanner.c`. The runtime-bundle pipeline points `PIP_PKGS` at this dir
  via `$PLUGIN_DIR/worker/vendored/code_visualizer/vendor/tree-sitter-gdscript`.

### Snapshot command (for refresh)

```
SRC=~/gitlab/ccsandbox/experiments/code-magic
DST=~/github/minerva-plugins/codetools/worker/vendored/code_visualizer
rm -rf $DST/analyzer $DST/server $DST/vendor
cp -a $SRC/analyzer $SRC/server $SRC/vendor $DST/
```

Then update the pinned-SHA row in this file with the new upstream HEAD.

## `sightline/`

code-probe — runtime-inspection / evidence-capture tool (P3). Python lib +
GDScript editor probe. **stdlib-only** (no pip deps); rg-backed search reuses the
`rg` already bundled by P2.1. Two sub-trees:

- `sightline/` — the Python package (`cli.py` argparse surface, plus
  `explore.py` / `inspect.py` / `validate.py` / `search.py` / `files.py` /
  `plugin_system.py` / `session_store.py` / `models.py`). The P3.2 adapter
  re-implements the explore/inspect/validate surface against the unified envelope
  and imports the library functions; it does NOT shell out to `cli.py`.
  `search.py` + `files.py` are rg-backed and DUPLICATE `worker/.../files/` — P3.5
  collapses them onto the shared module (do the bridging in the adapter, never
  edit vendored).
- `godot/` — the Godot integration: `plugin.py` (dispatcher; the X11 window
  capture via `xdotool`/`xwininfo`/`xwd`/ImageMagick is Linux-only and is
  feature-gated in P3.3) and `probe/addons/sightline_probe/` (the `@tool`
  EditorPlugin that emits `res://.sightline/godot_probe/debugger_state.json`).

**Probe schema is `sightline.godot.editor_probe_state.v3`** at this SHA (the DCR
text mentions v4 aspirationally — the snapshot pins v3). The P3.6 schema-version
guard asserts replay fixtures match the vendored probe's declared schema.

### Snapshot command (for refresh)

```
SRC=~/gitlab/minervaservices/experiments/sightline
DST=~/github/minerva-plugins/codetools/worker/vendored/sightline
rm -rf $DST/sightline $DST/godot $DST/sightline_main.py
rsync -a --exclude='.sightline' --exclude='__pycache__' --exclude='*.pyc' $SRC/src/sightline/ $DST/sightline/
cp -a $SRC/src/sightline_main.py $DST/sightline_main.py
rsync -a --exclude='.sightline' --exclude='__pycache__' --exclude='*.pyc' $SRC/plugins/godot/ $DST/godot/
```

Then update the pinned-SHA row + the schema version above with the new upstream HEAD.
