// Package tools — worker-backed MCP tool specs + handlers for the PCB plugin.
//
// These tools dispatch to the Python worker (python -m pcb_worker) via the
// shared Go↔Python bridge, exactly as the CAD plugin's mcad_validate does. The
// worker methods are pure functions over the canonical board YAML.
//
// Tool-naming convention (round D0-expose, docket 019fa486b408): these
// LLM-facing worker tools carry the full minerva_pcb_ prefix (minerva_pcb_validate,
// minerva_pcb_generate, minerva_pcb_check_libraries, minerva_pcb_check_bom, ...) —
// the SAME prefix the plugin's panel-executor tools use, and the prefix
// PluginToolRegistry.register_plugin_tools requires of every manifest-declared
// tool. This plugin previously followed CAD's short-prefix split (mcad_validate
// distinct from minerva_cad_*), registering these as bare pcb_validate/pcb_generate/
// etc — but PluginManager._discover_backend_tools() runs unconditionally on every
// plugin start and auto-prefixes any name not already starting with
// "minerva_pcb_", producing the double-prefixed minerva_pcb_pcb_validate. Naming
// the spec minerva_pcb_validate from the start makes that auto-prefix step a
// no-op, so the manifest-declared name and the backend-discovered name agree
// under one spelling whether or not discovery has run. The worker METHOD names
// (a different namespace — the short string passed to w.Call) are UNCHANGED and
// carry no prefix (validate, generate, check_libraries, check_bom) — same split
// CAD uses (MCP tool mcad_validate → worker method "validate"). The dotted
// panel-IPC channels (pcb.route, pcb.draft_check, pcb.serialize, ...) are a
// separate namespace again and are NOT renamed by this convention.
package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/libraries"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
	sharedruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
)

// WorkerToolHandlerFunc is the signature for a worker-backed tool: it threads a
// *bridge.Worker so the handler can Call the Python worker. The in-process tool
// path (ping / project channels) keeps the (ctx, params) signature; a small
// adapter (WorkerTool) bridges the two so both live in one Registry.
type WorkerToolHandlerFunc func(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error)

// ---- minerva_pcb_validate ----------------------------------------------------------

var Validate = ToolSpec{
	Name: "minerva_pcb_validate",
	Description: "Structurally validate a canonical PCB board (board-yaml contract). " +
		"Args {yaml:<board source>} or {board:<board object>}. Returns " +
		"{ok, errors:[{path,message}], warnings:[...]} — errors flag structural " +
		"faults (missing required fields, duplicate refs, net pin refs that don't " +
		"resolve, traces on unknown nets); warnings flag soft issues (out-of-bounds " +
		"coordinates, trace narrower than design rules). Cheap: no geometry engine.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."}
		}
	}`),
}

func HandleValidate(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "validate", params)
}

// ---- minerva_pcb_generate ----------------------------------------------------------

var Generate = ToolSpec{
	Name: "minerva_pcb_generate",
	Description: "Generate KiCad files from a canonical PCB board. Args {yaml|board, " +
		"name?:<basename>, out_dir?:<dir>}. Returns {files:{'<name>.kicad_pcb':text, " +
		"'<name>.kicad_sch':text, '<name>.kicad_pro':text}, written:[{path,bytes_written}]}. " +
		"The .kicad_pcb faithfully carries components/pads/traces/outline/vias at the " +
		"authored coordinates; .kicad_sch/.kicad_pro are minimal netlist-carrying " +
		"skeletons. When out_dir is given the files are also written to disk.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."},
			"name": {"type": "string", "description": "Optional output file basename (defaults to board name)."},
			"out_dir": {"type": "string", "description": "Optional directory to also write the files to."}
		}
	}`),
}

func HandleGenerate(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "generate", params)
}

// ---- minerva_pcb_gerbers -----------------------------------------------------------

var Gerbers = ToolSpec{
	Name: "minerva_pcb_gerbers",
	Description: "Generate fabrication files (Gerber RS-274X/X2 + Excellon drills) from a " +
		"canonical PCB board — pure Python, no KiCad binary. Args {yaml|board, name?:<basename>, " +
		"out_dir?:<dir>}. Returns {files:{'<name>-F_Cu.gbr':text, ...}, " +
		"written:[{path,bytes_written}], warnings:[...]}. NINE Gerber layers — F_Cu/B_Cu, " +
		"F_Mask/B_Mask, F_Paste/B_Paste, F_SilkS/B_SilkS and Edge_Cuts — plus separate plated " +
		"(PTH) and non-plated (NPTH) Excellon drill files (each drill file only when the board " +
		"has holes of that class) and a '<name>-job.gbrjob' naming every layer's function. " +
		"Coordinate format is self-declared per layer (read the %FS line, not assume 4.6). Silk " +
		"is REAL footprint legend geometry plus stroke-font reference designators, on BOTH " +
		"sides. Fab-correctness still needs a human viewer check — see docs/gerbers.md.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."},
			"name": {"type": "string", "description": "Optional output file basename (defaults to board name)."},
			"out_dir": {"type": "string", "description": "Optional directory to also write the files to."}
		}
	}`),
}

func HandleGerbers(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "gerbers", params)
}

// ---- minerva_pcb_drc ---------------------------------------------------------------

var DRC = ToolSpec{
	Name: "minerva_pcb_drc",
	Description: "Run a CONNECTIVITY/topology check over a canonical PCB board (pad centers " +
		"+ trace centerlines; NOT a geometric copper DRC — use minerva_pcb_drc_geometric for copper " +
		"clearance/width/annular). Pure " +
		"Python, no KiCad binary. Args {yaml:<board source>} or {board:<board object>}. " +
		"Returns {ok, findings:[{type,...}], counts:{type:count}}. Findings are structured " +
		"and located: 'wrong_net_pad' (a trace endpoint on a different-net pad -> short) " +
		"{net, at:[x,y], pad:{ref,pin,net}}; 'crossing' (two same-layer different-net traces " +
		"that intersect, deduped per net-pair-per-layer) {nets:[a,b], layer, at}; " +
		"'dangling_endpoint' (a leaf trace endpoint reaching no pad/via/same-net copper -> " +
		"open) {net, at}; 'layer_change_no_via' (a net's top and bottom copper meet with no " +
		"via or through-hole pad -> missing via) {net, at}. T-junction taps and same-" +
		"component internal-net pads are credited so they don't read as false opens. " +
		"Scope: checks key off trace endpoints/segments — this is NOT a full ratsnest/" +
		"connectivity check; a pad with no trace routed near it is not flagged as unrouted.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."}
		}
	}`),
}

