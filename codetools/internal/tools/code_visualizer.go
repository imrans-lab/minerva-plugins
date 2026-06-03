// Code-visualizer (vendored code-magic) MCP tool specs + handlers.
// P1.3 — each tool round-trips through the embedded Python worker into
// codetools_worker.code_visualizer.<name>, which returns the P1.2 unified
// envelope. The Go side is a thin spec+forward; all logic is in Python.
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/codetools/internal/bridge"
)

// Every code-visualizer tool accepts an optional `db_path` parameter (path to
// the SQLite store) that falls back to the CODETOOLS_DB env var when omitted.
// The shared description is duplicated in each schema below — Go's encoding/json
// has no inheritance and the schemas ship as raw JSON to the agent.

// ---------------------------------------------------------------------------
// 1. query
// ---------------------------------------------------------------------------

var Query = ToolSpec{
	Name:        "minerva_codetools_query",
	Description: "Search the code-visualizer store by name + full-text. Returns matching symbols or files with id, kind, file, lines, and description.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"query": {"type": "string", "description": "Search text (name or description token)."},
			"project": {"type": "string", "description": "Optional project name to scope the search."},
			"scope": {"type": "string", "enum": ["symbols", "files"], "description": "What to search across. Default: symbols."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"required": ["query"],
		"additionalProperties": false
	}`),
}

func HandleQuery(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "query", params)
}

// ---------------------------------------------------------------------------
// 2. get_context
// ---------------------------------------------------------------------------

var GetContext = ToolSpec{
	Name:        "minerva_codetools_get_context",
	Description: "Get full context for a symbol or file: description, incoming/outgoing edges, tags, file location. Identifier may be a symbol ID, symbol name, or file relative path.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"identifier": {"type": "string", "description": "Symbol ID, symbol name, or file relative path."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"required": ["identifier"],
		"additionalProperties": false
	}`),
}

func HandleGetContext(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "get_context", params)
}

// ---------------------------------------------------------------------------
// 3. stale_check
// ---------------------------------------------------------------------------

var StaleCheck = ToolSpec{
	Name:        "minerva_codetools_stale_check",
	Description: "List indexed files whose current git hash differs from the indexed one (or that no longer exist on disk).",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"project": {"type": "string", "description": "Optional project name to scope the check."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"additionalProperties": false
	}`),
}

func HandleStaleCheck(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "stale_check", params)
}

// ---------------------------------------------------------------------------
// 4. get_diff
// ---------------------------------------------------------------------------

var GetDiff = ToolSpec{
	Name:        "minerva_codetools_get_diff",
	Description: "Get a structured git diff between two refs (default HEAD vs working tree). Returns changed files with before/after content for side-by-side display.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"base": {"type": "string", "description": "Base git ref. Default: HEAD."},
			"head": {"type": "string", "description": "Head git ref. Empty = working tree (unstaged + staged)."},
			"file": {"type": "string", "description": "Optional path filter."},
			"repo_path": {"type": "string", "description": "Repo working tree. If empty, inferred from the first project in the store."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"additionalProperties": false
	}`),
}

func HandleGetDiff(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "get_diff", params)
}

// ---------------------------------------------------------------------------
// 5. analyze
// ---------------------------------------------------------------------------

var Analyze = ToolSpec{
	Name:        "minerva_codetools_analyze",
	Description: "Run a higher-level analysis over the store. analysis ∈ {dead_code, dry_candidates, coupling_hotspots, stats}.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"analysis": {"type": "string", "enum": ["dead_code", "dry_candidates", "coupling_hotspots", "stats"]},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"required": ["analysis"],
		"additionalProperties": false
	}`),
}

func HandleAnalyze(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "analyze", params)
}

// ---------------------------------------------------------------------------
// 6. set_description
// ---------------------------------------------------------------------------

var SetDescription = ToolSpec{
	Name:        "minerva_codetools_set_description",
	Description: "Set the human-readable description for a symbol or file.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"id": {"type": "string"},
			"description": {"type": "string"},
			"entity_type": {"type": "string", "enum": ["symbol", "file"], "description": "Default: symbol."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"required": ["id", "description"],
		"additionalProperties": false
	}`),
}

func HandleSetDescription(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "set_description", params)
}

// ---------------------------------------------------------------------------
// 7. describe_symbol
// ---------------------------------------------------------------------------

var DescribeSymbol = ToolSpec{
	Name:        "minerva_codetools_describe_symbol",
	Description: "Set description AND semantic tags for a symbol in one call. tags is a comma-separated list.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"id": {"type": "string"},
			"description": {"type": "string"},
			"tags": {"type": "string", "description": "Comma-separated semantic tags (e.g. 'mutates_state,does_io')."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"required": ["id", "description"],
		"additionalProperties": false
	}`),
}

func HandleDescribeSymbol(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "describe_symbol", params)
}

// ---------------------------------------------------------------------------
// 8. set_tags
// ---------------------------------------------------------------------------

var SetTags = ToolSpec{
	Name:        "minerva_codetools_set_tags",
	Description: "Set semantic tags on a symbol or file. tags is a comma-separated list.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"id": {"type": "string"},
			"tags": {"type": "string", "description": "Comma-separated tags."},
			"entity_type": {"type": "string", "enum": ["symbol", "file"], "description": "Default: symbol."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"required": ["id", "tags"],
		"additionalProperties": false
	}`),
}

func HandleSetTags(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "set_tags", params)
}

// ---------------------------------------------------------------------------
// 9. undescribed
// ---------------------------------------------------------------------------

var Undescribed = ToolSpec{
	Name:        "minerva_codetools_undescribed",
	Description: "List symbols or files that still lack a description.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"entity_type": {"type": "string", "enum": ["symbol", "file"], "description": "Default: symbol."},
			"limit": {"type": "integer", "minimum": 1, "description": "Max items. Default: 20."},
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Optional — falls back to the CODETOOLS_DB env var."}
		},
		"additionalProperties": false
	}`),
}

func HandleUndescribed(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "undescribed", params)
}

// ---------------------------------------------------------------------------
// 10. get_graph — full code graph with precomputed force-directed layout (P1.4)
// ---------------------------------------------------------------------------

var GetGraph = ToolSpec{
	Name:        "minerva_codetools_get_graph",
	Description: "Return the full code graph (nodes, edges, files, analysis, stats) with precomputed force-directed x/y positions on every node. Intended for the Godot visualizer panel.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"db_path": {"type": "string", "description": "Path to the code-visualizer SQLite store. Required — or set CODETOOLS_DB env var."}
		},
		"required": ["db_path"],
		"additionalProperties": false
	}`),
}

func HandleGetGraph(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "get_graph", params)
}
