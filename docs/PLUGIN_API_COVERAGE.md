# Minerva Plugin API — Coverage Ledger

Audit artifact for [`PLUGIN_DEVELOPER_GUIDE.md`](./PLUGIN_DEVELOPER_GUIDE.md). It
proves nothing was silently dropped: the full symbol matrix, the supported languages,
the manifest dialect findings, the three producer/consumer/schema diff lists, the
requirement bugs, and the open questions (including unresolved critic gaps).

Column meaning:
- **in_host** — implemented in the host (producer side).
- **in_schema** — recognized by the manifest parser / capability allowlist.
- **used_by** — shipped plugins that actually exercise it (empty = available-but-unused).

---

## 1. Coverage matrix

| symbol | category | in_host | in_schema | used_by | source_ref |
|---|---|---|---|---|---|
| CapabilityBroker.dispatch | runtime | yes | no | presentation, scansort, notes_helper, obs_controller, cad | CapabilityBroker.gd:207,255-319 |
| mcp.proxy:&lt;tool&gt; | host_api | yes | yes | notes_helper | CapabilityBroker.gd:329; PluginPolicy.gd:416 |
| secrets:get:&lt;handle&gt; | host_api | yes | yes | obs_controller | CapabilityBroker.gd:377,400,423-424 |
| secrets:set:&lt;handle&gt; | host_api | yes | yes | obs_controller | CapabilityBroker.gd:404 |
| secrets:delete:&lt;handle&gt; | host_api | yes | yes | — | CapabilityBroker.gd:409-411 |
| host.echo | host_api | yes | yes | scansort | CapabilityBroker.gd:451; scansort/src/main.rs:394-405 |
| host.documents.list_open | host_api | yes | yes | presentation | CapabilityBroker.gd:469-478; presentation/main.go:1170-1192 |
| host.documents.get_state | host_api | yes | yes | presentation | CapabilityBroker.gd:498-537; presentation/main.go:298-324 |
| host.documents.set_state | host_api | yes | yes | presentation | CapabilityBroker.gd:548-666; presentation/main.go:1682-1695 |
| host.documents.mark_dirty | host_api | yes | yes | — | CapabilityBroker.gd:676-711 |
| host.documents.get_node | host_api | yes | yes | presentation | CapabilityBroker.gd:735-817; JsonPointer.gd:43 |
| host.documents.get_blob | host_api | yes | yes | presentation | CapabilityBroker.gd:829-862; presentation/main.go:223-251 |
| host.documents.put_blob | host_api | yes | yes | presentation | CapabilityBroker.gd:1133-1174; presentation/main.go:265-293 |
| host.documents.patch_state | host_api | yes | yes | presentation | CapabilityBroker.gd:896-1111,903; presentation/main.go:495-523 |
| host.files.read | host_api | yes | yes | — (scansort declares, uses std::fs) | CapabilityBroker.gd:1298,125-191 |
| host.files.write | host_api | yes | yes | — | CapabilityBroker.gd:1358 |
| host.files.list | host_api | yes | yes | — | CapabilityBroker.gd:1431 |
| host.files.exists | host_api | yes | yes | — | CapabilityBroker.gd:1511 |
| host.files.stat | host_api | yes | yes | — | CapabilityBroker.gd:1544 |
| host.files.mkdir | host_api | yes | yes | — | CapabilityBroker.gd:1590 |
| host.files.delete | host_api | yes | yes | — | CapabilityBroker.gd:1640,1702 |
| host.files.move | host_api | yes | yes | — | CapabilityBroker.gd:1759 |
| host.editors.list | host_api | yes | yes | — | CapabilityBroker.gd:1893,1869 |
| host.editors.export | host_api | yes | yes | presentation | CapabilityBroker.gd:1920; presentation/main.go:377-410 |
| host.editors.open | host_api | yes | yes | presentation | CapabilityBroker.gd:2508; presentation/main.go:337-366 |
| host.providers.chat | host_api | yes | yes | scansort | CapabilityBroker.gd:2011; scansort/src/main.rs:1358-1374 |
| host.dialogs.file_picker | host_api | yes | yes | — | CapabilityBroker.gd:2787 |
| host.dialogs.directory_picker | host_api | yes | yes | — | CapabilityBroker.gd:2888 |
| host.permissions.grant_scope | permission | yes | yes | — | CapabilityBroker.gd:2976; PluginManager.gd:734 |
| host.pdf.generate | host_api | yes | yes | — | CapabilityBroker.gd:3330; src/sidecars/host_pdf/ |
| host.notify (capability form) | host_api | yes | yes | — | CapabilityBroker.gd:3263 |
| host.notify (JSON-RPC notification) | ipc | yes | no | cad, hello_scene | PluginNotifyRouter.gd:16; MCPServerConnection.gd:925-930; cad/main.go:126-148 |
| network.none (deny marker) | host_api | yes | no | — | CapabilityBroker.gd:256 |
| minerva/capability (plugin→host wire) | ipc | yes | no | presentation, scansort, notes_helper | MCPServerConnection.gd:777-810; presentation/main.go:136; notes_helper/server.py:138-146 |
| PluginWebviewBroker.handle_ipc_message | ipc | yes | no | obs_controller | PluginWebviewBroker.gd:150-343 |
| capability:&lt;name&gt; (panel string form) | ipc | yes | no | obs_controller | PluginWebviewBroker.gd:281; PluginScenePanelBroker.gd:1281 |
| PluginScenePanelBroker.handle_scene_request | ipc | yes | no | cad, hello_scene, test_paired_dsl | PluginScenePanelBroker.gd:547,594 |
| host.fs.watch / host.fs.unwatch | ipc | yes | no | — | PluginScenePanelBroker.gd:1146,1171 |
| host.fs.changed (outbound) | event | yes | no | — | PluginScenePanelBroker.gd:1192 |
| host_owned_save.get/set/response | ipc | yes | no | presentation | PluginScenePanelBroker.gd:126-132,937-1069 |
| attach_buffer / text_changed / detach_buffer | ipc | yes | no | cad, test_paired_dsl | PluginScenePanelBroker.gd:75-81,859,873 |
| minerva/plugin_event (wire) | event | yes | no | obs_controller, scansort | MCPServerConnection.gd:921,961-976; obs_controller/events.go:11-21 |
| minerva/plugin_state (wire) | state | yes | no | obs_controller | MCPServerConnection.gd:923,994-1007; obs_controller/events.go:24-34 |
| id | manifest_field | yes | yes | all 8 | PluginDefinition.gd:486,365-368,1223 |
| name | manifest_field | yes | yes | all 8 | PluginDefinition.gd:487,372-373 |
| version | manifest_field | yes | yes | all 8 | PluginDefinition.gd:488,374-375; cad/main.go:38-39 |
| host_api_version | manifest_field | yes | yes | all 8 | PluginDefinition.gd:489; PluginMCPTools.gd:466 |
| backend.transport | manifest_field | yes | yes | all 8 | PluginDefinition.gd:493,379-380 |
| backend.entrypoint | manifest_field | yes | yes | all 8 | PluginDefinition.gd:494,376-377; PluginManager.gd:505-520 |
| backend.args | manifest_field | yes | yes | hello_scene, notes_helper, test_paired_dsl, test_stdio_server | PluginDefinition.gd:496-497; PluginManager.gd:522-532 |
| backend.working_dir | manifest_field | yes | yes | — | PluginDefinition.gd:495; PluginManager.gd:495-496 |
| tools[] | manifest_field | yes | yes | obs_controller, notes_helper, test_stdio_server, scansort | PluginDefinition.gd:529-531; PluginToolRegistry.gd:562-669 |
| tools[].name | manifest_field | yes | yes | (same) | PluginDefinition.gd:385-388 |
| tools[].description | manifest_field | yes | yes | (same) | PluginDefinition.gd:531 |
| tools[].input_schema | manifest_field | yes | yes | obs_controller, notes_helper, scansort | PluginDefinition.gd:531 |
| skills[] | manifest_field | yes | yes | cad | PluginDefinition.gd:537-539,400-446; cad/manifest.json:12-37 |
| ui | manifest_field | yes | yes | cad, scansort, presentation, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd:500 |
| ui.ipc_messages | manifest_field | yes | yes | cad, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd:501-503; PluginWebviewBroker.gd:237-250 |
| ui.panels[] | manifest_field | yes | yes | cad, scansort, presentation, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd:505-526,656-839 |
| ui.panels[].name | manifest_field | yes | yes | (same) | PluginDefinition.gd:657-663 |
| ui.panels[].kind | manifest_field | yes | yes | (same) | PluginDefinition.gd:666-671 |
| ui.panels[].entry | manifest_field | yes | yes | obs_controller | PluginDefinition.gd:699-704; PluginManagerPanel.gd:926-928 |
| ui.panels[].entry_scene | manifest_field | yes | yes | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:680-685; PluginScenePanelHost.gd:112-116 |
| ui.panels[].scripts | manifest_field | yes | yes | (scene plugins) | PluginDefinition.gd:687-697; PluginScenePanelHost.gd:155-164 |
| ui.panels[].file_extensions | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:707-723; PluginEditorRegistry.gd:90-122 |
| ui.panels[].ipc_channels | manifest_field | yes | yes | cad, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd:725-742 |
| ui.panels[].save_mode | manifest_field | yes | yes | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:750-761 |
| ui.panels[].chrome.suppress | manifest_field | yes | yes | hello_scene | PluginDefinition.gd:769-796 |
| ui.panels[].fullscreen_capable | manifest_field | yes | yes | obs_controller | PluginDefinition.gd:799 |
| ui.panels[].multi_window | manifest_field | yes | yes | obs_controller | PluginDefinition.gd:802 |
| ui.panels[].render_mode | manifest_field | yes | yes | cad, test_paired_dsl | PluginDefinition.gd:809-820; singleton_object.gd:1629-1631 |
| ui.panels[].layout_hint | manifest_field | yes | yes | cad, test_paired_dsl | PluginDefinition.gd:826-837; singleton_object.gd:1505-1507 |
| events[] | manifest_field | yes | yes | obs_controller, scansort | PluginDefinition.gd:558-560 |
| events[].name | manifest_field | yes | yes | obs_controller, scansort | PluginDefinition.gd:559 |
| events[].payload_schema | manifest_field | yes | yes | obs_controller | PluginDefinition.gd:559 |
| state.schema | manifest_field | yes | yes | obs_controller | PluginDefinition.gd:561,124-125 |
| editor_items[] | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:553-555,447-456 |
| editor_items[].id | manifest_field | yes | yes | (same) | PluginDefinition.gd:455; PluginEditorRegistry.gd:142 |
| editor_items[].name | manifest_field | yes | yes | cad, presentation, hello_scene | PluginEditorRegistry.gd |
| editor_items[].panel | manifest_field | yes | yes | (same) | PluginDefinition.gd:451-456 |
| editor_items[].default_filename | manifest_field | yes | yes | (same) | PluginEditorRegistry.gd:148,167 |
| capabilities[] (top-level) | manifest_field | yes | yes | cad, presentation, hello_scene | PluginDefinition.gd:566-580,1131-1216 |
| capability: project_state | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:1131-1216 |
| capability: host_owned_save | manifest_field | yes | yes | cad, presentation, hello_scene | PluginDefinition.gd:1160-1196 |
| capability: project_export | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:1131-1216 |
| project_file | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:584-612 |
| project_file.serialize_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:590,599-604 |
| project_file.deserialize_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:591,605-610 |
| project_export | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:616-644 |
| project_export.collect_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:622,631-636 |
| project_export.apply_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd:623,637-642 |
| permissions | manifest_field | yes | yes | scansort, presentation, obs_controller, cad, notes_helper | PluginDefinition.gd:542-550 |
| permissions.host_capabilities | permission | yes | yes | scansort, presentation, obs_controller, notes_helper | PluginDefinition.gd:543-544,1063-1101 |
| permissions.network.mode | permission | yes | yes | obs_controller | PluginDefinition.gd:545-546 |
| permissions.network.ports | permission | **no** | **no** | obs_controller (declared, dropped) | PluginDefinition.gd:546; obs_controller/manifest.json:183-186 |
| permissions.filesystem.mode | permission | yes | yes | scansort, notes_helper, obs_controller | PluginDefinition.gd:548,1090-1095 |
| permissions.filesystem.paths | permission | yes | yes | scansort, notes_helper, obs_controller | PluginDefinition.gd:549-550,1096-1099 |
| data_directory | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:262,340 |
| autostart | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:341,307; PluginManager.gd:772-788 |
| auto_reload | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd:342,308; PluginManager.gd:840-1010 |
| class_names | manifest_field | yes | no | (host-populated) | PluginDefinition.gd:343-344,908 |
| STDIO transport / SubProcess.start | runtime | yes | no | all 8 | MCPServerConnection.gd:591-652; subprocess.cpp:16 |
| MCP initialize handshake | ipc | yes | no | all 8 | MCPServerConnection.gd:59,640-682 |
| tools/call routing + namespacing | ipc | yes | no | cad, scansort, presentation, obs_controller, notes_helper, test_stdio_server | PluginToolRegistry.gd:287-381,562-669 |
| PluginDB.install / install_plugin | lifecycle | yes | no | — | PluginDB.gd:40-89; PluginManager.gd:150-191,734-750 |
| start/stop/restart/remove | lifecycle | yes | no | — | PluginManager.gd:459-595,630-656,352-398 |
| Crash detection / CRASH_LOOP | lifecycle | yes | no | — | PluginManager.gd:797-832,1134-1182 |
| PluginDefinition.State enum | state | yes | no | — | PluginDefinition.gd:11-18 |
| PluginManager lifecycle signals | event | yes | no | — | PluginManager.gd:48-52; singleton_object.gd:576-611 |
| tools_registered/unregistered signals | event | yes | no | — | PluginToolRegistry.gd:24-27 |
| Hot reload (auto_reload watch) | lifecycle | yes | no | — | PluginManager.gd:840-1010 |
| PluginDB persistence + boot reconstruction | lifecycle | yes | no | — | PluginDB.gd:7-8,199-265 |
| PluginErrors success/error envelope | runtime | yes | no | presentation, scansort, cad, notes_helper, obs_controller | PluginErrors.gd:388-415 |
| Audit redaction | runtime | yes | no | — | CapabilityBroker.gd:3183-3208 |
| window.minerva JS bridge (WRY + CEF) | ipc | yes | no | obs_controller | minerva_bridge.gd:5-113; cef_bridge.gd:13-107 |
| HTML webview hosts (CEF preferred / WRY fallback) | ui_surface | yes | no | obs_controller | CefWebViewEditor.gd:86-135; WebViewEditor.gd:94-118 |
| PluginScenePanelHost (native mount) | ui_surface | yes | no | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginScenePanelHost.gd:49-219 |
| MinervaPluginPanel + lifecycle hooks | lifecycle | yes | no | (scene plugins) | MinervaPluginPanel.gd:1-116 |
| PluginEditorRegistry | registry | yes | no | cad, presentation, hello_scene, test_paired_dsl | PluginEditorRegistry.gd:66-135 |
| Document state (canonicality model) | document_model | yes | no | cad, presentation, test_paired_dsl | CapabilityBroker.gd:485-497,2655-2692 |
| JSON Pointer (RFC 6901) | document_model | yes | no | presentation | JsonPointer.gd:1-60 |
| JSON Patch (RFC 6902) | document_model | yes | no | presentation | JsonPatch.gd:1-71 |
| Blob storage / reference model | document_model | yes | no | presentation | PluginScenePanelBroker.gd:1642-1796; slide_model.gd:166-171 |
| Annotation model | document_model | yes | no | presentation, cad, hello_scene | presentation_tile_annotation_host.gd:1-77; cad/ui/CadAnnotationHost.gd |
| Embedded Python runtime (go:embed PBS) | runtime | no (plugin-side) | no | cad | cad/internal/runtime/embed.go:45-101; extract.go:71-140 |
| build-python-runtime-bundle.sh + .lock | runtime | no (plugin-side) | no | cad | scripts/build-python-runtime-bundle.sh:1-360; cad/scripts/runtime-bundle.lock |
| registry.json + regen_registry.py | registry | no (repo-side) | no | cad, scansort, presentation | registry.json:1-50; regen_registry.py:29,86-126 |
| MarketplaceClient install pipeline | runtime | yes | no | cad, scansort, presentation | MarketplaceClient.gd:47,88,113,134,432-461 |
| Release tag + tarball naming | registry | no (repo-side) | no | cad, scansort, presentation | presentation.yml:103-186; regen_registry.py:110-113 |
| save_mode=plugin_owned (UNIMPLEMENTED) | lifecycle | **no (stub)** | yes | — | Editor.gd:1538-1554 (TODO, push_warning only) |
| minerva.getSpreadsheet/updateSpreadsheet/createNote | ipc | yes | no | — (host tools confirmed) | minerva_bridge.gd:43-56; cef_bridge.gd:49-56; MCPSpreadsheetTools.gd, MCPNotesTools.gd |
| localhost:9315 MCP HTTP server (no auth) | runtime | yes | no | obs_controller (via minerva.call) | MinervaMCPHttpServer.gd:51-68,320 |
| elgato Stream Deck companion (separate substrate) | language | no (external) | no | elgato | plugins/elgato/manifest.json:1-26; src/index.ts:33-34,51 |