func HandleDRC(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "drc", params)
}

// ---- minerva_pcb_drc_geometric -----------------------------------------------------

var DRCGeometric = ToolSpec{
	Name: "minerva_pcb_drc_geometric",
	Description: "Run a GEOMETRIC copper design-rule check over the ResolvedBoard IR — real " +
		"pad/trace/via/hole copper geometry, pure Python, no KiCad binary. Args " +
		"{yaml:<board source>} or {board:<board object>}. Compiles the board to the " +
		"ResolvedBoard IR, then checks GC1 min trace width, GC2 copper-copper clearance, " +
		"GC3 drill/finished-hole (finished-hole is a necessary pre-DFM check — the IR " +
		"carries drill diameter, not the plated finished bore), GC4 annular ring, GC5 " +
		"copper-to-edge, GC6 hole-to-hole, GC7 filled-pour clearance, GC8 solder-mask " +
		"sliver, GC10 hole-to-copper, and GC11 hole-to-edge (an unconditional containment " +
		"refusal for a bore that crosses the outline or enters a cutout, plus a " +
		"proximity check that runs only when the profile declares min_hole_to_edge_mm). " +
		"GC9 silkscreen DFM (legend stroke width and legend-to-pad) is ADVISORY: its rows " +
		"appear in a separate top-level `advisories` array and are counted, but are NOT in " +
		"`findings` and NEVER change `verdict` — legend is cosmetic and is warned, never " +
		"fatal. Floors declared OPTIONAL by a profile (hole-to-copper, hole-to-edge, the " +
		"silk pair, feature-specific drill minima) are enforced only when that profile " +
		"states them. `counts` reports ROWS, not check coverage: zero can mean either " +
		"'the profile stated no floor' or 'the check ran and found no row'. A GC9 failure " +
		"is explicit as a counted `gc9_silk_indeterminate` advisory, never inferred from " +
		"the two measuring counts. " +
		"NEVER a false clean: modeled copper is exact or a superset (fail-safe), and " +
		"unresolved/unsupported geometry FAILS CLOSED to an indeterminate result. Returns a " +
		"discriminated union — determinate {ok:true, scope:'geometric', verifies_geometry:true, " +
		"verdict:'clean'|'violations', board_id, source_digest, rule_profile, findings:[{type, " +
		"entity_id, net_id, layer, measured_mm, required_mm, witness}], advisories:[...same " +
		"shape...], counts, warnings} or " +
		"indeterminate {ok:false, verdict:'indeterminate', error:{kind}} with NO clean/findings. " +
		"Distinct from minerva_pcb_drc (connectivity/topology only). Corroborated against kicad-cli DRC.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."}
		}
	}`),
}

func HandleDRCGeometric(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "drc_geometric", params)
}

// ---- minerva_pcb_resolve -----------------------------------------------------------

var Resolve = ToolSpec{
	Name: "minerva_pcb_resolve",
	Description: "Enrich a canonical PCB board with footprint silkscreen + courtyard " +
		"graphics — pure Python, no KiCad binary. Args {yaml:<board source>} or " +
		"{board:<board object>}. For each component the footprint ref is resolved from " +
		"the sha-verified seed library and its F.SilkS body outline + F.CrtYd keep-out " +
		"graphics are attached as component['graphics'] (component-LOCAL coords; the " +
		"placement/rotation transform stays the renderer's job, like pins). The existing " +
		"inline pads are left untouched. FAIL-CLOSED coincidence guard: every declared " +
		"pin's local position must equal the footprint pad's local position (matched by " +
		"number) within 0.01mm, else {ok:false, error:{kind:'coincidence', ref, pin, " +
		"delta_mm}} — never attach silk that would desync from the routed copper. Returns " +
		"{ok, board:<resolved board>, stats:{components, silk_graphics, courtyard_graphics}}.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."}
		}
	}`),
}

func HandleResolve(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "resolve", params)
}

// ---- minerva_pcb_normalize ---------------------------------------------------------

