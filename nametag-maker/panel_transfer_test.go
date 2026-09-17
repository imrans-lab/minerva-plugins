package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// controlCapBytes is the host's bound on one panel IPC message in either
// direction (PluginPayloadLimits.CONTROL_BYTES). Anything larger is replaced by
// a payload_too_large error before the panel ever sees it.
const controlCapBytes = 64 * 1024

// fileHost answers host.pdf.generate with a canned PDF and services
// host.files.read/write against the real filesystem, so a test measures bytes
// on disk rather than trusting the reply.
type fileHost struct {
	pdf       []byte
	pageCount int
	picker    json.RawMessage
	calls     []string
}

func (h *fileHost) callCapability(capability string, args map[string]interface{}) (json.RawMessage, *rpcError) {
	h.calls = append(h.calls, capability)
	switch capability {
	case "host.pdf.generate":
		return json.RawMessage(fmt.Sprintf(
			`{"success":true,"result":{"bytes_b64":%q,"byte_size":%d,"page_count":%d,"content_type":"application/pdf"}}`,
			base64.StdEncoding.EncodeToString(h.pdf), len(h.pdf), h.pageCount)), nil

	case "host.files.write":
		data, err := base64.StdEncoding.DecodeString(args["content"].(string))
		if err != nil {
			return json.RawMessage(`{"success":false,"error_code":"io_error","error_message":"bad base64"}`), nil
		}
		path := args["path"].(string)
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return json.RawMessage(fmt.Sprintf(`{"success":false,"error_code":"io_error","error_message":%q}`, err.Error())), nil
		}
		return json.RawMessage(fmt.Sprintf(`{"success":true,"result":{"path":%q,"bytes_written":%d}}`, path, len(data))), nil

	case "host.files.read":
		data, err := os.ReadFile(args["path"].(string))
		if err != nil {
			return json.RawMessage(fmt.Sprintf(`{"success":false,"error_code":"io_error","error_message":%q}`, err.Error())), nil
		}
		return json.RawMessage(fmt.Sprintf(`{"success":true,"result":{"content":%q,"size":%d}}`,
			base64.StdEncoding.EncodeToString(data), len(data))), nil

	case "host.dialogs.file_picker":
		return h.picker, nil
	}
	return nil, &rpcError{Code: -32601, Message: "unexpected capability " + capability}
}

func replyBytes(t *testing.T, result map[string]interface{}) int {
	t.Helper()
	b, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal tool result: %v", err)
	}
	return len(b)
}

