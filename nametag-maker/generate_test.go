package main

import (
	"encoding/json"
	"testing"
)

// fakeHost is a capabilityCaller seam that records the last call and returns a
// canned reply — no live broker.
type fakeHost struct {
	lastCapability string
	lastArgs       map[string]interface{}
	reply          json.RawMessage
	err            *rpcError
}

func (h *fakeHost) callCapability(capability string, args map[string]interface{}) (json.RawMessage, *rpcError) {
	h.lastCapability = capability
	h.lastArgs = args
	if h.err != nil {
		return nil, h.err
	}
	return h.reply, nil
}

func mustArgs(t *testing.T, v interface{}) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	return b
}

func TestNametagGenerateSuccessMapsResult(t *testing.T) {
	host := &fakeHost{
		reply: json.RawMessage(`{
			"success": true,
			"result": {
				"bytes_b64": "JVBERi0xLjcK",
				"byte_size": 12345,
				"page_count": 2,
				"content_type": "application/pdf"
			}
		}`),
	}

	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows": []map[string]interface{}{
			{"name": "Ada", "class": "Math 1", "group": "1", "room": "A101"},
			{"name": "Grace Hopper", "class": "CS 200", "group": "1", "room": "A101"},
		},
	})

	res := toolNametagGenerate(host, args)

	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("expected success, got %+v", res)
	}
	if res["bytes_b64"] != "JVBERi0xLjcK" {
		t.Fatalf("bytes_b64 not mapped through: %v", res["bytes_b64"])
	}
	if res["page_count"] != 2 {
		t.Fatalf("page_count: want 2, got %v", res["page_count"])
	}
	if res["content_type"] != "application/pdf" {
		t.Fatalf("content_type: want application/pdf, got %v", res["content_type"])
	}

	// The capability called must be host.pdf.generate.
	if host.lastCapability != "host.pdf.generate" {
		t.Fatalf("capability: want host.pdf.generate, got %q", host.lastCapability)
	}

	// CRITICAL: args ARE the doc itself (top-level pages), NOT wrapped in {"doc":…}.
	if _, wrapped := host.lastArgs["doc"]; wrapped {
		t.Fatalf("args must not be wrapped in {\"doc\":…}; got keys %v", keys(host.lastArgs))
	}
	pages, ok := host.lastArgs["pages"].([]interface{})
	if !ok {
		t.Fatalf("args missing top-level pages; got keys %v", keys(host.lastArgs))
	}
	// 2 rows, back_mode default "same" → 2 pages (front + back, one sheet).
	if len(pages) != 2 {
		t.Fatalf("doc page_count: want 2 (front+back), got %d", len(pages))
	}
}

func TestNametagGenerateBlankBackModeSinglePage(t *testing.T) {
	host := &fakeHost{
		reply: json.RawMessage(`{"success":true,"result":{"bytes_b64":"x","byte_size":1,"page_count":1,"content_type":"application/pdf"}}`),
	}
	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"back_mode":       "blank",
		"rows":            []map[string]interface{}{{"name": "Ada"}},
	})
	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("expected success, got %+v", res)
	}
	pages, _ := host.lastArgs["pages"].([]interface{})
	if len(pages) != 1 {
		t.Fatalf("blank back_mode: want 1 doc page, got %d", len(pages))
	}
}

func TestNametagGenerateCapabilityErrorSurfaces(t *testing.T) {
	// A GenError-style failure envelope from host.pdf.generate must surface as a
	// tool error carrying error_code/error_message.
	host := &fakeHost{
		reply: json.RawMessage(`{
			"success": false,
			"error_code": "pdf_generation_failed",
			"error_message": "gofpdf raised: bad image"
		}`),
	}
	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows":            []map[string]interface{}{{"name": "Ada"}},
	})

	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); ok {
		t.Fatalf("expected failure, got %+v", res)
	}
	if res["error_code"] != "pdf_generation_failed" {
		t.Fatalf("error_code: want pdf_generation_failed, got %v", res["error_code"])
	}
	if res["error_message"] != "gofpdf raised: bad image" {
		t.Fatalf("error_message not surfaced: %v", res["error_message"])
	}
}

func TestNametagGenerateTransportErrorSurfaces(t *testing.T) {
	host := &fakeHost{err: &rpcError{Code: -32603, Message: "stdin closed"}}
	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows":            []map[string]interface{}{{"name": "Ada"}},
	})
	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); ok {
		t.Fatalf("expected failure on transport error, got %+v", res)
	}
	if res["error_code"] != "rpc_error_-32603" {
		t.Fatalf("error_code: want rpc_error_-32603, got %v", res["error_code"])
	}
}