var Normalize = ToolSpec{
	Name: "minerva_pcb_normalize",
	Description: "Rewrite a canonical PCB board to its normalized v2 shape — the sync-back " +
		"the compile fold never persists on its own. Args {yaml:<board source>} or " +
		"{board:<board object>}. For every pin carrying deprecated inline fabrication " +
		"geometry (drill_mm/annulus_diameter_mm/pad_width_mm/pad_height_mm/plated): geometry " +
		"REDUNDANT with the locked footprint pad is dropped, geometry that DIVERGES is " +
		"migrated to a typed `override`, and an AMBIGUOUS pin (no matching footprint pad, or " +
		"unverifiable) fail-closes the WHOLE normalize (better none than a half-normalized " +
		"source). PURE — returns the normalized board for the host to persist; never writes " +
		"to disk. Returns {ok:true, board:<normalized>, warnings:[{severity,code,message,...}]} " +
		"on success (the warnings carry per-pin migrate/drop INFO diagnostics), or " +
		"{ok:false, error:{kind:'normalize'|'parse', message, diagnostics}} on a fail-closed " +
		"or parse fault. Idempotent: normalizing an already-normalized board is a no-op.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."}
		}
	}`),
}

func HandleNormalize(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "normalize", params)
}

// ---- pcb.route (worker-backed broker CHANNEL, not an LLM tool name) --------
//
// Unlike minerva_pcb_validate/minerva_pcb_generate/... (LLM-facing tool names
// under the minerva_pcb_ prefix), pcb.route is a dotted panel-IPC channel: ui/PCBPanel.gd's
// route_board() emits a "pcb.route" broker request (request.emit("pcb.route",
// params, reply_id)) driving the route-correction loop behind
// minerva_pcb_apply_route_hints. The broker requires every declared
// ipc_channels entry to have a same-named backend tool (main.go's registry
// gotcha, gap register A-7) — but the actual routing computation is a Python
// worker method (pcb_worker/methods.py's "route", vendoring agent_router), so
// this channel forwards verbatim to the worker rather than computing in Go.

var RouteChannel = ToolSpec{
	Name: "pcb.route",
	Description: "Panel IPC channel backing ui/PCBPanel.gd's route-correction loop " +
		"(minerva_pcb_apply_route_hints). Forwards verbatim to the Python worker's " +
		"'route' method, which autoroutes a canonical board with the vendored " +
		"agent_router engine. Args: {board:<canonical Board dict with a " +
		"'components' list — see docs/board-yaml.md>, route_hints:[<pcb_route_hint " +
		"annotation envelope>,...], selection:<optional dict scoping which hints/" +
		"nets to route — propose vs commit is expressed via the hint/selection " +
		"contents, not a separate flag>, options?:{allow_vias, single_layer, order, " +
		"trace_width, clearance, grid_resolution}}. Returns {ok, result:{success, " +
		"via_count, routes:[{net,segments:[{start,end,layer}],vias}], unrouted:" +
		"[{net,from,to}], warnings?, selected_hint_ids?}} on success, or " +
		"{ok:false, error:{kind,message}} on a structured routing/parse fault — " +
		"engine faults never crash the worker loop. FAILS CLOSED (019f783860c8): " +
		"canonical routing COMPILES the board and routes real ResolvedBoard copper; " +
		"it never approximates a pad. A board that will not compile returns " +
		"kind:\"compile\" with the blocking diagnostics, and one that compiles but " +
		"carries geometry the routing grid cannot model faithfully — accepted " +
		"traces/vias (until 019f70ebc9ed), inner copper layers, zones, copper " +
		"graphics, a non-rectangular outline — returns kind:\"unsupported_geometry\". " +
		"Either way ZERO routes come back: no proposal is ever computed over " +
		"guessed copper.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandleRouteChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "route", params)
}

// ---- pcb.draft_check (worker-backed broker CHANNEL, T2.4) ------------------
//
// The on-demand honest-DRC-over-the-draft-set seam behind ui/PCBPanel.gd's
// check_draft(). Like pcb.route it is a dotted panel-IPC channel (NOT an
// LLM-facing pcb_* tool) that forwards verbatim to the Python worker — here the
// "draft_check" method, which runs drc.run_drc over the union of committed
// copper and every candidate's draft geometry (SET-scoped). Every declared
// ipc_channels entry needs a same-named backend tool (main.go registry, gap
// A-7), and the computation is Python, so this forwards rather than computing.

var DraftCheckChannel = ToolSpec{
	Name: "pcb.draft_check",
	Description: "Panel IPC channel backing ui/PCBPanel.gd's on-demand routing " +
		"draft-check. Forwards verbatim to the Python worker's 'draft_check' " +
		"method, which runs the existing DRC checks over the UNION of the board's " +
		"committed copper and every candidate's draft segments/vias (set-scoped, " +
		"not per-candidate). Args: {board:<canonical Board dict>, candidates:[{" +
		"candidate_id, net, revision, segments:[{id,layer,width,points}], vias:[{" +
		"id,position,from_layer,to_layer}]}], board_token:<str>, " +
		"workspace_generation:<int>}. Returns {ok, result:{board_token, " +
		"workspace_generation, findings:[{kind,subjects:[{candidate_id," +
		"segment_id?/via_id?}],...}], per_candidate:{candidate_id:'clean'/" +
		"'violating'/'error'}}} — board_token + workspace_generation echoed " +
		"verbatim so the GD side can discard a stale reply.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandleDraftCheckChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "draft_check", params)
}

// ---- pcb.assembly_check (worker-backed broker CHANNEL) ---------------------
//
// DCR 019fd5fd9084 (work items 019fd5fe1241 load-time advisories +
// 019fd5fe2724 placement-op surfacing): the on-demand assembly/courtyard
// advisory seam behind ui/PCBPanel.gd's assembly_check(). Like pcb.route and
// pcb.draft_check it is a dotted panel-IPC channel (NOT an LLM-facing pcb_*
// tool) that forwards verbatim to the Python worker — here the new
// "assembly_check" method, which runs the approximate (bbox-level) courtyard/
// body-overlap pass over a canonical board dict. Every declared ipc_channels
// entry needs a same-named backend tool (main.go registry, gap A-7), and the
// computation is Python, so this forwards rather than computing.

var AssemblyCheckChannel = ToolSpec{
	Name: "pcb.assembly_check",
	Description: "Panel IPC channel backing ui/PCBPanel.gd's on-demand assembly " +
		"advisory check (DCR 019fd5fd9084). Forwards verbatim to the Python " +
		"worker's 'assembly_check' method, which runs the approximate " +
		"courtyard/body-overlap pass over a canonical board dict — the same " +
		"object pcb.route replies embed as board_health.assembly, computable " +
		"here WITHOUT a routing run (load-time and placement-op surfacing). " +
		"Args: {board:<canonical Board dict with a 'components' list — see " +
		"docs/board-yaml.md>}. Returns {ok, result:{status:'pass'|'findings'|" +
		"'indeterminate', findings:[...], indeterminate?:[...], error?:str}} — " +
		"tri-state and ADVISORY-GRADE: 'indeterminate' means the check could " +
		"not run (never silently a pass), and no result from this channel ever " +
		"hard-blocks an operation on its own; the GD side owns the commit-time " +
		"acknowledgment gate.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandleAssemblyCheckChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "assembly_check", params)
}

// ---- pcb.board_health (worker-backed broker CHANNEL) -----------------------
//
// Epoch UX2 station 9 (docket 019fde571300): the whole-board health ledger —
// the SAME board_health object every ok pcb.route reply carries (connectivity
// completeness census + tri-state assembly) — computable WITHOUT a routing
// run, so the load path can announce completeness at open. Same dotted
// panel-IPC channel idiom as pcb.assembly_check directly above; forwards
// verbatim to the Python worker's "board_health" method.

var BoardHealthChannel = ToolSpec{
	Name: "pcb.board_health",
	Description: "Panel IPC channel for the whole-board health ledger without " +
		"a routing run (Epoch UX2 station 9). Forwards verbatim to the Python " +
		"worker's 'board_health' method. Args: {board:<canonical Board dict>}. " +
		"Returns {ok, result:{complete:true|false|null, missing_copper:[net], " +
		"partial?:[{net,pin_groups}], indeterminate?:[{net,reason}], " +
		"assembly:{status,findings,...}, approximate:true}} — the exact keys " +
		"and tri-state semantics of a route reply's board_health, one census " +
		"kernel behind both.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandleBoardHealthChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "board_health", params)
}

// ---- pcb.mask_view (worker-backed broker CHANNEL) --------------------------
//
// WYSIWYG goal 019ff4a5a75a, gap G4: the panel's solder-mask overlay. Forwards
// verbatim to the Python worker's "mask_view" method, whose reply is
// Projection.mask — the EXACT collection GC8 measures slivers on and the same
// shared-owner enumeration (mask_source) the Gerber emitter adopts. The panel
// renders these openings and must never re-derive them: a second reading of
// the mask rule is the drift class the WYSIWYG goal exists to remove.

var MaskViewChannel = ToolSpec{
	Name: "pcb.mask_view",
	Description: "Panel IPC channel for the solder-mask overlay (WYSIWYG G4). " +
		"Forwards verbatim to the Python worker's 'mask_view' method. Args: " +
		"{board:<canonical Board dict>} or {yaml}. Returns {ok, result:{" +
		"openings:[{side:'top'|'bottom', shape, x_mm, y_mm, width_mm, " +
		"height_mm, corner_rratio, angle_deg, origin, ref, pad_number}], " +
		"indeterminate:[{entity, reason}]}} — Projection.mask verbatim, the " +
		"same openings GC8 checks and the Gerber emitter flashes. A non-empty " +
		"'indeterminate' means the aperture set is KNOWN-INCOMPLETE; a viewer " +
		"must mark the overlay, not silently draw the subset.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandleMaskViewChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "mask_view", params)
}

// ---- pcb.promote_check (worker-backed broker CHANNEL) ----------------------
//
// Epoch UX3 station 11 (docket 019fdf91b3ac, K13): the PROMOTION GATE — the
// full authoritative verdict (connectivity DRC + geometric DRC + assembly
// tri-state) in one call, composed fail-closed worker-side: promotable is
// true only when every check ran to a determinate clean/pass. Same dotted
// panel-IPC channel idiom as pcb.board_health directly above; forwards
// verbatim to the Python worker's "promote_check" method.

var PromoteCheckChannel = ToolSpec{
	Name: "pcb.promote_check",
	Description: "Panel IPC channel for the K13 promotion gate: full " +
		"connectivity DRC + geometric DRC (GC1-GC7) + assembly tri-state in " +
		"one fail-closed verdict. Forwards verbatim to the Python worker's " +
		"'promote_check' method. Args: {board:<canonical Board dict>}. " +
		"Returns {ok, result:{promotable, refusals:[string], connectivity, " +
		"geometric, assembly}} — any error, indeterminate or finding anywhere " +
		"makes promotable false with the reason named; 'could not check' is a " +
		"refusal, never a pass.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandlePromoteCheckChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "promote_check", params)
}

// ---- minerva_pcb_check_libraries ---------------------------------------------------

var CheckLibraries = ToolSpec{
	Name: "minerva_pcb_check_libraries",
	Description: "Verify component footprints against KiCAD footprint-library data. " +
		"Args {yaml|board, lib_dir?:<path to a dir of *.pretty libs>}. With no lib_dir " +
		"(the library data ships with a later child) returns {ok:true, checked:0, " +
		"missing_data:true} — never a crash. With lib_dir returns {ok, checked, " +
		"missing:[{ref,footprint,path}], missing_data:false}.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."},
			"lib_dir": {"type": "string", "description": "Directory of KiCAD *.pretty footprint libraries."}
		}
	}`),
}