// TestPanelPDFTransferStaysUnderTheControlCap is the panel round-trip oracle: a
// PDF far larger than one IPC message reaches the panel intact, as a path plus
// slices that each fit the cap, and the inline-bytes result it replaces would
// not have fit.
func TestPanelPDFTransferStaysUnderTheControlCap(t *testing.T) {
	// A synthetic PDF body well over the cap, with position-dependent content so
	// a mis-ordered or duplicated chunk cannot reassemble by luck.
	pdf := make([]byte, 200_000)
	copy(pdf, []byte("%PDF-1.7\n"))
	for i := range pdf {
		pdf[i] = byte(i*7 + i/251)
	}
	host := &fileHost{pdf: pdf, pageCount: 3}

	// nextPreviewPath writes into the system temp dir; point that at the test's.
	t.Setenv("TMPDIR", t.TempDir())

	args := mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"deliver_to_file": true,
		"rows":            []map[string]interface{}{{"name": "Ada"}, {"name": "Grace Hopper"}},
	})

	res := toolNametagGenerate(host, args)
	if ok, _ := res["success"].(bool); !ok {
		t.Fatalf("generate failed: %+v", res)
	}
	if _, inline := res["bytes_b64"]; inline {
		t.Fatalf("deliver_to_file must not carry the bytes inline: %v", keys(res))
	}
	if size := replyBytes(t, res); size > controlCapBytes {
		t.Fatalf("generate reply is %d bytes, over the %d-byte cap", size, controlCapBytes)
	}

	path, _ := res["path"].(string)
	if path == "" {
		t.Fatalf("generate returned no path: %+v", res)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat generated pdf: %v", err)
	}
	if info.Size() <= controlCapBytes {
		t.Fatalf("fixture is not over the cap: %d bytes on disk", info.Size())
	}
	if got := res["byte_size"]; got != int(info.Size()) {
		t.Fatalf("byte_size %v does not match the %d bytes on disk", got, info.Size())
	}
	if res["page_count"] != 3 {
		t.Fatalf("page_count: want 3, got %v", res["page_count"])
	}

	// Pull it back the way the panel does: slices from offset 0 until eof.
	var got []byte
	for round := 0; ; round++ {
		if round > 64 {
			t.Fatalf("chunk loop did not reach eof after %d rounds (%d bytes)", round, len(got))
		}
		chunk := toolNametagReadChunk(host, mustArgs(t, map[string]interface{}{
			"path": path, "offset": len(got),
		}))
		if ok, _ := chunk["success"].(bool); !ok {
			t.Fatalf("read chunk at %d failed: %+v", len(got), chunk)
		}
		if size := replyBytes(t, chunk); size > controlCapBytes {
			t.Fatalf("chunk reply is %d bytes, over the %d-byte cap", size, controlCapBytes)
		}
		if chunk["total_bytes"] != int(info.Size()) {
			t.Fatalf("total_bytes %v does not match the %d bytes on disk", chunk["total_bytes"], info.Size())
		}
		data, err := base64.StdEncoding.DecodeString(chunk["bytes_b64"].(string))
		if err != nil {
			t.Fatalf("chunk base64: %v", err)
		}
		if len(data) != chunk["length"] {
			t.Fatalf("chunk reports length %v but carries %d bytes", chunk["length"], len(data))
		}
		got = append(got, data...)
		if eof, _ := chunk["eof"].(bool); eof {
			break
		}
		if len(data) == 0 {
			t.Fatalf("chunk carried no bytes and did not report eof at offset %d", len(got))
		}
	}
	if !bytes.Equal(got, pdf) {
		t.Fatalf("reassembled %d bytes, want the %d generated bytes (equal=%v)", len(got), len(pdf), bytes.Equal(got, pdf))
	}

	// A finished transfer leaves nothing behind, and the file stops being
	// readable with it.
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("preview still on disk after the eof slice: err=%v", err)
	}
	after := toolNametagReadChunk(host, mustArgs(t, map[string]interface{}{"path": path}))
	if ok, _ := after["success"].(bool); ok {
		t.Fatalf("a consumed preview must no longer be readable: %+v", after)
	}

	// An abandoned preview (no eof read) is removed by the next delivery.
	first := toolNametagGenerate(host, args)
	firstPath, _ := first["path"].(string)
	if firstPath == "" {
		t.Fatalf("second generate returned no path: %+v", first)
	}
	second := toolNametagGenerate(host, args)
	if _, err := os.Stat(firstPath); !os.IsNotExist(err) {
		t.Fatalf("previous preview survived the next delivery: err=%v", err)
	}
	if secondPath, _ := second["path"].(string); secondPath == firstPath {
		t.Fatalf("two deliveries reused one path: %s", secondPath)
	}

	// The falsifier: the inline-bytes result this replaces is far over the cap,
	// so the host would swap it for payload_too_large and the panel would show
	// no preview at all.
	inline := toolNametagGenerate(host, mustArgs(t, map[string]interface{}{
		"icon_png_base64": "Zm9v",
		"rows":            []map[string]interface{}{{"name": "Ada"}, {"name": "Grace Hopper"}},
	}))
	if size := replyBytes(t, inline); size <= controlCapBytes {
		t.Fatalf("inline reply is only %d bytes — the fixture no longer proves the cap is exceeded", size)
	}
}

