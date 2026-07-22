// Package tools — host_owned / project-state channel handlers.
//
// The manifest declares four ipc_channels — pcb.serialize, pcb.deserialize,
// pcb.collect_export, pcb.apply_export — and lists them in ui.ipc_messages.
// The broker gotcha (project hint store): every ipc_channels entry MUST be
// registered as a backend MCP tool under the EXACT name AND appear in the
// ui.ipc_messages allowlist, or the broker returns permission_denied at
// runtime (gap register row A-7).
//
// pcb.serialize / pcb.deserialize are the REAL board-source codec (this round):
//   - pcb.serialize   args {board:<canonical Board JSON>} → {yaml:"<source>"}
//   - pcb.deserialize args {yaml:"..."} OR {minpcb_json:<legacy JSON>}
//     → {board:<canonical Board JSON dict>, warnings:[...]}
//
// pcb.collect_export / pcb.apply_export remain thin echo passthroughs for the
// project_export capability (untouched this round).
//
// Backward-compat note: the manifest binds pcb.serialize/deserialize to the
// project_file capability, whose original walking-skeleton contract echoed a
// {state} blob. To avoid regressing that path, the handlers fall back to the
// {state} echo when no board/yaml/minpcb_json argument is supplied. See
// docs/board-yaml.md and the round findings for this dual contract.
package tools

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/board"
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

// Serialize renders a canonical Board model to deterministic YAML source.
var Serialize = ToolSpec{
	Name:        "pcb.serialize",
	Description: "Serialize a canonical PCB board model to YAML board-source. Args {board:<Board JSON>}; returns {yaml}. If the serialized source exceeds the 64 KiB IPC cap it returns {error:'payload_too_large', bytes:N} instead of truncating. Falls back to {state} echo when no board is supplied (project_file compat).",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"board":{"type":"object","description":"Canonical Board model (see docs/board-yaml.md)."},"state":{"type":"object","description":"Legacy project_file state (echo fallback)."}}}`),
}

var Deserialize = ToolSpec{
	Name:        "pcb.deserialize",
	Description: "Parse board-source into the canonical Board model. Args {yaml} OR {minpcb_json:<legacy .minpcb JSON>}; returns {board, warnings}. Warnings flag non-canonical fields (still preserved losslessly). Falls back to {state} echo when neither is supplied (project_file compat).",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"yaml":{"type":"string","description":"Canonical board YAML source."},"minpcb_json":{"description":"Legacy .minpcb JSON (object or JSON string)."},"state":{"type":"object","description":"Legacy project_file state (echo fallback)."}}}`),
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

// HandleSerialize marshals a canonical Board (given as JSON under "board") to
// YAML board-source. Enforces the 64 KiB IPC payload cap: an oversized document
// yields a structured {error:"payload_too_large", bytes:N} rather than a
// truncated body. With no "board" it falls back to the project_file {state}
// echo so the host_owned save skeleton path is not regressed.
func HandleSerialize(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	var a struct {
		Board json.RawMessage `json:"board"`
	}
	if len(params) > 0 {
		// Malformed params must error, not silently fall through to the echo
		// path: a caller who SENT a board deserves a parse error, not {ok}.
		if err := json.Unmarshal(params, &a); err != nil {
			return nil, fmt.Errorf("pcb.serialize: parse params: %w", err)
		}
	}
	if len(a.Board) == 0 {
		// Genuinely absent board → project_file compatibility echo fallback.
		return echoState(ctx, params)
	}

	var b board.Board
	if err := json.Unmarshal(a.Board, &b); err != nil {
		return nil, fmt.Errorf("pcb.serialize: parse board: %w", err)
	}
	// Serialize is a fail-closed WRITE gate: refuse to emit canonical-looking
	// source for a board that would not survive the shared validation boundary
	// (bad/missing version, unminted or duplicate persistent id). Mirrors how
	// HandleDeserialize reports a validation error — a code-bearing wrapped
	// board.Validate error (finding 019f8b7fb07e, part 1).
	if err := board.Validate(&b); err != nil {
		return nil, fmt.Errorf("pcb.serialize: invalid board: %w", err)
	}
	yml, err := board.MarshalYAML(&b)
	if err != nil {
		return nil, fmt.Errorf("pcb.serialize: %w", err)
	}
	if len(yml) > board.MaxPayloadBytes {
		return json.Marshal(map[string]interface{}{
			"error": "payload_too_large",
			"bytes": len(yml),
		})
	}
	return json.Marshal(map[string]interface{}{"yaml": string(yml)})
}

// HandleDeserialize parses board-source into the canonical Board dict. Accepts
// {yaml} or {minpcb_json} (the latter an object or a JSON-encoded string).
// Returns {board, warnings}. With neither it falls back to the {state} echo.
func HandleDeserialize(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	var a struct {
		YAML       string          `json:"yaml"`
		MinpcbJSON json.RawMessage `json:"minpcb_json"`
	}
	if len(params) > 0 {
		// Malformed params must error, not silently fall through to the echo
		// path (see HandleSerialize).
		if err := json.Unmarshal(params, &a); err != nil {
			return nil, fmt.Errorf("pcb.deserialize: parse params: %w", err)
		}
	}

	var (
		b        *board.Board
		warnings []string
		err      error
	)
	switch {
	case a.YAML != "":
		b, err = board.UnmarshalYAML([]byte(a.YAML))
	case len(a.MinpcbJSON) > 0:
		b, warnings, err = board.ImportMinpcb(unwrapJSON(a.MinpcbJSON))
	default:
		return echoState(ctx, params) // project_file compatibility fallback
	}
	if err != nil {
		return nil, fmt.Errorf("pcb.deserialize: %w", err)
	}
	// v1→v2 identity migration (design decision D3): a sub-v2 board gets its
	// persistent ids minted here, at the deserialize boundary, and is persisted
	// on the host's next pcb.serialize. Idempotent — a v2 board is untouched.
	// Serialize never mints; it writes what it is given.
	if b.Version == 1 {
		n, mErr := board.MigrateV1toV2(b, board.DefaultIDSource())
		if mErr != nil {
			return nil, fmt.Errorf("pcb.deserialize: migrate v1→v2: %w", mErr)
		}
		if n > 0 {
			warnings = append(warnings,
				fmt.Sprintf("migrated board source v1→v2: minted %d persistent entity id(s)", n))
		}
	} else if vErr := board.Validate(b); vErr != nil {
		// Only a true v1 board migrates. Anything else — an inbound v2 board, or an
		// unsupported version (0/missing/3) — must satisfy the shared validation
		// boundary (comment 629). Gating on ==1 (not <2) stops a version-0/missing
		// board from being silently "fixed" by migration, matching the Python
		// validator which calls it unsupported_schema_version. Fail closed.
		return nil, fmt.Errorf("pcb.deserialize: invalid board: %w", vErr)
	}
	if warnings == nil {
		warnings = []string{}
	}
	return json.Marshal(map[string]interface{}{
		"board":    b,
		"warnings": warnings,
	})
}

// unwrapJSON tolerates minpcb_json arriving as a JSON-encoded string (a common
// shape when a host double-encodes) by unquoting it once; otherwise returns the
// raw bytes unchanged.
func unwrapJSON(raw json.RawMessage) []byte {
	if len(raw) > 0 && raw[0] == '"' {
		var s string
		if json.Unmarshal(raw, &s) == nil {
			return []byte(s)
		}
	}
	return raw
}

// HandleCollectExport / HandleApplyExport remain project_export echo
// passthroughs (untouched this round).
func HandleCollectExport(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return echoState(ctx, params)
}

func HandleApplyExport(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return echoState(ctx, params)
}