func HandleCheckLibraries(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "check_libraries", withDefaultLibDir(params))
}

// ---- minerva_pcb_check_bom ---------------------------------------------------------

var CheckBOM = ToolSpec{
	Name: "minerva_pcb_check_bom",
	Description: "Extract + validate a bill of materials from a canonical PCB board. " +
		"Args {yaml|board, lib_dir?}. Returns {ok, items:[{refs,footprint,value,qty}], " +
		"line_count, part_count, errors, warnings}. Warns on components missing a value " +
		"or footprint. Footprint-presence flags are added only when lib_dir is supplied.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."},
			"lib_dir": {"type": "string", "description": "Optional KiCAD footprint-library dir for presence checks."}
		}
	}`),
}

func HandleCheckBOM(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "check_bom", withDefaultLibDir(params))
}

// ---- minerva_pcb_export_assembly ---------------------------------------------------
//
// D0-5 (docket 019fc2f8b903): C8 shipped assembly_outputs.py (BOM+CPL
// emitters) and the assembly_bom/assembly_cpl worker dispatch entries
// (methods.py) worker-side only, with no agent-facing tool exposing them —
// that Go/manifest wiring is this unit's whole scope.
//
// NAMING DEVIATION FROM BRIEF, MEASURED: the brief that filed this unit
// specifies a "house" param. The worker's ACTUAL dispatch-level contract key
// is "profile" (methods.py _assembly_bom/_assembly_cpl read
// params.get("profile"); worker/tests/test_methods.py's own dispatch tests
// call it that way, e.g. test_assembly_cpl_unknown_house_is_named_refusal
// passes {"profile": "acme"} despite its own test NAME saying "house"). Every
// existing worker-backed Handle* in this file forwards params to w.Call
// UNCHANGED — zero translation layer — so naming this tool's schema property
// "house" and forwarding raw would silently break: the worker would never
// see the caller's choice under the key it actually reads, defaulting to
// "jlc" every time and making the unknown-house/oshpark refusal paths
// unreachable. Renaming here to match the measured wire contract, instead of
// adding a house->profile translation shim (which WOULD be a new dispatch
// style — none of Validate/Generate/Gerbers/etc. do any param rewriting
// beyond withDefaultLibDir's lib_dir fill, which never renames a caller key).
// Same reasoning for "out_dir" vs the brief's "output_dir": _write_assembly_files
// (methods.py) reads params.get("out_dir") — the exact key minerva_pcb_gerbers
// already uses — so this tool reuses "out_dir" verbatim rather than a
// same-meaning-different-spelling key the worker would silently ignore.
var ExportAssembly = ToolSpec{
	Name: "minerva_pcb_export_assembly",
	Description: "Generate a pre-assembly order package (BOM CSV + CPL/pick-and-place CSV) " +
		"from a canonical PCB board for one assembly house profile — pure Python, no KiCad " +
		"binary. Args {yaml|board, profile?:<house id, default \"jlc\">, name?:<basename>, " +
		"out_dir?:<dir>}. \"jlc\" is the only house profile that currently offers assembly " +
		"service; \"oshpark\" is a KNOWN house that refuses (bare-board only — no assembly " +
		"service). Returns {profile, bom:{filename,rows,path}, cpl:{filename,rows,path}} — " +
		"rows counts data rows (header excluded); path is omitted unless out_dir was given, " +
		"in which case both CSVs are also written to disk. Refusals are NAMED, never a " +
		"silent best-guess format or a blank identity cell: a component the profile requires " +
		"identity for (jlc requires mpn) and lacks it refuses naming the component ref; an " +
		"unrecognized or assembly-incapable house id refuses naming the id. CPL rotation is " +
		"emitted verbatim from the authored rotation_deg (KiCad-equivalent clockwise " +
		"convention); CPL Y is the authored y_mm negated, X verbatim. Calls the worker's " +
		"assembly_bom then assembly_cpl methods over the same board+profile — whichever " +
		"refuses first is the error this tool surfaces.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."},
			"profile": {"type": "string", "description": "Assembly house profile id (default \"jlc\" — the only assembly-capable profile shipped; \"oshpark\" is known but refuses — bare-board only)."},
			"name": {"type": "string", "description": "Optional output file basename (defaults to \"board\")."},
			"out_dir": {"type": "string", "description": "Optional directory to also write the files to."}
		}
	}`),
}

