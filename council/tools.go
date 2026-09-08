package main

import (
	"encoding/json"
	"fmt"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// toolSpec is one entry of the tools/list response.
type toolSpec struct {
	Name        string
	Description string
	InputSchema json.RawMessage
}

// toolHandler takes the raw tools/call arguments and returns the JSON body of
// the tool result. An error becomes an isError result, not a protocol error.
type toolHandler func(args json.RawMessage) ([]byte, error)

type entry struct {
	spec    toolSpec
	handler toolHandler
}

// registry holds the backend's MCP tools in advertised order.
type registry struct {
	entries []entry
}

func (r *registry) register(spec toolSpec, handler toolHandler) {
	r.entries = append(r.entries, entry{spec: spec, handler: handler})
}

func (r *registry) specs() []toolSpec {
	out := make([]toolSpec, 0, len(r.entries))
	for _, e := range r.entries {
		out = append(out, e.spec)
	}
	return out
}

// lookup resolves a tools/call name. The host sends the name it registered
// (PluginMCPTools.gd) and PluginToolRegistry refuses any tool that does not
// carry the minerva_<plugin_id>_ prefix, so the registered name is the only one
// that can arrive.
func (r *registry) lookup(name string) (toolHandler, bool) {
	for _, e := range r.entries {
		if e.spec.Name == name {
			return e.handler, true
		}
	}
	return nil, false
}

// newRegistry wires the backend's tool surface over one command engine.
//
// The surface is deliberately small: a liveness probe, one door for the whole
// protocol command set, the two hooks that move the snapshot in and out for
// host persistence, and a cheap summary. Adding a tool per command would put a
// second, hand-maintained copy of the command enum beside the schema's.
func newRegistry(store *session.Store) *registry {
	r := &registry{}

	r.register(toolSpec{
		Name:        "minerva_council_ping",
		Description: "Liveness handshake for the Council backend. Returns {ok, plugin, version, protocol_version, snapshot_revision} and echoes the optional 'echo' string so a caller can verify round-trip integrity.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"echo": {"type": "string", "description": "Optional string echoed back verbatim."}
			}
		}`),
	}, func(args json.RawMessage) ([]byte, error) {
		var a struct {
			Echo string `json:"echo"`
		}
		if len(args) > 0 {
			// Ignore a parse failure: ping must stay a dependable probe.
			_ = json.Unmarshal(args, &a)
		}
		return json.Marshal(map[string]any{
			"ok":                true,
			"plugin":            serverName,
			"version":           serverVersion,
			"protocol_version":  protocolVersion,
			"snapshot_revision": store.Revision(),
			"echo":              a.Echo,
		})
	})

	r.register(toolSpec{
		Name: "minerva_council_command",
		Description: "Apply one Council protocol command and return the reply envelope. The arguments ARE the request envelope: {request_id, command, base_revision, payload}. " +
			"Mutating commands (definition.upsert, definition.import, source.upsert, session.create, session.bind_chat, run.start, run.cancel, run.retry, outcome.retain) must carry base_revision equal to the current snapshot_revision; " +
			"read commands (snapshot.get, source.fetch, definition.export) must not carry it. A repeated request_id returns the stored reply with replayed:true and applies nothing a second time. " +
			"Every reply carries the snapshot_revision it was produced against; a failure carries {code, message, retryable}. " +
			"source.fetch returns the NEWEST capture of a source when payload.source_revision is omitted; pass a source_revision to read the exact capture a past contribution was grounded in.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"request_id": {"type": "string", "description": "Caller-minted idempotency key. Repeating one returns the stored reply."},
				"command": {"type": "string", "enum": [
					"snapshot.get", "definition.upsert", "definition.export", "definition.import",
					"source.upsert", "source.fetch", "session.create", "session.bind_chat",
					"run.start", "run.cancel", "run.retry", "outcome.retain"
				]},
				"base_revision": {"type": "integer", "description": "The snapshot_revision this command was written against. Required by every mutating command, refused on a read."},
				"payload": {"type": "object", "description": "Command arguments. See the Council architecture document for the shape each command takes."}
			},
			"required": ["request_id", "command", "payload"]
		}`),
	}, func(args json.RawMessage) ([]byte, error) {
		raw, err := normaliseEnvelope(args)
		if err != nil {
			return nil, err
		}
		reply, err := store.Dispatch(raw)
		if err != nil {
			return nil, err
		}
		return json.Marshal(reply)
	})

	r.register(toolSpec{
		Name: "minerva_council_load_snapshot",
		Description: "Hand the backend the council_project_snapshot the panel restored, replacing whatever it was working on. " +
			"Runs the interruption rule: a run that was in flight when its owning process went away is demoted to a visible failed state with an explicit retry, never resumed. " +
			"Returns {ok, snapshot_revision, definitions, sessions, runs_demoted}.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"snapshot": {"type": "object", "description": "A council_project_snapshot record."}
			},
			"required": ["snapshot"]
		}`),
	}, func(args json.RawMessage) ([]byte, error) {
		var a struct {
			Snapshot json.RawMessage `json:"snapshot"`
		}
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, fmt.Errorf("parse arguments: %w", err)
		}
		if len(a.Snapshot) == 0 {
			return nil, fmt.Errorf("argument \"snapshot\" is required")
		}
		report, err := store.Load(a.Snapshot)
		if err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{
			"ok":                true,
			"snapshot_revision": report.SnapshotRevision,
			"definitions":       report.Definitions,
			"sessions":          report.Sessions,
			"runs_demoted":      report.RunsDemoted,
		})
	})

	r.register(toolSpec{
		Name:        "minerva_council_export_snapshot",
		Description: "Return the acknowledged council_project_snapshot for the host to persist. This is the state the panel writes into the project and into a .mcouncil file; the backend keeps nothing durable of its own.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, func(json.RawMessage) ([]byte, error) {
		return json.Marshal(map[string]any{"ok": true, "snapshot": store.Export()})
	})

	r.register(toolSpec{
		Name:        "minerva_council_status",
		Description: "Summarise the loaded snapshot without moving it: the councils it holds, and for each session its status, chat binding, runs and how many outcomes were retained.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, func(json.RawMessage) ([]byte, error) {
		status := store.Status()
		status["ok"] = true
		return json.Marshal(status)
	})

	return r
}

// normaliseEnvelope completes a tools/call argument object into a full request
// envelope. The wrapper hop already sends complete envelopes; an agent calling
// the tool directly supplies only the fields it cares about, and filling the
// two constant ones here means both reach the same validator.
func normaliseEnvelope(args json.RawMessage) ([]byte, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("a command call needs at least request_id, command and payload")
	}
	var fields map[string]any
	if err := json.Unmarshal(args, &fields); err != nil {
		return nil, fmt.Errorf("arguments are not a JSON object: %w", err)
	}
	if _, ok := fields["schema_version"]; !ok {
		fields["schema_version"] = session.SchemaVersion
	}
	if _, ok := fields["envelope"]; !ok {
		fields["envelope"] = "request"
	}
	if _, ok := fields["payload"]; !ok {
		fields["payload"] = map[string]any{}
	}
	return json.Marshal(fields)
}
