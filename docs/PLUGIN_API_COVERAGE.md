# Minerva Plugin API — Coverage Ledger

Audit artifact for [`PLUGIN_DEVELOPER_GUIDE.md`](./PLUGIN_DEVELOPER_GUIDE.md). It
proves nothing was silently dropped: the full symbol matrix, the supported languages,
the manifest dialect findings, the three producer/consumer/schema diff lists, the
requirement bugs, and the open questions (including unresolved critic gaps).

Column meaning:
- **in_host** — implemented in the host (producer side).
- **in_schema** — recognized by the manifest parser / capability allowlist.
- **used_by** — shipped plugins that actually exercise it (empty = available-but-unused).

> **Revision state.** The original audit was taken against Minerva as of 2026-06-13.
> This revision (2026-08-17, Minerva `adcb58e3`) re-verified the *claims* and folded in
> the substrate added since — the `setup` build pipeline and install lanes, manifest
> `settings`, eight host capabilities (`host.settings.*`, `host.models.*`,
> `host.chat_providers.*`, `host.project.*`), six panel lifecycle hooks, three
> setup-pipeline states, and the annotation substrate. Rows and findings added or
> corrected in this pass are marked **(2026-08)**.
>
> **`source_ref` carries files and symbols, never line numbers.** The original audit
> pinned every reference to a line; a single epoch of work moved nearly all of them
> (`CapabilityBroker.gd` alone grew past 4000 lines), which made the column actively
> misleading — it looked precise while pointing at the wrong code. All 223 line
> references were removed in this pass. **Grep for the symbol**; file and symbol names
> survive refactors that line numbers do not. Keep it that way when you add rows.

---

## 1. Coverage matrix

