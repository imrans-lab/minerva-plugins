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
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/board"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// readVerifiedSnapshot reads a board-by-reference snapshot file and verifies
// its sha256 against the caller-supplied digest (hex, case-insensitive)
// before a byte of it is trusted. The digest is MANDATORY — an unverified
// file read is refused by name, never silently accepted (work item
// 01a0223ec9e271269fd664fcf90dd20b).
func readVerifiedSnapshot(path, digest string) ([]byte, error) {
	if digest == "" {
		return nil, fmt.Errorf("board_path requires board_digest (sha256 hex of the file bytes)")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read board_path %q: %w", path, err)
	}
	sum := sha256.Sum256(raw)
	if actual := hex.EncodeToString(sum[:]); !strings.EqualFold(actual, digest) {
		return nil, fmt.Errorf("board_path digest mismatch for %q: expected %s, file has %s",
			path, digest, actual)
	}
	if len(raw) == 0 {
		// A verified-but-empty snapshot must refuse by name (the Python arm's
		// "YAML source is empty" symmetry) — falling through would let
		// HandleSerialize's echoState compatibility path swallow it silently.
		return nil, fmt.Errorf("board_path %q is an empty file", path)
	}
	return raw, nil
}

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
		Board       json.RawMessage `json:"board"`
		BoardPath   string          `json:"board_path"`
		BoardDigest string          `json:"board_digest"`
	}
	if len(params) > 0 {
		// Malformed params must error, not silently fall through to the echo
		// path: a caller who SENT a board deserves a parse error, not {ok}.
		if err := json.Unmarshal(params, &a); err != nil {
			return nil, fmt.Errorf("pcb.serialize: parse params: %w", err)
		}
	}
	if len(a.Board) == 0 && a.BoardPath != "" {
		// Board-by-reference arm (work item 01a0223ec9e271269fd664fcf90dd20b):
		// an O(board) document must not ride the host broker's capped request
		// pipe, so the panel snapshots it to a file and sends {board_path,
		// board_digest}. Inline board takes precedence — this arm is additive.
		raw, err := readVerifiedSnapshot(a.BoardPath, a.BoardDigest)
		if err != nil {
			return nil, fmt.Errorf("pcb.serialize: %w", err)
		}
		a.Board = raw
	}
	if len(a.Board) == 0 {
		// Genuinely absent board → project_file compatibility echo fallback.
		return echoState(ctx, params)
	}

	// Raw-JSON structural probe BEFORE the typed decode (mirrors the YAML path's
	// probeNodeTree): a typed json.Unmarshal either collapses `components:[null]`
	// (or a null in any of the five entity collections) into a phantom zero-valued
	// struct Validate cannot distinguish from a minimal one, or rejects a non-list
	// collection with a native, code-less error. Probe the raw board across all
	// five collections first so both fail closed with the shared
	// invalid_board_structure code instead of leaking / surfacing an opaque parse
	// error (finding 019f8b7fb07e).
	if err := board.ProbeJSONBoard(a.Board); err != nil {
		return nil, fmt.Errorf("pcb.serialize: %w", err)
	}
	var b board.Board
	if err := json.Unmarshal(a.Board, &b); err != nil {
		return nil, fmt.Errorf("pcb.serialize: parse board: %w", err)
	}
	// Canonicalize the pth_holes / npth_holes aliases into mounting_holes before the
	// write gate, so serialize emits ONE hole collection and validates it (finding
	// 019f8b7fb07e comment 689).
	board.NormalizeHoles(&b)
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
		// An over-cap document is no longer refused: it lands in a temp file
		// and the reply carries {yaml_path, yaml_digest} for the panel to
		// read back verified (the outbound half of board-by-reference,
		// work item 01a0223ec9e271269fd664fcf90dd20b). Under-cap documents
		// keep the inline {yaml} shape byte-for-byte.
		f, err := os.CreateTemp("", "pcb-serialize-*.yaml")
		if err != nil {
			return nil, fmt.Errorf("pcb.serialize: land oversized document: %w", err)
		}
		if _, err := f.Write(yml); err != nil {
			f.Close()
			os.Remove(f.Name())
			return nil, fmt.Errorf("pcb.serialize: land oversized document: %w", err)
		}
		if err := f.Close(); err != nil {
			os.Remove(f.Name())
			return nil, fmt.Errorf("pcb.serialize: land oversized document: %w", err)
		}
		sum := sha256.Sum256(yml)
		return json.Marshal(map[string]interface{}{
			"yaml_path":   f.Name(),
			"yaml_digest": hex.EncodeToString(sum[:]),
			"bytes":       len(yml),
		})
	}
	return json.Marshal(map[string]interface{}{"yaml": string(yml)})
}