---

## 2. Supported languages / runtimes

1. **Compiled native stdio MCP binary (language-agnostic: Go, Rust, …)** — `backend.transport:"stdio"` + `backend.entrypoint:"./<binary>"`. Author ships a per-platform compiled binary. Examples: obs_controller (Go), scansort (Rust), presentation (Go).
2. **Go shim + go:embed'd PBS CPython worker** — declared as an ordinary stdio binary; internally embeds a python-build-standalone CPython + packages per `(GOOS,GOARCH)`, extracts to `<DataDir>/runtime/<version>/`, proxies over length-prefixed framing (not MCP). Isolated env → no host/plugin library collisions. Example: cad (also ships a godot_scene panel).
3. **Interpreter + script (Python today; Node.js documented, unexercised)** — `entrypoint:"python3"`/`"python"`, `args:["server.py"]`. No shipped/verified interpreter — PATH dependency. Examples: hello_scene, notes_helper, test_paired_dsl, test_stdio_server.
4. **Native GDScript / Godot scene panel** — `ui.panels[].kind:"godot_scene"` + `entry_scene` + `scripts[]` (whitelist, audited), mounted in-process. Still declares a stdio backend (may be a stub). Examples: cad CADPanel, presentation SlideEditorPanel, scansort ScansortPanel, hello_scene, test_paired_dsl.
5. **HTML/JS webview panel** — `ui.panels[].kind:"html"` + `entry:"ui/panel.html"`, self-contained; host injects `window.minerva`; runs in godot-cef (preferred) or godot_wry (fallback). Example: obs_controller (Go backend + HTML panel — canonical multi-language example).
6. **TypeScript/Bun external Stream Deck companion (NOT a Minerva-manifest plugin)** — Elgato manifest schema, `bun build --compile`, connects to Minerva via `ws://127.0.0.1:{port}` as a client. Example: elgato.