// TestReadChunkRefusesWhatItDidNotWrite — the verb hands file bytes back to its
// caller, so it serves only this backend's own output, and a caller that walks
// off the end or names nothing gets a structured error rather than an empty
// slice that would read as a truncated PDF.
func TestReadChunkRefusesWhatItDidNotWrite(t *testing.T) {
	dir := t.TempDir()
	host := &fileHost{}

	// A file on disk that this backend did NOT write: readable by the host, but
	// not reachable through read_chunk.
	foreign := filepath.Join(dir, "secret.txt")
	if err := os.WriteFile(foreign, []byte("not ours"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	res := toolNametagReadChunk(host, mustArgs(t, map[string]interface{}{"path": foreign}))
	if ok, _ := res["success"].(bool); ok {
		t.Fatalf("a path this process never wrote must be refused: %+v", res)
	}
	if res["error_code"] != "target_not_allowlisted" {
		t.Fatalf("refusal code: want target_not_allowlisted, got %+v", res)
	}
	for _, c := range host.calls {
		if c == "host.files.read" {
			t.Fatalf("a refused path must never be read: %v", host.calls)
		}
	}

	// The same file becomes readable once the backend itself writes it.
	path := filepath.Join(dir, "own.pdf")
	if _, _, fault := writePDFFile(host, path, base64.StdEncoding.EncodeToString([]byte("%PDF-1.7\n"))); fault != nil {
		t.Fatalf("write own pdf: %+v", fault)
	}
	if ok, _ := toolNametagReadChunk(host, mustArgs(t, map[string]interface{}{"path": path}))["success"].(bool); !ok {
		t.Fatalf("this backend's own file must be readable")
	}
	// It was not a delivered preview, so reading it to eof must not delete it.
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("a saved (non-preview) PDF must survive being read: %v", err)
	}

	for name, args := range map[string]map[string]interface{}{
		"no path":        {"offset": 0},
		"past the end":   {"path": path, "offset": 1000},
		"negative":       {"path": path, "offset": -1},
		"empty path str": {"path": "   "},
	} {
		res := toolNametagReadChunk(host, mustArgs(t, args))
		if ok, _ := res["success"].(bool); ok {
			t.Fatalf("%s: expected a failure, got %+v", name, res)
		}
		if code, _ := res["error_code"].(string); code == "" {
			t.Fatalf("%s: failure carries no error_code: %+v", name, res)
		}
	}
}

// TestPickIconReturnsPathOrCancel — the panel's route to a large icon: a path
// crosses the bridge, never the PNG.
func TestPickIconReturnsPathOrCancel(t *testing.T) {
	host := &fileHost{picker: json.RawMessage(`{"success":true,"result":{"cancelled":false,"path":"/home/me/logo.png"}}`)}
	res := toolNametagPickIcon(host, nil)
	if ok, _ := res["success"].(bool); !ok || res["path"] != "/home/me/logo.png" {
		t.Fatalf("pick icon: %+v", res)
	}
	if cancelled, _ := res["cancelled"].(bool); cancelled {
		t.Fatalf("pick icon reported cancelled on a pick: %+v", res)
	}
	if len(host.calls) != 1 || host.calls[0] != "host.dialogs.file_picker" {
		t.Fatalf("expected one file_picker call, got %v", host.calls)
	}

	host = &fileHost{picker: json.RawMessage(`{"success":true,"result":{"cancelled":true}}`)}
	res = toolNametagPickIcon(host, nil)
	if cancelled, _ := res["cancelled"].(bool); !cancelled {
		t.Fatalf("cancel must be reported as cancelled, not a failure: %+v", res)
	}

	host = &fileHost{picker: json.RawMessage(`{"success":false,"error_code":"dialog_unavailable","error_message":"no UI"}`)}
	res = toolNametagPickIcon(host, nil)
	if ok, _ := res["success"].(bool); ok {
		t.Fatalf("a picker failure must surface as a failure: %+v", res)
	}
	if res["error_code"] != "dialog_unavailable" {
		t.Fatalf("error_code not surfaced: %+v", res)
	}
}
