# Minerva Plugin Developer Guide

This guide is written for someone authoring a Minerva plugin **without access to
Minerva's source code**. Everything here is grounded in the verified host behavior
(`CapabilityBroker`, `PluginDefinition`, `PluginManager`, the IPC brokers, the
marketplace client) and the shipped example plugins. Where a fact is unknown or
unconfirmed it is called out explicitly and cross-referenced to
[`PLUGIN_API_COVERAGE.md`](./PLUGIN_API_COVERAGE.md).

> **Repo note:** The canonical plugins repository is **`imrans-lab/minerva-plugins`**.
> The marketplace registry is served from
> `https://raw.githubusercontent.com/imrans-lab/minerva-plugins/main/registry.json`.

---

## 1. Overview & plugin anatomy

A Minerva plugin is a directory containing a **`manifest.json`** plus the code and
assets the manifest references. Minerva launches the plugin's **backend** as a
subprocess that speaks the **MCP protocol over stdio** (newline-delimited JSON-RPC
2.0). Optionally the plugin contributes one or more **UI panels** (HTML in a webview,
or a native Godot scene mounted in-process).

### Minimal directory layout

```
my_plugin/
  manifest.json            # REQUIRED — the contract
  my-plugin                # backend binary (Go/Rust) OR server.py (Python)
  ui/                      # OPTIONAL — panels
    panel.html             #   html-kind panel (self-contained: CSS + JS inline)
    MyPanel.tscn           #   godot_scene-kind panel
    MyPanel.gd             #   every .gd referenced by the scene (whitelisted)
  help.md                  # OPTIONAL
```

### The three moving parts

1. **The backend** — a stdio MCP server. Exposes *tools* to Minerva and can call
   *host capabilities* back up. Required (even a near-empty stub) for every plugin,
   because `backend.entrypoint` is a required manifest field.
2. **The manifest** — declares identity, the backend launch command, the tools the
   plugin exposes, the host capabilities it needs, the events/state it emits, and any
   UI panels.
3. **Optional UI panels** — an HTML/JS surface in an embedded webview, or a native
   Godot scene. Panels talk to the backend and to host capabilities **only through
   the host IPC broker**, never directly.

### How the host launches a plugin (high level)

- Install registers the manifest (validation gate) and persists it.
- Start spawns `backend.entrypoint` + `backend.args` as a subprocess, performs the
  MCP `initialize` handshake, then calls `tools/list`. The plugin only becomes
  `RUNNING` after the handshake completes.
- The subprocess inherits Minerva's environment and current working directory.
  **There is no per-plugin env-var injection and no `chdir`** (see §10).

---

## 2. Supported languages & runtimes (first-class)

There are **five** ways to build a Minerva plugin, plus one *external* companion
pattern that is not a Minerva-manifest plugin. The backend transport is
**language-agnostic**: anything that can read stdin and write stdout and speak
JSON-RPC 2.0 works (Go, Rust, Python, Node.js, …). The UI surface is selected per
panel by `ui.panels[].kind` (`html` or `godot_scene`).

### 2.1 Compiled native stdio binary (Go, Rust, any compiled language)

**Manifest:**
```json
"backend": { "transport": "stdio", "entrypoint": "./my-plugin", "args": [] }
```
**Author ships:** `manifest.json` + the **compiled binary, per platform** + optional
`help.md`. A `./`-relative `entrypoint` is resolved to an absolute path against the
plugin's install directory at launch. If the binary is missing, start fails with
*"needs to be compiled for &lt;OS&gt;"* and the plugin goes to `ERROR`. There is no
cross-build — produce one binary per target.

**Shipped examples:** `obs_controller` (Go, `./obs_controller`), `scansort`
(Rust, `./scansort-plugin`), `presentation` (Go, `./presentation-plugin`).

### 2.2 Go shim + bundled (embedded) Python — no host/plugin library collisions

This is how the `cad` plugin ships `build123d`/OCCT (a Python CAD stack) without
depending on the user's Python.

