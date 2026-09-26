package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/ipeerbhai/plugins/orchview/internal/readmodel"
)

// hostClient reaches Docket and Minerva's session registry through the
// host's mcp.proxy capabilities. Docket's tools are Minerva MCP tools named
// minerva_<docket tool>; each one used is granted in manifest.json.
type hostClient struct {
	call func(ctx context.Context, capability string, args map[string]any) (json.RawMessage, error)
}

// Call implements readmodel.Fetcher.
func (h *hostClient) Call(ctx context.Context, tool string, args map[string]any) (json.RawMessage, error) {
	return h.proxy(ctx, "minerva_"+tool, args)
}

// proxy calls one Minerva MCP tool and returns its decoded result.
//
// The broker answers {success, result} (or {success:false, error_code,
// error_message}); the result may still carry an MCP content envelope or a
// Docket host {value} wrapper, which are opened here. Numbers pass through
// Godot's JSON, which writes integers as floats ("3.0"); integral floats are
// written back as integers so typed fields decode.
func (h *hostClient) proxy(ctx context.Context, tool string, args map[string]any) (json.RawMessage, error) {
	raw, err := h.call(ctx, "mcp.proxy:"+tool, args)
	if err != nil {
		return nil, err
	}
	var envelope struct {
		Success      bool            `json:"success"`
		Result       json.RawMessage `json:"result"`
		ErrorCode    string          `json:"error_code"`
		ErrorMessage string          `json:"error_message"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, fmt.Errorf("%s: unreadable capability reply: %w", tool, err)
	}
	if !envelope.Success {
		return nil, fmt.Errorf("%s: %s", tool, strings.TrimSpace(envelope.ErrorCode+" "+envelope.ErrorMessage))
	}
	body, err := unwrap(envelope.Result)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", tool, err)
	}
	return integralNumbers(body)
}

func unwrap(raw json.RawMessage) (json.RawMessage, error) {
	var shape struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		Value json.RawMessage `json:"value"`
	}
	if json.Unmarshal(raw, &shape) != nil {
		return raw, nil
	}
	if len(shape.Content) == 1 && shape.Content[0].Type == "text" && json.Valid([]byte(shape.Content[0].Text)) {
		return json.RawMessage(shape.Content[0].Text), nil
	}
	if len(shape.Value) > 0 && bytes.HasPrefix(bytes.TrimSpace(shape.Value), []byte("{")) {
		return shape.Value, nil
	}
	return raw, nil
}

func integralNumbers(raw json.RawMessage) (json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return json.Marshal(normalize(v))
}

func normalize(v any) any {
	switch t := v.(type) {
	case map[string]any:
		for k, x := range t {
			t[k] = normalize(x)
		}
	case []any:
		for i, x := range t {
			t[i] = normalize(x)
		}
	case json.Number:
		if _, err := t.Int64(); err == nil {
			return t
		}
		if f, err := t.Float64(); err == nil && f == math.Trunc(f) && math.Abs(f) < 1<<53 {
			return int64(f)
		}
	}
	return v
}

// projects lists the Docket projects Minerva has open.
func (h *hostClient) projects(ctx context.Context) ([]string, error) {
	raw, err := h.proxy(ctx, "minerva_docket_project_list", map[string]any{})
	if err != nil {
		return nil, err
	}
	var listed struct {
		Projects []struct {
			Name string `json:"name"`
		} `json:"projects"`
	}
	if err := json.Unmarshal(raw, &listed); err != nil {
		return nil, fmt.Errorf("docket_project_list: %w", err)
	}
	var names []string
	for _, p := range listed.Projects {
		if p.Name != "" {
			names = append(names, p.Name)
		}
	}
	return names, nil
}

// sessions reads the registered harness sessions from minerva_terminal_list
// and maps each to the Docket principals that address it, as
// HarnessSessionRegistry.identities_addressed_by does: its identity, and its
// role unless a handover superseded it. The host reports no observation or
// turn time, so ObservedAt is when this read was made and LastActivityAt
// stays unset.
func (h *hostClient) sessions(ctx context.Context, now time.Time) ([]readmodel.SessionEvidence, error) {
	raw, err := h.proxy(ctx, "minerva_terminal_list", map[string]any{})
	if err != nil {
		return nil, err
	}
	var listed struct {
		Sessions []struct {
			Identity     string `json:"identity"`
			Role         string `json:"role"`
			Liveness     string `json:"liveness"`
			SupersededBy string `json:"superseded_by"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal(raw, &listed); err != nil {
		return nil, fmt.Errorf("minerva_terminal_list: %w", err)
	}
	var out []readmodel.SessionEvidence
	for _, s := range listed.Sessions {
		ev := readmodel.SessionEvidence{Principal: s.Identity, Identity: s.Identity, Role: s.Role,
			Liveness: s.Liveness, ObservedAt: now}
		out = append(out, ev)
		if s.Role != "" && s.SupersededBy == "" && !strings.EqualFold(s.Role, s.Identity) {
			ev.Principal = s.Role
			out = append(out, ev)
		}
	}
	return out, nil
}
