// Package tools — host_owned / project-state channel handlers (walking skeleton).
//
// The manifest declares four ipc_channels — pcb.serialize, pcb.deserialize,
// pcb.collect_export, pcb.apply_export — and lists them in ui.ipc_messages.
// The broker gotcha (project hint store): every ipc_channels entry MUST be
// registered as a backend MCP tool under the EXACT name AND appear in the
// ui.ipc_messages allowlist, or the broker returns permission_denied at
// runtime. Before this file the scaffold registered only `ping`, leaving those
// four channels declared-but-unserved (gap register row A-7). These handlers
// close that inconsistency so the manifest↔backend contract is internally
// consistent.
//
// Walking-skeleton semantics: the board's canonical truth lives PANEL-side and
// round-trips through the host_owned panel hooks (_on_panel_save_request /
// _on_panel_load_request), NOT through these channels. The real host_owned FILE
// save never touches the backend. These channels back the SEPARATE project_file
// (.minproj) / project_export capabilities, which the skeleton slice does not
// exercise. They are therefore intentionally thin echo passthroughs: they accept
// whatever state dict the host hands them and hand it straight back, so a future
// project-state round-trip is a slot-in, not a reshape.
package tools

import (
	"context"
	"encoding/json"
)

// echoState is the shared handler for the four project channels. It unmarshals
// the incoming arguments (tolerating an empty/absent body) and echoes the
// `state` field back verbatim under `state`, plus an `ok` marker. This proves
// the channel is wired end-to-end (broker → backend tool → broker) without
// pretending to own board truth it does not have this round.
func echoState(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var a struct {
		State json.RawMessage `json:"state"`
	}
	if len(params) > 0 {
		_ = json.Unmarshal(params, &a)
	}
	reply := map[string]interface{}{
		"ok":     true,
		"plugin": "pcb",
	}
	if len(a.State) > 0 {
		reply["state"] = a.State
	} else {
		reply["state"] = map[string]interface{}{}
	}
	return json.Marshal(reply)
}

// Serialize/Deserialize back the project_file capability (.minproj state).
var Serialize = ToolSpec{
	Name:        "pcb.serialize",
	Description: "project_file serialize channel (walking skeleton echo). Returns {ok, plugin, state} echoing the supplied state.",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"state":{"type":"object"}}}`),
}

var Deserialize = ToolSpec{
	Name:        "pcb.deserialize",
	Description: "project_file deserialize channel (walking skeleton echo). Returns {ok, plugin, state} echoing the supplied state.",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"state":{"type":"object"}}}`),
}

// Collect/Apply back the project_export capability.
var CollectExport = ToolSpec{
	Name:        "pcb.collect_export",
	Description: "project_export collect channel (walking skeleton echo). Returns {ok, plugin, state}.",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"state":{"type":"object"}}}`),
}

var ApplyExport = ToolSpec{
	Name:        "pcb.apply_export",
	Description: "project_export apply channel (walking skeleton echo). Returns {ok, plugin, state}.",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"state":{"type":"object"}}}`),
}

// HandleSerialize / HandleDeserialize / HandleCollectExport / HandleApplyExport
// all delegate to echoState — the skeleton has no per-channel divergence yet.
func HandleSerialize(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return echoState(ctx, params)
}

func HandleDeserialize(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return echoState(ctx, params)
}

func HandleCollectExport(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return echoState(ctx, params)
}

func HandleApplyExport(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return echoState(ctx, params)
}