// HandleDeserialize parses board-source into the canonical Board dict. Accepts
// {yaml} or {minpcb_json} (the latter an object or a JSON-encoded string).
// Returns {board, warnings}. With neither it falls back to the {state} echo.
//
// This is the PURE CODEC entry point (no worker, no enrichment) and is kept at
// this arity deliberately: it is the parse contract other Go code and the codec
// tests call directly. The registered pcb.deserialize handler is the sibling
// HandleDeserializeResolved below, which is this same code plus a best-effort
// footprint-graphics attach.
func HandleDeserialize(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	return handleDeserialize(ctx, nil, params)
}

// HandleDeserializeResolved is the handler REGISTERED for the pcb.deserialize
// channel — the board-LOAD path (docket 019fb430750a, unit 1).
//
// It is HandleDeserialize plus one thing: each component in the parsed board is
// enriched, BEST-EFFORT, with its footprint's F.SilkS/F.CrtYd graphics from the
// Python worker, so a board arrives at the panel with something for the silk
// renderer to draw. Before this, a plain board load produced graphics=[] on
// every component and the (already working) body-outline renderer had nothing
// to draw — the resolver and the renderer both existed, nobody connected them.
//
// Enriching HERE rather than in the panel is deliberate: this is the one choke
// point every board load funnels through, so every consumer of pcb.deserialize
// (the panel YAML load, minerva_pcb_load_board, anything added later) inherits
// it without opting in.
//
// The enrichment can NEVER fail a load. Any fault — no worker, cold-start
// timeout, worker crash, a footprint the library cannot resolve, a coincidence
// fault — leaves the board exactly as the codec produced it and records the
// reason in `warnings`. Silk is a rendering nicety; the board is the contract.
func HandleDeserializeResolved(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return handleDeserialize(ctx, w, params)
}

