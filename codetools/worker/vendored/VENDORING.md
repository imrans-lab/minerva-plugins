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