func TestNametagGenerateMissingIcon(t *testing.T) {
	host := &fakeHost{}
	args := mustArgs(t, map[string]interface{}{
		"rows": []map[string]interface{}{{"name": "Ada"}},
	})
	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); ok {
		t.Fatalf("expected failure without icon, got %+v", res)
	}
	if res["error_code"] != "schema_validation_failed" {
		t.Fatalf("error_code: want schema_validation_failed, got %v", res["error_code"])
	}
	if host.lastCapability != "" {
		t.Fatalf("must not call capability when validation fails; called %q", host.lastCapability)
	}
}

func TestNametagGenerateCSVPath(t *testing.T) {
	host := &fakeHost{
		reply: json.RawMessage(`{"success":true,"result":{"bytes_b64":"x","byte_size":1,"page_count":2,"content_type":"application/pdf"}}`),
	}
	csv := "Name,Class,Group #,Room Assignment\n" +
		"Ada,Math 1,1,A101\n" +
		"Grace Hopper,CS 200,1,A101\n"
	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"csv":             csv,
	})
	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("expected success from CSV path, got %+v", res)
	}
	pages, _ := host.lastArgs["pages"].([]interface{})
	if len(pages) != 2 {
		t.Fatalf("CSV 2 rows back_mode same: want 2 doc pages, got %d", len(pages))
	}
}

func TestParseCSVRowsHeaderMapping(t *testing.T) {
	csv := "Name,Class,Group #,Room Assignment\n" +
		"Ada,Math 1,3,A101\n" +
		"\n" + // blank line skipped
		"Bob,Chem,2,C300\n"
	rows, fault := parseCSVRows(csv)
	if fault != nil {
		t.Fatalf("parseCSVRows fault: %+v", fault)
	}
	if len(rows) != 2 {
		t.Fatalf("want 2 rows (blank skipped), got %d", len(rows))
	}
	if rows[0].Name != "Ada" || rows[0].Class != "Math 1" || rows[0].Group != "3" || rows[0].Room != "A101" {
		t.Fatalf("row 0 mismatched: %+v", rows[0])
	}
}

// recordedCall captures one callCapability invocation for sequence assertions.
type recordedCall struct {
	capability string
	args       map[string]interface{}
}

// seqHost is a capabilityCaller that returns canned replies in order and
// records every call — used to exercise the multi-step nametag_save flow.
type seqHost struct {
	replies []json.RawMessage
	calls   []recordedCall
	idx     int
}

func (h *seqHost) callCapability(capability string, args map[string]interface{}) (json.RawMessage, *rpcError) {
	h.calls = append(h.calls, recordedCall{capability: capability, args: args})
	if h.idx >= len(h.replies) {
		return nil, &rpcError{Code: -32603, Message: "seqHost: no canned reply for call " + capability}
	}
	r := h.replies[h.idx]
	h.idx++
	return r, nil
}

// TestNametagSavePickerFallback covers the no-`path` human-panel flow:
// generate → file_picker → files.write, with NO grant_scope handshake.
func TestNametagSavePickerFallback(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		// host.pdf.generate
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERi0xLjcK","byte_size":42,"page_count":2,"content_type":"application/pdf"}}`),
		// host.dialogs.file_picker
		json.RawMessage(`{"success":true,"result":{"cancelled":false,"path":"/tmp/x.pdf"}}`),
		// host.files.write
		json.RawMessage(`{"success":true,"result":{"path":"/tmp/x.pdf","bytes_written":42}}`),
	}}

	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows": []map[string]interface{}{
			{"name": "Ada"},
			{"name": "Grace Hopper"},
		},
	})

	res := toolNametagSave(host, args)

	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("expected success, got %+v", res)
	}
	if saved, _ := res["saved"].(bool); !saved {
		t.Fatalf("expected saved:true, got %+v", res)
	}
	if res["path"] != "/tmp/x.pdf" {
		t.Fatalf("path: want /tmp/x.pdf, got %v", res["path"])
	}
	if res["page_count"] != 2 {
		t.Fatalf("page_count: want 2, got %v", res["page_count"])
	}
	if res["bytes_written"] != 42 {
		t.Fatalf("bytes_written: want 42, got %v", res["bytes_written"])
	}

	// Exactly three capabilities, in order — NO grant_scope.
	wantOrder := []string{
		"host.pdf.generate",
		"host.dialogs.file_picker",
		"host.files.write",
	}
	if len(host.calls) != len(wantOrder) {
		t.Fatalf("expected %d capability calls, got %d: %+v", len(wantOrder), len(host.calls), host.calls)
	}
	for i, want := range wantOrder {
		if host.calls[i].capability != want {
			t.Fatalf("call %d: want %q, got %q", i, want, host.calls[i].capability)
		}
	}
	for _, c := range host.calls {
		if c.capability == "host.permissions.grant_scope" {
			t.Fatalf("grant_scope must not be called — the unrestricted fs mode authorizes the write")
		}
	}

	// file_picker args: mode=save and filters is Godot FileDialog Array-of-String.
	picker := host.calls[1].args
	if picker["mode"] != "save" {
		t.Fatalf("file_picker mode: want save, got %v", picker["mode"])
	}
	filters, ok := picker["filters"].([]string)
	if !ok || len(filters) != 1 || filters[0] != "*.pdf ; PDF Files" {
		t.Fatalf("file_picker filters: want [\"*.pdf ; PDF Files\"], got %#v", picker["filters"])
	}

	// files.write MUST carry the generated bytes_b64 verbatim, base64-encoded.
	write := host.calls[2].args
	if write["content"] != "JVBERi0xLjcK" {
		t.Fatalf("files.write content: want generated bytes_b64, got %v", write["content"])
	}
	if write["encoding"] != "base64" {
		t.Fatalf("files.write encoding: want base64, got %v", write["encoding"])
	}
	if write["path"] != "/tmp/x.pdf" {
		t.Fatalf("files.write path: want /tmp/x.pdf, got %v", write["path"])
	}
}