// handleDeserialize is the shared body. A nil worker means "codec only" — the
// enrichment is skipped entirely and the reply is byte-identical to the
// pre-enrichment behaviour, which is what keeps HandleDeserialize pure.
func handleDeserialize(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	var a struct {
		YAML        string          `json:"yaml"`
		MinpcbJSON  json.RawMessage `json:"minpcb_json"`
		Board       json.RawMessage `json:"board"`
		BoardPath   string          `json:"board_path"`
		BoardDigest string          `json:"board_digest"`
	}
	if len(params) > 0 {
		// Malformed params must error, not silently fall through to the echo
		// path (see HandleSerialize).
		if err := json.Unmarshal(params, &a); err != nil {
			return nil, fmt.Errorf("pcb.deserialize: parse params: %w", err)
		}
	}
	if a.YAML == "" && len(a.MinpcbJSON) == 0 && len(a.Board) == 0 && a.BoardPath != "" {
		// Board-by-reference arm — see HandleSerialize. Inline yaml/minpcb
		// take precedence; the snapshot file is board source (YAML) verified
		// against its sha256 before a byte of it is parsed.
		raw, err := readVerifiedSnapshot(a.BoardPath, a.BoardDigest)
		if err != nil {
			return nil, fmt.Errorf("pcb.deserialize: %w", err)
		}
		// The snapshot is whichever document the caller held: the panel's
		// board dict (a JSON object) or canonical YAML text. A flow-style YAML
		// document also opens with '{' but is not valid JSON, so it stays YAML.
		if trimmed := bytes.TrimSpace(raw); len(trimmed) > 0 && trimmed[0] == '{' && json.Valid(trimmed) {
			a.Board = trimmed
		} else {
			a.YAML = string(raw)
		}
	}

	var (
		b        *board.Board
		warnings []string
		err      error
	)
	switch {
	case a.YAML != "":
		b, warnings, err = board.UnmarshalYAMLWithWarnings([]byte(a.YAML))
	case len(a.MinpcbJSON) > 0:
		b, warnings, err = board.ImportMinpcb(unwrapJSON(a.MinpcbJSON))
	case len(a.Board) > 0:
		// The live board dict, read exactly as pcb.serialize reads it — so a
		// panel that holds a board (not a document) can have it resolved in
		// place. Probe first: a bare json.Unmarshal collapses a null component
		// silently.
		if err = board.ProbeJSONBoard(a.Board); err == nil {
			var live board.Board
			if err = json.Unmarshal(a.Board, &live); err == nil {
				board.NormalizeHoles(&live)
				b = &live
			}
		}
		if err != nil {
			err = fmt.Errorf("board dict (JSON): %w", err)
		}
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
	// footprint_resolved is DERIVED, never board source: it says a resolve
	// succeeded against the library of the machine doing the resolving. A
	// document that carries one (older boards were saved with it) would
	// survive adoptResolvedGeometry's absent-only rule and come back out of
	// this channel asserting a resolve THIS host never performed — and the
	// panel's wire trim believes the flag and drops the component's pads.
	// Clearing it here makes the reply's flags mean exactly "resolved here,
	// just now", on both the enriched and the pure-codec arm.
	dropDerivedComponentKeys(b)
	// Board-LOAD enrichment: attach each component's footprint silk/courtyard
	// graphics, best-effort. No-op when w == nil (the pure codec path). Runs
	// AFTER validation so we never resolve a board we are about to reject, and
	// BEFORE the marshal so the graphics ride the normal reply.
	warnings = attachFootprintGraphics(ctx, w, b, warnings)

	if warnings == nil {
		warnings = []string{}
	}
	return json.Marshal(map[string]interface{}{
		"board":    b,
		"warnings": warnings,
	})
}

// ---------------------------------------------------------------------------
// Footprint-graphics enrichment (board-LOAD path, docket 019fb430750a unit 1)
// ---------------------------------------------------------------------------

// resolveGraphicsBudget bounds how long a board load will wait for the worker's
// footprint resolve before giving up and returning the unenriched board.
//
// It MUST stay comfortably under the panel's 30s pcb.deserialize timeout
// (ui/PCBPanel.gd), because the Python worker is spawned LAZILY on first call
// and the panel's _request_with_backend_ensure warms only the GO backend — it
// never touches the worker. So a board load can pay a cold Python start, whose
// own ready deadline (shared/bridge, 60s) is twice the panel's patience.
// Without this bound, a cold or wedged worker would not merely cost us silk: it
// would blow the panel timeout and fail the WHOLE LOAD, which is strictly worse
// than the bodyless render we are fixing.
const resolveGraphicsBudget = 15 * time.Second

// graphicsSkipped formats the single, honest warning shape for a degraded
// enrichment. The load succeeded; the bodies just are not drawn. The reason
// reaches the caller as result.warnings, so this degrades LOUDLY, not silently.
func graphicsSkipped(reason string) string {
	return "footprint graphics not attached (components render without silk body outlines): " + reason
}

// attachFootprintGraphics enriches b's components IN PLACE with their
// footprint's F.SilkS/F.CrtYd graphics AND its real pad geometry ("pads" +
// "has_pad_geometry"), returning warnings extended with one entry if the
// enrichment degraded. It never returns an error: every failure mode is a
// degrade, because a board must load even when its bodies cannot be drawn.
//
// PAD ADOPTION (WYSIWYG goal 019ff4a5a75a, closing gap G1). This unit
// originally took ONLY "graphics" and deliberately dropped the resolve's pad
// geometry, deferring "would change pad rendering and retire the unresolved
// badge" as a separate change. The measured consequence of that deferral:
// every library-footprint board rendered fallback pad DISCS — no drill
// barrels, no real pad shapes — with a permanent amber unresolved badge on
// every component, while the fab path compiled the true geometry from the
// same footprints. The panel side was already built and waiting: the model's
// _pads_from_list parses exactly the resolve's pad dict shape, and the canvas
// gates its drill-hole render on the pad "type" only the resolve can supply.
// Adopting the two keys here is what connects them.
//
// The attach is strictly ADDITIVE: a component whose source already carries
// graphics (or pads) keeps what the source gave it — authored data wins over
// derived, per key, so a board with authored pads but no graphics still gains
// the body outlines and vice versa. "has_pad_geometry" rides ONLY with pads
// this unit itself attaches: it is the resolved-vs-fallback marker the badge
// and the accurate-pad renderer key on, so stamping it while keeping authored
// pads would launder an unresolved component into a resolved-looking one.
func attachFootprintGraphics(ctx context.Context, w *bridge.Worker, b *board.Board, warnings []string) []string {
	if w == nil || b == nil || len(b.Components) == 0 {
		return warnings // codec-only path, or nothing to enrich
	}

	// Send the board as the host will see it — the same JSON encoding the reply
	// uses (Extra inlined, see json.go), so the worker resolves the exact board
	// the panel is about to render, not a different projection of it.
	boardJSON, err := json.Marshal(b)
	if err != nil {
		return append(warnings, graphicsSkipped(fmt.Sprintf("board could not be encoded for resolve: %v", err)))
	}
	reqParams, err := json.Marshal(map[string]json.RawMessage{"board": boardJSON})
	if err != nil {
		return append(warnings, graphicsSkipped(fmt.Sprintf("resolve request could not be encoded: %v", err)))
	}

	result, err := callResolveBestEffort(ctx, w, reqParams)
	if err != nil {
		return append(warnings, graphicsSkipped(err.Error()))
	}

	byRef := resolvedByRef(result)
	if len(byRef) == 0 {
		return append(warnings, graphicsSkipped("the resolve returned no footprint geometry"))
	}

	if adoptResolvedGeometry(b, byRef) == 0 {
		return append(warnings, graphicsSkipped("no component matched a resolved footprint"))
	}
	return warnings
}

// derivedComponentKeys are per-component Extra keys that state something a
// resolve DERIVES, never something a board authors — so a document carrying
// one is stating a fact about the machine that wrote it. The list is the
// board package's (it is the same set the minpcb importer must NOT warn
// about), read here as the drop-list.
var derivedComponentKeys = board.DerivedComponentKeys

// dropDerivedComponentKeys removes every derivedComponentKeys entry from every
// component's Extra. Called once at the deserialize boundary so the only such
// keys a reply can carry are the ones adoptResolvedGeometry stamped from this
// host's own resolve. Nil-safe and cheap on a board that carries none.
func dropDerivedComponentKeys(b *board.Board) {
	if b == nil {
		return
	}
	for i := range b.Components {
		if b.Components[i].Extra == nil {
			continue
		}
		for _, k := range derivedComponentKeys {
			delete(b.Components[i].Extra, k)
		}
	}
}

// adoptResolvedGeometry applies the per-key adoption policy (see
// attachFootprintGraphics's doc comment) and returns how many components took
// at least one key. Pure over its inputs so the policy is testable without a
// live worker — the bridge call and this decision are separate concerns.
func adoptResolvedGeometry(b *board.Board, byRef map[string]resolvedComponent) int {
	attached := 0
	for i := range b.Components {
		r, ok := byRef[b.Components[i].Ref]
		if !ok {
			continue // footprint unresolvable (best-effort left it inline) — badge stays
		}
		if b.Components[i].Extra == nil {
			b.Components[i].Extra = map[string]interface{}{}
		}
		took := false
		if len(r.graphics) > 0 {
			if _, exists := b.Components[i].Extra["graphics"]; !exists {
				b.Components[i].Extra["graphics"] = r.graphics
				took = true
			}
		}
		// WHERE the fab prints this component's designator (WYSIWYG G2) —
		// the footprint's own reference-text anchor, adopted like graphics.
		// The strokes themselves are NOT carried: the renderer owns the same
		// glyph table and strokes the component's live ref, so a renamed or
		// copied part cannot keep drawing the designator it was rendered from.
		// dropDerivedComponentKeys has already cleared any strokes an older
		// document carried, so this pass is the only writer here.
		if len(r.refdesAnchor) > 0 {
			if _, exists := b.Components[i].Extra["refdes_anchor"]; !exists {
				b.Components[i].Extra["refdes_anchor"] = r.refdesAnchor
				took = true
			}
		}
		// The component-level resolved fact. Boolean and worker-owned:
		// absence means the best-effort resolve left the component pristine,
		// so absent stays absent. dropDerivedComponentKeys has already cleared
		// any flag the document carried, so the absent-only guard below can
		// only ever see a key this pass itself wrote.
		if r.footprintResolved {
			if _, exists := b.Components[i].Extra["footprint_resolved"]; !exists {
				b.Components[i].Extra["footprint_resolved"] = true
				took = true
			}
		}
		// Pads + the resolved marker travel TOGETHER (see the doc comment):
		// has_pad_geometry asserts "these pads are the footprint's real
		// geometry", so it must never be stamped over authored pads.
		if r.hasPadGeometry && len(r.pads) > 0 {
			if _, exists := b.Components[i].Extra["pads"]; !exists {
				b.Components[i].Extra["pads"] = r.pads
				b.Components[i].Extra["has_pad_geometry"] = true
				took = true
			}
		}
		if took {
			attached++
		}
	}
	return attached
}

// callResolveBestEffort runs the worker's tolerant resolve under a wall-clock
// budget and returns its raw result ({ok, board, stats}).
//
// The budget is enforced by this select and NOT by a context deadline, which
// would be a trap: the bridge threads the call ctx into exec.CommandContext when
// it LAZILY SPAWNS the worker, so cancelling a per-call ctx kills the long-lived
// shared worker and forces a cold respawn for every other tool. That is why the
// call itself runs on context.Background(), matching the plugin's dispatch path.
// A call we stop waiting for is simply abandoned; the bridge discards its reply.
func callResolveBestEffort(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	type callResult struct {
		raw json.RawMessage
		err error
	}
	// Buffered: the goroutine must never block (and so never leak) when we have
	// already given up on this call.
	done := make(chan callResult, 1)
	go func() {
		// The LOAD path resolves through the same live chain the fab path
		// compiles through (B7): a promoted user-layer part must show its
		// silk when the board opens, not only when it fabricates.
		raw, err := w.Call(context.Background(), "resolve_best_effort", withLibraryChain(params))
		done <- callResult{raw: raw, err: err}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			return nil, fmt.Errorf("worker resolve failed: %w", r.err)
		}
		return r.raw, nil
	case <-time.After(resolveGraphicsBudget):
		return nil, fmt.Errorf("worker resolve exceeded its %s budget", resolveGraphicsBudget)
	case <-ctx.Done():
		return nil, fmt.Errorf("worker resolve abandoned: %w", ctx.Err())
	}
}