// assemblyCallReply is the shape ONE worker call (assembly_bom or
// assembly_cpl) replies with on success: {files:{filename:content}, ...}.
// This tool always calls with out_dir stripped (see stripOutDir), so the
// worker's own "written" field is never populated here and is deliberately
// not decoded — disk writing is this tool's OWN job, done in Go, only after
// BOTH calls succeed (see HandleExportAssembly's HALF-WRITE fix comment).
// Exactly one entry in files per call, since each call emits exactly one CSV.
type assemblyCallReply struct {
	Files map[string]string `json:"files"`
}

// assemblyOutputSummary is this tool's per-file reply shape. The worker's own
// reply carries no row count (AssemblyResult.rows is a Python-side attribute,
// not part of the {filename:content} dict that gets JSON-serialized) — rows
// is derived here from the returned CSV text itself.
type assemblyOutputSummary struct {
	Filename string `json:"filename"`
	Rows     int    `json:"rows"`
	Path     string `json:"path,omitempty"`
}

// decodeAssemblyFile pulls the (single) filename+content pair out of one
// worker call's {files:{filename:content}} reply, without writing anything —
// writing is HandleExportAssembly's job, deferred until BOTH calls are known
// to have succeeded.
func decodeAssemblyFile(raw json.RawMessage) (filename, content string, err error) {
	var r assemblyCallReply
	if err := json.Unmarshal(raw, &r); err != nil {
		return "", "", fmt.Errorf("decode assembly worker reply: %w", err)
	}
	for f, c := range r.Files {
		filename, content = f, c
	}
	return filename, content, nil
}