---

## 3. Manifest dialects

- **SINGLE CURRENT DIALECT** — the rich `host_api_version` + `backend` + `ui` +
  `permissions` + `capabilities` dialect is the *only* one the parser
  (`PluginDefinition.from_manifest` / `_from_dict_internal`) accepts. All 8
  shipped plugins use it. There is exactly one parser.
- **The "flat dialect" premise is inaccurate / does not exist.** `host_capabilities`
  is always nested under `permissions`; top-level `capabilities` is a separate opt-in
  contract list (`project_state`/`host_owned_save`/`project_export`), not a grant list.
  The plugin some called "flat" (`presentation`) is in fact the rich dialect. No
  legacy dialect to migrate from.
- **Sub-variation within the single dialect — `events[]` shape drift:** doc-comment
  says `{name, payload_schema}` (obs_controller) but `{name, description}` (scansort)
  also parses, unvalidated. No canonical event shape.
- **NON-Minerva dialect:** elgato uses the Elgato Stream Deck manifest schema
  (`schemas.elgato.com`, SDKVersion 2) — entirely separate.

---

## 4. Diff lists

### 4a. Producer-only (implemented in host, used by no shipped plugin)

- `host.documents.mark_dirty` — implemented, declared by nobody.
- `host.files.read/write/list/exists/stat/mkdir/delete/move` — fully implemented;
  scansort *declares* all 8 but its Rust uses `std::fs` directly and never calls them
  → effectively no plugin exercises the channel.