// resolvedComponent is one component's adoptable enrichment from the resolve
// reply: its footprint body graphics, its real pad geometry, and the anchor
// its printed reference designator is stroked at (WYSIWYG G2 — derived silk
// the emitters synthesize themselves from the ref, so only the placement has
// to travel).
type resolvedComponent struct {
	graphics          []interface{}
	pads              []interface{}
	refdesAnchor      map[string]interface{}
	hasPadGeometry    bool
	footprintResolved bool
}

// resolvedByRef indexes the resolve reply's per-component enrichment by
// component ref. A component the best-effort resolve left inline (unresolvable
// footprint: no graphics AND no resolved pads) is omitted, so callers can
// distinguish "resolved to nothing" from "not resolved" and leave the latter
// untouched — its badge stays, which is the honest state.
//
// Pads are indexed ONLY when the reply's own has_pad_geometry says they are
// the footprint's real geometry. The worker echoes the component's inline pads
// through the resolve even when the footprint did not resolve, so taking
// "pads" unconditionally would re-import the caller's own fallback data
// wearing a resolved label.
func resolvedByRef(result json.RawMessage) map[string]resolvedComponent {
	var payload struct {
		Board struct {
			Components []struct {
				Ref            string                 `json:"ref"`
				Graphics       []interface{}          `json:"graphics"`
				Pads           []interface{}          `json:"pads"`
				RefdesAnchor   map[string]interface{} `json:"refdes_anchor"`
				HasPadGeometry bool                   `json:"has_pad_geometry"`
				// The COMPONENT-level resolved fact (bug 019ff4a9a0d7) — a
				// silk-only footprint resolves with zero pads, so the pad
				// marker alone cannot say "this component is resolved".
				FootprintResolved bool `json:"footprint_resolved"`
			} `json:"components"`
		} `json:"board"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		return nil
	}
	out := make(map[string]resolvedComponent, len(payload.Board.Components))
	for _, c := range payload.Board.Components {
		if c.Ref == "" {
			continue
		}
		rc := resolvedComponent{graphics: c.Graphics, refdesAnchor: c.RefdesAnchor,
			footprintResolved: c.FootprintResolved}
		if c.HasPadGeometry {
			rc.pads = c.Pads
			rc.hasPadGeometry = true
		}
		if len(rc.graphics) == 0 && len(rc.refdesAnchor) == 0 &&
			!rc.hasPadGeometry && !rc.footprintResolved {
			continue
		}
		out[c.Ref] = rc
	}
	return out
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