**Manifest:** declares an ordinary stdio binary:
```json
"backend": { "transport": "stdio", "entrypoint": "./cad-plugin", "args": [] }
```
From Minerva's point of view this is just a compiled stdio binary. **Internally** the
Go binary `go:embed`s a [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
(PBS) CPython 3.12 plus the worker's Python packages, **one bundle per
`(GOOS, GOARCH)`**. On first run it extracts the bundle (SHA256-verified) to
`<DataDir>/runtime/<version>/`, then spawns the Python worker as a child and proxies
to it over its own length-prefixed framing (this inner framing is **not** MCP).

**Isolation — no library collisions:** the worker is launched with a *fresh*
environment (`PYTHONHOME`/`PYTHONPATH` point only at the extracted bundle's
site-packages; host `PYTHON*`, `VIRTUAL_ENV`, `CONDA_*` are deliberately **not**
forwarded). Each plugin extracts into its **own** `<DataDir>/runtime/<version>/` —
no shared interpreter, no shared site-packages. Collisions with the host's Python or
another plugin's Python are impossible by construction.

**Author ships:** the per-platform Go binary **with the PBS bundle baked in** (see
§11 for how to build the bundle). `cad` is dual-runtime: it also ships a
`godot_scene` panel.

> **Gotcha:** the `cad` Go binary is per-machine — rebuild after a `git pull` that
> touches `*.go`. Also see the version-drift bug in §15.

### 2.3 Interpreter + script (Python today; Node.js documented but unexercised)

**Manifest:**
```json
"backend": { "transport": "stdio", "entrypoint": "python3", "args": ["server.py"] }
```
An `args` element ending in `.py`/`.js`/`.sh`/`.gd` is resolved to an absolute,
plugin-relative path when the file exists (this is how `python3 server.py` works
without a CWD). **Author ships:** `manifest.json` + `server.py`.

> **Packaging gap (important):** there is **no embedded interpreter** here. The host
> runs whatever `python3` (or `python`, or `node`) resolves to on the *user's* PATH.
> The marketplace tarball does **not** ship an interpreter and the host does **not**
> verify one at install. Your plugin will fail to start on a host that has no
> compatible interpreter on PATH. If you need a guaranteed runtime, use the embedded
> approach in §2.2 instead.

**Shipped examples:** `hello_scene`, `notes_helper`, `test_paired_dsl`
(`python3 server.py`), `test_stdio_server` (bare `python server.py`).

### 2.4 Native GDScript / Godot scene panel (in-process UI)

**Manifest:**
```json
"ui": {
  "ipc_messages": ["my.greet", "my.serialize", "my.deserialize"],
  "panels": [{
    "name": "my_panel",
    "kind": "godot_scene",
    "entry_scene": "ui/MyPanel.tscn",
    "scripts": ["ui/MyPanel.gd", "ui/MyHelper.gd"],
    "ipc_channels": ["my.greet"],
    "file_extensions": [".myx"],
    "save_mode": "host_owned"
  }]
}
```
The `.tscn` + `.gd` scripts are loaded **in-process** by the host (not a subprocess).
The host audits the scene's internal resource table and **rejects any script not
listed in `scripts[]`** (a missing/unlisted script yields a diagnostic placeholder,
not a crash). Scripts load with cache-mode-ignore.

A `godot_scene` plugin **still declares a backend** (the `backend` block is required);
that backend may be a near-empty stub (`tools: []`). The panel root is a `Control`
that may implement the lifecycle hooks `_on_panel_loaded(ctx)`, `_on_panel_unload()`,
`_on_panel_save_request() -> Dictionary`, `_on_panel_load_request(doc)`,
`receive(channel, payload)`, and `get_annotation_host()`.

**`class_name` constraint:** any `class_name` you declare in panel scripts must match
`^<CanonicalPrefix>_[A-Za-z0-9_]+$` and must not collide with core or another
plugin's classes. **Off-tree (installed) plugin scripts cannot use `class_name` for
cross-script type references** — reference sibling scripts by `preload`/path instead.

**Author ships:** `manifest.json` + backend stub + `.tscn` + every `.gd` in
`scripts[]`. **Shipped examples:** `cad` (CADPanel), `presentation`
(SlideEditorPanel), `scansort` (ScansortPanel), `hello_scene`, `test_paired_dsl`.

### 2.5 HTML/JS panel in a webview

**Manifest:**
```json
"ui": {
  "ipc_messages": ["minerva_obs_controller_connect", "capability:secrets:get:obs_password"],
  "panels": [{
    "name": "obs_controller_panel",
    "kind": "html",
    "entry": "ui/panel.html",
    "ipc_channels": ["minerva_obs_controller_connect", "capability:secrets:get:obs_password"],
    "fullscreen_capable": false,
    "multi_window": false
  }]
}
```
`html` is the default `kind`. Ship a **single self-contained HTML file** (CSS + JS
inline) under `ui/`. The host loads it in a webview — **godot-cef** (`CefTexture`,
preferred when available) or **godot_wry** (`WebView`, fallback) — and **auto-injects
the `window.minerva` JS bridge** before display. Your panel drives everything from
JS via `window.minerva` (see §6).

**Author ships:** `manifest.json` + the compiled backend binary + `ui/panel.html`.
The backend and the panel are **two separate runtimes** that communicate only through
the host broker.

> **Launch-path gotcha:** the "Open Panel" button in the Plugin Manager probes
> `ui/<panel_name>.html` then `ui/panel.html` and **ignores the manifest `entry`
> value**. If you set a custom `entry`, name your file to match one of those two
> probes (e.g. name the panel so `ui/<name>.html` is correct, or use `ui/panel.html`).

**Canonical multi-language example — `obs_controller`:** a **Go backend** (12 MCP
tools, emits events + state) **plus an HTML panel** (`ui/panel.html`). The panel calls
the backend's tools with `minerva.call('minerva_obs_controller_*')` and reads/writes
the OBS WebSocket password from Minerva's secret vault with
`minerva.pluginIPC('capability:secrets:get:obs_password', {})` /
`minerva.pluginIPC('capability:secrets:set:obs_password', { value })`.

### 2.6 TypeScript/Bun external companion (NOT a Minerva-manifest plugin)

The `elgato` Stream Deck plugin shows that **bun/TypeScript** is a viable runtime —
but via a *different* path. It uses Elgato's own manifest schema
(`schemas.elgato.com`, `SDKVersion 2`, `CodePaths` per target triple), is compiled
with `bun build --compile --target=bun-<plat>`, runs under the Stream Deck app, and
connects to Minerva as a client over `ws://127.0.0.1:{port}`. It is **not** installed
via the marketplace and has **no Minerva manifest**. Use this pattern only for an
external companion device; it is not a supervised Minerva plugin.

> The Minerva-side WebSocket endpoint `elgato` connects to was not located in the
> surveyed material — see the open questions in the coverage ledger.

---

## 3. Manifest contract — full field reference

### 3.1 There is ONE dialect

Minerva has exactly **one** manifest parser (`PluginDefinition.from_manifest`). All
eight shipped plugins use the **same** dialect. There is **no** legacy "flat"
dialect and nothing to migrate from. In particular:

- `permissions.host_capabilities` (array, **nested under `permissions`**) is the
  capability **grant list**.
- top-level `capabilities` (array) is a **separate opt-in contract list** whose only
  legal values are `project_state`, `host_owned_save`, `project_export`.

These are two different fields with different meanings — *not* two dialects. A guide
or example that places `host_capabilities` at the top level, or treats top-level
`capabilities` as a grant list, is wrong.

### 3.2 Field reference

Legend: **R** = required, **O** = optional. "Strict→null" means a violation makes
`from_manifest` return null (install fails).

| Field | R/O | Type | Default | Meaning / notes |
|---|---|---|---|---|
| `id` | R | string | `""` | Must match `^[a-z][a-z0-9_]*$`. Drives tool prefix `minerva_<id>_` and class-name prefix. |
| `name` | R | string | `""` | Human-readable display name. |
| `version` | R | string | `""` | Semver by convention; only non-empty is checked. The marketplace tarball filename uses this version. |
| `host_api_version` | O | string | `"1"` | Coerced via `str()` (int `1` → `"1"`). **Unenforced** today — advisory metadata. |
| `backend` | O* | object | `{}` | Launch config. Its children make it effectively required. |
| `backend.transport` | O | string | `"stdio"` | **Must equal `"stdio"`** or validation fails. Only stdio MCP is supported. |
| `backend.entrypoint` | R | string | `""` | Launch command (`./bin`, `python3`, `node`). `./`-relative resolved against install dir. |
| `backend.args` | O | string[] | `[]` | Appended after entrypoint. `.py/.js/.sh/.gd` args resolved to absolute plugin-relative paths if the file exists. |
| `backend.working_dir` | O | string | `""` | **Parsed but NEVER applied** (SubProcess cannot `chdir`). Do not rely on it. |
| `tools` | O | object[] | `[]` | **Install-time review metadata only.** The runtime `tools/list` REPLACES this. Only `tools[].name` is validated. |
| `tools[].name` | R* | string | — | Must begin with `minerva_<id>_`. |
| `tools[].description` | O | string | — | Pass-through, surfaced to `tools/list`. |
| `tools[].input_schema` | O | object | — | JSON Schema, pass-through, **not validated**. |
| `skills` | O | object[] | `[]` | Agent skills seeded into the docket on install. See §3.3. |
| `ui` | O | object | `{}` | `{panels[], ipc_messages[]}`. |
| `ui.ipc_messages` | O | string[] | `[]` | Plugin-wide IPC allowlist. Every channel referenced anywhere (panel `ipc_channels`, `project_file`, `project_export`, and `capability:*` messages) MUST appear here. |
| `ui.panels` | O | object[] | `[]` | String entries are **hard-rejected**. Each must be a typed Dictionary with a unique `name`. |
| `ui.panels[].name` | R | string | — | Empty → strict→null. Broker key; for plugin-scene panels this equals the editor tab name and the blob-store key. |
| `ui.panels[].kind` | O | string | `"html"` | `html` \| `godot_scene`. Anything else strict→null. |
| `ui.panels[].entry` | O | string | `ui/<name>.html` | html-only HTML path. (Launch ignores it — see §2.5 gotcha.) |
| `ui.panels[].entry_scene` | R(scene) | string | — | godot_scene `.tscn` path. Sandboxed (must not escape plugin dir). |
| `ui.panels[].scripts` | R(scene) | string[] | — | godot_scene `.gd` whitelist. Non-empty required. Audited against the scene. |
| `ui.panels[].file_extensions` | O | string[] | `[]` | Each lowercased, **must start with `.`**. Maps an extension → this panel. |
| `ui.panels[].ipc_channels` | O | string[] | `[]` | Per-panel subset of `ui.ipc_messages`. Every entry MUST be in `ui.ipc_messages`. |
| `ui.panels[].save_mode` | O | string | `"host_owned"` | `host_owned` \| `plugin_owned` \| `none`. **Do not use `plugin_owned`** (unimplemented — see §7/§15). |
| `ui.panels[].chrome.suppress` | O | string[] | `[]` | Subset of `save_all` \| `save` \| `create_note` \| `inject_toggle`. Hides editor-tab chrome buttons. |
| `ui.panels[].fullscreen_capable` | O | bool | `false` | Advisory; no enforcement found. |
| `ui.panels[].multi_window` | O | bool | `false` | Advisory; no enforcement found. |
| `ui.panels[].render_mode` | O | string | `"single"` | `single` \| `paired_dsl`. `paired_dsl` opens the panel beside a text editor sharing one DocumentBuffer. |
| `ui.panels[].layout_hint` | O | string | `"tabs"` | `tabs` \| `side_by_side`. **`side_by_side` split is unimplemented** — opens a sibling tab. |
| `events` | O | object[] | `[]` | **Top-level** (headless plugins can emit). Lax — no structural validation. See §8. |
| `events[].name` | — | string | — | Conventional event id (e.g. `obs.scene_changed`). Never validated. |
| `events[].payload_schema` | O | object | — | Pass-through, not validated. (Some plugins use `description` instead — both accepted.) |
| `state` | O | object | `{}` | Only `state.schema` is read → `state_schema`. **Documentary only**, not enforced. See §8. |
| `editor_items` | O | object[] | `[]` | **Top-level.** Powers New→Item creation. Each `panel` (if set) must name a declared panel. |
| `editor_items[].id` | R* | string | — | Creatable-item key (e.g. `new_mcad`). |
| `editor_items[].name` | O | string | — | Menu label (e.g. "New CAD Document"). |
| `editor_items[].panel` | O | string | — | Must reference a declared `ui.panels` name if non-empty. |
| `editor_items[].default_filename` | O | string | `"untitled"` | e.g. `untitled.mcad`. |
| `capabilities` | O | string[] | `[]` | **Top-level opt-in contract list.** Only `project_state`, `host_owned_save`, `project_export` legal (unknown → strict→null). See §12. |
| `project_file` | O | object | — | `{serialize_channel, deserialize_channel}` — both must be non-empty AND in `ui.ipc_messages`. Required by `project_state`. |
| `project_export` | O | object | — | `{collect_channel, apply_channel}` — same rules. Required by `project_export`. |
| `permissions` | O | object | `{}` | `{host_capabilities[], network{}, filesystem{}}`. Unknown keys ignored. |
| `permissions.host_capabilities` | O | string[] | `[]` | **The capability grant list.** See §4 + §13. |
| `permissions.network.mode` | O | string | `"none"` | `none`/`localhost`/`unrestricted` documented; **value not validated and not enforced** (see §13). |
| `permissions.network.ports` | O | int[] | — | **Silently dropped** by the parser. Dead metadata. |
| `permissions.filesystem.mode` | O | string | `"none"` | `none`/`scoped_paths`. Must be `scoped_paths` (with non-empty `paths`) if any `host.files.*` is declared. |
| `permissions.filesystem.paths` | O | string[] | `[]` | Allowlisted roots (e.g. `user://plugins/data/<id>/`). Required non-empty when `host.files.*` declared. |
| `data_directory` | O | string | (overwritten) | Ignored from manifest (host overwrites with the plugin's own dir). |
| `autostart` | O | bool | `false` | **Loader drift:** NOT read on manifest install; only honored after persist+reload (§10). |
| `auto_reload` | O | bool | `false` | Same loader drift. When true, source edits trigger a debounced reload. |
| `class_names` | — | — | — | **Not author-supplied.** Populated by the host at install (scanning panel scripts). |

### 3.3 `skills[]` fields

Each skill must contain: `id`, `title`, `summary`, `system_prompt`, `outcome`,
`preconditions`, `steps`, `tool_deps`, `target` (`optimization` optional).
`skill.id` must match `^minerva_<id>_[a-z0-9_]+$` and be unique. `tool_deps` is an
array of non-empty strings resolved against the host tool registry **at install**.
`cad` ships `minerva_cad_modeling` (teaches the `.mcad` DSL). Note that `cad`'s
`tool_deps` reference **host-provided** tools (e.g. `minerva_cad_*`,
`minerva_create_plugin_editor`) that are not in the cad backend — see the open
questions in the coverage ledger.

---

## 4. Host APIs & capabilities a plugin can call

A plugin reaches host functionality through the **capability broker**. Every
capability is gated by `permissions.host_capabilities` (deny-by-default; capabilities
are auto-granted at install **except** `host.permissions.grant_scope`). Two callers:

- **Backend** (any language): emit a JSON-RPC request
  `{"method":"minerva/capability","id":...,"params":{"capability":<name>,"args":{...}}}`
  on stdout; the host replies on your stdin with the result keyed by `id`.
- **HTML/scene panels:** use the IPC string `capability:<name>` (the host strips the
  `capability:` prefix and dispatches `<name>` with your payload as args). The
  channel must also appear in `ui.ipc_messages`.

### 4.1 Return envelope (load-bearing)

**Success:** `{"success": true, "result": {...}}` — double-wrapped. Read your data
from `.result.<field>`.
**Error:** flat `{"success": false, "error_code": "...", "error_message": "...", "plugin_id": "..."}`
(no `result` key).

The `{success, result}` wrap is load-bearing — three host consumers (audit logger,
policy logger, capability-call unmarshalling) all branch on `result.get("success")`.

> **Exception:** the platform-reserved scene channels `host.fs.*` (§6/§7) return a
> **bare** `{success, error}` shape, NOT the `{success, result}` envelope. Don't reuse
> your `capability:*` unwrap logic on those replies.

### 4.2 Capability reference

Args use **exact field names**. "Used by shipped plugins" is marked; everything else
is available-but-unused.

| Capability | Args (exact) | Success result | Gated by | Used by |
|---|---|---|---|---|
| `host.echo` | any | `{echo: <args>}` | `host.echo` | scansort (arg key `message`) |
| `host.notify` | `message` (req), `level` (`info`/`warning`/`error`/`success`) | `{}` | `host.notify` | — (capability form unused; see §8 for the JSON-RPC form actually used) |
| `mcp.proxy:<tool>` | forwarded verbatim to the host MCP tool | wraps the tool dict | `mcp.proxy:<tool>` (wildcards `mcp.proxy:*`, prefix `mcp.proxy:minerva_note_*`) | notes_helper (`mcp.proxy:minerva_create_note`) |
| `secrets:get:<handle>` | none | `{handle, value, exists}` (missing → `exists:false`) | `secrets:get:<handle>` (exact) | obs_controller |
| `secrets:set:<handle>` | `value` (req) — **not** `secret`/`password` | `{handle, ...}` | `secrets:set:<handle>` | obs_controller |
| `secrets:delete:<handle>` | none | success | `secrets:delete:<handle>` | — |
| `host.documents.list_open` | none | `{documents:[{editor_name, kind, plugin_id, panel_name, path}]}` | `host.documents.list_open` | presentation |
| `host.documents.get_state` | `editor_name` (req) | buffer-canonical: `+buffer_text/version/dirty`; panel-canonical: `+panel_state` | `host.documents.get_state` | presentation |
| `host.documents.set_state` | `editor_name` (req); `buffer_text` XOR `panel_state`; `expected_version` (opt). Unknown keys rejected. | `{editor_name, version?, dirty:true, kind, plugin_id, ...}` | `host.documents.set_state` (+ownership) | presentation |
| `host.documents.mark_dirty` | `editor_name` (req) only | `{editor_name, dirty:true, kind, plugin_id}` | `host.documents.mark_dirty` (+ownership) | — |
| `host.documents.get_node` | `editor_name` (req), `path` (RFC 6901: `""`=root else starts `/`) | `{path, found, value, key}` (`found:false` is non-error) | `host.documents.get_node` | presentation |
| `host.documents.get_blob` | `editor_name`, `blob_handle` (req) | `{content_type, bytes_b64}` | `host.documents.get_blob` | presentation |
| `host.documents.put_blob` | `editor_name`, `content_type`, `bytes_b64` (req) | `{blob_handle, content_type}` | `host.documents.put_blob` | presentation |
| `host.documents.patch_state` | `editor_name` (req), **`json_patch`** (req, non-empty RFC 6902 op array) — **NOT `patch`** | `{op_count, applied_ops, dirty:true}` | `host.documents.patch_state` (+ownership) | presentation |
| `host.files.read` | `path` (req), `encoding` (`text`/`base64`) | `{path, encoding, size, content}` | `host.files.read` + `scoped_paths` | — (scansort declares but uses `std::fs`) |
| `host.files.write` | `path`, `content` (req); `encoding`, `create_parents` | `{path, encoding, bytes_written}` | `host.files.write` + `scoped_paths` | — |
| `host.files.list` | `path` (req), `include_hidden` | `{entries:[{name, kind, size, modified_unix}], truncated?}` | `host.files.list` + `scoped_paths` | — |
| `host.files.exists` | `path` (req) | `{path, exists, kind}` | `host.files.exists` + `scoped_paths` | — |
| `host.files.stat` | `path` (req) | `{path, kind, size, modified_unix}` (nonexistent → `io_error`) | `host.files.stat` + `scoped_paths` | — |
| `host.files.mkdir` | `path` (req), `parents` | `{path, created}` (idempotent) | `host.files.mkdir` + `scoped_paths` | — |
| `host.files.delete` | `path` (req), `recursive` | `{path, removed:true, kind, entries_removed?}` | `host.files.delete` + `scoped_paths` | — |
| `host.files.move` | **`source`, `dest`** (req) — NOT `path`; `overwrite` | `{source, dest, overwritten}` | `host.files.move` + `scoped_paths` | — |
| `host.editors.list` | none | `{editors:[{..., export_formats}]}` (hides internal editors) | `host.editors.list` | — |
| `host.editors.export` | `editor_name`, `format` (req) | `{mime, size, content}` (base64) | `host.editors.export` | presentation (`format:"png"`) |
| `host.editors.open` | `path` (req) | `{tab_name, kind, plugin_id, panel_name, path, was_already_open}` | `host.editors.open` | presentation |
| `host.providers.chat` | `messages` (req array of `{role, text\|content, images?}`); `model` XOR `model_spec`; `provider`/`max_tokens`/`temperature` | OpenAI-shape `{model, choices, usage, provider, cost_usd, free}` | `host.providers.chat` (+budget/key/opt-out) | scansort |
| `host.core.session` | none | `{ws_url, token, client_id}` | `host.core.session` | gen3d, movie_gen |
| `host.dialogs.file_picker` | all opt: `title`, `initial_path`, `filters[]`, `mode` (`open`/`save`) | `{cancelled, path?}` | `host.dialogs.file_picker` | — |
| `host.dialogs.directory_picker` | opt: `title`, `initial_path` | `{cancelled, path?}` | `host.dialogs.directory_picker` | — |
| `host.permissions.grant_scope` | `path` (req, absolute, no `..`/null), `reason` | `{granted, already_granted, cancelled, path}` | `host.permissions.grant_scope` — **NEVER auto-granted** (privilege escalation) | — |
| `host.terminal.exec` | `command*` (string), `cwd?` (string), `timeout_ms?` (default 120000, max 600000), `terminal_id?` | `{stdout (merged stdout+stderr), exit_code, exit_code_known, timed_out, routed_through:"terminal"\|"headless", terminal_id?}` — routes to a visible UI terminal when present (exit_code best-effort 0, exit_code_known=false), falls back to OS.execute (real exit code) | `host.terminal.exec` | — |
| `host.terminal.list` | none | `{terminals:[{id,name,visible,cols,rows}], count}` | `host.terminal.list` | agent-relay |
| `host.terminal.read` | `terminal_id?`, `start_row?` (int), `end_row?` (int) | viewport: `{content,rows,cols,total_scrollback_rows,viewport_rows}` — row range: same + `start_row,end_row` | `host.terminal.read` | agent-relay |
| `host.terminal.write` | `terminal_id?`, `text*`, `raw?` (bool, **default `true`** for this capability — see note) | `{bytes_sent}` | `host.terminal.write` | agent-relay |
| `host.terminal.wait` | `terminal_id?`, `timeout_ms?` (default 30000), `settle_ms?` (default 500) | `{content,rows,cols,…,timed_out,waited_ms,bell_rung}` + `shell_exited,shell_exit_code` when shell exits | `host.terminal.wait` | agent-relay |
| `host.pdf.generate` | declarative doc: `defaults{format,orientation,unit}`, `metadata`, `images[{id,format,bytes_b64}]`, `pages[{ops:[…]}]`; ops = `draw_text`(+`fit`)/`draw_image`/`draw_line`/`draw_rect` | `{bytes_b64, byte_size, page_count, content_type:"application/pdf"}` | `host.pdf.generate` | — |
| `network.none` | — | always `permission_denied` | n/a — deny marker; granting it is a config error | — |

**`host.core.session` notes:** mints a **new, distinct Core session** (an independent re-login with the user's stored credentials) and returns `{ws_url, token, client_id}`. Use it when your plugin needs to talk to a Core service (media-gen, etc.) over its **own** WebSocket connection. Do **not** try to reuse Minerva's own session token to open a second connection — Core composes the connection identity as `user_id:::session_id`, so the same token collides ("Session ID collision"). A fresh login yields a fresh `session_id` (Core allows up to 10 concurrent sessions per user), so the plugin's connection is independent of Minerva's and of other plugins'. The minted session carries the user's `svc_allow` (service-level allowlist) — it is **not** scoped to specific topics, so treat the grant as "this plugin may act as the user on Core." Errors with `backend_error` when the host is not logged in / has no stored credentials. The reference consumers `gen3d` and `movie_gen` use it via the shared `minerva-media-client` crate (`shared/rust/`), which performs the Core register handshake + binary artifact relay.

**`host.terminal.*` notes:** the four interactive capabilities (`list`/`read`/`write`/`wait`) observe and converse with open terminal tabs; they do not own terminal lifecycle (no create/close in v1). `host.terminal.write` defaults `raw=true` for this capability path because plugin SDKs send real control characters in JSON strings (e.g. a literal `\r` byte), and the MCP-side `c_unescape` step — which converts LLM-typed escape strings like `\\r` into real bytes — would corrupt them. Pass `raw=false` only if your plugin explicitly builds `\\r`-style escape sequences as strings. `host.terminal.wait` returns `bell_rung: true` when a standalone BEL arrived during the wait — useful as a fast-path turn signal for bell-capable CLI agents. **`bell_rung` is always `false` on Windows** (the ghostty-vt shim that provides the BEL counter is Unix/macOS-only). `shell_exited` and `shell_exit_code` appear in the result only when the shell exits during the wait. Error code: `terminal_tool_error` (inner tool failure), `schema_validation_failed` (unknown arg key). `host.terminal.exec` is a pre-existing separate capability for one-shot command execution with merged stdout+stderr output; it is unrelated to these four.

**Filesystem path rules** (`host.files.*`): path must be absolute or `user://`,
contain no `..` segments and no null bytes, and prefix-match (with trailing slash) one
of `permissions.filesystem.paths`. 8 MiB read/write cap. **No symlink realpath
resolution** (documented limitation; recursive delete re-validates every child against
scope as a partial mitigation). Writes are **not** atomic.

**`host.providers.chat` `model_spec` kinds:** `core_action`
`{service_client_id, action_name}`, `dynamic` `{model_id >= 10000}`, `builtin`
`{model_id}`. Forward `model_spec` only when it is a non-empty object (the broker
rejects empty `{}`). Per-message image cap ≈ 10 MiB.

**`host.pdf.generate` notes:** the host owns the one PDF generator (a bundled
`go-pdf/fpdf` sidecar) — plugins describe the document and never embed their own PDF
lib. **Units are points** (1in=72pt), origin **top-left**, colors `[r,g,b]` 0–255;
auto-page-break is always off (you position everything). Embed each image **once** in
`images[]` and reference it by `id` from `draw_image`. Fonts are referenced inline by
`{family, style, size}` with **no handle**; v1 bundles only **DejaVuSans** regular
(`""`) and bold (`"B"`) — any other `(family,style)` → `font_not_available`.
`draw_text.fit {max_width, min_size, step}` shrinks the size sidecar-side to fit.
8 MiB request cap (`payload_too_large`). Errors: `schema_validation_failed`,
`font_not_available`, `unknown_image_id`, `image_decode_failed`,
`pdf_generation_failed`. Page/layout math (grids, crop marks, duplex) lives in the
plugin — the host only draws. Full contract: Minerva `Docs/design/host_pdf_contract.md`.

---

## 5. Tools a plugin EXPOSES to Minerva

Your backend advertises tools via the MCP `tools/list` response. Each tool has
`name`, `description`, and `input_schema` (a JSON Schema object). **Naming
convention:** the host auto-prefixes the names you return to
`minerva_<plugin_id>_<name>` (dots become underscores). Advertise **clean short
names** — do not hardcode the `minerva_` prefix yourself (an already-prefixed name is
accepted as-is; a name with a *different* plugin's prefix is rejected).

`tools/call` returns the MCP shape:
```json
{"jsonrpc":"2.0","id":...,"result":{"content":[{"type":"text","text":"<json-string>"}]}}
```
The host unwraps `result.content[0].text` and JSON-parses it into the tool result.
Set `isError: true` on the result to signal a tool error.

The runtime `tools/list` is **authoritative** — it replaces whatever `tools[]` your
manifest declared (manifest `tools[]` is install-time review metadata). `cad` and
`presentation` ship `tools: []` in the manifest and build the full list at runtime;
`scansort`/`obs_controller`/`notes_helper`/`test_stdio_server` declare statically.

---

## 6. HTML panels & the IPC model

### 6.1 `ui.panels[]` fields for `kind: "html"`

- `kind: "html"`, `entry` (HTML path; launch probes `ui/<name>.html` then
  `ui/panel.html` — see §2.5 gotcha)
- `ipc_channels[]` — the per-panel allowlist (subset of `ui.ipc_messages`)
- `fullscreen_capable`, `multi_window` — advisory booleans

### 6.2 The injected `window.minerva` bridge

The host injects `window.minerva` before the panel is shown. Methods:

- **`minerva.call(toolName, args) -> Promise`** — invokes an MCP tool. **This path
  POSTs directly to the Minerva MCP HTTP server at `http://localhost:9315`** (a
  JSON-RPC `tools/call`), unwraps `result.content[0].text`, and throws on
  `json.error` / `result.isError`. **It does NOT go through the per-message
  `ui.ipc_messages` allowlist.** See the security note in §13.
- **`minerva.pluginIPC(messageType, payload) -> Promise`** — routes through the host
  webview broker (WRY: `window.ipc.postMessage`; CEF: `window.sendIpcMessage`). This
  path **is** gated by `ui.ipc_messages` (and, for `capability:*`, by the capability
  policy). The host replies asynchronously by calling `window.minerva._ipcReply(...)`.
- **`minerva.onPluginEvent(cb)` / `minerva.onPluginState(cb)`** — register handlers;
  the host pushes events/state to them.
- **Convenience wrappers** (both WRY and CEF bridges expose them — they are thin
  `minerva.call()` shims over host tools): `minerva.getSpreadsheet(name)` →
  `minerva_get_spreadsheet_data`, `minerva.updateSpreadsheet(name, updates)` →
  `minerva_update_spreadsheet_data`, `minerva.createNote(title, content, thread)` →
  `minerva_create_note`. (These host tools are confirmed to exist.)

### 6.3 Message shape & direction

- **Panel → backend tool:** `minerva.pluginIPC('<minerva_<id>_tool>', payload)` — the
  message type is used verbatim as the MCP tool name on your backend. Or use
  `minerva.call('<minerva_<id>_tool>', args)` (direct HTTP, ungated).
- **Panel → host capability:** `minerva.pluginIPC('capability:<name>', payload)` — the
  channel must be listed in `ui.ipc_messages`.
- **Host → panel:** events via `onPluginEvent(name, payload)`; state via
  `onPluginState(state)`.
- **Payload cap:** 64 KiB for the `pluginIPC` path.

### 6.4 Worked snippet (from `obs_controller/ui/panel.html`)

```js
// Guard: the bridge may not be injected yet — defend against it.
if (typeof minerva === 'undefined') {
  // obs_controller retries after 500ms / 1000ms before giving up.
}

// Call a backend tool:
const status = await minerva.call('minerva_obs_controller_get_status', {});

// Read a secret from Minerva's vault (host capability over IPC):
const got = await minerva.pluginIPC('capability:secrets:get:obs_password', {});
//   got => { handle, value, exists }   (note: unwrapped .result)

// Write a secret:
await minerva.pluginIPC('capability:secrets:set:obs_password', { value: newPassword });

// React to host-pushed events/state:
minerva.onPluginEvent((name, payload) => { /* name e.g. 'obs.scene_changed' */ });
minerva.onPluginState((state) => { /* state matches your manifest state.schema */ });
```

> **Manifest must list every channel.** Both `minerva_obs_controller_get_status`
> (tool) and `capability:secrets:get:obs_password` (capability) appear in
> `ui.ipc_messages` and in that panel's `ipc_channels`. `capability:*` messages count
> as IPC messages and must be allowlisted too.

---

## 7. Native scene panels (GDScript) — how they differ from HTML panels

| Aspect | HTML panel | Native scene panel |
|---|---|---|
| Where it runs | Embedded browser (CEF/WRY), out of the Godot scene | **In-process** Godot scene mounted in the editor |
| Entry | `entry` (HTML) | `entry_scene` (`.tscn`) + `scripts[]` (`.gd` whitelist) |
| Backend↔panel comms | `window.minerva` JS bridge | Panel emits a `request(channel, payload, reply_id)` signal; host routes it |
| Capability dispatch | `minerva.pluginIPC('capability:<name>', …)` | `request('capability:<name>', …)` over the broker |
| Host push | `onPluginEvent` / `onPluginState` JS callbacks | `receive(channel, payload)` method on the panel root |
| Save | not document-bound by default | `_on_panel_save_request()` / `_on_panel_load_request()` hooks |

A scene panel reaches host capabilities by emitting a `request` with channel
`capability:<name>` (the broker validates it against `ui.ipc_messages`/policy and
dispatches it just like the HTML path). Other declared channels route to your
backend's tools.

**Event/state delivery to scene panels (important shape difference):** for an event,
the host calls `panel.receive(<event_name>, payload)` — the channel is the **raw
event name** (e.g. `"obs.scene_changed"`), **not** a literal `"event"`. For state, the
host calls `panel.receive("state", state)` — the channel is the literal string
`"state"`. Write your `receive()` switch to match on each declared event name (plus
`"state"`), not on a generic `"event"` channel. (HTML panels instead get the
`onPluginEvent(name, payload)` callback.)

**Platform-reserved channels** that bypass the manifest allowlist for scene panels:
`attach_buffer` / `text_changed` / `detach_buffer` (paired-DSL buffer sync, §12),
`host.fs.watch` / `host.fs.unwatch` (request) + `host.fs.changed` (push) (file
watching — these return a **bare** `{success, error}`), and the `host_owned_save.*`
channels (used internally by the host for panel-canonical state, §12).

**`save_mode` caveat:** `host_owned` (the default) works — on Ctrl+S the host calls
`_on_panel_save_request()`, serializes the returned dict, and writes the file.
`none` means nothing is persisted. **`plugin_owned` is currently UNIMPLEMENTED**: on
Ctrl+S the host only logs a warning ("plugin_owned mode not yet implemented … file
NOT written by Minerva") and writes nothing. **Do not use `plugin_owned`** — your
document will silently never save.

---

## 8. Events & state

Both are emitted by your **backend** as one-way stdout JSON-RPC notifications (no id),
and they work for headless plugins too (`events` is top-level, not under `ui`).

**Event (edge-triggered):**
```json
{"jsonrpc":"2.0","method":"minerva/plugin_event","params":{"event":"obs.scene_changed","payload":{"scene":"Cam 1"}}}
```
The host validates the event name against your manifest `events[]` (an *undeclared*
name logs a warning but is still delivered), then pushes it to your panels.

**State (latest-snapshot):**
```json
{"jsonrpc":"2.0","method":"minerva/plugin_state","params":{"state":{"connected":true,"scene":"Cam 1","recording":false}}}
```
The host stores the latest snapshot per plugin and pushes it to panels;
`minerva_plugin_state` queries return it. State is cleared on stop/crash.

**`host.notify` (one-way log/toast):** distinct from the `host.notify` *capability*.
A backend can emit a notification:
```json
{"jsonrpc":"2.0","method":"host.notify","params":{"level":"info","message":"...","details":{}}}
```
This path is **not** gated by the capability policy (it routes through the notify
router, renders a toast, and appends to the "Activity: MCP" tab). It accepts level
`warn` and has no `success` level (unlike the capability form). `cad` and
`hello_scene` emit it.

**`state.schema`** in the manifest is parsed and round-tripped but is **documentary
only** — it is not enforced against `set_state`/`patch_state` payloads. Many plugins
omit it (only `obs_controller` declares one). **`events[]` shape is unvalidated** —
`{name, payload_schema}` and `{name, description}` both parse; there is no canonical
event-declaration schema.

### 8.1 PLUGIN_EVENT trigger — waking a Minerva agent chat from a plugin event

A `PLUGIN_EVENT` trigger (trigger_type=4) lets a plugin wake a Minerva agent chat
whenever it emits a declared event. This is the mechanism the `agent-relay` plugin
uses to relay terminal turns into a chat conversation, but it is generic — any plugin
can use it (scansort processing-done, CAD render-done, etc.).

**Setup (via `minerva_create_trigger`):**

```json
{
  "name": "relay turn → agent chat",
  "agent_id": "<agent-definition-id>",
  "trigger_type": 4,
  "action_type": 1,
  "plugin_id": "my_plugin",
  "plugin_event_name": "my_plugin.thing_done",
  "consecutive_fire_limit": 5,
  "initial_message": "A new turn arrived. terminal_id={terminal_id}",
  "enabled": true
}
```

- `trigger_type=4` — `PLUGIN_EVENT`
- `action_type=1` — `MESSAGE_EXISTING` (send into an existing agent chat; the only
  useful action type for a conversation loop)
- `plugin_id` — empty string means any plugin; non-empty matches exactly
- `plugin_event_name` — empty means any event name
- `consecutive_fire_limit` — default 5; 0 = unlimited. After N consecutive fires
  without a human message in between, the trigger pauses. **Reset caveat:** the
  counter resets only when a human message lands in an **agent chat** (a chat driven
  by an agent definition); a paused trigger targeting a plain chat re-arms only via
  `minerva_update_trigger` (toggle `enabled`).
- Event payload keys are merged into the trigger context: `{terminal_id}` in
  `initial_message` expands from the emitted payload.

**Declaring the event in the manifest:**

```json
"events": [
  {
    "name": "my_plugin.thing_done",
    "description": "Emitted when processing completes.",
    "payload_schema": {
      "type": "object",
      "properties": {
        "terminal_id": {"type": "string"},
        "status": {"type": "string"}
      }
    }
  }
]
```

Undeclared event names log a warning but are still delivered.

---

## 9. Transport & lifecycle

**Spawn:** the host requires the `SubProcess` GDExtension (same extension as the
terminal). It runs `entrypoint + args` via `SubProcess.start(command, args)`. **There
is no env-var parameter and no working-directory parameter** — the plugin inherits
Minerva's environment and CWD. Resolve all your own paths from `argv`, not from CWD.

**Handshake:** newline-delimited JSON-RPC 2.0. The host sends `initialize`
(`protocolVersion: "2025-06-18"`, `clientInfo: {name:"Minerva", version:"1.0.0"}`),
then `notifications/initialized`, then `tools/list`. Your plugin only reaches
`RUNNING` after `initialize` succeeds. **stdout is the transport only; stderr is for
logs** (captured and shown as rate-limited toasts).

**Lifecycle (no separate "enable" verb):**
- **Install** is the trust act — parse + validate manifest, create the plugin data
  dir, **auto-grant every declared `host_capabilities` except
  `host.permissions.grant_scope`**, seed skills. Does not start a process.
- **Start** → `STARTING` → (`RUNNING` | `ERROR`).
- **Stop** is idempotent; **Restart** = stop + brief yield + start.
- **Uninstall/remove** stops the plugin, unseeds plugin-shipped skills, and optionally
  deletes the plugin's data dir.
- **Autostart** (persisted flag) governs start-on-boot.

**Crash handling:** a health poll (every 5 s) plus the disconnect signal detect
unexpected exits. **3+ crashes within 60 s → `CRASH_LOOP`** (no auto-restart until
reset).

**Runtime state is transient** — it is reconstructed as `INSTALLED` on every restart;
only `autostart`/`auto_reload`/`class_names` are persisted.

---

## 10. Runtime & packaging caveats you must design around

- **No per-plugin env vars, no CWD.** `backend.working_dir` is parsed but never
  applied. Make your plugin location-independent.
- **Compiled plugins ship a binary per platform.** Targets:
  `linux-x86_64`, `linux-arm64`, `macos-universal`, `windows-x86_64`. Missing binary
  → start fails *"needs to be compiled for &lt;OS&gt;"*.
- **Interpreter-script plugins (Python/Node) depend on the user's PATH.** No
  interpreter is shipped or verified at install. Prefer the embedded-runtime approach
  (§11) if you need a guaranteed runtime.
- **Loader drift on `autostart`/`auto_reload`:** these are not read on the
  fresh-manifest install path; they only take effect after the host persists the
  record and reloads it.

---

## 11. Embedded-interpreter runtime & bundle (the `cad` story)

When you need a guaranteed, isolated language runtime (e.g. a Python scientific
stack), embed it in a Go shim:

1. Author your worker (e.g. a Python package) and a `pyproject` / pip pin set.
2. Write `scripts/runtime-bundle.lock` (shell `KEY=VALUE`): `PBS_TAG`, `CPYTHON`,
   `PIP_PKGS`, `LAYER1_IMPORTS`, `WORKER_SOURCE_DIR`, `WORKER_PACKAGES`,
   `BUNDLE_OUT_DIR`. (cad pins `PBS_TAG=20260510`, `CPYTHON=3.12.13`,
   `PIP_PKGS=build123d==0.10.0`.)
3. Add `embed_<goos>_<goarch>.go` files with `//go:embed bundle/runtime-bundle-<triple>.tar.zst`
   and the `.sha256` sidecar. **`BUNDLE_OUT_DIR` must live under the embedding Go
   package** (Go forbids `..` in embed paths). One `embed_*.go` per platform, gated by
   build tags.
4. Build the bundle for each target with the repo-root
   `scripts/build-python-runtime-bundle.sh <plugin-dir> <triple>` (the per-plugin
   `scripts/build-runtime.sh` is a not-implemented stub). It downloads PBS, pip-installs
   (native: the bundle's python; cross: host python with `--only-binary=:all:
   --platform`), runs a Layer-1 import self-test (native only), writes a per-file
   `manifest.sha256` and a zstd-19 `.tar.zst` + a tarball `.sha256`.
5. `go build` (CGO disabled) — `go:embed` bakes the bundle into the binary.

**Build tooling:** `bash`, `curl`, `tar`, `zstd` (`-19`), `sha256sum`/`shasum -a 256`.
Supported triples: `linux-x86_64`, `linux-arm64`, `macos-arm64`, `macos-amd64`,
`windows-x86_64`. The macOS universal binary is built by lipo-ing the amd64 + arm64
binaries (each carrying its own embedded bundle). **Cross-builds require prebuilt
wheels** for the target — source-only deps can't cross-build, and the import self-test
is skipped on cross targets (run it on a native CI runner). Bundle ≈ 150–250 MB
per platform; CI should assert the final binary is ≥ 100 MB to catch an empty embed.

**How the binary finds its interpreter at runtime:** on first run `EnsureRuntime`
verifies `sha256(embedded)` and extracts the tar.zst to `<DataDir>/runtime/<version>/`
(atomic rename; `manifest.sha256` is the cache key). `PythonPath()` resolves in three
tiers: (1) the extracted bundle, (2) a dev `.venv`, (3) system `python3`. The worker
is then launched with an isolated env (`PYTHONHOME`/`PYTHONPATH` → the bundle;
host `PYTHON*`/`VIRTUAL_ENV`/`CONDA_*` not forwarded). Old runtime versions are not
GC'd (out of scope for v1).

**Host-set env:** Minerva sets `MINERVA_PLUGIN_DATA_DIR` at spawn to give each plugin a
private extraction/data dir; `MINERVA_WORKER_READY_TIMEOUT_SEC` overrides the 60 s
cold-start timeout.

---

## 12. Document & state model

### Two canonicality modes

- **Buffer-canonical** — the editor's source of truth is a `DocumentBuffer`
  (`buffer_text` + monotonic `version` + `dirty`). For a plugin-scene panel this only
  applies when the panel is **`render_mode: paired_dsl`** and the host has attached a
  shared buffer (the panel sits beside a text editor on the same buffer; e.g. `.mcad`,
  which is plain-text DSL — so `get_node` on it returns `not_buffer_canonical`).
- **Panel-canonical** — the state is a free-form JSON dict held in the panel's UI
  memory and reached via the `host_owned_save` IPC round-trip
  (`_on_panel_save_request` / `_on_panel_load_request`). e.g. `.mdeck`.

### `.mcad` / `.mdeck` documents

`cad` binds `.mcad` (parametric CAD DSL, `paired_dsl`, buffer-canonical). `presentation`
binds `.mdeck` (slide-deck JSON, `host_owned_save`, panel-canonical).

### Addressing & patching

- **JSON Pointer (RFC 6901):** `""` = root, otherwise must start with `/`; `~1`→`/`,
  `~0`→`~`; the array token `-` is the append target.
- **JSON Patch (RFC 6902):** ops `add`/`remove`/`replace`/`move`/`copy`/`test`, applied
  **atomically** (all-or-nothing). Op dicts use the standard keys `op`/`path`/`value`/`from`.

### `patch_state` — the EXACT key

`host.documents.patch_state` reads **`args.json_patch`** (a non-empty array of RFC 6902
ops, each with an `op` key). It does **NOT** read `args.patch`. A client-only mock or a
plugin sending `patch` silently no-ops — there is no host-side error for the typo. The
`presentation` Go backend correctly sends `json_patch`.

### Blobs

Blobs live out-of-band, keyed `(editor_name, "blob-N")`, refcounted. Two wire shapes:
the inline `{"__blob__": true, "content_type": ..., "bytes": <PackedByteArray|base64>}`
(panel raw state) and the placeholder `{"__blob_handle__": ..., "content_type": ...}`
(what plugins see/send). Outbound reads strip wrappers → handles; inbound writes
rehydrate handles → bytes. **Lifecycle:** `put_blob` stores at refcount 1 but the blob
is *unreferenced* until a subsequent `patch_state` embeds the
`{"__blob_handle__", "content_type"}` placeholder in an op value. Follow every
`put_blob` with a `patch_state` that references the handle, or the blob lingers (no
timeout) until the editor closes.

### `host_owned_save`

The capability (declared in top-level `capabilities[]`) is validated at install:
panel scripts must define `_on_panel_save_request` AND `_on_panel_load_request`, at
least one panel must declare non-empty `file_extensions`, and at least one
`godot_scene` panel must use `save_mode: "host_owned"`. Pair it with `project_file`
(`serialize_channel`/`deserialize_channel`) for `.minproj` round-trip
(`project_state`) and `project_export` (`collect_channel`/`apply_channel`).

### Annotations

Annotations are part of document state. In `presentation`, per-slide annotations live
under `slide.annotations[]` (kinds `callout` / `2d_arrow` / `2d_text`); the panel's
`AnnotationHost` (returned by `get_annotation_host()`) lets the editor mount the shared
annotation toolbar. In `cad`, edge annotations are a **separate live channel**
(`minerva_cad_list_user_labels` / `minerva_cad_annotate_edges`) tied to the B-Rep edge
registry and **not** persisted in the `.mcad` document.

---

## 13. Permissions & security model

- **Deny-by-default.** Every capability must be declared in
  `permissions.host_capabilities` and is then auto-granted at install — **except**
  `host.permissions.grant_scope`, which is never auto-granted (privilege escalation,
  prompts the user).
- **Capability matching is exact**, with two namespace exceptions:
  `mcp.proxy:<tool>` (supports `mcp.proxy:*` and prefix `mcp.proxy:<x>*` wildcards) and
  `secrets:<op>:<handle>`.
- **Secrets are namespaced** per plugin (`plugin/<id>/<handle>` internally) — you
  cannot read another plugin's secrets. Secrets are never written to on-disk config;
  only the panel reads/writes them via the `secrets:*` capabilities.
- **Filesystem** requires `permissions.filesystem.mode == "scoped_paths"` with a
  non-empty `paths[]` whenever any `host.files.*` is declared. Path rules in §4. No
  symlink realpath resolution.
- **Network mode is documentary only.** `permissions.network.mode`
  (`none`/`localhost`/`unrestricted`) is **not validated and not enforced** — there is
  no egress-gating layer. A plugin with `mode: "none"` can still open arbitrary sockets
  from its own subprocess. `permissions.network.ports` is parsed and **silently
  dropped**. Do not assume `network.mode` constrains your plugin's real network access.
- **Audit:** every capability dispatch is logged with redaction (sensitive fields like
  `buffer_text`/`bytes`/`value`/`password`/`token`/`secret`/`api_key`/`authorization`
  are stripped; `patch_state` logs only a shape summary).

### ⚠ The local MCP HTTP server (`localhost:9315`) is unauthenticated

`minerva.call()` in the injected bridge POSTs directly to `http://localhost:9315` —
the Minerva MCP HTTP server. That server **binds all interfaces, has no
Authorization/token check, and has no plugin scoping** (agent identity is a TODO).
Consequence: any HTML panel — and anything else on the host or LAN that can reach the
port — can call **every** MCP tool, bypassing the per-message `ui.ipc_messages`
allowlist that gates `pluginIPC()`. Treat `minerva.call()` as an **unscoped, unauthenticated**
channel and design your panel's trust assumptions accordingly. This is a confirmed gap
(see the coverage ledger), not a hardened boundary.

---

## 14. Registry & release

### `registry.json`

```json
{ "registry_version": 2, "plugins": [ { "id": "...", "name": "...", "version": "...",
  "manifest_version": "...", "release_tag": "...", "manifest_url": "...",
  "downloads": { "linux-x86_64": "<url>", "macos-universal": "<url>", ... } } ] }
```
Generated deterministically by `scripts/regen_registry.py` (sorted by `id`); a CI gate
(`registry-check.yml`) `git diff`s the regenerated file so it must always be a
committed artifact. `version` is derived from the git tag; **`manifest_version` (from
`manifest.json`) drives the tarball filename**.

### Tag / tarball / SHA256 conventions

- **Release tag:** `<id>-v<MAJOR>.<MINOR>.<PATCH>` (e.g. `presentation-v0.0.3`).
  Pushes to `main` tag as `<id>-v<manifest.version>`; other branches get a
  `-branch-<branch>` sentinel (prerelease, **excluded** from the registry).
- **Tarball filename:** `<id>-<manifest.version>-<target>.tar.gz`,
  `target ∈ {linux-x86_64, linux-arm64, macos-universal, windows-x86_64}`.
- **Tarball contents (files at archive ROOT, not nested):** the plugin binary
  **matching `backend.entrypoint`**, `manifest.json`, the entire `ui/` directory
  (every `.gd` in `scripts[]` — omit it and the panel fails with "Whitelisted script
  not found"), and a `SHA256SUMS` covering every other file.
- **`SHA256SUMS`** is required at install (`<64hex>  <relative-path>`). Missing it is a
  hard failure. **Integrity only — no signing/GPG/notarization.** The sidecar lives
  inside the same tarball it describes, so it guards against transit corruption, not a
  malicious publisher; authenticity is anchored solely in HTTPS to github.com.

### Marketplace install pipeline

`fetch_registry` (HTTPS, 4 MiB / 30 s caps) → `resolve_platform_target()` picks the
`downloads` key for the current OS/arch → download to staging (2 GiB / 600 s, follows
GitHub redirects) → `tar -xzf` → verify `SHA256SUMS` → read the **tarball-internal**
`manifest.json` (the registry `manifest_url` is *not* fetched for install) → move to
`user://plugins/<id>/` → `chmod +x` the entrypoint on Unix → register/install.

> **Naming-mismatch trap:** the tarball's binary name MUST equal `backend.entrypoint`'s
> basename. If they differ, install succeeds but **start** later fails with "needs to
> be compiled for &lt;OS&gt;". On disk today, `presentation`'s entrypoint is
> `./presentation-plugin` but the built binary is named `presentation` — the CI build
> step must rename/produce the entrypoint-named file. (See §15.)

---

## 15. Known gotchas (requirement bugs & dialect drift)

1. **`patch_state` arg key is `json_patch`, not `patch`.** Sending `patch` silently
   no-ops with no host error.
2. **Success envelope is load-bearing.** Always `{success:true, result:{...}}` on
   success; read `.result`. Errors are flat (no `result`). `host.fs.*` scene channels
   are the exception — they return a bare `{success, error}`.
3. **`save_mode: "plugin_owned"` is unimplemented.** Ctrl+S logs a warning and writes
   nothing. Use `host_owned` or `none`.
4. **`localhost:9315` (and thus `minerva.call()`) is unauthenticated and unscoped**
   (§13). Binds all interfaces; no token; reaches every MCP tool.
5. **`network.mode` is unenforced and `network.ports` is dropped.** No egress gating
   anywhere — do not rely on the network permission to constrain your plugin.
6. **Interpreter-script plugins have an unshipped, unverified PATH dependency**
   (§2.3). Prefer an embedded runtime for guaranteed behavior.
7. **`backend.working_dir` is parsed but never applied** (no `chdir`). Resolve paths
   from `argv`.
8. **Loader drift:** `autostart`/`auto_reload` are not honored on the fresh-manifest
   install path; only after persist + reload.
9. **Entrypoint/binary name must match** (§14). `presentation` ships
   `./presentation-plugin` vs on-disk `presentation`; `scansort` has no built binary.
10. **`cad` version drift:** the runtime cache key is the binary's `serverVersion`
    constant, not the manifest `version`. Bumping the manifest without bumping
    `serverVersion` will **not** trigger a runtime re-extract.
11. **`events[]` has no canonical shape** (`payload_schema` vs `description` both
    parse) and `state.schema` is documentary only — neither is enforced.
12. **`layout_hint: "side_by_side"` split is unimplemented** — the panel opens as a
    sibling tab.
13. **Plugin manager "Open Panel" ignores `entry`** — name your HTML file
    `ui/<name>.html` or `ui/panel.html`.
14. **Scene-panel event channel is the raw event name**, not `"event"` (state is the
    literal `"state"`). Match your `receive()` switch accordingly (§7).
15. **Least privilege:** declare only the capabilities you actually use. `scansort`
    over-declares 14 (uses 2); `cad` under-declares (emits `host.notify` with an empty
    list — it works only because the notify *notification* path is ungated). Auditors
    will flag both.
16. **`host.terminal.write` defaults `raw=true` for the capability path** — unlike the
    MCP tool (`minerva_terminal_write`) which defaults `raw=false`. Reason: plugin SDKs
    send real control bytes in JSON; the `c_unescape` step that converts LLM-typed `\\r`
    strings into real bytes would corrupt them. If your plugin builds escape sequences as
    backslash strings rather than real bytes, pass `raw=false` explicitly.
17. **`host.terminal.wait` bell_rung is always `false` on Windows** — the ghostty-vt
    shim that exposes the BEL counter is only compiled for Unix/macOS. Design your
    turn-detection logic to work without `bell_rung` on Windows (fall back to
    settle-heuristics only).
18. **PLUGIN_EVENT consecutive_fire_limit resets only for agent-chat targets** — the
    reset fires from `agent_chat_finished` which only emits for `IsAgentChat` histories.
    A paused trigger pointing at a plain chat re-arms only via `minerva_update_trigger`
    (toggle `enabled`). This is acceptable for the primary use-case (MESSAGE_EXISTING
    into an agent chat).

---

## 16. Minimal worked examples

### 16.1 "Hello world" stdio Go plugin

**`manifest.json`**
```json
{
  "id": "hello_world",
  "name": "Hello World",
  "version": "0.1.0",
  "host_api_version": "1",
  "backend": { "transport": "stdio", "entrypoint": "./hello-world", "args": [] },
  "permissions": { "host_capabilities": [], "network": { "mode": "none" },
                   "filesystem": { "mode": "none", "paths": [] } }
}
```

**`main.go`** (sketch — uses an MCP Go SDK over stdio)
```go
// On tools/list, advertise the SHORT name "say_hello"; the host exposes it as
// minerva_hello_world_say_hello.
//
// Tool input_schema: { "type":"object",
//   "properties": { "name": { "type":"string" } }, "required": ["name"] }
//
// On tools/call: return MCP content:
//   { "content": [ { "type":"text", "text": "{\"greeting\":\"Hello, <name>!\"}" } ] }
//
// stdout = JSON-RPC only; write all logs to stderr.
```

Build per platform (`go build -o hello-world`), package the binary + `manifest.json`
into `hello_world-0.1.0-<target>.tar.gz` with a `SHA256SUMS` at the root (§14).

### 16.2 HTML-panel pattern (pointer)

For a panel that drives a Go backend and reads a secret, follow `obs_controller`:
- `manifest.json`: `ui.panels[]` with `kind:"html"`, `entry:"ui/panel.html"`, and
  `ui.ipc_messages` listing both the backend tool names and the `capability:secrets:*`
  channels.
- `ui/panel.html`: a single self-contained file using
  `minerva.call('minerva_<id>_<tool>', args)` for backend tools,
  `minerva.pluginIPC('capability:secrets:get:<handle>', {})` for secrets, and
  `onPluginEvent` / `onPluginState` for host pushes (worked snippet in §6.4).

For a native scene panel that owns a document, follow `presentation` (panel-canonical,
`host_owned_save`, `host.documents.patch_state` with `json_patch`) or `cad`
(`paired_dsl`, buffer-canonical).

---

*See [`PLUGIN_API_COVERAGE.md`](./PLUGIN_API_COVERAGE.md) for the full audit matrix,
the producer/consumer diffs, the requirement-bug ledger, and the open questions.*
