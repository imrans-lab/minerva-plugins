// Sightline (code-probe) MCP tool specs + handlers (P3.2).
//
// Three op-driven tools are registered here: explore, inspect, validate.
// Each is a thin spec + forward to the Python worker — all logic lives in
// codetools_worker/sightline_probe.py. The pattern is identical to files.go:
// ToolSpec constant + HandleX function that calls w.Call(ctx, "method", params).
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/codetools/internal/bridge"
)

// ---------------------------------------------------------------------------
// 1. explore — code search / navigation
// ---------------------------------------------------------------------------

// Explore is the MCP spec for minerva_codetools_explore.
var Explore = ToolSpec{
	Name:        "minerva_codetools_explore",
	Description: "Code search and navigation using the vendored sightline library. Dispatches by op: 'search' (literal/regex search), 'where-defined' (find definitions), 'where-tested' (find test files), 'locate-edit' (find best edit targets), 'trace-topic' (trace a topic through the codebase), 'files' (list repo files). All ops return structured artifacts for agent consumption.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"op": {
				"type": "string",
				"enum": ["search", "where-defined", "where-tested", "locate-edit", "trace-topic", "files"],
				"description": "Operation to perform."
			},
			"query": {
				"type": "string",
				"description": "Search query or symbol name. Required for all ops except 'files'."
			},
			"root": {
				"type": "string",
				"description": "Root directory of the repo to search. Defaults to the worker's current working directory."
			},
			"limit": {
				"type": "integer",
				"minimum": 1,
				"description": "Max results to return. Defaults: search=20, where-* / locate-edit=5, trace-topic=6."
			},
			"regex": {
				"type": "boolean",
				"description": "Use regex mode for 'search'. Default: false (literal)."
			},
			"intent": {
				"type": "string",
				"description": "Search intent hint for 'search': definition, config, tests, edit, flow, example."
			},
			"path_contains": {
				"type": "string",
				"description": "Filter results to paths containing this substring."
			},
			"extension": {
				"type": "string",
				"description": "Filter results to files with this extension (e.g. '.py', '.go')."
			}
		},
		"required": ["op"],
		"additionalProperties": false
	}`),
}

// HandleExplore forwards the call to the worker's "explore" method.
func HandleExplore(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "explore", params)
}

// ---------------------------------------------------------------------------
// 2. inspect — evidence artifact capture / list / status
// ---------------------------------------------------------------------------

// Inspect is the MCP spec for minerva_codetools_inspect.
var Inspect = ToolSpec{
	Name:        "minerva_codetools_inspect",
	Description: "Evidence artifact capture, listing, and probe status for the sightline inspect subsystem. Dispatches by op: 'attach' (create an attachment session with artifact paths), 'list' (list sessions or artifacts for a session), 'status' (read Godot probe status, read-only — no Godot launch). Live Godot capture (godot-debugger-issues, godot-output-console, launch-editor) is gated to P3.3.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"op": {
				"type": "string",
				"enum": ["attach", "list", "status"],
				"description": "Operation to perform."
			},
			"root": {
				"type": "string",
				"description": "Root directory for the inspection store (.sightline/). Defaults to the worker's current working directory."
			},
			"surface_kind": {
				"type": "string",
				"description": "attach: surface kind for the SurfaceTarget (default: 'path')."
			},
			"surface_path": {
				"type": "string",
				"description": "attach: path component of the SurfaceTarget."
			},
			"route": {
				"type": "string",
				"description": "attach: route component of the SurfaceTarget."
			},
			"component_hint": {
				"type": "string",
				"description": "attach: component hint for the SurfaceTarget."
			},
			"artifacts": {
				"type": "array",
				"description": "attach: list of [kind, path] pairs or {kind, path} objects to register.",
				"items": {}
			},
			"session_id": {
				"type": "string",
				"description": "list: if given, list artifacts for this session instead of listing all sessions."
			},
			"project_path": {
				"type": "string",
				"description": "status: path to the Godot project to check probe status for."
			}
		},
		"required": ["op"],
		"additionalProperties": false
	}`),
}

// HandleInspect forwards the call to the worker's "inspect" method.
func HandleInspect(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "inspect", params)
}

// ---------------------------------------------------------------------------
// 3. validate — validate evidence against a goal
// ---------------------------------------------------------------------------

// Validate is the MCP spec for minerva_codetools_validate.
var Validate = ToolSpec{
	Name:        "minerva_codetools_validate",
	Description: "Validate code evidence and inspect artifacts against a stated goal. Runs a suite of checks (code region touched, artifact files present, artifact text matching, runtime issue thresholds) and returns a ValidationResultRecord with status, confidence, per-check results, and a recommended next step.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"goal": {
				"type": "string",
				"description": "Human-readable goal to validate (e.g. 'the export button is visible and labelled Export')."
			},
			"root": {
				"type": "string",
				"description": "Root directory for the sightline stores. Defaults to the worker's current working directory."
			},
			"code_result_ids": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Result handle IDs from prior explore/search calls to use as code evidence."
			},
			"artifact_ids": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Artifact IDs from prior inspect/attach calls to use as inspect evidence."
			},
			"artifact_only": {
				"type": "boolean",
				"description": "Skip the code-evidence requirement; pass when only artifact evidence is available. Default: false."
			},
			"expected_artifact_text": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Strings that must appear in at least one artifact's text content or metadata."
			},
			"require_no_runtime_issues": {
				"type": "boolean",
				"description": "Fail validation if any runtime_issue_report artifact contains issues. Default: false."
			},
			"max_runtime_warnings": {
				"type": "integer",
				"minimum": 0,
				"description": "Fail if the total warning count across runtime_issue_report artifacts exceeds this threshold."
			},
			"expected_runtime_warnings": {
				"type": "integer",
				"minimum": 0,
				"description": "Fail if the total warning count does not equal exactly this value."
			}
		},
		"required": ["goal"],
		"additionalProperties": false
	}`),
}

// HandleValidate forwards the call to the worker's "validate" method.
func HandleValidate(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "validate", params)
}
