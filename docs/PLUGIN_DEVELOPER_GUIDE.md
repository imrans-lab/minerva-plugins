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

> **Verified against:** Minerva `adcb58e3` (2026-08-17). Substrate added since the
> previous revision: the `setup` build pipeline and install lanes ([§17](#17-build-from-source--the-setup-stanza--install-lanes)),
> manifest-declared `settings` ([§3.4](#34-settings-fields)), eight host capabilities
> (`host.settings.*`, `host.models.*`, `host.chat_providers.*`, `host.project.*` — [§4.2](#42-capability-reference)),
> six panel lifecycle hooks ([§7.1](#71-panel-lifecycle-hooks-full-list)), and the
> annotation substrate ([§18](#18-annotations)).

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

> **Who compiles the binary?** The five options below describe what your plugin
> *is*. Orthogonal to that is *who builds it*: ship a prebuilt binary per platform
> (the marketplace lane), or declare a `setup` stanza and let Minerva build from
> source at install time (the manifest lane). Both lanes read the same
> `manifest.json`. See [§17](#17-build-from-source--the-setup-stanza--install-lanes).

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
>
> **Middle ground:** a `setup` stanza with a `requires` entry (`{"tool": "python",
> "min": "3.12"}`) turns "the user might not have a compatible interpreter" from a
> confusing start-time failure into a specific, actionable install-time error with an
> install hint — and a `python_venv` step can build the venv your `args` point at.
> This only applies to the manifest lane ([§17](#17-build-from-source--the-setup-stanza--install-lanes)).

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
that may implement any of thirteen optional lifecycle hooks — `_on_panel_loaded(ctx)`,
`_on_panel_unload()`, `_on_panel_save_request()`, `_on_panel_load_request(doc)`,
`receive(channel, payload)`, `get_annotation_host()`, `handle_tool()` and six more.
Every one is opt-in and probed with `has_method`; the full list with signatures is
[§7.1](#71-panel-lifecycle-hooks-full-list).

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
| `tools[].executor` | O | string | `"backend"` | `backend` \| `panel`. `panel` serves the tool from the live scene panel instead of the subprocess. See §7. |
| `skills` | O | object[] | `[]` | Agent skills seeded into the docket on install. See §3.3. |
| `settings` | O | object[] | `[]` | Declarative user-editable settings contributed to Minerva's Preferences window. See §3.4. |
| `settings_title` | O | string | `""` | Preferences tab title for this plugin's settings. Defaults to the plugin's display `name`. |
| `setup` | O | object | `{}` | `{requires[], steps[]}` build recipe. Run at install on the **manifest lane only**. Structurally validated — a bad stanza fails manifest load. See §17. |
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
| `permissions.filesystem.mode` | O | string | `"none"` | `none` \| `scoped_paths` \| **`unrestricted`**. Must be `scoped_paths` (with non-empty `paths`) **or** `unrestricted` if any `host.files.*` is declared. |
| `permissions.filesystem.paths` | O | string[] | `[]` | Allowlisted roots (e.g. `user://plugins/data/<id>/`). Required non-empty when `host.files.*` is declared **with `scoped_paths`**; ignored under `unrestricted`. |
| `release_targets` | O | string[] | — | **Not parsed by the host** — CI/registry metadata naming the platforms you publish tarballs for. See §14. |
| `data_directory` | O | string | (overwritten) | Ignored from manifest (host overwrites with the plugin's own dir). |
| `autostart` | O | bool | `false` | **Loader drift:** NOT read on manifest install; only honored after persist+reload (§10). |
| `auto_reload` | O | bool | `false` | Same loader drift. When true, source edits trigger a debounced reload. |
| `class_names` | — | — | — | **Not author-supplied.** Populated by the host at install (scanning panel scripts). |
| `install_lane` | — | — | `"manifest"` | **Not author-supplied.** Recorded by the host at install (`manifest` \| `marketplace`) and persisted. See §17. |

### 3.3 `skills[]` fields

Each skill must contain: `id`, `title`, `summary`, `system_prompt`, `outcome`,
`preconditions`, `steps`, `tool_deps`, `target` (`optimization` optional).
`skill.id` must match `^minerva_<id>_[a-z0-9_]+$` and be unique. `tool_deps` is an
array of non-empty strings resolved against the host tool registry **at install**.
`cad` ships `minerva_cad_modeling` (teaches the `.mcad` DSL). Note that `cad`'s
`tool_deps` reference **host-provided** tools (e.g. `minerva_cad_*`,
`minerva_create_plugin_editor`) that are not in the cad backend — see the open
questions in the coverage ledger.

### 3.4 `settings[]` fields

A plugin contributes user-editable settings to Minerva's **Preferences** window by
declaring them in the manifest. The host owns the widgets, the persistence, the type
coercion and the validation — you declare the schema and read the values back.

```json
"settings_title": "PCB",
"settings": [
  {"key": "drc_profile", "type": "enum", "label": "DRC profile",
   "options": ["jlc_2layer", "jlc_4layer"], "default": "jlc_2layer",
   "help": "Fab capability floors used by the checker."},
  {"key": "router_provider", "type": "provider", "label": "Router LLM"},
  {"key": "router_model",    "type": "model",    "label": "Model",
   "provider_key": "router_provider"}
]
```

| Field | R/O | Notes |
|---|---|---|
| `key` | R | Non-empty and unique within the plugin (duplicates → `manifest_duplicate_setting_key`, install fails). |
| `type` | R | One of `string`, `multiline`, `enum`, `bool`, `number`, `provider`, `model`. Anything else fails install. |
| `label` | O | Widget label. |
| `default` | O | Returned by `host.settings.get` until the user sets a value. |
| `options` | R (enum) | Non-empty array; an `enum` without it fails install. Writes outside the list are rejected. |
| `provider_key` | O (model) | For `type: "model"` — the `key` of the sibling `provider` field whose enabled models populate this dropdown. |
| `help` | O | Help text under the widget. |

- **Where values live:** `config_file.cfg`, section `[Plugin:<id>]`, key = your `key`.
  The host coerces on write (`bool` accepts `"true"`/`1`; `number` accepts numeric
  strings; `enum` is membership-checked) and returns the schema `default` when unset.
- **Where they appear:** a Preferences tab named by `settings_title`, falling back to
  the plugin's display `name`, falling back to its `id`.
- **How you read them:** the `host.settings.get` / `host.settings.list` capabilities
  ([§4.2](#42-capability-reference)) — scoped to your own plugin, no arg can select
  another plugin's scope. **There is no `host.settings.set`**: settings are
  user-owned, and a plugin cannot write its own configuration. Agents can read and
  write them via the host tools `minerva_list_preferences` / `minerva_get_preference`
  / `minerva_set_preference`.
- `provider` and `model` values are stored as plain strings (a provider key and a
  model name) and resolved against the live catalog at use time — pair them with
  `host.models.list_providers` / `host.models.list_models` if your backend needs to
  validate or enumerate.

---

## 4. Host APIs & capabilities a plugin can call

A plugin reaches host functionality through the **capability broker**. Every
capability is gated by `permissions.host_capabilities` (deny-by-default: a capability
you do not declare is never dispatchable). **Install is the trust act** — every
capability the manifest declares is granted at install, with no exceptions and no
per-capability prompt; the user can revoke any of them afterward in the Plugin
Manager. (Earlier revisions of this guide said `host.permissions.grant_scope` was held
back from the auto-grant. It no longer is — the host's never-auto-grant list is
deliberately empty.) Two callers:

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
| `host.settings.get` | `key` (req) | `{key, value}` (schema default when unset) | `host.settings.get` | — |
| `host.settings.list` | none | `{fields:[{key, type, label, default?, options?, help?, value}]}` | `host.settings.list` | — |
| `host.models.list_providers` | none | `{providers:[…]}` — the user's **enabled** providers | `host.models.list_providers` | — |
| `host.models.list_models` | `provider` (req) | `{provider, models:[…]}` — enabled models for that provider | `host.models.list_models` | — |
| `host.chat_providers.register` | `entry_id`, `display_name`, `generate_tool`, `history_mode` (req); `timeout_sec`, `cancel_tool`, `metadata` (opt) | `{key, entry_id, display_name}` | `host.chat_providers.register` | — |
| `host.chat_providers.unregister` | `entry_id` (req) | `{entry_id, removed}` | **the `…register` grant** — see the trap below | — |
| `host.project.current` | none | `{path, dirty}` | `host.project.current` | — |
| `host.project.open` | `path` (req, must exist and end `.minproj`); `discard_unsaved` (opt) | `{opened}` — means *accepted*, not *loaded* | `host.project.open` | — |
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

**`host.settings.*` notes:** the scope is fixed to your own plugin — there is no arg
that selects another scope, and no `set` capability (settings are user-owned; see
[§3.4](#34-settings-fields)). `get` on a key you did not declare is a
`schema_validation_failed`, not a null.

**`host.chat_providers.*` notes — a plugin can BE a chat provider.** Registering an
entry makes it selectable in Minerva's chat provider chooser; when the user picks it,
each turn dispatches to your `generate_tool` as a normal MCP tool call:

```jsonc
// args your generate_tool receives
{"chat_id": "<owner history id>",       // stable per chat
 "entry_id": "<the entry you registered>",  // which of your entries this turn is for
 "text": "<newest user message>",
 "messages": [ … ]}                      // ONLY when history_mode == "full"
```

Your reply must be a dict with a `kind` discriminator — the host maps it onto the
chat bubble and rejects anything else:

| `kind` | Fields read | Effect |
|---|---|---|
| `answer` | `text` | Normal assistant turn. |
| `question` | `text`, `options[{label, keystroke}]` | Turn plus selectable options. |
| `error` | `text` | Rendered as a chat error. |

`prompt_tokens` / `completion_tokens` are copied through when present (else 0).
`timeout_sec` defaults to **600**. If you declare a `cancel_tool`, it is called with
`{chat_id}` when the user stops a turn; without one, cancel still returns promptly
host-side and your late reply is discarded. Entries are keyed
`plugin:<plugin_id>:<entry_id>`; re-registering the same pair updates in place. All
entries are dropped when your plugin stops or crashes, so **register from your
backend at startup**, not once at install.

> **Trap — do NOT declare `host.chat_providers.unregister`.** It is dispatchable but
> is deliberately *not* in the host's allowed-capability list: it is gated by the
> `host.chat_providers.register` grant. A manifest that lists it fails install with
> `unknown host_capability`. Declare `host.chat_providers.register` and call both ops.

**`host.project.*` notes:** `open` refuses with error code `unsaved_changes` (plus
`needs_save: true`) when the current project is dirty, unless you pass
`discard_unsaved: true` — so opening can never silently discard the user's work.
Success means the open was *accepted*: the load runs through the same signal the File
menu uses and there is no synchronous "loaded" result to await. Poll
`host.project.current` if you need to observe the switch.

**`host.terminal.*` notes:** the four interactive capabilities (`list`/`read`/`write`/`wait`) observe and converse with open terminal tabs; they do not own terminal lifecycle (no create/close in v1). `host.terminal.write` defaults `raw=true` for this capability path because plugin SDKs send real control characters in JSON strings (e.g. a literal `\r` byte), and the MCP-side `c_unescape` step — which converts LLM-typed escape strings like `\\r` into real bytes — would corrupt them. Pass `raw=false` only if your plugin explicitly builds `\\r`-style escape sequences as strings. `host.terminal.wait` returns `bell_rung: true` when a standalone BEL arrived during the wait — useful as a fast-path turn signal for bell-capable CLI agents. **`bell_rung` is always `false` on Windows** (the ghostty-vt shim that provides the BEL counter is Unix/macOS-only). `shell_exited` and `shell_exit_code` appear in the result only when the shell exits during the wait. Error code: `terminal_tool_error` (inner tool failure), `schema_validation_failed` (unknown arg key). `host.terminal.exec` is a pre-existing separate capability for one-shot command execution with merged stdout+stderr output; it is unrelated to these four.

**Filesystem path rules** (`host.files.*`) — two modes, and you must pick one to use
these capabilities at all:

- **`scoped_paths`** (recommended): path must be absolute or `user://`, contain no
  `..` segments and no null bytes, and prefix-match (with trailing slash) one of
  `permissions.filesystem.paths`.
- **`unrestricted`**: syntactic validation only (non-empty, no null bytes, no `..`) —
  **no allowlist at all**. Any absolute path the agent supplies is read/writable. This
  is deliberate parity with Minerva's core file tools (`minerva_disk_write`,
  `minerva_doc_*`), which enforce no path policy either; install is the trust act.
  Declare it only when your plugin genuinely operates on arbitrary user paths, and
  expect an auditor to ask why.

Both modes: 8 MiB read/write cap, **no symlink realpath resolution** (documented
limitation; recursive delete re-validates every child against scope as a partial
mitigation), and writes are **not** atomic.

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

### 7.1 Panel lifecycle hooks (full list)

Every hook is **optional** and probed with `has_method` on your panel's scene root
before it is called — omitting one is never an error, it just selects the platform's
default behavior. Declare them on the root `Control` script.

| Hook | When the host calls it | Contract |
|---|---|---|
| `_on_panel_loaded(ctx: Dictionary)` | Once, after the panel mounts and **after** the broker is wired. Deferred to `ready` if the scene isn't ready yet. | `ctx` shape below. |
| `_on_panel_unload()` | Panel/tab is closing. | Release timers, threads, file watches. |
| `_on_panel_save_request() -> Dictionary` | Ctrl+S under `save_mode: "host_owned"`. | Return the document dict; the host serializes and writes the file. |
| `_on_panel_load_request(document)` | Opening a bound file, and on `.minproj` restore. | Rebuild the scene from the document. |
| `_on_panel_apply_sync(document) -> Dictionary` | An MCP write tool applied a document and wants the *result* of your per-apply work (e.g. a re-evaluate round-trip) in its reply. | **May `await`.** Return at least `{ok: bool}`; extra fields pass through verbatim. Not implementing it is normal — the host falls back to `_on_panel_load_request` + buffer-only behavior. |
| `receive(channel: String, payload)` | Backend→panel push. | Channel is the **raw event name** for events and the literal `"state"` for state (see below). |
| `handle_tool(tool_name, args) -> Dictionary` | An `executor: "panel"` tool targets this panel. | See the panel-tools section below. Return `{}` for names you don't own. |
| `on_progress(request_id, phase, fraction)` | Backend progress notification. **Implicit channel** — not declared in `ipc_channels`/`ui.ipc_messages`. | See the caveat in §8. |
| `_on_hot_reload()` | After the host hot-reloads your `.gd`/`.tscn` sources (`auto_reload`). | Re-establish anything the reload dropped. Manifest edits are *not* covered — see the reinstall gotcha below. |
| `_on_panel_create_note_request(ctx) -> Dictionary` | User creates a note from your panel. | Return a note descriptor. Not implementing it falls back to screenshot-to-image-note. |
| `_on_panel_restore_from_note(payload) -> bool` | A `plugin_data` note created by the hook above is reopened. | Inverse of `_on_panel_create_note_request`. Return `false` for an unrecognised/old payload — the host toasts and leaves the panel blank. Without the hook the note degrades to preview-image-only. |
| `_on_panel_render_for_llm(ctx) -> Array` | Your panel's content is being injected into a chat. | Return a canonical multimodal payload: an Array of `{"type":"text","text":String}` and/or `{"type":"image","image":Image,"alt":String}` parts. Return `[]` / omit the hook to fall back to the note's preview image. |
| `_on_panel_inject_toggle_changed(enabled: bool)` | User toggles chat injection for this tab. | Fire-and-forget; the host's bookkeeping happens regardless. |
| `get_annotation_host() -> RefCounted` | The editor is mounting the shared annotation toolbar/dock. | Return your `AnnotationHost` subclass — see [§18](#18-annotations). |

**The `ctx` Dictionary** passed to `_on_panel_loaded` (and to the create-note /
render-for-llm hooks):

```gdscript
{
  "plugin_id":         String,   # your id
  "panel_name":        String,   # the manifest panel name
  "data_directory":    String,   # your install dir — resolve your own paths from this
  "broker":            Object,   # PluginScenePanelBroker (may be null in headless tests)
  "file_path":         String,   # bound file, or "" when unbacked
  "associated_object": Variant,  # the editor's bound object (a String path when file-backed)
  "editor":            Object,   # the host Editor wrapper
  "host_api_version":  "1",
}
```

`data_directory` is the supported way to find your own files — the process has no
per-plugin CWD and no per-plugin env var (§10).

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

### Panel-executed MCP tools (executor: `"panel"`)

A native scene panel can serve MCP tools **directly from its own in-process
scene state**, with no backend round-trip at all. This is a second dispatch
path alongside the normal backend tools described in §5 — pick whichever fits
each tool:

| | Backend tool (`executor` absent / `"backend"`) | Panel tool (`executor: "panel"`) |
|---|---|---|
| Runs where | Your subprocess, over MCP `tools/call` | In-process, inside the live scene panel |
| Needs the plugin running? | Yes — fails `plugin_not_running` if stopped | **No** — the subprocess-running check is skipped entirely |
| Good for | Compute (geometry kernels, parsers, anything CPU-bound or stateful outside the scene tree) | **Reading or mutating scene-local state** the panel already holds — selection, camera/view state, in-memory model objects, annotation hosts |
| Needs `editor_name`? | Optional, tool-specific | **Required** — v1 panel tools always resolve against one live editor tab |

If your tool only needs to look at (or poke) something the panel's Godot
nodes/scripts already know — a camera transform, a selection, an in-memory
document model — make it a panel tool. If it needs real compute or state that
outlives the scene panel, keep it a backend tool.

**The manifest field.** Add `"executor": "panel"` to the tool's `tools[]`
entry (default when absent is `"backend"`, so every tool you already ship is
unaffected). The `input_schema` **must** declare `editor_name` as a required
string property — panel tools have no other way to know which live tab to
target:

```json
{
  "name": "minerva_cad_view_state",
  "description": "…",
  "executor": "panel",
  "input_schema": {
    "type": "object",
    "properties": {
      "editor_name": {"type": "string", "description": "Name of the CAD editor tab"}
    },
    "required": ["editor_name"]
  }
}
```

**The `handle_tool` contract.** Your panel's script root implements one entry
point:

```gdscript
func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
    ...
```

- Signature is `Dictionary in, Dictionary out`. It **may be `async`** (use
  `await` inside it) — the host always awaits the call, so a synchronous
  `return {...}` and an `await`-ing coroutine both work.
- Return `{}` (or anything that isn't a non-empty Dictionary) for a
  `tool_name` you don't recognize — the host turns that into a structured
  `tool_unhandled` error for the caller. Never crash on an unknown name.
- The Dictionary you return is passed back **verbatim** as the tool result —
  panel tools own their own success/error envelope shape, same as backend
  tools do.

**Dispatch guarantees (host-side, you get these for free):**
- No subprocess required — panel tools work even while your plugin's backend
  is stopped.
- `editor_name` is validated before your code ever runs: missing →
  `editor_name_required`; not a currently-open editor of yours → resolves via
  the live scene-panel registry, and a miss returns `editor_not_found` with
  the list of known editor names (so an agent can self-correct).
- **Ownership is enforced**: the resolved panel must belong to the plugin
  that declared the tool. A tool from plugin A can never execute against
  plugin B's panel — this is checked before `handle_tool` is called, not
  something your code needs to defend against.
- If your panel doesn't implement `handle_tool` at all, callers get a
  structured `panel_no_handler` error instead of a crash.

**Worked example (from this plugin — the CAD `minerva_cad_view_state` tool,
DCR 019f6c3d0e3d round C6).** `cad/ui/CADPanel.gd` forwards to a small
dispatch file, `cad/ui/panel_tools.gd`, which just calls back into a plain
public method the panel already needed for other reasons:

```gdscript
# CADPanel.gd
const _PanelToolsScript: Script = preload("panel_tools.gd")

func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
    return _PanelToolsScript.handle(self, tool_name, args)

func get_view_state() -> Dictionary:
    # ... reads _responsive.width_class, _active_viewport_id, the active
    # pane's OrbitCamera — all state the panel already tracked.
    return {"width_class": ..., "active_viewport_id": ..., "camera": ...}
```

```gdscript
# panel_tools.gd — no class_name (off-tree rule, see §15)
static func handle(panel, tool_name: String, args: Dictionary) -> Dictionary:
    match tool_name:
        "minerva_cad_view_state":
            return _ok(panel.get_view_state())
    return {}

static func _ok(data: Dictionary = {}) -> Dictionary:
    var result := {"success": true}
    result.merge(data)
    return result
```

Note what's absent: no `editor_name` handling, no host/registry lookup, no
subprocess call. The dispatcher already resolved `editor_name` to this exact
live panel instance before calling `handle_tool` — by the time your code
runs, `panel` (here, `self`) just *is* the right one.

For a full-scale example with 20+ panel tools, model mutations, async
route-worker calls, and structured per-tool error messages, read
[`pcb/ui/panel_tools.gd`](../pcb/ui/panel_tools.gd) end to end — it's the
production reference this pattern was extracted from.

> **Reinstall gotcha:** manifest edits (including adding/changing
> `executor`) are **not** picked up by `.gd`/`.tscn` hot reload. If you're
> iterating on an already-installed plugin, reinstall (or restart) it after
> editing `manifest.json`, and reconnect any MCP client (`/mcp` in Claude
> Code) so it re-fetches `tools/list` — otherwise it keeps calling the old
> tool shape.

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

> **Progress notifications are not wired yet.** The scene-panel broker implements the
> delivery half (`push_progress` → your panel's `on_progress(request_id, phase,
> fraction)`, an implicit channel needing no manifest declaration), but **nothing
> currently routes a backend `{"method":"progress","params":{…}}` notification into
> it** — the host-side integration carries an open TODO. Implementing `on_progress`
> today is harmless and future-proof; do not design a feature that depends on it
> firing. For progress a user must see now, push it as plugin **state** (§8) or as a
> `host.notify` toast.

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
  dir, **auto-grant every declared `host_capabilities`** (no exceptions — §4), seed
  skills. Does not start a process. On the manifest lane, a `setup` stanza also
  builds here (`BUILDING` → `BUILD_FAILED` / `NEEDS_BINARY` on failure — §17).
- **Start** → `STARTING` → (`RUNNING` | `ERROR`).
- **Stop** is idempotent; **Restart** = stop + brief yield + start.
- **Uninstall/remove** stops the plugin, unseeds plugin-shipped skills, and optionally
  deletes the plugin's data dir.
- **Autostart** (persisted flag) governs start-on-boot.

**Crash handling:** a health poll (every 5 s) plus the disconnect signal detect
unexpected exits. **3+ crashes within 60 s → `CRASH_LOOP`** (no auto-restart until
reset).

**Runtime state is transient** — it is reconstructed as `INSTALLED` on every restart;
only `autostart`/`auto_reload`/`class_names`/`install_lane` and the setup-pipeline
states below are persisted.

**The nine states.** The six lifecycle states above (`INSTALLED`, `STARTING`,
`RUNNING`, `STOPPED`, `ERROR`, `CRASH_LOOP`) are joined by three setup-pipeline states
that only the manifest lane can reach: `BUILDING` (pipeline running), `BUILD_FAILED`
(a step failed — terminal until Rebuild) and `NEEDS_BINARY` (preflight failed, or no
runnable artifact for this platform). These three persist across restart, so a
half-installed plugin reports honestly on the next launch, and both carry a structured
failure envelope readable with `minerva_plugin_build_status`. See §17.

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

> **Correction (2026-08-17): Minerva does NOT set `MINERVA_PLUGIN_DATA_DIR`.** A
> previous revision of this guide claimed the host injects it at spawn. It does not —
> the host sets **no** environment variables for a plugin process (consistent with
> §9/§10: `SubProcess.start()` takes neither an env nor a cwd parameter). The only
> reader of that variable in the tree is a test helper. **Derive your data directory
> from `argv[0]`**, or — for a scene panel — from `ctx.data_directory` (§7.1). If your
> own launcher exports `MINERVA_PLUGIN_DATA_DIR` for its child worker, that is your
> convention, not a host guarantee.
>
> In practice this is already handled for Go plugins: `shared/runtime.DataDir(id)`
> treats the env var as an *optional override* and otherwise resolves a per-OS user
> data dir (`~/.local/share/Minerva/plugins/<id>`, `~/Library/Application
> Support/Minerva/plugins/<id>`, `%APPDATA%/Minerva/plugins/<id>`). Because the
> override is never set in production, **tier 2 is the path your plugin actually
> uses** — note that it is a private data dir, *not* your install directory.
> `MINERVA_WORKER_READY_TIMEOUT_SEC` is likewise read by our own `shared/bridge`
> worker helper (and set by CI), not by the host — it is a plugin-side convention.

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

Annotations are now a full platform substrate with its own kind/anchor registries,
schema, trust boundary and workbench dock — how to *host* them from your panel is
[§18](#18-annotations); what you see here is only how they sit in document state.

---

## 13. Permissions & security model

- **Deny-by-default, but install is the trust act.** Every capability must be declared
  in `permissions.host_capabilities`; every declared capability is then auto-granted at
  install, **including `host.permissions.grant_scope`** — the host's never-auto-grant
  list is deliberately empty, on the reasoning that the user already made the trust
  decision by installing. The user can revoke individual capabilities afterward. The
  practical consequence for you: an over-declared manifest is not "harmless because the
  user would be prompted anyway" — it is granted. Declare only what you use.
- **Capability matching is exact**, with two namespace exceptions:
  `mcp.proxy:<tool>` (supports `mcp.proxy:*` and prefix `mcp.proxy:<x>*` wildcards) and
  `secrets:<op>:<handle>`.
- **Secrets are namespaced** per plugin (`plugin/<id>/<handle>` internally) — you
  cannot read another plugin's secrets. Secrets are never written to on-disk config;
  only the panel reads/writes them via the `secrets:*` capabilities.
- **Filesystem** requires `permissions.filesystem.mode` to be `scoped_paths` (with a
  non-empty `paths[]`) **or** `unrestricted` whenever any `host.files.*` is declared.
  `unrestricted` disables the allowlist entirely — syntactic checks only. Path rules
  in §4. No symlink realpath resolution in either mode.
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
the Minerva MCP HTTP server. That server has **no Authorization/token check and no
plugin scoping** (agent identity is a TODO). Consequence: any HTML panel — and any
other process on the same machine — can call **every** MCP tool, bypassing the
per-message `ui.ipc_messages` allowlist that gates `pluginIPC()`. Treat
`minerva.call()` as an **unscoped, unauthenticated** channel and design your panel's
trust assumptions accordingly.

**Update (2026-08-17): the LAN half of this is fixed.** The server now binds the IPv4
loopback (`127.0.0.1`) rather than all interfaces, so the OS rejects non-local
connections at the socket layer. Earlier revisions of this guide said it "binds all
interfaces" — that is no longer true. The *unauthenticated and unscoped* half stands:
same-host reach is still full-tool reach.

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

**`release_targets`** (manifest, top-level) lists the platform triples you publish
tarballs for — e.g. `["linux-x86_64", "macos-universal", "windows-x86_64"]`. All ten
shipped plugins declare it. It is **repo tooling, not host contract**: Minerva's
manifest parser ignores the field entirely (it is neither validated nor stored), so it
can never fail an install; it exists so CI and the registry generator know which
`downloads` keys to expect. Keep it truthful anyway — a target you list but never
build produces a registry entry with no artifact behind it.

### Tag / tarball / SHA256 conventions

- **Release tag:** `<id>-v<MAJOR>.<MINOR>.<PATCH>` (e.g. `presentation-v0.0.3`).
  Pushes to `main` tag as `<id>-v<manifest.version>`; other branches get a
  `-branch-<branch>` sentinel (prerelease, **excluded** from the registry).
- **Tarball filename:** `<id>-<manifest.version>-<target>.tar.gz`,
  `target ∈ {linux-x86_64, linux-arm64, macos-universal, windows-x86_64}`.
- **Tarball contents (files at archive ROOT, not nested):** the plugin binary
  **matching `backend.entrypoint`**, `manifest.json` (**with any `setup` stanza
  stripped** — see §17), the entire `ui/` directory (every `.gd` in `scripts[]` — omit
  it and the panel fails with "Whitelisted script not found"), any data your plugin is
  fail-closed without (e.g. `pcb` ships its `library/`), and a `SHA256SUMS` covering
  every other file.
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
   (§13). No token; reaches every MCP tool. It now binds loopback only, so the
   exposure is same-host rather than LAN-wide.
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
15. **Least privilege — and there is no second gate.** Declare only the capabilities
    you actually use: **everything you declare is granted at install**, including
    `host.permissions.grant_scope` (§4, §13). `scansort` over-declares 14 (uses 2);
    `cad` under-declares (emits `host.notify` with an empty list — it works only
    because the notify *notification* path is ungated). Auditors will flag both.
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
19. **Never declare `host.chat_providers.unregister`** — it is dispatchable but not in
    the host's allowed list (it rides the `…register` grant). Declaring it fails
    install with `unknown host_capability` (§4.2).
20. **`MINERVA_PLUGIN_DATA_DIR` is not set by the host** (§11). No env var is. Resolve
    your own paths from `argv[0]`, or `ctx.data_directory` in a scene panel.
21. **A `setup` stanza is inert on the marketplace lane** (§17). The same
    `manifest.json` ships in the release tarball, where the source it would build was
    never packaged — so a missing binary there is `NEEDS_BINARY`
    (`plugin_binary_missing`), repaired by reinstalling, not by rebuilding.
22. **`exec` setup steps fail closed when nobody can approve them.** An install driven
    by an agent/CI with no interactive approver **denies** every `exec` step rather
    than running it. Prefer the typed step types (`go_build`/`cargo_build`/
    `python_venv`/`copy`); keep `exec` for genuinely last-resort work (§17).
23. **Progress notifications are not routed yet** (§8). `on_progress` is safe to
    implement but nothing fires it today.
24. **Panel-tool `input_schema` must require `editor_name`** (§7) — and manifest edits
    need a reinstall, not a hot reload.

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

## 17. Build-from-source — the `setup` stanza & install lanes

A plugin with a compiled backend has two ways to get a runnable binary onto a user's
machine. Both read the **same `manifest.json`**; the host records which one produced
the install as the plugin's **lane**.

| | **manifest lane** | **marketplace lane** |
|---|---|---|
| How it installs | Side-load / dev install pointing at a `manifest.json` in a source checkout | SHA-pinned release tarball from the registry |
| Source present? | Yes, by definition | No — only what you packaged |
| `setup` stanza | **Built on every install/reinstall** | **Inert** — logged once, never run |
| Entrypoint artifact | Verified by the pipeline | Verified at install |
| Artifact missing | `BUILD_FAILED` (`setup_step_failed`) | `NEEDS_BINARY` (`plugin_binary_missing`) |
| Repair | `rebuild()` | reinstall/update — rebuild refuses with `rebuild_unavailable_marketplace` |

You do not choose the lane; the installer does (only the marketplace client sets the
marketplace lane). **Declaring a `setup` stanza is safe for a plugin that also
publishes release tarballs** — that is exactly what the lane split is for.
`minerva_plugin_build_status` reports `install_lane` and `rebuildable` so an agent
picks the right repair.

> **Repo rule: strip `setup` from the packed manifest.** Current Minerva ignores the
> stanza on the marketplace lane, but a host *predating* the install-lane split would
> try to compile source the tarball never carried. Every release workflow in this repo
> therefore removes the key when packing — and does so **before** `SHA256SUMS` is
> computed, so integrity still checks out over the stripped file:
>
> ```bash
> python3 -c "import json,sys; m=json.load(open('manifest.json')); m.pop('setup',None); json.dump(m,open(sys.argv[1],'w'),indent=2)" "$PACKDIR/manifest.json"
> ```
>
> Copy that step into any workflow that ships a plugin declaring a stanza. `pcb` pins
> the guarantee with a test (`manifest_binary_tier_test.go`) that fails if the pack
> step reverts to a plain `cp` or if the strip stops preceding the checksum.

**Who declares one today (8 of 10 shipped plugins):** `go_build` — `nametag-maker`,
`pcb`, `presentation`; `cargo_build` + `copy` — `3d-gen`, `agent-relay`, `drive`,
`movie-gen`, `scansort`.

**Who deliberately does not, and why it matters to you:** `cad` and `codetools` ship a
per-platform embedded Python runtime bundle built by a network-fetching script that
lives *outside* the plugin directory — `go build ./` on a clean checkout fails for
both. The v1 step vocabulary cannot express that honestly, and a `go_build`-only
stanza would advertise a producer that doesn't actually produce. **If your real build
needs a step the vocabulary can't express, ship no stanza rather than a partial one**
— a stanza is a promise that a clean checkout builds.

### 17.1 The stanza

```json
"setup": {
  "requires": [
    {"tool": "go",     "min": "1.22"},
    {"tool": "python", "min": "3.12"}
  ],
  "steps": [
    {"type": "go_build",    "package": "./",  "output": "pcb-plugin", "timeout_s": 600},
    {"type": "python_venv", "dir": "worker",  "install": "editable"},
    {"type": "copy",        "from": "assets/policy.json", "to": "bin/policy.json"},
    {"type": "exec",        "argv": ["./scripts/postinstall.sh"], "artifact": "bin/generated.dat"}
  ]
}
```

**Step vocabulary (v1 — closed):**

| `type` | Required | Optional | Artifact verified after the step |
|---|---|---|---|
| `go_build` | `package`, `output` | `timeout_s` | `output` |
| `cargo_build` | `manifest_dir`, `artifact` | `profile` (default `release`), `timeout_s` | `artifact` |
| `python_venv` | `dir`, `install` (`"editable"` \| `"requirements"`) | `requirements_file` (default `requirements.txt`), `timeout_s` | `<dir>/.venv` marker (`pyvenv.cfg`) |
| `copy` | `from`, `to` | `timeout_s` | `to` |
| `exec` | `argv` (non-empty string array) | `artifact`, `timeout_s` | only `artifact`, if declared |

Any step may add `artifact` to have its existence checked afterwards. `timeout_s`
defaults to **300** per step. The vocabulary is deliberately closed — the litmus test
for adding to it is *"could two machines with the same checkout and the same tool
versions disagree about what to execute?"*

**Rules you must design around:**

- **All paths are relative to your plugin directory.** Absolute paths and any `..`
  segment are validation errors (`setup_path_escape`), and manifest load fails.
- **No environment-variable expansion, anywhere.** `%APPDATA%` / `$HOME` are literal
  characters in a setup path, never substituted.
- **Steps are cwd-independent.** Godot cannot set a child working directory, so the
  runner absolutizes paths at argv-build time (`go build -C <plugin_dir>`, an absolute
  `--manifest-path` for cargo, absolute paths for `python_venv`/`copy`). **`exec` gets
  no cwd guarantee**: an `argv[0]` starting with `./` resolves against the plugin dir,
  everything after it is passed verbatim. An exec'd program that needs the plugin dir
  must derive it from `argv[0]` or take it as an explicit argument. Never wrap argv in
  a shell to fake a cwd — there is no shell; argv goes straight to the process.
- **Always-build.** The pipeline runs on *every* manifest install/reinstall; your
  toolchain's own incremental build is the cache. There is no host-level source-hash
  skip.
- **`exec` requires explicit user approval** at install; its argv is shown verbatim.
  With no interactive approver (agent-driven or CI install) it is **denied** —
  fail-closed — and the build ends with `detail: exec_denied`. Prefer the typed steps.

**Validation error codes** (all fail manifest load, before anything executes):
`setup_unknown_step_type`, `setup_step_missing_field`, `setup_path_escape`,
`setup_bad_requires`, `setup_empty_argv`.

### 17.2 `requires` and toolchain preflight

Each entry is `{"tool": <registry name>, "min": <semver-ish>}`. The v1 registry knows
**`go`, `cargo`, `python`, `node`, `bun`, `zig`, `scons`**; anything else is not
resolvable. Preflight resolves each tool as: persisted user override → well-known
install dirs → `PATH`. The well-known tier is mandatory because a GUI-launched Godot
does not inherit your shell's `PATH` — *do not assume a tool on your terminal `PATH`
is visible to Minerva.*

A candidate is **executed** to be accepted: the probe runs the tool's version argv with
a 5 s timeout and requires exit 0 plus a parseable version. Presence on disk is never
sufficiency; a hang or garbage output is a failure. Windows Store shims
(`*/Microsoft/WindowsApps/*`) are rejected *before* execution. Failures land the plugin
in `NEEDS_BINARY` with a per-requirement envelope:

```json
{"error": "toolchain_missing" | "toolchain_too_old" | "toolchain_shim_rejected" | "toolchain_probe_failed",
 "tool": "go", "found_path": "…", "found_version": "1.19", "required_min": "1.22",
 "install_hint": "https://go.dev/dl"}
```

### 17.3 When a build fails

`BUILD_FAILED` carries:

```json
{"error": "setup_step_failed", "step_type": "go_build", "step_index": 1,
 "resolved_argv": ["/usr/local/go/bin/go", "build", "-C", "/…/pcb", "-o", "pcb-plugin", "./"],
 "exit_code": 2, "stderr_tail": "<= 2KB", "artifact_expected": "pcb-plugin"}
```

`artifact_expected` present **with `exit_code: 0`** means the step succeeded but did
not produce what it promised — that is a manifest bug, not a build error. A mismatch
between your declared `backend.entrypoint` and what the steps actually produced
reuses the same envelope with `step_type: "entrypoint_check"`.

### 17.4 Tools for authors

- **`minerva_plugin_setup_dry_run`** — renders the exact argv each step *would* run,
  without executing anything, probing anything, or touching the filesystem. Takes an
  installed `id` or a `manifest_path`. Tool names appear unresolved (`go`, not an
  absolute path) precisely because no probe runs. Use it to check a stanza before
  shipping it.
- **`minerva_plugin_build_status`** — state + live `{step_index, step_count,
  step_type}` while building, the full failure envelope, the step log of the most
  recent build, and `install_lane` / `rebuildable`. Poll it after
  `minerva_plugin_install` returns `{building: true}`.

---

## 18. Annotations

Minerva ships an **annotation substrate**: a shared toolbar, overlay, workbench dock
and JSON schema that any editor — core or plugin — can host. A plugin panel opts in by
returning an `AnnotationHost` subclass from `get_annotation_host()` ([§7.1](#71-panel-lifecycle-hooks-full-list)).

The split: the substrate owns the host protocol, the kind/anchor registries, schema
validation, the overlay Control, the trust state machine and the apply/dry-run
wrapper. Your plugin owns concrete `AnnotationKind` subclasses, anchor resolvers,
authoring tools and body views — the substrate never learns what a "PCB net" or a "CAD
edge" is; that stays behind opaque payloads and your resolvers.

Two rules worth knowing before you start:

- **Namespace.** Plugin kinds are `<plugin>_<kind>`; the `2d_*` prefix is reserved for
  core, and registering into it is rejected.
- **Trust.** Every plugin contribution (renderers, resolvers, apply tools) runs behind
  `AnnotationTrustManager`, so a misbehaving plugin auto-suspends instead of taking the
  editor down with it.

The full adoption guide — base-class signatures, kind registration, custom anchors,
body views, per-kind actions, authoring tools, canvas opt-out, the trust boundary and
the off-tree-plugin gotchas — is a companion document in this repo:
**[`ANNOTATION_SUBSTRATE_ADOPTION.md`](./ANNOTATION_SUBSTRATE_ADOPTION.md)**. It is
self-contained; you do not need a Minerva checkout to follow it.

> **Off-tree reminder** (it bites here more than anywhere else): installed plugin
> scripts **cannot use `class_name`** for cross-script type references. Reference your
> kind/tool scripts by `preload` and path — see [§2.4](#24-native-gdscript--godot-scene-panel-in-process-ui).

---

*See [`PLUGIN_API_COVERAGE.md`](./PLUGIN_API_COVERAGE.md) for the full audit matrix,
the producer/consumer diffs, the requirement-bug ledger, and the open questions.*