// csvDataRowCount counts non-empty data lines in the emitted CSV, excluding
// the header row. Splits on "\n" and trims a trailing "\r" per line so it is
// agnostic to the emitter's CSV_EOL choice ("\r\n" today, per
// assembly_outputs.py) rather than hard-coding that literal here.
func csvDataRowCount(content string) int {
	lines := strings.Split(content, "\n")
	n := 0
	for _, l := range lines {
		if strings.TrimRight(l, "\r") != "" {
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return n - 1 // header row
}

// stripOutDir returns params with out_dir removed. HandleExportAssembly ALWAYS
// computes both assembly_bom and assembly_cpl with out_dir stripped —
// HALF-WRITE FIX (cold review, elevated finding): forwarding out_dir straight
// to both worker calls (mirroring every other worker-backed tool's
// convention, e.g. HandleGerbers) would let the worker write the BOM CSV to
// disk on the FIRST call, then strand that file if the SECOND call refuses
// for a reason the BOM computation never hits — measured live: an invalid
// x_mm/y_mm (or a bad rotation_deg/layer token) fails only
// assembly_outputs._cpl_rows/_resolve_side, never _bom_rows, since BOM rows
// carry no position/side column. A refusal must be all-or-nothing: zero
// artifacts on disk either way. So this tool computes BOTH CSVs first (worker
// never touches disk), then — only once both have succeeded — writes both
// itself, in Go (see writeAssemblyFile below), with the first file removed
// again if the second write fails for a filesystem-level reason.
func stripOutDir(params json.RawMessage) json.RawMessage {
	var m map[string]interface{}
	if len(params) == 0 {
		return params
	}
	if err := json.Unmarshal(params, &m); err != nil {
		return params
	}
	delete(m, "out_dir")
	out, err := json.Marshal(m)
	if err != nil {
		return params
	}
	return out
}

// writeAssemblyFile writes one CSV to out_dir/filename, mkdir'ing out_dir as
// needed. Errors come back as a *bridge.WorkerError{Kind:"io"} — the same
// kind methods.py's own _write_assembly_files uses for an OSError — so a
// disk-level fault reads identically to the shape callers already handle for
// every other worker-backed tool's out_dir failures.
func writeAssemblyFile(outDir, filename, content string) error {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return &bridge.WorkerError{Kind: "io", Message: fmt.Sprintf("failed to write to out_dir: %v", err)}
	}
	if err := os.WriteFile(filepath.Join(outDir, filename), []byte(content), 0o644); err != nil {
		return &bridge.WorkerError{Kind: "io", Message: fmt.Sprintf("failed to write to out_dir: %v", err)}
	}
	return nil
}

func HandleExportAssembly(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	var p struct {
		Profile string `json:"profile"`
		OutDir  string `json:"out_dir"`
	}
	_ = json.Unmarshal(params, &p) // best-effort; empty/malformed falls through to the defaults below

	// Compute BOTH CSVs BEFORE writing anything — see stripOutDir's doc
	// comment (HALF-WRITE fix).
	computeParams := stripOutDir(params)

	bomRaw, err := w.Call(ctx, "assembly_bom", computeParams)
	if err != nil {
		return nil, err
	}
	bomFilename, bomContent, err := decodeAssemblyFile(bomRaw)
	if err != nil {
		return nil, err
	}

	cplRaw, err := w.Call(ctx, "assembly_cpl", computeParams)
	if err != nil {
		return nil, err
	}
	cplFilename, cplContent, err := decodeAssemblyFile(cplRaw)
	if err != nil {
		return nil, err
	}

	bomSummary := assemblyOutputSummary{Filename: bomFilename, Rows: csvDataRowCount(bomContent)}
	cplSummary := assemblyOutputSummary{Filename: cplFilename, Rows: csvDataRowCount(cplContent)}

	// Both computations succeeded — NOW write, only here, and only both
	// together: if the CPL write fails after the BOM write already landed,
	// remove the BOM file too, so a filesystem-level fault leaves zero
	// artifacts exactly like a worker-level refusal does.
	if strings.TrimSpace(p.OutDir) != "" {
		if err := writeAssemblyFile(p.OutDir, bomFilename, bomContent); err != nil {
			return nil, err
		}
		bomPath := filepath.Join(p.OutDir, bomFilename)
		bomSummary.Path = bomPath
		if err := writeAssemblyFile(p.OutDir, cplFilename, cplContent); err != nil {
			_ = os.Remove(bomPath)
			return nil, err
		}
		cplSummary.Path = filepath.Join(p.OutDir, cplFilename)
	}

	profile := p.Profile
	if profile == "" {
		profile = "jlc" // mirrors the worker's own default (methods.py _assembly_bom/_assembly_cpl)
	}
	data, err := json.Marshal(map[string]interface{}{
		"profile": profile,
		"bom":     bomSummary,
		"cpl":     cplSummary,
	})
	if err != nil {
		return nil, err
	}
	return json.RawMessage(data), nil
}

// ---- rendered-bless surface (S3/B2, docket 019ff5687b99) -------------------
//
// The library trust boundary. The coincidence guard compares pad CENTRES and
// cannot be a trust boundary; a human blessing a RENDERED footprint against its
// datasheet is. These three tools are that surface: STAGE a .kicad_mod into the
// WIP layer, REPORT it (fact table + SVG), BLESS it. The gate lives in the
// Python worker (pcb_worker/bless.py): an unblessed entry is absent from the
// resolving chain's lock VIEW, so no resolver path can serve it.
//
// WIP ROOT (see withWIPRoot): every one of these forwards with wip_root set to
// <plugin data dir>/library_wip, ALWAYS overriding any caller value.

var FootprintStage = ToolSpec{
	Name: "minerva_pcb_footprint_stage",
	Description: "Stage a .kicad_mod footprint into the WIP library layer, " +
		"sha256-pinned and UNBLESSED. Args {ref:'LibNick:PartName', " +
		"kicad_mod_text, source_kind:'official_kicad|vendor_export|git|url|" +
		"hand_authored|generated', source_ref, license, retrieved_at?, " +
		"provenance_note?}. Returns {ref, entry:<acquisition-lock v2 entry with " +
		"bless:null>, report:{facts, not_rendered, svg_sha256, " +
		"artifact_sha256}}. The text is " +
		"PARSED FIRST — unparseable or padless input writes no file and mutates " +
		"no lock. A staged entry cannot supply copper until " +
		"minerva_pcb_footprint_bless records a verdict against it: unblessed " +
		"refs are excluded from the resolution chain, so a board resolves the " +
		"lower layer's part rather than the staged bytes. Re-staging a ref " +
		"replaces its bytes and RESETS bless to null. Empty source_kind/" +
		"source_ref/license are refused by name.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"ref": {"type": "string", "description": "Full footprint ref, 'LibNick:PartName' — the library nickname names the .pretty directory the staged file is written into."},
			"kicad_mod_text": {"type": "string", "description": "The complete .kicad_mod s-expression text to stage."},
			"source_kind": {"type": "string", "description": "Provenance class: official_kicad, vendor_export, git, url, hand_authored or generated."},
			"source_ref": {"type": "string", "description": "Where the bytes came from (URL, git rev, datasheet + author, ...)."},
			"license": {"type": "string", "description": "SPDX id or LicenseRef for the staged text."},
			"retrieved_at": {"type": "string", "description": "Acquisition date (defaults to UTC now)."},
			"provenance_note": {"type": "string", "description": "Optional free-text note kept on the lock entry."}
		},
		"required": ["ref", "kicad_mod_text", "source_kind", "source_ref", "license"]
	}`),
}

func HandleFootprintStage(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "footprint_stage", withWIPRoot(params))
}

var FootprintReport = ToolSpec{
	Name: "minerva_pcb_footprint_report",
	Description: "Render the two artifacts a human blesses a footprint " +
		"against: a FACT TABLE and a self-contained SVG. Args {ref, " +
		"max_svg_bytes?}. Returns {ref, facts:{ref, footprint_name, layer, " +
		"source_kind, license, source_ref, pad_count, pad_numbers, " +
		"pads:[{number,type,shape,x_mm,y_mm,size,drill,drill_shape,drill_size," +
		"layers,rotation,roundrect_rratio,solder_mask_margin," +
		"solder_paste_margin}], courtyard_bbox, body_bbox, assembly}, " +
		"not_rendered:[{feature,detail,...}], svg, svg_sha256, " +
		"artifact_sha256, svg_bytes, svg_truncated}. artifact_sha256 digests " +
		"the staged content sha + the complete facts + not_rendered + the " +
		"picture — it is what a human-tier bless must quote back as " +
		"expected_artifact_sha256. Coordinates in facts are footprint-LOCAL " +
		"with KiCad's y-DOWN sign (verbatim from the .kicad_mod); the SVG " +
		"negates y so the picture is a conventional top view, and does not " +
		"mirror x, so back-side geometry is drawn as seen through the board. " +
		"not_rendered lists EVERY parsed element the picture omits — an empty " +
		"not_rendered is the only condition under which the render shows the " +
		"whole part. svg_sha256/svg_bytes always describe the WHOLE artifact " +
		"even when svg itself is truncated for transport.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"ref": {"type": "string", "description": "Footprint ref to report on ('LibNick:PartName'); resolves through the layer chain, staged WIP parts included."},
			"max_svg_bytes": {"type": "integer", "description": "Truncate the returned svg body at this many bytes (default 200000). svg_sha256/svg_bytes still describe the whole artifact."}
		},
		"required": ["ref"]
	}`),
}

