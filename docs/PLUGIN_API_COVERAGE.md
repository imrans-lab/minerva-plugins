# Minerva Plugin API — Coverage Ledger

Audit artifact for [`PLUGIN_DEVELOPER_GUIDE.md`](./PLUGIN_DEVELOPER_GUIDE.md). It
proves nothing was silently dropped: the full symbol matrix, the supported languages,
the manifest dialect findings, the three producer/consumer/schema diff lists, the
requirement bugs, and the open questions (including unresolved critic gaps).

Column meaning:
- **in_host** — implemented in the host (producer side).
- **in_schema** — recognized by the manifest parser / capability allowlist.
- **used_by** — shipped plugins that actually exercise it (empty = available-but-unused).

The guarded categories below are compared in both directions with their source
owners during explicit two-repository qualification. Other rows distinguish
runtime behavior, pass-through metadata, unsupported fields and repo-only tooling;
they are not additional capability grants. Guide links are checked locally.
`source_ref` names files and symbols, never unstable line numbers.

---

## 1. Coverage matrix

| symbol | category | in_host | in_schema | used_by | source_ref | guide |
|---|---|---|---|---|---|---|
| CapabilityBroker.dispatch | runtime | yes | no | presentation, scansort, notes_helper, obs_controller, cad | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| mcp.proxy:&lt;tool&gt; | host_api | yes | yes | notes_helper | CapabilityBroker.gd; PluginPolicy.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| secrets:get:&lt;handle&gt; | host_api | yes | yes | obs_controller | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| secrets:set:&lt;handle&gt; | host_api | yes | yes | obs_controller | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| secrets:delete:&lt;handle&gt; | host_api | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.echo` | host_capability | yes | yes | scansort | CapabilityBroker.gd; scansort/src/main.rs | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.list_open` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.get_state` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.set_state` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.mark_dirty` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.get_node` | host_capability | yes | yes | presentation | CapabilityBroker.gd; JsonPointer.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.get_blob` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.put_blob` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.documents.patch_state` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.read` | host_capability | yes | yes | — (scansort declares, uses std::fs) | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.write` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.list` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.exists` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.stat` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.mkdir` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.delete` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.files.move` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.editors.list` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.editors.export` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.editors.open` | host_capability | yes | yes | presentation | CapabilityBroker.gd; presentation/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.providers.chat` | host_capability | yes | yes | scansort | CapabilityBroker.gd; scansort/src/main.rs | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.dialogs.file_picker` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.dialogs.directory_picker` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.permissions.grant_scope` | host_capability | yes | yes | — | CapabilityBroker.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.terminal.exec` | host_capability | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.terminal.list` | host_capability | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.terminal.read` | host_capability | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.terminal.write` | host_capability | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.terminal.wait` | host_capability | yes | yes | agent-relay | CapabilityBroker.gd; PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.pdf.generate` | host_capability | yes | yes | — | CapabilityBroker.gd; src/sidecars/host_pdf/ | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| host.notify (capability form) | host_api | yes | yes | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| host.notify (JSON-RPC notification) | ipc | yes | no | cad, hello_scene | PluginNotifyRouter.gd; MCPServerConnection.gd; cad/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| network.none (deny marker) | host_api | yes | no | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| minerva/capability (plugin→host wire) | ipc | yes | no | presentation, scansort, notes_helper | MCPServerConnection.gd; presentation/main.go; notes_helper/server.py | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| PluginWebviewBroker.handle_ipc_message | ipc | yes | no | obs_controller | PluginWebviewBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| capability:&lt;name&gt; (panel string form) | ipc | yes | no | obs_controller | PluginWebviewBroker.gd; PluginScenePanelBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| PluginScenePanelBroker.handle_scene_request | ipc | yes | no | cad, hello_scene, test_paired_dsl | PluginScenePanelBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| host.fs.watch / host.fs.unwatch | ipc | yes | no | — | PluginScenePanelBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| host.fs.changed (outbound) | event | yes | no | — | PluginScenePanelBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#8-events--state) |
| host_owned_save.get/set/response | ipc | yes | no | presentation | PluginScenePanelBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| attach_buffer / text_changed / detach_buffer | ipc | yes | no | cad, test_paired_dsl | PluginScenePanelBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| minerva/plugin_event (wire) | event | yes | no | obs_controller, scansort, agent-relay | MCPServerConnection.gd; obs_controller/events.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#8-events--state) |
| minerva/plugin_state (wire) | state | yes | no | obs_controller | MCPServerConnection.gd; obs_controller/events.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| PLUGIN_EVENT trigger type (trigger_type=4) | trigger | yes | yes | agent-relay | TriggerDefinition.gd; TriggerManager.gd; MCPAgentTools.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| `id` | manifest_field | yes | yes | all 8 | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `name` | manifest_field | yes | yes | all 8 | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `version` | manifest_field | yes | yes | all 8 | PluginDefinition.gd; cad/main.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `host_api_version` | manifest_field | yes | yes | all 8 | PluginDefinition.gd; PluginMCPTools.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `backend.transport` | manifest_field | yes | yes | all 8 | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `backend.entrypoint` | manifest_field | yes | yes | all 8 | PluginDefinition.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `backend.args` | manifest_field | yes | yes | hello_scene, notes_helper, test_paired_dsl, test_stdio_server | PluginDefinition.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `backend.working_dir` | manifest_field | yes | yes | — | PluginDefinition.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `tools` | manifest_field | yes | yes | obs_controller, notes_helper, test_stdio_server, scansort | PluginDefinition.gd; PluginToolRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `tools[].name` | manifest_field | yes | yes | (same) | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| tools[].description | manifest_metadata | yes | yes | (same) | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| tools[].input_schema | manifest_metadata | yes | yes | obs_controller, notes_helper, scansort | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `skills` | manifest_field | yes | yes | cad | PluginDefinition.gd; cad/manifest.json | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui` | manifest_field | yes | yes | cad, scansort, presentation, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.ipc_messages` | manifest_field | yes | yes | cad, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginWebviewBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels` | manifest_field | yes | yes | cad, scansort, presentation, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].name` | manifest_field | yes | yes | (same) | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].kind` | manifest_field | yes | yes | (same) | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].entry` | manifest_field | yes | yes | obs_controller | PluginDefinition.gd; PluginManagerPanel.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].entry_scene` | manifest_field | yes | yes | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginScenePanelHost.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].scripts` | manifest_field | yes | yes | (scene plugins) | PluginDefinition.gd; PluginScenePanelHost.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].file_extensions` | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginEditorRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].ipc_channels` | manifest_field | yes | yes | cad, obs_controller, hello_scene, test_paired_dsl | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].save_mode` | manifest_field | yes | yes | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].chrome.suppress` | manifest_field | yes | yes | hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].fullscreen_capable` | manifest_field | yes | yes | obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].multi_window` | manifest_field | yes | yes | obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].render_mode` | manifest_field | yes | yes | cad, test_paired_dsl | PluginDefinition.gd; singleton_object.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].layout_hint` | manifest_field | yes | yes | cad, test_paired_dsl | PluginDefinition.gd; singleton_object.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `events` | manifest_field | yes | yes | obs_controller, scansort | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| events[].name | manifest_metadata | yes | yes | obs_controller, scansort | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| events[].payload_schema | manifest_metadata | yes | yes | obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `state.schema` | manifest_field | yes | yes | obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `editor_items` | manifest_field | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| editor_items[].id | manifest_metadata | yes | yes | (same) | PluginDefinition.gd; PluginEditorRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| editor_items[].name | manifest_metadata | yes | yes | cad, presentation, hello_scene | PluginEditorRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| editor_items[].panel | manifest_metadata | yes | yes | (same) | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| editor_items[].default_filename | manifest_metadata | yes | yes | (same) | PluginEditorRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| capabilities[] (top-level) | manifest_metadata | yes | yes | cad, presentation, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `project_state` | plugin_capability | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#31-there-is-one-dialect) |
| `host_owned_save` | plugin_capability | yes | yes | cad, presentation, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#31-there-is-one-dialect) |
| `project_export` | plugin_capability | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#31-there-is-one-dialect) |
| `project_file` | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `project_file.serialize_channel` | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `project_file.deserialize_channel` | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `project_export.collect_channel` | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `project_export.apply_channel` | manifest_field | yes | yes | cad, hello_scene | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions` | manifest_field | yes | yes | scansort, presentation, obs_controller, cad, notes_helper | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions.host_capabilities` | manifest_field | yes | yes | scansort, presentation, obs_controller, notes_helper | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions.network.mode` | manifest_field | yes | yes | obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| permissions.network.ports | permission | **no** | **no** | obs_controller (declared, dropped) | PluginDefinition.gd; obs_controller/manifest.json | [reference](PLUGIN_DEVELOPER_GUIDE.md#13-permissions--security-model) |
| `permissions.filesystem.mode` | manifest_field | yes | yes | scansort, notes_helper, obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions.filesystem.paths` | manifest_field | yes | yes | scansort, notes_helper, obs_controller | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| data_directory | manifest_metadata | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| autostart | manifest_metadata | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| auto_reload | manifest_metadata | yes | yes | cad, presentation, hello_scene, test_paired_dsl | PluginDefinition.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| class_names | manifest_metadata | yes | no | (host-populated) | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| STDIO transport / SubProcess.start | runtime | yes | no | all 8 | MCPServerConnection.gd; subprocess.cpp | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| MCP initialize handshake | ipc | yes | no | all 8 | MCPServerConnection.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| tools/call routing + namespacing | ipc | yes | no | cad, scansort, presentation, obs_controller, notes_helper, test_stdio_server | PluginToolRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| PluginDB.install / install_plugin | lifecycle | yes | no | — | PluginDB.gd; PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| start/stop/restart/remove | lifecycle | yes | no | — | PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| Crash detection / CRASH_LOOP | lifecycle | yes | no | — | PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| PluginDefinition.State enum | state | yes | no | — | PluginDefinition.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| PluginManager lifecycle signals | event | yes | no | — | PluginManager.gd; singleton_object.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#8-events--state) |
| tools_registered/unregistered signals | event | yes | no | — | PluginToolRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#8-events--state) |
| `auto_reload` file watcher | lifecycle | yes | no | — | PluginManager.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| PluginDB persistence + boot reconstruction | lifecycle | yes | no | — | PluginDB.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| PluginErrors success/error envelope | runtime | yes | no | presentation, scansort, cad, notes_helper, obs_controller | PluginErrors.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| Audit redaction | runtime | yes | no | — | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| window.minerva JS bridge (WRY + CEF) | ipc | yes | no | obs_controller | minerva_bridge.gd; cef_bridge.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| HTML webview hosts (CEF preferred / WRY fallback) | ui_surface | yes | no | obs_controller | CefWebViewEditor.gd; WebViewEditor.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| PluginScenePanelHost (native mount) | ui_surface | yes | no | cad, scansort, presentation, hello_scene, test_paired_dsl | PluginScenePanelHost.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| MinervaPluginPanel + lifecycle hooks | lifecycle | yes | no | (scene plugins) | MinervaPluginPanel.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| PluginEditorRegistry | registry | yes | no | cad, presentation, hello_scene, test_paired_dsl | PluginEditorRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#14-registry--release) |
| Document state (canonicality model) | document_model | yes | no | cad, presentation, test_paired_dsl | CapabilityBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#12-document--state-model) |
| JSON Pointer (RFC 6901) | document_model | yes | no | presentation | JsonPointer.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#12-document--state-model) |
| JSON Patch (RFC 6902) | document_model | yes | no | presentation | JsonPatch.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#12-document--state-model) |
| Blob storage / reference model | document_model | yes | no | presentation | PluginScenePanelBroker.gd; slide_model.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#12-document--state-model) |
| Annotation model | document_model | yes | no | presentation, cad, hello_scene | presentation_tile_annotation_host.gd; cad/ui/CadAnnotationHost.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#12-document--state-model) |
| Embedded Python runtime (go:embed PBS) | runtime | no (plugin-side) | no | cad | cad/internal/runtime/embed.go; extract.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| build-python-runtime-bundle.sh + .lock | runtime | no (plugin-side) | no | cad | scripts/build-python-runtime-bundle.sh; cad/scripts/runtime-bundle.lock | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| registry.json + regen_registry.py | registry | no (repo-side) | no | cad, scansort, presentation | registry.json; regen_registry.py | [reference](PLUGIN_DEVELOPER_GUIDE.md#14-registry--release) |
| MarketplaceClient install pipeline | runtime | yes | no | cad, scansort, presentation | MarketplaceClient.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| Release tag + tarball naming | registry | no (repo-side) | no | cad, scansort, presentation | presentation.yml; regen_registry.py | [reference](PLUGIN_DEVELOPER_GUIDE.md#14-registry--release) |
| save_mode=plugin_owned (UNIMPLEMENTED) | lifecycle | **no (stub)** | yes | — | Editor.gd (TODO, push_warning only) | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| minerva.call / minerva.createNote | ipc | yes | no | MultiMeter (canonical Sheets create) | minerva_bridge.gd; cef_bridge.gd; PluginWebviewBroker.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#6-html-panels--the-ipc-model) |
| localhost:9315 MCP HTTP server | runtime | yes | no | direct HTTP clients | MinervaMCPHttpServer.gd; separate from the native panel bridge | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| elgato Stream Deck companion (separate substrate) | language | no (external) | no | elgato | plugins/elgato/manifest.json; src/index.ts | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| `host.settings.get` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_settings_get`; PluginSettingsStore.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.settings.list` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_settings_list` | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.models.list_providers` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_models_list_providers` | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.models.list_models` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_models_list_models` | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.chat_providers.register` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_chat_providers_register`; PluginChatProviderRegistry.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| host.chat_providers.unregister **(2026-08)** | host_api | yes | **no (rides the register grant — declaring it fails install)** | — | CapabilityBroker `_handle_host_chat_providers_unregister`; PluginDefinition `ALLOWED_HOST_CAPABILITIES` | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.project.current` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_project_current` | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.project.open` | host_capability | yes | yes | — | CapabilityBroker `_handle_host_project_open` | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| PluginProvider (plugin-as-chat-provider) **(2026-08)** | runtime | yes | no | — | Providers/PluginProvider.gd `generate_content`, `_apply_result_to_bot` | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| `settings` | manifest_field | yes | yes | — | PluginDefinition `SETTING_TYPES`, `validate()`; PluginSettingsStore.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `settings_title` | manifest_field | yes | yes | — | PluginSettingsStore `scope_tab` | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| setup{} (requires/steps) **(2026-08)** | manifest_metadata | yes | yes | 8 of 10: nametag-maker, pcb, presentation (go_build); 3d-gen, agent-relay, drive, movie-gen, scansort (cargo_build+copy). cad + codetools abstain — embedded-runtime build not expressible in v1 vocabulary | Setup/SetupSchema.gd, SetupPipeline.gd, SetupExecutors.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `setup` stripped from packed manifest **(2026-08)** | registry | n/a (repo-side) | n/a | every release workflow | .github/workflows/*.yml pack step; pcb/manifest_binary_tier_test.go | [reference](PLUGIN_DEVELOPER_GUIDE.md#14-registry--release) |
| setup toolchain registry + preflight **(2026-08)** | runtime | yes | n/a | pcb | Setup/ToolchainRegistry.gd `TOOLS`, ToolchainProbe.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| install_lane (manifest \| marketplace) **(2026-08)** | manifest_metadata | yes | no (host-recorded) | all | PluginDefinition `LANE_MANIFEST`/`LANE_MARKETPLACE`, `resolve_install_lane` | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| release_targets **(2026-08)** | manifest_metadata | **no (repo/CI only)** | **no (parser ignores)** | all 10 | */manifest.json; scripts/regen_registry.py | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| tools[].executor: "panel" **(2026-08)** | manifest_metadata | yes | yes | pcb (76 of 88), cad | PluginToolRegistry; PluginDefinition `_from_dict_internal` | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| S_BUILDING / S_BUILD_FAILED / S_NEEDS_BINARY **(2026-08)** | state | yes | no | — | PluginManager.gd `S_BUILDING`…`S_NEEDS_BINARY` (**not** members of `PluginDefinition.State`) | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| minerva_plugin_build_status **(2026-08)** | host_tool | yes | n/a | — | PluginMCPTools.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| minerva_plugin_setup_dry_run **(2026-08)** | host_tool | yes | n/a | — | PluginMCPTools.gd; Setup/SetupDryRun.gd | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| minerva_get/set/list_preference(s) **(2026-08)** | host_tool | yes | n/a | — | MCP preference tools → PluginSettingsStore | [reference](PLUGIN_DEVELOPER_GUIDE.md#1-overview--plugin-anatomy) |
| `_on_panel_apply_sync` | panel_hook | yes | no | pcb, cad | PluginScenePanelHost `invoke_apply_sync` | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_create_note_request` | panel_hook | yes | no | — | PluginScenePanelHost `invoke_create_note` | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_restore_from_note` | panel_hook | yes | no | — | PluginScenePanelHost `invoke_restore_from_note` | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_render_for_llm` | panel_hook | yes | no | — | PluginScenePanelHost `invoke_render_for_llm` | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_inject_toggle_changed` | panel_hook | yes | no | — | PluginScenePanelHost `invoke_inject_toggle` | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| panel hook `on_progress` **(2026-08)** | lifecycle | **partial — delivery only, no producer wiring** | no (implicit channel) | — | PluginScenePanelBroker `push_progress` (carries a TODO(integration)) | [reference](PLUGIN_DEVELOPER_GUIDE.md#9-transport--lifecycle) |
| Annotation substrate v2 **(2026-08)** | document_model | yes | no | pcb, cad, hello_scene | src/Scripts/Services/Annotations/*; `get_annotation_host()` | [reference](PLUGIN_DEVELOPER_GUIDE.md#12-document--state-model) |
| filesystem mode "unrestricted" **(2026-08)** | permission | yes | yes | — (no shipped plugin declares it) | PluginDefinition `filesystem_mode`; CapabilityBroker `_files_scope_check` | [reference](PLUGIN_DEVELOPER_GUIDE.md#13-permissions--security-model) |
| `host.audio` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.chat.active` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.chat.input` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.core.session` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.notes.create_from_editor` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.notify` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `host.speech_log` | host_capability | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#42-capability-reference) |
| `mcp.proxy:` | capability_namespace | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITY_NAMESPACES | [reference](PLUGIN_DEVELOPER_GUIDE.md#4-host-apis--capabilities-a-plugin-can-call) |
| `secrets:` | capability_namespace | yes | yes | — | PluginDefinition.ALLOWED_HOST_CAPABILITY_NAMESPACES | [reference](PLUGIN_DEVELOPER_GUIDE.md#4-host-apis--capabilities-a-plugin-can-call) |
| `live_reload` | plugin_capability | yes | yes | — | PluginDefinition.CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#31-there-is-one-dialect) |
| `plugin_dependencies` | plugin_capability | yes | yes | — | PluginDefinition.CAPABILITIES | [reference](PLUGIN_DEVELOPER_GUIDE.md#31-there-is-one-dialect) |
| `backend` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `capabilities` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `knowledge` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `knowledge_project` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `log_stderr` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `panel_authority` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions.filesystem` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions.host_events` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `permissions.network` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `project_export` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `requires_plugins` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `requires_plugins[].actions` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#required-providers-and-readiness) |
| `requires_plugins[].id` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#required-providers-and-readiness) |
| `requires_plugins[].min_version` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#required-providers-and-readiness) |
| `setup` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `state` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `tools[].executor` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `tools[].tool_set` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].chrome` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].file_actions` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].native_save_extensions` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `ui.panels[].write_guidance` | manifest_field | yes | yes | — | PluginDefinition parser/validator | [reference](PLUGIN_DEVELOPER_GUIDE.md#32-field-reference) |
| `_on_panel_capture_live_state` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_load_request` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_loaded` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_redo_request` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_restore_live_state` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_save_request` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_self_check` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_undo_request` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `_on_panel_unload` | panel_hook | yes | n/a | — | PluginScenePanelHost invocation sites | [reference](PLUGIN_DEVELOPER_GUIDE.md#71-panel-lifecycle-hooks-full-list) |
| `res://Scripts/Services/Annotations/AnnotationV2Schema.gd` | host_path | yes | n/a | — | PluginGenerationStore.HOST_PATHS | [reference](PLUGIN_DEVELOPER_GUIDE.md#public-scene-sdk) |
| `res://Scripts/Services/Annotations/BuiltinKinds.gd` | host_path | yes | n/a | — | PluginGenerationStore.HOST_PATHS | [reference](PLUGIN_DEVELOPER_GUIDE.md#public-scene-sdk) |
| `res://Scripts/Services/Documents/DocumentBuffer.gd` | host_path | yes | n/a | — | PluginGenerationStore.HOST_PATHS | [reference](PLUGIN_DEVELOPER_GUIDE.md#public-scene-sdk) |
| `res://Scripts/Services/Plugins/AtomicFile.gd` | host_path | yes | n/a | — | PluginGenerationStore.HOST_PATHS | [reference](PLUGIN_DEVELOPER_GUIDE.md#public-scene-sdk) |
| `res://Scripts/Services/Plugins/MinervaPluginPanel.gd` | host_path | yes | n/a | — | PluginGenerationStore.HOST_PATHS | [reference](PLUGIN_DEVELOPER_GUIDE.md#public-scene-sdk) |
| `res://Scripts/UI/Controls/responsive_container.gd` | host_path | yes | n/a | — | PluginGenerationStore.HOST_PATHS | [reference](PLUGIN_DEVELOPER_GUIDE.md#public-scene-sdk) |
| `MinervaIPC.get_bulk_payload_limit` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#contextual-calls-and-cancellation) |
| `MinervaIPC.request_bulk` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#contextual-calls-and-cancellation) |
| `MinervaIPC.request_capability` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#contextual-calls-and-cancellation) |
| `MinervaIPC.request_private` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#contextual-calls-and-cancellation) |
| `RequiredPlugins.release_page` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#required-providers-and-readiness) |
| `RequiredPlugins.repository` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#required-providers-and-readiness) |
| `handle_tool` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#contextual-calls-and-cancellation) |
| `handle_tool_with_context` | sdk_method | yes | n/a | — | MinervaIPC; PluginToolRegistry; RequiredPlugins | [reference](PLUGIN_DEVELOPER_GUIDE.md#contextual-calls-and-cancellation) |
| `repo` | required_plugin_field | yes | n/a | — | RequiredPlugins.repository | [reference](PLUGIN_DEVELOPER_GUIDE.md#required-providers-and-readiness) |

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
- Install/start/stop/restart/remove lifecycle, crash-loop detection, auto_reload,
  PluginDB persistence — host machinery with no plugin-declared surface.
- Audit redaction (`_audit_dispatch`) — host-only.
- `capability:editor.request_save` (the `plugin_owned` save dispatch) — **referenced
  only in a TODO comment; NOT a real dispatch path** (see requirement bug #3).
- JSON Pointer / JSON Patch / blob walker engines — host machinery (only presentation
  drives them, only via patch_state).
- `minerva.createNote` bridge convenience method (→ `minerva_create_note`).
  Sheets tools use generic `minerva.call` with canonical `minerva_sheets_*` names.

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
4. **Direct loopback HTTP and the panel bridge are separate interfaces.**
   `minerva.call()` uses native IPC and the registered panel identity, with exact
   cross-plugin capability grants. Direct HTTP clients use the loopback MCP
   listener and its own access policy. (`PluginWebviewBroker.gd`;
   `MinervaMCPHttpServer.gd`.)
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
6. **`host_api_version` is an exact install/start gate.** `PluginDefinition`
   converts the manifest value to a string, then `host_api_error()` requires
   `"2"`; `PluginManager` checks it before install/start. Loading an old saved
   record remains allowed, but that does not make an incompatible plugin runnable.
7. **Latent `get_state` blob-strip bypass:** a FUTURE `paired_dsl` plugin emitting JSON
   `buffer_text` containing `{__blob__}` envelopes would skip the outbound strip walker
   in `get_state` (only `request_panel_state` runs it). Safe today (.mcad is plain-text
   DSL) but a `paired_dsl` `get_state` integration test is missing.
   (CapabilityBroker.gd.)
8. **Windows SubProcess fd/stdin inheritance** was not verified (Windows
   `subprocess.cpp` not read).
9. **CEF bridge parity:** `cef_bridge.gd` uses the same `MinervaBridge.BRIDGE_JS`.
   Both expose generic `call`, `pluginIPC` and `createNote`. Plugin MCP calls use
   the native broker and the exact tool capability grant.
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
