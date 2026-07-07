// Package tools — worker-backed MCP tool specs + handlers for the PCB plugin.
//
// These four tools dispatch to the Python worker (python -m pcb_worker) via the
// shared Go↔Python bridge, exactly as the CAD plugin's mcad_validate does. The
// worker methods are pure functions over the canonical board YAML.
//
// Tool-naming convention (matches CAD): CAD exposes its worker analysis tools
// under a short prefix — mcad_validate / mcad_list_edges — distinct from its
// dotted panel-IPC channels (cad.evaluate, cad.export) and from core Minerva's
// minerva_cad_* tools. The PCB analog uses the pcb_ prefix for the LLM-facing
// worker tools (pcb_validate, pcb_generate, pcb_check_libraries, pcb_check_bom),
// keeping them distinct from the dotted pcb.serialize/... IPC channels declared
// in the manifest and from any core minerva_pcb_* tools. The worker METHOD names
// carry no prefix (validate, generate, check_libraries, check_bom) — same split
// CAD uses (MCP tool mcad_validate → worker method "validate").
package tools

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/libraries"
	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// WorkerToolHandlerFunc is the signature for a worker-backed tool: it threads a
// *bridge.Worker so the handler can Call the Python worker. The in-process tool
// path (ping / project channels) keeps the (ctx, params) signature; a small
// adapter (WorkerTool) bridges the two so both live in one Registry.
type WorkerToolHandlerFunc func(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error)

// ---- pcb_validate ----------------------------------------------------------

var Validate = ToolSpec{
	Name: "pcb_validate",
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

// ---- pcb_generate ----------------------------------------------------------

var Generate = ToolSpec{
	Name: "pcb_generate",
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

// ---- pcb_gerbers -----------------------------------------------------------

var Gerbers = ToolSpec{
	Name: "pcb_gerbers",
	Description: "Generate fabrication files (Gerber RS-274X/X2 + Excellon drills) from a " +
		"canonical PCB board — pure Python, no KiCad binary. Args {yaml|board, name?:<basename>, " +
		"out_dir?:<dir>}. Returns {files:{'<name>-F_Cu.gbr':text, ...'-B_Cu/-F_Mask/-B_Mask/" +
		"-F_SilkS/-Edge_Cuts.gbr', '<name>-PTH.drl':text, '<name>-NPTH.drl':text}, " +
		"written:[{path,bytes_written}]}. Six Gerber layers plus separate plated (PTH) and " +
		"non-plated (NPTH) Excellon drill files (each drill file only when the board has holes " +
		"of that class). Coordinate format is self-declared per layer (read the %FS line, not " +
		"assume 4.6). Silk currently renders a courtyard-box placeholder per top component " +
		"(no glyph text yet). Fab-correctness still needs a human viewer check — see docs/gerbers.md.",
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

// ---- pcb_drc ---------------------------------------------------------------

var DRC = ToolSpec{
	Name: "pcb_drc",
	Description: "Run a geometric design-rule check over a canonical PCB board — pure " +
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

// ---- pcb_resolve -----------------------------------------------------------

var Resolve = ToolSpec{
	Name: "pcb_resolve",
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

// ---- pcb.route (worker-backed broker CHANNEL, not an LLM tool name) --------
//
// Unlike pcb_validate/pcb_generate/... (LLM-facing tool names under the pcb_
// prefix), pcb.route is a dotted panel-IPC channel: ui/PCBPanel.gd's
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
		"agent_router engine. Args: {board:<canonical Board dict with a "+
		"'components' list — see docs/board-yaml.md>, route_hints:[<pcb_route_hint " +
		"annotation envelope>,...], selection:<optional dict scoping which hints/" +
		"nets to route — propose vs commit is expressed via the hint/selection " +
		"contents, not a separate flag>, options?:{allow_vias, single_layer, order, " +
		"trace_width, clearance, grid_resolution}}. Returns {ok, result:{success, " +
		"via_count, routes:[{net,segments:[{start,end,layer}],vias}], unrouted:" +
		"[{net,from,to}], warnings?, selected_hint_ids?}} on success, or " +
		"{ok:false, error:{kind,message}} on a structured routing/parse fault — " +
		"engine faults never crash the worker loop.",
	InputSchema: json.RawMessage(`{"type":"object"}`),
}

func HandleRouteChannel(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "route", params)
}

// ---- pcb_check_libraries ---------------------------------------------------

var CheckLibraries = ToolSpec{
	Name: "pcb_check_libraries",
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

// ---- pcb_check_bom ---------------------------------------------------------

var CheckBOM = ToolSpec{
	Name: "pcb_check_bom",
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

// withDefaultLibDir fills in lib_dir with the fetched-library data directory
// (libraries.DefaultDir — pcb_fetch_libraries's destination) whenever the
// caller omits it or supplies an empty/whitespace-only value, so an LLM
// caller doesn't need to know the path to get real footprint/symbol checks
// once pcb_fetch_libraries has run. An explicit caller-supplied lib_dir is
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