// TestNametagSaveExplicitPath covers the agent-driven flow: an explicit `path`
// is written directly with NO file_picker and NO grant_scope — just
// generate → files.write.
func TestNametagSaveExplicitPath(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		// host.pdf.generate
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"JVBERi0xLjcK","byte_size":42,"page_count":2,"content_type":"application/pdf"}}`),
		// host.files.write
		json.RawMessage(`{"success":true,"result":{"path":"/home/me/tags.pdf","bytes_written":42}}`),
	}}

	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"path":            "/home/me/tags.pdf",
		"rows":            []map[string]interface{}{{"name": "Ada"}},
	})

	res := toolNametagSave(host, args)

	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("expected success, got %+v", res)
	}
	if saved, _ := res["saved"].(bool); !saved {
		t.Fatalf("expected saved:true, got %+v", res)
	}
	if res["path"] != "/home/me/tags.pdf" {
		t.Fatalf("path: want /home/me/tags.pdf, got %v", res["path"])
	}

	// Exactly two capabilities — NO file_picker, NO grant_scope.
	wantOrder := []string{"host.pdf.generate", "host.files.write"}
	if len(host.calls) != len(wantOrder) {
		t.Fatalf("expected %d capability calls, got %d: %+v", len(wantOrder), len(host.calls), host.calls)
	}
	for i, want := range wantOrder {
		if host.calls[i].capability != want {
			t.Fatalf("call %d: want %q, got %q", i, want, host.calls[i].capability)
		}
	}
	for _, c := range host.calls {
		if c.capability == "host.dialogs.file_picker" || c.capability == "host.permissions.grant_scope" {
			t.Fatalf("explicit path must not trigger %q", c.capability)
		}
	}

	// files.write must target the explicit path with the generated bytes.
	write := host.calls[1].args
	if write["path"] != "/home/me/tags.pdf" {
		t.Fatalf("files.write path: want /home/me/tags.pdf, got %v", write["path"])
	}
	if write["content"] != "JVBERi0xLjcK" {
		t.Fatalf("files.write content: want generated bytes_b64, got %v", write["content"])
	}
}

func TestNametagSaveCancelledPicker(t *testing.T) {
	host := &seqHost{replies: []json.RawMessage{
		// host.pdf.generate
		json.RawMessage(`{"success":true,"result":{"bytes_b64":"x","byte_size":1,"page_count":1,"content_type":"application/pdf"}}`),
		// host.dialogs.file_picker — cancelled
		json.RawMessage(`{"success":true,"result":{"cancelled":true}}`),
	}}

	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows":            []map[string]interface{}{{"name": "Ada"}},
	})

	res := toolNametagSave(host, args)

	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("cancelled picker should not be an error; got %+v", res)
	}
	if saved, _ := res["saved"].(bool); saved {
		t.Fatalf("expected saved:false on cancel, got %+v", res)
	}
	if cancelled, _ := res["cancelled"].(bool); !cancelled {
		t.Fatalf("expected cancelled:true, got %+v", res)
	}

	// Must have called only generate + picker — NO grant, NO write.
	if len(host.calls) != 2 {
		t.Fatalf("expected 2 calls (generate, picker), got %d: %+v", len(host.calls), host.calls)
	}
	for _, c := range host.calls {
		if c.capability == "host.permissions.grant_scope" || c.capability == "host.files.write" {
			t.Fatalf("must not call %q after a cancelled picker", c.capability)
		}
	}
}

func keys(m map[string]interface{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