func HandleFootprintReport(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "footprint_report", withWIPRoot(params))
}

var FootprintBless = ToolSpec{
	Name: "minerva_pcb_footprint_bless",
	Description: "Record a bless verdict against a staged footprint, which is " +
		"what lets it supply copper. Args {ref, verdict?:'approved'|'rejected', " +
		"who?, blessed_at?, expected_artifact_sha256?}. Returns {ref, " +
		"entry:<entry with bless:{tier, verdict, who, artifact_sha256, " +
		"content_sha256, blessed_at}>, report:{facts, not_rendered, " +
		"svg_sha256, artifact_sha256}}. TIERING: source_kind official_kicad " +
		"AUTO-BLESSES on provenance — omit verdict for it, and passing one is " +
		"refused rather than silently recorded, so the lock can always " +
		"distinguish parts a human reviewed from parts policy trusted. Every " +
		"other source_kind (hand_authored above all — we authored those " +
		"numbers) requires an explicit human verdict PLUS " +
		"expected_artifact_sha256: the artifact_sha256 of the " +
		"minerva_pcb_footprint_report the reviewer actually looked at. If the " +
		"staged content changed since that review the bless REFUSES — an " +
		"approval never transfers to an artifact nobody saw. The render is " +
		"regenerated here and its digest pinned, so a footprint that cannot be " +
		"rendered cannot be blessed. A 'rejected' verdict is recorded and " +
		"keeps the ref unresolvable.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"ref": {"type": "string", "description": "Staged footprint ref ('LibNick:PartName')."},
			"verdict": {"type": "string", "description": "'approved' or 'rejected'. OMIT for an official_kicad entry, which auto-blesses; supplying one for it is refused."},
			"who": {"type": "string", "description": "Who performed the rendered check. Required for a human-tier verdict."},
			"blessed_at": {"type": "string", "description": "Timestamp to record (defaults to UTC now)."},
			"expected_artifact_sha256": {"type": "string", "description": "artifact_sha256 of the report the reviewer looked at. Required with a human-tier verdict; the bless refuses if the staged content renders a different artifact now."}
		},
		"required": ["ref"]
	}`),
}

func HandleFootprintBless(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "footprint_bless", withWIPRoot(params))
}

// ---- acquisition (S4/B3, docket 019ff5689732) ------------------------------
//
// One official KiCad footprint, on demand. GO FETCHES; THE WORKER STAGES. The
// bytes are pulled here (internal/libraries/acquire.go — network code is Go-only
// in this plugin, the Python worker never fetches), then handed to the worker's
// footprint_acquire_store, which runs the SAME B2 machinery the manual surface
// runs: stage_footprint parse-validates and sha-pins, auto_bless_footprint
// records the auto-tier verdict. There is deliberately no second staging path.
//
// The sha256 computed here over the wire bytes travels with the text, and the
// worker recomputes it independently over what it received and REFUSES on
// disagreement — two derivations of the same bytes, either side of a bridge.

var AcquireFootprint = ToolSpec{
	Name: "minerva_pcb_acquire_footprint",
	Description: "Acquire ONE official KiCad footprint by ref and make it usable " +
		"in a single call. Args {ref:'LibNick:PartName'}. Performs outbound HTTPS " +
		"to gitlab.com for the kicad-footprints file at the release tag pinned in " +
		"pcb/libraries.lock.json (the lock is the single source of truth for which " +
		"official release this plugin tracks — the tag is read, never restated " +
		"here), then hands the bytes to the worker, which parse-validates them, " +
		"stages them into the WIP library layer, and records the auto-tier verdict " +
		"official_kicad provenance earns. Returns {ref, layer:'wip', sha256, " +
		"source_ref:'kicad-footprints@<tag>/<Lib>.pretty/<Name>.kicad_mod', license, " +
		"bless:{tier:'auto', verdict, who, artifact_sha256, blessed_at}, entry, " +
		"report_summary:{facts, not_rendered, svg_sha256, artifact_sha256}} — " +
		"the ref resolves " +
		"immediately afterwards. Refuses without writing anything on: a ref with a " +
		"path separator or traversal segment, a non-200 status (404 = no such part " +
		"at this release), a body over 1 MiB, non-UTF-8 bytes, or content that is " +
		"markup rather than a footprint s-expression. The sha256 of the fetched " +
		"bytes is recomputed independently worker-side and a mismatch is refused. " +
		"ACQUISITION is the only library operation that needs a network: resolution " +
		"reads sha-pinned bytes off disk and never opens a socket, so a fetch " +
		"failure blocks adding this part and nothing else.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"ref": {"type": "string", "description": "Official KiCad footprint ref, 'LibNick:PartName' (e.g. 'Resistor_SMD:R_0402_1005Metric') — the library nickname names the upstream .pretty directory."}
		},
		"required": ["ref"]
	}`),
}

