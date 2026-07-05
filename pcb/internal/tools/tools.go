// Package tools maintains the registry of MCP tools exposed by the PCB plugin.
//
// Register tools at server startup (not in init()) so the registry is empty at
// import time. Each tool's handler is a ToolHandlerFunc that receives raw JSON
// params and returns raw JSON result or an error.
//
// The worker round threads a *bridge.Worker through Dispatch, mirroring cad's
// internal/tools so worker-backed tools (pcb_validate/generate/check_*) slot in
// alongside the in-process tools (ping, the pcb.* project channels) without
// reshaping the router. In-process handlers keep their original (ctx, params)
// signature and are adapted via WrapInProcess, so their handlers and tests are
// untouched.
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// ToolSpec describes an MCP tool for the tools/list response.
type ToolSpec struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// ToolHandlerFunc is the signature for an MCP tool handler. It threads the
// worker so worker-backed tools can Call the Python subprocess; in-process
// tools ignore it (see WrapInProcess). params is the raw JSON from the
// tools/call "arguments" field.
type ToolHandlerFunc func(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error)

// InProcessHandlerFunc is the signature for a tool served entirely in-process
// (no worker) — ping and the pcb.* project channels. WrapInProcess adapts one
// to a ToolHandlerFunc so both kinds live in one Registry.
type InProcessHandlerFunc func(ctx context.Context, params json.RawMessage) (json.RawMessage, error)

// WrapInProcess adapts an in-process handler to the worker-threaded
// ToolHandlerFunc signature, discarding the (unused) worker.
func WrapInProcess(h InProcessHandlerFunc) ToolHandlerFunc {
	return func(ctx context.Context, _ *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
		return h(ctx, params)
	}
}

type entry struct {
	spec    ToolSpec
	handler ToolHandlerFunc
}

// Registry holds MCP tool registrations.
type Registry struct {
	entries []entry
}

// NewRegistry creates an empty Registry.
func NewRegistry() *Registry {
	return &Registry{}
}

// Register adds a tool with its spec and handler to the registry.
func (r *Registry) Register(spec ToolSpec, handler ToolHandlerFunc) {
	r.entries = append(r.entries, entry{spec: spec, handler: handler})
}

// Specs returns the ToolSpec for every registered tool, in registration order.
// Used to build the tools/list response.
func (r *Registry) Specs() []ToolSpec {
	specs := make([]ToolSpec, len(r.entries))
	for i, e := range r.entries {
		specs[i] = e.spec
	}
	return specs
}

// Dispatch looks up and calls the handler for the named tool, threading the
// worker to worker-backed handlers. The bool return is false if the name is
// not found (caller should return method-not-found). w may be nil for a
// registry containing only in-process tools.
func (r *Registry) Dispatch(ctx context.Context, w *bridge.Worker, name string, params json.RawMessage) (json.RawMessage, error, bool) {
	for _, e := range r.entries {
		if e.spec.Name == name {
			result, err := e.handler(ctx, w, params)
			return result, err, true
		}
	}
	return nil, nil, false
}
