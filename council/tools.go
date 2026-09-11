package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/ipeerbhai/plugins/council/internal/session"
	"github.com/ipeerbhai/plugins/council/presets"
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
	// The two tools the registered chat entry names. They live beside the rest
	// of the surface but answer in the host's provider envelope, not this one's
	// — see chatprovider.go.
	registerChatTools(r, store)

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
			"Mutating commands (definition.upsert, definition.import, source.upsert, source.capture, member.upsert, member.adopt_source, session.create, session.bind_chat, run.start, run.cancel, run.retry, outcome.retain, outcome.mark_missing) must carry base_revision equal to the current snapshot_revision; " +
			"read commands (snapshot.get, source.fetch, definition.export, run.await) must not carry it. A repeated request_id returns the stored reply with replayed:true and applies nothing a second time. " +
			"Every reply carries the snapshot_revision it was produced against; a failure carries {code, message, retryable}. " +
			"source.fetch returns the NEWEST capture of a source when payload.source_revision is omitted; pass a source_revision to read the exact capture a past contribution was grounded in." +
			" source.capture derives a source revision's hash and excerpt spans from the raw text so the page and the engine cannot disagree about them, and repairs an inventory entry in place when the text hashes to the revision's recorded content_hash. member.upsert edits an identity and mints member_revision itself, advancing it only when kind, represents, scope, limitations or grounding change; it never touches seats. member.adopt_source is the explicit act of moving a member onto another capture, which leaves every past run reading what it actually read. definition.export takes include_content and an optional include_source_ids selection, and reports which sources' content travelled." +
			" run.start CONSULTS THE MEMBERS: it sets the round going and answers within a bounded wait (the envelope's optional wait_seconds, 1-25, default 20) with the run_id and the run's status so far, plus every contribution's status, model and usage and the chair's synthesis if it is already there. A round that outruns the wait keeps going; read it with run.await, which takes the same wait_seconds, and stop it with run.cancel. Each initial member is sent the same context snapshot and its own pinned grounding and never another member's answer. run.start's payload takes seat_ids (who is consulted), kind, prompt, addressed_seat_id or addressed_claim_id (a follow-up to a member or to one argument, routed to whoever made it, and consulting that seat alone), model_overrides keyed by seat_id, and limits, which may only NARROW the council's own max_concurrent_members, max_prompt_bytes, per_member_timeout_seconds and run_budget_seconds. run.cancel stops a run that is still running and suppresses what is in flight: a reply landing afterwards is recorded stale and moves nothing. run.retry starts a fresh run over the seats that did not answer, narrowable with seat_ids; nothing ever retries or resumes on its own." +
			" outcome.mark_missing records that a retained note could not be resolved, or that it has come back; the reference is kept either way, because a note the user moved or deleted is a recoverable state and never a reason to lose the link back to the contribution.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"request_id": {"type": "string", "description": "Caller-minted idempotency key. Repeating one returns the stored reply."},
				"command": {"type": "string", "enum": [
					"snapshot.get", "definition.upsert", "definition.export", "definition.import",
					"source.upsert", "source.capture", "source.fetch",
					"member.upsert", "member.adopt_source",
					"session.create", "session.bind_chat",
					"run.start", "run.await", "run.cancel", "run.retry", "outcome.retain", "outcome.mark_missing"
				]},
				"expected_project_id": {"type": "string", "description": "Pin the command to this document identity; a different loaded document is refused before execution."},
				"base_revision": {"type": "integer", "description": "The snapshot_revision this command was written against. Required by every mutating command, refused on a read."},
				"payload": {"type": "object", "description": "Command arguments. See the Council architecture document for the shape each command takes."},
				"wait_seconds": {"type": "integer", "minimum": 1, "maximum": 25, "description": "Top-level bounded wait for run.start, run.await or run.retry; defaults to 20 seconds."}
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
			"Migrates a document written by an older Council up to this build's shape, minting the durable project identity if it has none. " +
			"Runs the interruption rule: a run that was in flight when its owning process went away is demoted to a visible failed state with an explicit retry, never resumed. " +
			"In mode \"reopen\" — the panel's own seeding path — it keeps what it is already holding when that is a later state of the same document, which is the round that kept going after the panel closed, and says so with recovered:true. " +
			"Returns {ok, snapshot_revision, project_id, definitions, sessions, runs_demoted, migrations, recovered}; export the snapshot whenever migrations, recovered or a changed revision says the record moved.",
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"snapshot": {"type": "object", "description": "A council_project_snapshot record."},
				"mode": {"type": "string", "enum": ["replace", "reopen"], "description": "replace (the default) makes the engine hold exactly this document, stopping anything it was running. reopen is the panel's own seeding path: it is the same, except that a later state of THIS document already in the engine is kept and reported with recovered:true, which is what stops a round that outlived its panel from being thrown away."}
			},
			"required": ["snapshot"]
		}`),
	}, func(args json.RawMessage) ([]byte, error) {
		var a struct {
			Snapshot json.RawMessage `json:"snapshot"`
			Mode     string          `json:"mode"`
		}
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, fmt.Errorf("parse arguments: %w", err)
		}
		if len(a.Snapshot) == 0 {
			return nil, fmt.Errorf("argument \"snapshot\" is required")
		}
		switch a.Mode {
		case "", "replace", "reopen":
		default:
			return nil, fmt.Errorf("mode %q is not one this tool has; it is \"replace\" (the default) or \"reopen\"", a.Mode)
		}
		// Opening a document is the natural moment to re-read the host's model
		// list: it is a host call, so it has to happen with the engine lock
		// released, and this is the last point before Load takes it. A failure
		// is not fatal — the previous catalogue stands and hints go unchecked.
		refresh, cancel := context.WithTimeout(context.Background(), chatDiscoveryTimeout)
		if err := store.RefreshModels(refresh); err != nil {
			log.Printf("could not refresh the host's enabled models on load: %v", err)
		}
		cancel()
		load := store.Load
		if a.Mode == "reopen" {
			load = store.Reopen
		}
		report, err := load(a.Snapshot)
		if err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{
			"ok":                true,
			"snapshot_revision": report.SnapshotRevision,
			"project_id":        report.ProjectID,
			"definitions":       report.Definitions,
			"sessions":          report.Sessions,
			"runs_demoted":      report.RunsDemoted,
			"migrations":        report.Migrations,
			"recovered":         report.Recovered,
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
		Name: "minerva_council_models",
		Description: "Re-read Minerva's enabled providers and models, and return them. Council offers these as a member's model_spec (legacy model_hint is supported) and refuses one the host does not have before a round starts, " +
			"so this is what to call after enabling a model in Minerva's settings. Returns {ok, models:[{provider_key, provider_display, model_name, display, model_spec?}], known}. " +
			"known is false when the host could not be asked at all, which is the state in which a hint travels unchecked. " +
			"THE FIRST ENTRY MATTERS: a member with no model_hint, and a run with no override for its seat, is consulted with models[0] — the alphabetically first model of the alphabetically first provider — because Council never falls back to the host's \"default\" route. " +
			"That choice costs money and sets the answer's quality, so give a member an explicit model_hint rather than letting the list decide. " +
			"The list holds the providers Minerva manages dynamically AND TurnRock/Core's live service actions, which appear under the \"turnrock\" provider as one model per action — those run on this machine, cost nothing, and can take minutes to answer the first time while the model loads. A static built-in model may be callable and still absent here, and Council refuses a hint it cannot see.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, func(json.RawMessage) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), chatDiscoveryTimeout)
		defer cancel()
		refreshErr := store.RefreshModels(ctx)
		models, known := store.Models()
		listed := []map[string]any{}
		for _, model := range models {
			row := map[string]any{
				"provider_key":     model.ProviderKey,
				"provider_display": model.ProviderDisplay,
				"model_name":       model.ModelName,
				"display":          model.ModelDisplay,
			}
			if len(model.ModelSpec) > 0 {
				row["model_spec"] = model.ModelSpec
			}
			listed = append(listed, row)
		}
		out := map[string]any{"ok": true, "models": listed, "known": known}
		if refreshErr != nil {
			// The cached list is still returned: it is what the engine is
			// actually checking against, and hiding it would make a refusal
			// unexplainable.
			out["refresh_error"] = refreshErr.Error()
		}
		return json.Marshal(out)
	})

	r.register(toolSpec{
		Name: "minerva_council_presets",
		Description: "List the councils Council ships with, ready to import. Returns {ok, presets:[{file, definition_id, name, purpose, definition}]}, where each definition is a complete council_definition record. " +
			"To start one, send it as the payload of a definition.import command through minerva_council_command — AFTER replacing its definition_id with a fresh one, because import refuses an id the project already holds and the shipped id is a name rather than a claim on a slot. " +
			"The presets are ordinary councils: nothing about them is special once imported, and they are edited, seated and re-grounded like any other. " +
			"The grounded example carries its own source material inline, so it is the one to read to see what a citation actually resolves against; its author is not a real person and the essay was written for the example.",
		InputSchema: json.RawMessage(`{"type": "object", "properties": {}}`),
	}, func(json.RawMessage) ([]byte, error) {
		shipped, err := presets.All()
		if err != nil {
			return nil, err
		}
		listed := []map[string]any{}
		for _, preset := range shipped {
			listed = append(listed, map[string]any{
				"file":          preset.File,
				"definition_id": preset.DefinitionID,
				"name":          preset.Name,
				"purpose":       preset.Purpose,
				"definition":    preset.Definition,
			})
		}
		return json.Marshal(map[string]any{"ok": true, "presets": listed})
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