func HandleAcquireFootprint(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	var p struct {
		Ref string `json:"ref"`
	}
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, &bridge.WorkerError{Kind: "acquire",
				Message: fmt.Sprintf("minerva_pcb_acquire_footprint: params are not a JSON object: %v", err)}
		}
	}

	fetched, err := libraries.AcquireFootprint(libraries.DefaultLockPath(pluginRoot), p.Ref)
	if err != nil {
		return nil, acquireWorkerError(err)
	}

	// The worker is told the ref, the bytes, the provenance and the sha to
	// cross-check — and NOT the source_kind. official_kicad is fixed by the
	// method itself (methods.py _footprint_acquire_store), so this path cannot
	// be talked into auto-blessing third-party bytes by passing a field.
	call, err := json.Marshal(map[string]interface{}{
		"ref":            fetched.Ref,
		"kicad_mod_text": fetched.Text,
		"source_ref":     fetched.SourceRef,
		"license":        fetched.License,
		"fetched_sha256": fetched.SHA256,
	})
	if err != nil {
		return nil, err
	}
	return w.Call(ctx, "footprint_acquire_store", withWIPRoot(call))
}

// acquireWorkerError converts a libraries.AcquireError into the SAME
// {ok:false, error:{kind, message, details}} envelope a worker refusal takes
// (main.go turns a *bridge.WorkerError into MCP tool-result content with
// isError set, while any other error becomes an opaque JSON-RPC fault). An
// acquisition refusal is something the caller can act on — fix the ref, retry
// when the network is back — so it must reach the caller as content, not as a
// protocol error.
func acquireWorkerError(err error) error {
	ae, ok := err.(*libraries.AcquireError)
	if !ok {
		return &bridge.WorkerError{Kind: "acquire", Message: err.Error()}
	}
	details, mErr := json.Marshal(map[string]interface{}{
		"reason": ae.Kind,
		"ref":    ae.Ref,
		"url":    ae.URL,
		"offline_contract": "acquisition requires network access to gitlab.com; resolution never " +
			"does — already-acquired footprints resolve from sha-pinned bytes on disk",
	})
	we := &bridge.WorkerError{Kind: "acquire", Message: ae.Message}
	if mErr == nil {
		we.Details = details
	}
	return we
}

// wipRootDir is the staging library root: <plugin data dir>/library_wip,
// resolved through shared/runtime.DataDir (which honors MINERVA_PLUGIN_DATA_DIR)
// exactly like libraries.DefaultDir's <plugin data dir>/libraries sibling. Not
// created here — the worker creates it on the first stage.
func wipRootDir() string {
	return filepath.Join(sharedruntime.DataDir("pcb"), "library_wip")
}

// withWIPRoot forces wip_root onto a bless-surface call.
//
// Unlike withDefaultLibDir (which fills in only when the caller omitted the
// value), this ALWAYS overrides. wip_root is a WRITE destination derived from a
// ref the caller also controls, so honoring a caller-supplied root would turn
// minerva_pcb_footprint_stage into a write-anywhere primitive for an LLM. The
// host owns the data directory; the agent chooses the part, never the path.
//
// Malformed params (not a JSON object) are passed through unchanged so the
// worker's own uniform parse-error handling reports them.
func withWIPRoot(params json.RawMessage) json.RawMessage {
	var m map[string]interface{}
	if len(params) == 0 {
		m = map[string]interface{}{}
	} else if err := json.Unmarshal(params, &m); err != nil {
		return params
	}
	m["wip_root"] = wipRootDir()
	out, err := json.Marshal(m)
	if err != nil {
		return params
	}
	return out
}

// withDefaultLibDir fills in lib_dir with the fetched-library data directory
// (libraries.DefaultDir — minerva_pcb_fetch_libraries's destination) whenever the
// caller omits it or supplies an empty/whitespace-only value, so an LLM
// caller doesn't need to know the path to get real footprint/symbol checks
// once minerva_pcb_fetch_libraries has run. An explicit caller-supplied lib_dir is
// never overridden. The worker's own os.path.isdir(lib_dir) guard handles the
// not-yet-fetched case gracefully (missing_data:true + hint) — this helper
// never needs to check presence itself.
//
// Malformed params (not a JSON object) are passed through unchanged; the
// worker's own parse-error handling reports that uniformly.
func withDefaultLibDir(params json.RawMessage) json.RawMessage {
	var m map[string]interface{}
	if len(params) == 0 {
		m = map[string]interface{}{}
	} else if err := json.Unmarshal(params, &m); err != nil {
		return params
	}

	if ld, ok := m["lib_dir"]; !ok || isBlankString(ld) {
		m["lib_dir"] = libraries.DefaultDir()
	}

	out, err := json.Marshal(m)
	if err != nil {
		return params
	}
	return out
}

func isBlankString(v interface{}) bool {
	if v == nil {
		return true
	}
	s, ok := v.(string)
	return ok && strings.TrimSpace(s) == ""
}