- `host.dialogs.file_picker` / `host.dialogs.directory_picker` — implemented; scansort
  declares both, calls neither; nobody invokes them.
- `host.permissions.grant_scope` — implemented (never auto-granted); scansort declares,
  nobody calls.
- `host.editors.list` — implemented, used by nobody (presentation uses
  list_open/export/open, not editors.list).
- `secrets:delete:<handle>` — implemented; obs_controller declares get/set only.
- `host.notify` **capability form** — implemented as a gated capability; the only
  host.notify in the wild is the **ungated JSON-RPC notification** path.
- `network.none` deny marker — implemented for match-table completeness; not usefully
  consumable.
- `host.fs.watch` / `host.fs.unwatch` / `host.fs.changed` — implemented; no surveyed
  plugin subscribes.
- Install/start/stop/restart/remove lifecycle, crash-loop detection, hot-reload,
  PluginDB persistence — host machinery with no plugin-declared surface.
- Audit redaction (`_audit_dispatch`) — host-only.
- `capability:editor.request_save` (the `plugin_owned` save dispatch) — **referenced
  only in a TODO comment; NOT a real dispatch path** (see requirement bug #3).
- JSON Pointer / JSON Patch / blob walker engines — host machinery (only presentation
  drives them, only via patch_state).
- `minerva.getSpreadsheet`/`updateSpreadsheet`/`createNote` bridge convenience methods
  (→ `minerva_get_spreadsheet_data` / `minerva_update_spreadsheet_data` /
  `minerva_create_note`) — present in both bridges; no shipped plugin uses them.

### 4b. Orphan declarations (consumer references the host can't / doesn't satisfy)

- **Host-side `minerva_cad_*` / `minerva_doc_*` / `minerva_create_plugin_editor`** —
  referenced in cad's skill `tool_deps` but NOT implemented in the cad backend. They
  are host-provided tools whose implementation lives in Minerva's `MCP/Modules`,
  outside both the cad backend and the surveyed producer extractors. If absent at
  install, cad's skill `tool_deps` resolution would fail.
- **`permissions.network.ports`** (obs_controller `[4455]`) — no host consumer; parser
  reads only `network.mode` and silently drops `ports`. No egress enforcement anywhere.
- **cad emits `host.notify`** (main.go:140) with an **empty** `permissions.host_capabilities`
  — works only because the JSON-RPC notify path is ungated; the manifest under-declares
  real host usage.
- **scansort backend `./scansort-plugin`** is declared but **not present on disk** — start
  would fail until built. **presentation** declares `./presentation-plugin` but the
  on-disk binary is named `presentation` — entrypoint/binary name mismatch (the CI build
  must produce the entrypoint-named file).
- **elgato → `ws://127.0.0.1:{port}`** — the Minerva-side WebSocket endpoint serving
  this port was not located in any plugin dir or producer extractor; its implementation
  is unconfirmed.

### 4c. Schema-only (legal manifest field, no/minimal consumer)

- `backend.working_dir` — legal, parsed, **never applied** at spawn; no plugin sets it.
- `ui.panels[].chrome.suppress` — legal; only hello_scene smoke panels use it.
- `ui.panels[].multi_window` — legal bool, advisory, no enforcement; only obs_controller
  sets it (false).
- `ui.panels[].fullscreen_capable` — legal bool, advisory, no enforcement; only
  obs_controller (false).
- `events[].payload_schema` — legal pass-through, never validated; only obs_controller
  populates it.
- `state.schema` — legal pass-through, never enforced on set_state/patch_state; only
  obs_controller declares it.
- `permissions.network.ports` — accepted then silently dropped; only obs_controller
  carries it; no consumer.
- `editor_items[].default_filename` — legal; default `untitled` applied in
  PluginEditorRegistry.
- `autostart` / `auto_reload` — legal but loader-asymmetric (not read by from_manifest,
  only by the plugins.json reload path); all shipped set `autostart:false`,
  `auto_reload:true`.
- `save_mode:"plugin_owned"` — legal enum value, but **the host stub is unimplemented**
  (see #3); no shipped panel uses it.
- `layout_hint:"side_by_side"` — legal; cad/test_paired_dsl declare it but the
  horizontal split is unimplemented (opens a sibling tab).

---

## 5. Requirement bugs / dialect drift

1. **`patch_state` arg key is `json_patch`, NOT `patch`** — sending `patch` silently
   no-ops, no host error. (CapabilityBroker.gd:903; presentation/main.go:496;
   MEMORY feedback_patch_state_field_name.)
2. **Success envelope `{success:true, result:{...}}` is load-bearing** — audit logger,
   policy logger, and capability-call unmarshalling all do `result.get("success")`;
   dropping the wrap breaks three consumers silently. Errors are flat (no `result`).
   `host.fs.*` scene channels return a **bare** `{success, error}` exception.
   (PluginErrors.gd:388-415; MEMORY feedback_plugin_errors_success_wrap.)
3. **`save_mode:"plugin_owned"` is UNIMPLEMENTED — false-positive capability.** On Ctrl+S
   for a PLUGIN_SCENE editor in `plugin_owned` mode, `Editor.gd:1538-1554` only
   `push_warning`s ("plugin_owned mode not yet implemented … file NOT written by
   Minerva") and returns. `capability:editor.request_save` appears only in a TODO
   comment (Editor.gd:1542) and a manifest doc-comment (PluginDefinition.gd:747) — **zero
   dispatch sites**. Authors must NOT use `plugin_owned`.
4. **`localhost:9315` MCP HTTP server is unauthenticated and unscoped** —
   `TCPServer.listen(port)` with no bind address (all interfaces), no Authorization/token
   check, agent identity is a TODO (`X-Agent-Id` header, line 320). `minerva.call()`
   POSTs here, bypassing the per-message `ui.ipc_messages` allowlist that gates
   `pluginIPC()`. Every HTML panel — and anything on host/LAN reaching the port — can
   call every MCP tool. (MinervaMCPHttpServer.gd:51-68,189,320.) Confirmed gap, not an
   open question.
5. **`network.mode`/`filesystem.mode` value enums unenforced + no egress layer** —
   there is no network-egress gate anywhere; `permissions.network.mode` is purely
   documentary for all values, and a `mode:"none"` plugin can still open arbitrary
   sockets from its own subprocess. The `network.none` deny marker only blocks a
   dispatch nobody makes. (PluginDefinition.gd:545-546; no gate in PluginPolicy/CapabilityBroker.)
6. **cad UNDER-declares** — emits `host.notify` but declares empty
   `permissions.host_capabilities`. (cad/manifest.json; cad/main.go:140.)
7. **scansort OVER-declares** — 14 host_capabilities declared, only `host.echo` +
   `host.providers.chat` called; declared `filesystem` scoped_paths is bypassed by
   arbitrary-absolute-path `std::fs`. (scansort/manifest.json:418-438 vs src/main.rs.)
8. **Entrypoint/binary name drift** — scansort `./scansort-plugin` (no binary on disk);
   presentation `./presentation-plugin` vs on-disk `presentation`. Start fails "needs to
   be compiled" until the build produces the entrypoint-named binary.
   (presentation/manifest.json:8; confirmed via `ls`.)
9. **cad version drift** — manifest `version` 0.1.2 but `main.go serverVersion` 0.1.1;
   the runtime cache key is `<DataDir>/runtime/<serverVersion>/`, so a manifest bump
   without a serverVersion bump does NOT re-extract the runtime. (cad/main.go:38-39;
   extract.go:71-140.)
10. **events[] dialect drift** — `{name,payload_schema}` (obs_controller) vs
    `{name,description}` (scansort) both parse unvalidated; no canonical shape.
11. **Loader-path asymmetry** — `_from_dict_internal` (manifest parse) does NOT read
    `autostart`/`auto_reload`/`class_names`; only the plugins.json reload path does. A
    fresh manifest's booleans aren't honored at install through from_manifest.
    (PluginDefinition.gd:336-354 vs 482-646.)
12. **`network.ports` silently dropped** — obs_controller declares `[4455]`; parser
    reads only `network.mode`; dead metadata. (PluginDefinition.gd:546.)
13. **Plugin Manager HTML launch ignores `panel.entry`** — probes `ui/<name>.html` then
    `ui/panel.html`. (PluginManagerPanel.gd:926-928.)
14. **`layout_hint:"side_by_side"` split unimplemented** — opens a sibling tab.
    (singleton_object.gd:1505-1507.)
15. **`host.fs.*` scene channels return bare `{success,error}`** not the
    `{success,result}` envelope — reusing the `capability:*` unwrap (`.result`) on them
    mis-reads the reply. (PluginScenePanelBroker.gd:1146,1171.)
16. **Scene-panel event channel is the raw event name** (e.g. `"obs.scene_changed"`),
    not a literal `"event"`; state uses the literal `"state"`. A scene `receive()`
    switch matching `"event"` would never fire. (singleton_object.gd:705-731.)
17. **Interpreter-script plugins have an unshipped/unverified PATH dependency** — the
    host runs whatever `python3`/`python`/`node` is on PATH; no interpreter is bundled
    or verified at install. (PluginManager.gd:495-532; MCPServerConnection.gd:591-652.)
18. **No code signing / GPG / notarization** anywhere in release or install —
    `SHA256SUMS` is the only integrity check and it ships inside the same tarball it
    describes (guards transit corruption, not a malicious publisher). Trust anchored in
    HTTPS to github.com only. (MarketplaceClient.gd:432-461; cad.yml:191-198.)
19. **regen_registry emits all 4 download TARGETS regardless of a plugin's build
    matrix** — cad dropped `linux-arm64` (no aarch64 wheels for cadquery-ocp) yet regen
    would emit a `linux-arm64` URL → 404 on install (download_bad_status).
    (regen_registry.py:38,110-113; cad.yml:35-41.)

---

## 6. Open questions (incl. unresolved critic gaps)

1. **Where are the host-side `minerva_cad_*` / `minerva_doc_*` / `minerva_create_plugin_editor`
   tools implemented?** Referenced in cad's skill `tool_deps` but not in the cad backend;
   presumed in Minerva `MCP/Modules` but not surveyed. Affects whether cad's skill
   install-time `tool_deps` resolution can succeed.
2. **Does the install flow re-persist so manifest `autostart`/`auto_reload` eventually
   win**, or are they genuinely ignored until first restart? Extractors agree the
   manifest-parse path drops them but disagree on the install round-trip.
3. **Is `state.schema` enforced/surfaced anywhere** (MCP tool-schema generation, event
   broker)? It is parsed/round-tripped but no validation path was found — appears
   documentary.
4. **Is `localhost:9315` ever intended to gain plugin-scoped auth?** The code shows it
   is currently unauthenticated/unscoped (requirement bug #4). Confirm whether the open
   binding + missing token is an intentional/known gap or slated for hardening.
5. **The Minerva-side WebSocket endpoint elgato connects to (`ws://127.0.0.1:{port}`)**
   was not located in any plugin dir or producer extractor — its host implementation /
   registration is unconfirmed.
6. **Is `host_api_version` intended to gain a future min-version gate**, or permanently
   advisory? Any value parses today (cad ships int `1`, others string `"1"`).
7. **Latent `get_state` blob-strip bypass:** a FUTURE `paired_dsl` plugin emitting JSON
   `buffer_text` containing `{__blob__}` envelopes would skip the outbound strip walker
   in `get_state` (only `request_panel_state` runs it). Safe today (.mcad is plain-text
   DSL) but a `paired_dsl` `get_state` integration test is missing.
   (CapabilityBroker.gd:2723-2736.)
8. **Windows SubProcess fd/stdin inheritance** was not verified (Windows
   `subprocess.cpp` not read).
9. **CEF bridge convenience-method parity (resolved):** confirmed — `cef_bridge.gd:49-56`
   exposes the same `getSpreadsheet`/`updateSpreadsheet`/`createNote` methods as the WRY
   bridge, and `minerva_get_spreadsheet_data` / `minerva_update_spreadsheet_data` /
   `minerva_create_note` are real host tools (MCPSpreadsheetTools.gd / MCPNotesTools.gd).
10. **`presentation` (godot_scene, `tools:[]`) reaches `host.documents.*` how —**
    via the Go backend's `minerva/capability` upstream calls (confirmed: presentation/main.go
    issues `minerva/capability`), so the panel's host-document access flows through the
    backend, not panel-broker `capability:*` dispatch.
