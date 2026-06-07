package tools

// file_read / file_write / file_edit — codetools' agentic file tools.
//
// These do NOT touch disk directly. They delegate to Minerva's CORE buffered
// document tools (minerva_doc_read/_write/_edit) via the host-capability bridge
// (mcp.proxy:), so every edit is buffered -> journaled -> activity-logged and
// stays coherent with the live editor + annotations/refs. Raw-disk writes (bash)
// bypass all that; these intentionally don't. (work item 019ea035bb28 /
// 019e8f811497.)

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/imrans-lab/minerva-plugins/codetools/internal/bridge"
)

// HostCaller calls back into a Minerva host capability mid-tools/call (e.g.
// mcp.proxy:minerva_doc_write). Implemented in main by the bidirectional
// stdin/stdout client; left nil in tests that don't exercise it.
type HostCaller interface {
	Call(capability string, args json.RawMessage) (json.RawMessage, error)
}

// Host is the process-wide host caller, set once at startup by main().
var Host HostCaller

// ── Tool specs ───────────────────────────────────────────────────────────────

var FileRead = ToolSpec{
	Name:        "minerva_codetools_file_read",
	Description: "Read a file's current text via Minerva's buffered document store (sees unsaved editor edits). Delegates to core minerva_doc_read. Prefer this over bash `cat` for code you may edit.",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path."}},"required":["path"]}`),
}

var FileWrite = ToolSpec{
	Name:        "minerva_codetools_file_write",
	Description: "Write a file's full content through Minerva's buffered document store and flush to disk. Buffered => journaled (reviewable) + coherent with the live editor/annotations, unlike a raw bash write. Delegates to core minerva_doc_write (save). Creates parent dirs.",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path."},"content":{"type":"string","description":"Full file content."},"if_match_version":{"type":"integer","description":"Optimistic concurrency: only write if the file buffer's version equals this (from minerva_codetools_file_read). On mismatch the write is rejected (version_mismatch with want/got) so you can re-read and retry. Omit for last-write-wins."}},"required":["path","content"]}`),
}

var FileEdit = ToolSpec{
	Name:        "minerva_codetools_file_edit",
	Description: "Replace old_string with new_string in a file through Minerva's buffered document store and flush to disk (journaled + editor-coherent). Without replace_all, old_string must be unique. Delegates to core minerva_doc_edit (save).",
	InputSchema: json.RawMessage(`{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path."},"old_string":{"type":"string","description":"Text to find (unique unless replace_all)."},"new_string":{"type":"string","description":"Replacement text."},"replace_all":{"type":"boolean","description":"Replace every occurrence (default false)."},"if_match_version":{"type":"integer","description":"Optimistic concurrency: only edit if the file buffer's version equals this (from minerva_codetools_file_read). On mismatch the edit is rejected (version_mismatch with want/got) so you can re-read and retry. Omit for last-write-wins."}},"required":["path","old_string","new_string"]}`),
}

// ── Handlers ─────────────────────────────────────────────────────────────────

func HandleFileRead(_ context.Context, _ *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	var in struct {
		Path string `json:"path"`
	}
	_ = json.Unmarshal(params, &in)
	if in.Path == "" {
		return errEnvelope("path is required"), nil
	}
	docArgs, _ := json.Marshal(map[string]any{"path": in.Path})
	return proxyDoc("minerva_doc_read", "read "+in.Path, docArgs), nil
}

func HandleFileWrite(_ context.Context, _ *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	var in struct {
		Path           string `json:"path"`
		Content        string `json:"content"`
		IfMatchVersion *int64 `json:"if_match_version"`
	}
	_ = json.Unmarshal(params, &in)
	if in.Path == "" {
		return errEnvelope("path is required"), nil
	}
	// minerva_doc_write uses "text"; persist to disk with save:true.
	m := map[string]any{"path": in.Path, "text": in.Content, "save": true}
	if in.IfMatchVersion != nil {
		m["if_match_version"] = *in.IfMatchVersion // optimistic concurrency (DCR 019ea404ffcd P3)
	}
	docArgs, _ := json.Marshal(m)
	return proxyDoc("minerva_doc_write", "wrote "+in.Path, docArgs), nil
}

func HandleFileEdit(_ context.Context, _ *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	var in struct {
		Path           string `json:"path"`
		OldString      string `json:"old_string"`
		NewString      string `json:"new_string"`
		ReplaceAll     bool   `json:"replace_all"`
		IfMatchVersion *int64 `json:"if_match_version"`
	}
	_ = json.Unmarshal(params, &in)
	if in.Path == "" {
		return errEnvelope("path is required"), nil
	}
	m := map[string]any{
		"path":        in.Path,
		"old_string":  in.OldString,
		"new_string":  in.NewString,
		"replace_all": in.ReplaceAll,
		"save":        true,
	}
	if in.IfMatchVersion != nil {
		m["if_match_version"] = *in.IfMatchVersion // optimistic concurrency (DCR 019ea404ffcd P3)
	}
	docArgs, _ := json.Marshal(m)
	return proxyDoc("minerva_doc_edit", "edited "+in.Path, docArgs), nil
}

// ── Delegation + envelope helpers ────────────────────────────────────────────

// proxyDoc calls mcp.proxy:<tool> through the host bridge and maps the broker
// payload ({success, result} / {success:false, error_message}) into the
// codetools unified envelope. Returns a status:"error" envelope (never a Go
// error) on any failure so the model gets a clean tool result.
func proxyDoc(tool string, summary string, docArgs json.RawMessage) json.RawMessage {
	if Host == nil {
		return errEnvelope("host capability bridge unavailable")
	}
	payload, err := Host.Call("mcp.proxy:"+tool, docArgs)
	if err != nil {
		return errEnvelope(fmt.Sprintf("%s: %v", tool, err))
	}
	var wrap struct {
		Success bool            `json:"success"`
		Result  json.RawMessage `json:"result"`
		ErrMsg  string          `json:"error_message"`
		ErrCode string          `json:"error_code"`
	}
	_ = json.Unmarshal(payload, &wrap)
	if !wrap.Success {
		msg := wrap.ErrMsg
		if msg == "" {
			msg = fmt.Sprintf("%s failed", tool)
		}
		return errEnvelope(msg)
	}
	out, _ := json.Marshal(map[string]any{
		"status":  "ok",
		"summary": summary,
		"result":  wrap.Result,
	})
	return out
}

func errEnvelope(summary string) json.RawMessage {
	out, _ := json.Marshal(map[string]any{
		"status":  "error",
		"summary": summary,
		"error":   map[string]string{"message": summary},
	})
	return out
}