| symbol | category | in_host | in_schema | used_by | source_ref |
|---|---|---|---|---|---|
| CapabilityBroker.dispatch | runtime | yes | no | presentation, scansort, notes_helper, obs_controller, cad | CapabilityBroker.gd |
| mcp.proxy:&lt;tool&gt; | host_api | yes | yes | notes_helper | CapabilityBroker.gd; PluginPolicy.gd |
| secrets:get:&lt;handle&gt; | host_api | yes | yes | obs_controller | CapabilityBroker.gd |
| secrets:set:&lt;handle&gt; | host_api | yes | yes | obs_controller | CapabilityBroker.gd |
| secrets:delete:&lt;handle&gt; | host_api | yes | yes | — | CapabilityBroker.gd |
| host.echo | host_api | yes | yes | scansort | CapabilityBroker.gd; scansort/src/main.rs |
| host.documents.list_open | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.documents.get_state | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.documents.set_state | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.documents.mark_dirty | host_api | yes | yes | — | CapabilityBroker.gd |
| host.documents.get_node | host_api | yes | yes | presentation | CapabilityBroker.gd; JsonPointer.gd |
| host.documents.get_blob | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.documents.put_blob | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.documents.patch_state | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.files.read | host_api | yes | yes | — (scansort declares, uses std::fs) | CapabilityBroker.gd |
| host.files.write | host_api | yes | yes | — | CapabilityBroker.gd |
| host.files.list | host_api | yes | yes | — | CapabilityBroker.gd |
| host.files.exists | host_api | yes | yes | — | CapabilityBroker.gd |
| host.files.stat | host_api | yes | yes | — | CapabilityBroker.gd |
| host.files.mkdir | host_api | yes | yes | — | CapabilityBroker.gd |
| host.files.delete | host_api | yes | yes | — | CapabilityBroker.gd |
| host.files.move | host_api | yes | yes | — | CapabilityBroker.gd |
| host.editors.list | host_api | yes | yes | — | CapabilityBroker.gd |
| host.editors.export | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.editors.open | host_api | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go |
| host.providers.chat | host_api | yes | yes | scansort | CapabilityBroker.gd; scansort/src/main.rs |
| host.dialogs.file_picker | host_api | yes | yes | — | CapabilityBroker.gd |
| host.dialogs.directory_picker | host_api | yes | yes | — | CapabilityBroker.gd |
| host.permissions.grant_scope | permission | yes | yes | — | CapabilityBroker.gd; PluginManager.gd |
| host.terminal.exec | host_api | yes | yes | — | CapabilityBroker.gd |
| host.terminal.list | host_api | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd |
| host.terminal.read | host_api | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd |
| host.terminal.write | host_api | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd |
| host.terminal.wait | host_api | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd |
| host.pdf.generate | host_api | yes | yes | — | CapabilityBroker.gd; src/sidecars/host_pdf/ |
| host.notify (capability form) | host_api | yes | yes | — | CapabilityBroker.gd |
| host.notify (JSON-RPC notification) | ipc | yes | no | cad, hello_scene | PluginNotifyRouter.gd; MCPServerConnection.gd; cad/main.go |
| network.none (deny marker) | host_api | yes | no | — | CapabilityBroker.gd |
| minerva/capability (plugin→host wire) | ipc | yes | no | presentation, scansort, notes_helper | MCPServerConnection.gd; presentation/main.go; notes_helper/server.py |
| PluginWebviewBroker.handle_ipc_message | ipc | yes | no | obs_controller | PluginWebviewBroker.gd |
| capability:&lt;name&gt; (panel string form) | ipc | yes | no | obs_controller | PluginWebviewBroker.gd; PluginScenePanelBroker.gd |
| PluginScenePanelBroker.handle_scene_request | ipc | yes | no | cad, hello_scene, test_paired_dsl | PluginScenePanelBroker.gd |
| host.fs.watch / host.fs.unwatch | ipc | yes | no | — | PluginScenePanelBroker.gd |
| host.fs.changed (outbound) | event | yes | no | — | PluginScenePanelBroker.gd |
| host_owned_save.get/set/response | ipc | yes | no | presentation | PluginScenePanelBroker.gd |
| attach_buffer / text_changed / detach_buffer | ipc | yes | no | cad, test_paired_dsl | PluginScenePanelBroker.gd |
| minerva/plugin_event (wire) | event | yes | no | obs_controller, scansort, agent-relay | MCPServerConnection.gd; obs_controller/events.go |
| minerva/plugin_state (wire) | state | yes | no | obs_controller | MCPServerConnection.gd; obs_controller/events.go |
| PLUGIN_EVENT trigger type (trigger_type=4) | trigger | yes | yes | agent-relay | TriggerDefinition.gd; TriggerManager.gd; MCPAgentTools.gd |
| id | manifest_field | yes | yes | all 8 | PluginDefinition.gd |
| name | manifest_field | yes | yes | all 8 | PluginDefinition.gd |
| version | manifest_field | yes | yes | all 8 | PluginDefinition.gd; cad/main.go |
| host_api_version | manifest_field | yes | yes | all 8 | PluginDefinition.gd; PluginMCPTools.gd |
| backend.transport | manifest_field | yes | yes | all 8 | PluginDefinition.gd |
| backend.entrypoint | manifest_field | yes | yes | all 8 | PluginDefinition.gd; PluginManager.gd |
| backend.args | manifest_field | yes | yes | hello_scene, notes_helper, test_paired_dsl, test_stdio_server | PluginDefinition.gd; PluginManager.gd |
| backend.working_dir | manifest_field | yes | yes | — | PluginDefinition.gd; PluginManager.gd |
| tools[] | manifest_field | yes | yes | obs_controller, notes_helper, test_stdio_server, scansort | PluginDefinition.gd; PluginToolRegistry.gd |
| tools[].name | manifest_field | yes | yes | (same) | PluginDefinition.gd |
| tools[].description | manifest_field | yes | yes | (same) | PluginDefinition.gd |
| tools[].input_schema | manifest_field | yes | yes | obs_controller, notes_helper, scansort | PluginDefinition.gd |
| skills[] | manifest_field | yes | yes | cad | PluginDefinition.gd; cad/manifest.json |
| ui | manifest_field | yes | yes | cad, scansort, presentation, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd |
| ui.ipc_messages | manifest_field | yes | yes | cad, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginWebviewBroker.gd |
| ui.panels[] | manifest_field | yes | yes | cad, scansort, presentation, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd |
| ui.panels[].name | manifest_field | yes | yes | (same) | PluginDefinition.gd |
| ui.panels[].kind | manifest_field | yes | yes | (same) | PluginDefinition.gd |
| ui.panels[].entry | manifest_field | yes | yes | obs_controller | PluginDefinition.gd; PluginManagerPanel.gd |
| ui.panels[].entry_scene | manifest_field | yes | yes | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginScenePanelHost.gd |
| ui.panels[].scripts | manifest_field | yes | yes | (scene plugins) | PluginDefinition.gd; PluginScenePanelHost.gd |
| ui.panels[].file_extensions | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginEditorRegistry.gd |
| ui.panels[].ipc_channels | manifest_field | yes | yes | cad, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd |
| ui.panels[].save_mode | manifest_field | yes | yes | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd |
| ui.panels[].chrome.suppress | manifest_field | yes | yes | hello_scene | PluginDefinition.gd |
| ui.panels[].fullscreen_capable | manifest_field | yes | yes | obs_controller | PluginDefinition.gd |
| ui.panels[].multi_window | manifest_field | yes | yes | obs_controller | PluginDefinition.gd |
| ui.panels[].render_mode | manifest_field | yes | yes | cad, test_paired_dsl | PluginDefinition.gd; singleton_object.gd |
| ui.panels[].layout_hint | manifest_field | yes | yes | cad, test_paired_dsl | PluginDefinition.gd; singleton_object.gd |
| events[] | manifest_field | yes | yes | obs_controller, scansort | PluginDefinition.gd |
| events[].name | manifest_field | yes | yes | obs_controller, scansort | PluginDefinition.gd |
| events[].payload_schema | manifest_field | yes | yes | obs_controller | PluginDefinition.gd |
| state.schema | manifest_field | yes | yes | obs_controller | PluginDefinition.gd |
| editor_items[] | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd |
| editor_items[].id | manifest_field | yes | yes | (same) | PluginDefinition.gd; PluginEditorRegistry.gd |
| editor_items[].name | manifest_field | yes | yes | cad, presentation, hello_scene | PluginEditorRegistry.gd |
| editor_items[].panel | manifest_field | yes | yes | (same) | PluginDefinition.gd |
| editor_items[].default_filename | manifest_field | yes | yes | (same) | PluginEditorRegistry.gd |
| capabilities[] (top-level) | manifest_field | yes | yes | cad, presentation, hello_scene | PluginDefinition.gd |
| capability: project_state | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| capability: host_owned_save | manifest_field | yes | yes | cad, presentation, hello_scene | PluginDefinition.gd |
| capability: project_export | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| project_file | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| project_file.serialize_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| project_file.deserialize_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| project_export | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| project_export.collect_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| project_export.apply_channel | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd |
| permissions | manifest_field | yes | yes | scansort, presentation, obs_controller, cad, notes_helper | PluginDefinition.gd |
| permissions.host_capabilities | permission | yes | yes | scansort, presentation, obs_controller, notes_helper | PluginDefinition.gd |
| permissions.network.mode | permission | yes | yes | obs_controller | PluginDefinition.gd |
| permissions.network.ports | permission | **no** | **no** | obs_controller (declared, dropped) | PluginDefinition.gd; obs_controller/manifest.json |
| permissions.filesystem.mode | permission | yes | yes | scansort, notes_helper, obs_controller | PluginDefinition.gd |
| permissions.filesystem.paths | permission | yes | yes | scansort, notes_helper, obs_controller | PluginDefinition.gd |
| data_directory | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd |
| autostart | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginManager.gd |
| auto_reload | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginManager.gd |
| class_names | manifest_field | yes | no | (host-populated) | PluginDefinition.gd |
| STDIO transport / SubProcess.start | runtime | yes | no | all 8 | MCPServerConnection.gd; subprocess.cpp |
| MCP initialize handshake | ipc | yes | no | all 8 | MCPServerConnection.gd |
| tools/call routing + namespacing | ipc | yes | no | cad, scansort, presentation, obs_controller, notes_helper, test_stdio_server | PluginToolRegistry.gd |
| PluginDB.install / install_plugin | lifecycle | yes | no | — | PluginDB.gd; PluginManager.gd |
| start/stop/restart/remove | lifecycle | yes | no | — | PluginManager.gd |
| Crash detection / CRASH_LOOP | lifecycle | yes | no | — | PluginManager.gd |
| PluginDefinition.State enum | state | yes | no | — | PluginDefinition.gd |
| PluginManager lifecycle signals | event | yes | no | — | PluginManager.gd; singleton_object.gd |
| tools_registered/unregistered signals | event | yes | no | — | PluginToolRegistry.gd |
| Hot reload (auto_reload watch) | lifecycle | yes | no | — | PluginManager.gd |
| PluginDB persistence + boot reconstruction | lifecycle | yes | no | — | PluginDB.gd |
| PluginErrors success/error envelope | runtime | yes | no | presentation, scansort, cad, notes_helper, obs_controller | PluginErrors.gd |
| Audit redaction | runtime | yes | no | — | CapabilityBroker.gd |
| window.minerva JS bridge (WRY + CEF) | ipc | yes | no | obs_controller | minerva_bridge.gd; cef_bridge.gd |
| HTML webview hosts (CEF preferred / WRY fallback) | ui_surface | yes | no | obs_controller | CefWebViewEditor.gd; WebViewEditor.gd |
| PluginScenePanelHost (native mount) | ui_surface | yes | no | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginScenePanelHost.gd |
| MinervaPluginPanel + lifecycle hooks | lifecycle | yes | no | (scene plugins) | MinervaPluginPanel.gd |
| PluginEditorRegistry | registry | yes | no | cad, presentation, hello_scene, test_paired_dsl | PluginEditorRegistry.gd |
| Document state (canonicality model) | document_model | yes | no | cad, presentation, test_paired_dsl | CapabilityBroker.gd |
| JSON Pointer (RFC 6901) | document_model | yes | no | presentation | JsonPointer.gd |
| JSON Patch (RFC 6902) | document_model | yes | no | presentation | JsonPatch.gd |
| Blob storage / reference model | document_model | yes | no | presentation | PluginScenePanelBroker.gd; slide_model.gd |
| Annotation model | document_model | yes | no | presentation, cad, hello_scene | presentation_tile_annotation_host.gd; cad/ui/CadAnnotationHost.gd |
| Embedded Python runtime (go:embed PBS) | runtime | no (plugin-side) | no | cad | cad/internal/runtime/embed.go; extract.go |
| build-python-runtime-bundle.sh + .lock | runtime | no (plugin-side) | no | cad | scripts/build-python-runtime-bundle.sh; cad/scripts/runtime-bundle.lock |
| registry.json + regen_registry.py | registry | no (repo-side) | no | cad, scansort, presentation | registry.json; regen_registry.py |
| MarketplaceClient install pipeline | runtime | yes | no | cad, scansort, presentation | MarketplaceClient.gd |
| Release tag + tarball naming | registry | no (repo-side) | no | cad, scansort, presentation | presentation.yml; regen_registry.py |
| save_mode=plugin_owned (UNIMPLEMENTED) | lifecycle | **no (stub)** | yes | — | Editor.gd (TODO, push_warning only) |
| minerva.getSpreadsheet/updateSpreadsheet/createNote | ipc | yes | no | — (host tools confirmed) | minerva_bridge.gd; cef_bridge.gd; MCPSpreadsheetTools.gd, MCPNotesTools.gd |
| localhost:9315 MCP HTTP server (no auth) | runtime | yes | no | obs_controller (via minerva.call) | MinervaMCPHttpServer.gd |
| elgato Stream Deck companion (separate substrate) | language | no (external) | no | elgato | plugins/elgato/manifest.json; src/index.ts |
| host.settings.get **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_settings_get`; PluginSettingsStore.gd |
| host.settings.list **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_settings_list` |
| host.models.list_providers **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_models_list_providers` |
| host.models.list_models **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_models_list_models` |
| host.chat_providers.register **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_chat_providers_register`; PluginChatProviderRegistry.gd |
| host.chat_providers.unregister **(2026-08)** | host_api | yes | **no (rides the register grant — declaring it fails install)** | — | CapabilityBroker `_handle_host_chat_providers_unregister`; PluginDefinition `ALLOWED_HOST_CAPABILITIES` |
| host.project.current **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_project_current` |
| host.project.open **(2026-08)** | host_api | yes | yes | — | CapabilityBroker `_handle_host_project_open` |
| PluginProvider (plugin-as-chat-provider) **(2026-08)** | runtime | yes | no | — | Providers/PluginProvider.gd `generate_content`, `_apply_result_to_bot` |
| settings[] **(2026-08)** | manifest_field | yes | yes | — | PluginDefinition `SETTING_TYPES`, `validate()`; PluginSettingsStore.gd |
| settings_title **(2026-08)** | manifest_field | yes | yes | — | PluginSettingsStore `scope_tab` |
| setup{} (requires/steps) **(2026-08)** | manifest_field | yes | yes | 8 of 10: nametag-maker, pcb, presentation (go_build); 3d-gen, agent-relay, drive, movie-gen, scansort (cargo_build+copy). cad + codetools abstain — embedded-runtime build not expressible in v1 vocabulary | Setup/SetupSchema.gd, SetupPipeline.gd, SetupExecutors.gd |
| `setup` stripped from packed manifest **(2026-08)** | registry | n/a (repo-side) | n/a | every release workflow | .github/workflows/*.yml pack step; pcb/manifest_binary_tier_test.go |
| setup toolchain registry + preflight **(2026-08)** | runtime | yes | n/a | pcb | Setup/ToolchainRegistry.gd `TOOLS`, ToolchainProbe.gd |
| install_lane (manifest \| marketplace) **(2026-08)** | manifest_field | yes | no (host-recorded) | all | PluginDefinition `LANE_MANIFEST`/`LANE_MARKETPLACE`, `resolve_install_lane` |
| release_targets **(2026-08)** | manifest_field | **no (repo/CI only)** | **no (parser ignores)** | all 10 | */manifest.json; scripts/regen_registry.py |
| tools[].executor: "panel" **(2026-08)** | manifest_field | yes | yes | pcb (76 of 88), cad | PluginToolRegistry; PluginDefinition `_from_dict_internal` |
| S_BUILDING / S_BUILD_FAILED / S_NEEDS_BINARY **(2026-08)** | state | yes | no | — | PluginManager.gd `S_BUILDING`…`S_NEEDS_BINARY` (**not** members of `PluginDefinition.State`) |
| minerva_plugin_build_status **(2026-08)** | host_tool | yes | n/a | — | PluginMCPTools.gd |
| minerva_plugin_setup_dry_run **(2026-08)** | host_tool | yes | n/a | — | PluginMCPTools.gd; Setup/SetupDryRun.gd |
| minerva_get/set/list_preference(s) **(2026-08)** | host_tool | yes | n/a | — | MCP preference tools → PluginSettingsStore |
| panel hook `_on_panel_apply_sync` **(2026-08)** | lifecycle | yes | no | pcb, cad | PluginScenePanelHost `invoke_apply_sync` |
| panel hook `_on_panel_create_note_request` **(2026-08)** | lifecycle | yes | no | — | PluginScenePanelHost `invoke_create_note` |
| panel hook `_on_panel_restore_from_note` **(2026-08)** | lifecycle | yes | no | — | PluginScenePanelHost `invoke_restore_from_note` |
| panel hook `_on_panel_render_for_llm` **(2026-08)** | lifecycle | yes | no | — | PluginScenePanelHost `invoke_render_for_llm` |
| panel hook `_on_panel_inject_toggle_changed` **(2026-08)** | lifecycle | yes | no | — | PluginScenePanelHost `invoke_inject_toggle` |
| panel hook `_on_hot_reload` **(2026-08)** | lifecycle | yes | no | — | PluginManager (hot-reload dispatch) |
| panel hook `on_progress` **(2026-08)** | lifecycle | **partial — delivery only, no producer wiring** | no (implicit channel) | — | PluginScenePanelBroker `push_progress` (carries a TODO(integration)) |
| Annotation substrate v2 **(2026-08)** | document_model | yes | no | pcb, cad, hello_scene | src/Scripts/Services/Annotations/*; `get_annotation_host()` |
| filesystem mode "unrestricted" **(2026-08)** | permission | yes | yes | — (no shipped plugin declares it) | PluginDefinition `filesystem_mode`; CapabilityBroker `_files_scope_check` |

---

## 2. Supported languages / runtimes

1. **Compiled native stdio MCP binary (language-agnostic: Go, Rust, …)** — `backend.transport:"stdio"` + `backend.entrypoint:"./<binary>"`. Author ships a per-platform compiled binary. Examples: obs_controller (Go), scansort (Rust), presentation (Go).
2. **Go shim + go:embed'd PBS CPython worker** — declared as an ordinary stdio binary; internally embeds a python-build-standalone CPython + packages per `(GOOS,GOARCH)`, extracts to `<DataDir>/runtime/<version>/`, proxies over length-prefixed framing (not MCP). Isolated env → no host/plugin library collisions. Example: cad (also ships a godot_scene panel).
3. **Interpreter + script (Python today; Node.js documented, unexercised)** — `entrypoint:"python3"`/`"python"`, `args:["server.py"]`. No shipped/verified interpreter — PATH dependency. Examples: hello_scene, notes_helper, test_paired_dsl, test_stdio_server.
4. **Native GDScript / Godot scene panel** — `ui.panels[].kind:"godot_scene"` + `entry_scene` + `scripts[]` (whitelist, audited), mounted in-process. Still declares a stdio backend (may be a stub). Examples: cad CADPanel, presentation SlideEditorPanel, scansort ScansortPanel, hello_scene, test_paired_dsl.
5. **HTML/JS webview panel** — `ui.panels[].kind:"html"` + `entry:"ui/panel.html"`, self-contained; host injects `window.minerva`; runs in godot-cef (preferred) or godot_wry (fallback). Example: obs_controller (Go backend + HTML panel — canonical multi-language example).
6. **TypeScript/Bun external Stream Deck companion (NOT a Minerva-manifest plugin)** — Elgato manifest schema, `bun build --compile`, connects to Minerva via `ws://127.0.0.1:{port}` as a client. Example: elgato.

**(2026-08) Orthogonal to the six above: who compiles the artifact.** A compiled backend
now has two delivery paths reading the same `manifest.json` — the **marketplace lane**
(prebuilt, SHA-pinned tarball) and the **manifest lane** (dev/side-load, where a `setup`
stanza makes the host build from source at install: `go_build`, `cargo_build`,
`python_venv`, `copy`, `exec`, gated by a `requires` toolchain preflight over
`go`/`cargo`/`python`/`node`/`bun`/`zig`/`scons`). This is a packaging axis, not a
seventh language. `pcb` is the reference consumer. See the developer guide §17.

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
- `host.permissions.grant_scope` — implemented; scansort declares, nobody calls.
  **(2026-08 correction)** it is no longer held back from the auto-grant: the host's
  never-auto-grant list is now empty by owner decision ("install is the trust act"), so
  a manifest declaring `grant_scope` gets it granted at install like any other
  capability. (`PluginManager._NEVER_AUTO_GRANT` / `_auto_grant_declared_capabilities`.)
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
- **cad emits `host.notify`** (main.go) with an **empty** `permissions.host_capabilities`
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
   no-ops, no host error. (CapabilityBroker.gd; presentation/main.go;
   MEMORY feedback_patch_state_field_name.)
2. **Success envelope `{success:true, result:{...}}` is load-bearing** — audit logger,
   policy logger, and capability-call unmarshalling all do `result.get("success")`;
   dropping the wrap breaks three consumers silently. Errors are flat (no `result`).
   `host.fs.*` scene channels return a **bare** `{success, error}` exception.
   (PluginErrors.gd; MEMORY feedback_plugin_errors_success_wrap.)
3. **`save_mode:"plugin_owned"` is UNIMPLEMENTED — false-positive capability.** On Ctrl+S
   for a PLUGIN_SCENE editor in `plugin_owned` mode, `Editor.gd` only
   `push_warning`s ("plugin_owned mode not yet implemented … file NOT written by
   Minerva") and returns. `capability:editor.request_save` appears only in a TODO
   comment (Editor.gd) and a manifest doc-comment (PluginDefinition.gd) — **zero
   dispatch sites**. Authors must NOT use `plugin_owned`.
4. **`localhost:9315` MCP HTTP server is unauthenticated and unscoped** — no
   Authorization/token check, agent identity is a TODO. `minerva.call()` POSTs here,
   bypassing the per-message `ui.ipc_messages` allowlist that gates `pluginIPC()`, so
   every HTML panel — and any other process on the same machine — can call every MCP
   tool. **(2026-08 partial fix)** the "binds all interfaces" half is resolved: the
   server now listens on `BIND_ADDRESS = "127.0.0.1"` so the OS rejects non-local
   connections at the socket layer. Exposure is same-host, no longer LAN-wide; the
   missing auth/scoping stands. (`MinervaMCPHttpServer.gd` `BIND_ADDRESS`.)
5. **`network.mode`/`filesystem.mode` value enums unenforced + no egress layer** —
   there is no network-egress gate anywhere; `permissions.network.mode` is purely
   documentary for all values, and a `mode:"none"` plugin can still open arbitrary
   sockets from its own subprocess. The `network.none` deny marker only blocks a
   dispatch nobody makes. (PluginDefinition.gd; no gate in PluginPolicy/CapabilityBroker.)
6. **cad UNDER-declares** — emits `host.notify` but declares empty
   `permissions.host_capabilities`. (cad/manifest.json; cad/main.go.)
7. **scansort OVER-declares** — 14 host_capabilities declared, only `host.echo` +
   `host.providers.chat` called; declared `filesystem` scoped_paths is bypassed by
   arbitrary-absolute-path `std::fs`. (scansort/manifest.json vs src/main.rs.)
8. **Entrypoint/binary name drift** — scansort `./scansort-plugin` (no binary on disk);
   presentation `./presentation-plugin` vs on-disk `presentation`. Start fails "needs to
   be compiled" until the build produces the entrypoint-named binary.
   (presentation/manifest.json; confirmed via `ls`.)
9. **cad version drift** — manifest `version` 0.1.2 but `main.go serverVersion` 0.1.1;
   the runtime cache key is `<DataDir>/runtime/<serverVersion>/`, so a manifest bump
   without a serverVersion bump does NOT re-extract the runtime. (cad/main.go;
   extract.go.)
10. **events[] dialect drift** — `{name,payload_schema}` (obs_controller) vs
    `{name,description}` (scansort) both parse unvalidated; no canonical shape.
11. **Loader-path asymmetry** — `_from_dict_internal` (manifest parse) does NOT read
    `autostart`/`auto_reload`/`class_names`; only the plugins.json reload path does. A
    fresh manifest's booleans aren't honored at install through from_manifest.
    (PluginDefinition.gd vs 482-646.)
12. **`network.ports` silently dropped** — obs_controller declares `[4455]`; parser
    reads only `network.mode`; dead metadata. (PluginDefinition.gd.)
13. **Plugin Manager HTML launch ignores `panel.entry`** — probes `ui/<name>.html` then
    `ui/panel.html`. (PluginManagerPanel.gd.)
14. **`layout_hint:"side_by_side"` split unimplemented** — opens a sibling tab.
    (singleton_object.gd.)
15. **`host.fs.*` scene channels return bare `{success,error}`** not the
    `{success,result}` envelope — reusing the `capability:*` unwrap (`.result`) on them
    mis-reads the reply. (PluginScenePanelBroker.gd.)
16. **Scene-panel event channel is the raw event name** (e.g. `"obs.scene_changed"`),
    not a literal `"event"`; state uses the literal `"state"`. A scene `receive()`
    switch matching `"event"` would never fire. (singleton_object.gd.)
17. **Interpreter-script plugins have an unshipped/unverified PATH dependency** — the
    host runs whatever `python3`/`python`/`node` is on PATH; no interpreter is bundled
    or verified at install. (PluginManager.gd; MCPServerConnection.gd.)
18. **No code signing / GPG / notarization** anywhere in release or install —
    `SHA256SUMS` is the only integrity check and it ships inside the same tarball it
    describes (guards transit corruption, not a malicious publisher). Trust anchored in
    HTTPS to github.com only. (MarketplaceClient.gd; cad.yml.)
19. **regen_registry emits all 4 download TARGETS regardless of a plugin's build
    matrix** — cad dropped `linux-arm64` (no aarch64 wheels for cadquery-ocp) yet regen
    would emit a `linux-arm64` URL → 404 on install (download_bad_status).
    (regen_registry.py; cad.yml.)
20. **PLUGIN_EVENT consecutive_fire_limit reset fires only for agent chats** —
    `TriggerManager._reset_plugin_event_consecutive_if_human` is invoked from
    `agent_chat_finished` which only emits for `IsAgentChat` histories
    (ChatPane.gd). A paused PLUGIN_EVENT trigger whose target is a plain (non-agent)
    chat does NOT re-arm on human message; re-arm by toggling `enabled` via
    `minerva_update_trigger`. The primary use-case (MESSAGE_EXISTING into an agent
    chat) is unaffected. (TriggerManager.gd; resolution of docket 019eafc1d9b3.)
21. **host.terminal.wait bell_rung is always false on Windows** — the ghostty-vt shim
    that exposes the BEL counter is only compiled for Unix/macOS. On Windows the
    terminal glue has no shim; `bell_serial` is never incremented.
    (MCPTerminalTools.gd; scripts/build-extensions.sh.)
22. **(2026-08) `host.chat_providers.unregister` is dispatchable but undeclarable** — the
    broker maps it onto the `host.chat_providers.register` grant, and it is deliberately
    absent from `ALLOWED_HOST_CAPABILITIES`. A manifest listing it fails
    `validate_host_capabilities()` with `unknown host_capability`, i.e. install fails.
    The asymmetry is intentional but discoverable only by reading the broker.
23. **(2026-08) `MINERVA_PLUGIN_DATA_DIR` is not set by the host** — the guide previously
    claimed Minerva injects it at spawn. It does not; `SubProcess.start()` takes no env
    parameter and nothing in Minerva sets any plugin env var. The only in-tree reader is
    `src/test/marketplace_test_helpers.gd`. Our own `shared/runtime.DataDir()` treats it
    as an optional override and falls through to a per-OS user data dir, so no shipped
    plugin is broken — but the *claim* was wrong and code comments repeated it.
24. **(2026-08) Setup `exec` steps fail closed with no approver** — an install driven by
    an agent or CI (no interactive approver wired) denies every `exec` step rather than
    running it, ending the build with `detail: exec_denied`. Correct-by-design, but a
    plugin whose only producer is an `exec` step is uninstallable headlessly.
25. **(2026-08) Progress notifications have a delivery half and no producer half** —
    `PluginScenePanelBroker.push_progress()` → `panel.on_progress()` is implemented and
    audited, but nothing routes a backend `{"method":"progress"}` notification into it;
    the broker carries an explicit `TODO(integration)`. A panel implementing
    `on_progress` today will simply never be called.
26. **(2026-08) `PluginDefinition.State` does not include the three setup states** —
    `S_BUILDING`/`S_BUILD_FAILED`/`S_NEEDS_BINARY` are plain ints (6/7/8) defined on
    `PluginManager` and assigned into a field typed as the six-member enum. Deliberate
    (scope fence, and GDScript enums are ints), but any consumer switching exhaustively
    over `PluginDefinition.State` will not see them.

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
4. **Is `localhost:9315` ever intended to gain plugin-scoped auth?** ~~The code shows it
   is currently unauthenticated/unscoped~~ **(2026-08: half answered.)** The open
   *binding* was a known gap and has been closed — the server now binds `127.0.0.1`
   with an explicit comment saying the endpoint is unauthenticated and must never be
   reachable off-host. Whether it gains a *token* and per-plugin scoping is still open
   (agent identity remains a TODO). See requirement bug #4.
5. **The Minerva-side WebSocket endpoint elgato connects to (`ws://127.0.0.1:{port}`)**
   was not located in any plugin dir or producer extractor — its host implementation /
   registration is unconfirmed.
6. **Is `host_api_version` intended to gain a future min-version gate**, or permanently
   advisory? Any value parses today (cad ships int `1`, others string `"1"`).
7. **Latent `get_state` blob-strip bypass:** a FUTURE `paired_dsl` plugin emitting JSON
   `buffer_text` containing `{__blob__}` envelopes would skip the outbound strip walker
   in `get_state` (only `request_panel_state` runs it). Safe today (.mcad is plain-text
   DSL) but a `paired_dsl` `get_state` integration test is missing.
   (CapabilityBroker.gd.)
8. **Windows SubProcess fd/stdin inheritance** was not verified (Windows
   `subprocess.cpp` not read).
9. **CEF bridge convenience-method parity (resolved):** confirmed — `cef_bridge.gd`
   exposes the same `getSpreadsheet`/`updateSpreadsheet`/`createNote` methods as the WRY
   bridge, and `minerva_get_spreadsheet_data` / `minerva_update_spreadsheet_data` /
   `minerva_create_note` are real host tools (MCPSpreadsheetTools.gd / MCPNotesTools.gd).
10. **`presentation` (godot_scene, `tools:[]`) reaches `host.documents.*` how —**
    via the Go backend's `minerva/capability` upstream calls (confirmed: presentation/main.go
    issues `minerva/capability`), so the panel's host-document access flows through the
    backend, not panel-broker `capability:*` dispatch.
11. **(2026-08) What routes a backend progress notification to `push_progress`?** The
    broker's own TODO names the missing piece (a handler in `MinervaMCPServer` or a
    dedicated notification router) but nothing implements it. Open: is the producer half
    scheduled, or should `on_progress` be documented as deprecated-before-arrival?
12. **(2026-08) Are `settings[]` writable by the plugin that declares them?** Today: no —
    only `host.settings.get`/`.list` exist, and agents write through
    `minerva_set_preference`. Open whether a `host.settings.set` is deliberately withheld
    (settings are user-owned) or simply not built yet.
13. **(2026-08) Does the `setup` toolchain registry intend to stay closed at seven
    tools?** `go`, `cargo`, `python`, `node`, `bun`, `zig`, `scons` are hardcoded in
    `ToolchainRegistry.TOOLS`; a plugin needing anything else (cmake, dotnet, …) has no
    declarable `requires` entry and must fall back to an `exec` step — which is exactly
    the step type that fails closed headlessly (bug #24).
