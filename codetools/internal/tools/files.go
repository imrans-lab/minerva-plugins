// File-primitive MCP tool specs + handlers (P2.1).
//
// Four tools are registered here: glob, grep, bash, cwd. Each is a thin
// spec + forward to the Python worker — all logic lives in the Python handler.
// The pattern is identical to code_visualizer.go: ToolSpec constant + HandleX
// function that calls w.Call(ctx, "method", params).
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/codetools/internal/bridge"
)

// ---------------------------------------------------------------------------
// 1. glob
// ---------------------------------------------------------------------------

// Glob is the MCP spec for minerva_codetools_glob.
var Glob = ToolSpec{
	Name:        "minerva_codetools_glob",
	Description: "Find files matching a glob pattern (*, **, ?) under a base directory. Excludes .git, node_modules, __pycache__ etc. Results are sorted; a configurable limit prevents runaway output.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"pattern": {
				"type": "string",
				"description": "Glob pattern, e.g. '**/*.py', 'src/*.go', 'tests/test_?.py'."
			},
			"path": {
				"type": "string",
				"description": "Base directory to search. Defaults to the worker's current working directory."
			},
			"limit": {
				"type": "integer",
				"minimum": 0,
				"description": "Maximum number of results to return. 0 = unlimited. Default: 500."
			}
		},
		"required": ["pattern"],
		"additionalProperties": false
	}`),
}

// HandleGlob forwards the call to the worker's "glob" method.
func HandleGlob(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "glob", params)
}

// ---------------------------------------------------------------------------
// 2. grep
// ---------------------------------------------------------------------------

// Grep is the MCP spec for minerva_codetools_grep.
var Grep = ToolSpec{
	Name:        "minerva_codetools_grep",
	Description: "Regex search over file contents using bundled ripgrep (rg). Falls back to Python on dev boxes without a built bundle. Supports context lines, type filters, and file-glob filters. Binary files are auto-skipped.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"pattern": {
				"type": "string",
				"description": "Regex pattern to search for."
			},
			"path": {
				"type": "string",
				"description": "File or directory to search. Defaults to the worker's current working directory."
			},
			"type": {
				"type": "string",
				"description": "Language type filter, e.g. 'py', 'go', 'ts', 'gd'. Restricts search to files of that type."
			},
			"file_glob": {
				"type": "string",
				"description": "Glob filter on filenames, e.g. '*.test.ts'. Applied in addition to the type filter."
			},
			"ignore_case": {
				"type": "boolean",
				"description": "Case-insensitive search. Default: false."
			},
			"context_before": {
				"type": "integer",
				"minimum": 0,
				"description": "Lines of context before each match. Default: 0."
			},
			"context_after": {
				"type": "integer",
				"minimum": 0,
				"description": "Lines of context after each match. Default: 0."
			},
			"context_lines": {
				"type": "integer",
				"minimum": 0,
				"description": "Shorthand for equal context_before and context_after. Default: 0."
			},
			"limit": {
				"type": "integer",
				"minimum": 1,
				"description": "Maximum number of matches to return. Default: 200."
			}
		},
		"required": ["pattern"],
		"additionalProperties": false
	}`),
}

// HandleGrep forwards the call to the worker's "grep" method.
func HandleGrep(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "grep", params)
}

// ---------------------------------------------------------------------------
// 3. bash
// ---------------------------------------------------------------------------

// Bash is the MCP spec for minerva_codetools_bash.
var Bash = ToolSpec{
	Name:        "minerva_codetools_bash",
	Description: "Execute a shell command (headless subprocess, not a PTY). Policy is loaded from the plugin data directory; denied commands return an error envelope without execution. Output cap ~30 KB; timeout default 120 s (max 600 s).",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"command": {
				"type": "string",
				"description": "Shell command to execute."
			},
			"cwd": {
				"type": "string",
				"description": "Working directory for the command. Defaults to the worker's current working directory."
			},
			"timeout": {
				"type": "integer",
				"minimum": 1,
				"maximum": 600,
				"description": "Timeout in seconds. Default: 120. Hard cap: 600."
			}
		},
		"required": ["command"],
		"additionalProperties": false
	}`),
}

// HandleBash forwards the call to the worker's "bash" method.
func HandleBash(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "bash", params)
}

// ---------------------------------------------------------------------------
// 4. cwd
// ---------------------------------------------------------------------------

// Cwd is the MCP spec for minerva_codetools_cwd.
var Cwd = ToolSpec{
	Name:        "minerva_codetools_cwd",
	Description: "Get or set the worker's current working directory. When 'path' is omitted, returns the current directory. When 'path' is given, validates it exists and performs os.chdir() in the worker process so subsequent tool calls inherit the new directory.",
	InputSchema: json.RawMessage(`{
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Directory to change to. Supports ~ expansion and relative paths. Omit to just get the current directory."
			}
		},
		"additionalProperties": false
	}`),
}

// HandleCwd forwards the call to the worker's "cwd" method.
func HandleCwd(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "cwd", params)
}
