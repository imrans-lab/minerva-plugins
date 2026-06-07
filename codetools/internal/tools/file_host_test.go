package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

type mockHost struct {
	lastCap  string
	lastArgs json.RawMessage
	payload  json.RawMessage
	err      error
}

func (m *mockHost) Call(capability string, args json.RawMessage) (json.RawMessage, error) {
	m.lastCap = capability
	m.lastArgs = args
	return m.payload, m.err
}

func envStatus(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var e struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(raw, &e); err != nil {
		t.Fatalf("envelope parse: %v (raw=%s)", err, string(raw))
	}
	return e.Status
}

func TestFileWriteProxiesDocWriteWithSave(t *testing.T) {
	m := &mockHost{payload: json.RawMessage(`{"success":true,"result":{"version":2,"saved":true}}`)}
	Host = m
	defer func() { Host = nil }()

	out, err := HandleFileWrite(context.Background(), nil, json.RawMessage(`{"path":"/tmp/x.gd","content":"hi"}`))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if m.lastCap != "mcp.proxy:minerva_doc_write" {
		t.Errorf("capability = %q, want mcp.proxy:minerva_doc_write", m.lastCap)
	}
	args := string(m.lastArgs)
	for _, want := range []string{`"path":"/tmp/x.gd"`, `"text":"hi"`, `"save":true`} {
		if !strings.Contains(args, want) {
			t.Errorf("doc args %s missing %s", args, want)
		}
	}
	if envStatus(t, out) != "ok" {
		t.Errorf("status = %s, want ok", envStatus(t, out))
	}
}

func TestFileEditProxiesDocEdit(t *testing.T) {
	m := &mockHost{payload: json.RawMessage(`{"success":true,"result":{}}`)}
	Host = m
	defer func() { Host = nil }()

	_, _ = HandleFileEdit(context.Background(), nil, json.RawMessage(
		`{"path":"/a.gd","old_string":"foo","new_string":"bar","replace_all":true}`))
	if m.lastCap != "mcp.proxy:minerva_doc_edit" {
		t.Errorf("capability = %q", m.lastCap)
	}
	args := string(m.lastArgs)
	for _, want := range []string{`"old_string":"foo"`, `"new_string":"bar"`, `"replace_all":true`, `"save":true`} {
		if !strings.Contains(args, want) {
			t.Errorf("doc args %s missing %s", args, want)
		}
	}
}

func TestFileReadProxiesDocReadNoSave(t *testing.T) {
	m := &mockHost{payload: json.RawMessage(`{"success":true,"result":{"text":"x"}}`)}
	Host = m
	defer func() { Host = nil }()

	_, _ = HandleFileRead(context.Background(), nil, json.RawMessage(`{"path":"/r.gd"}`))
	if m.lastCap != "mcp.proxy:minerva_doc_read" {
		t.Errorf("capability = %q", m.lastCap)
	}
	if strings.Contains(string(m.lastArgs), `"save"`) {
		t.Errorf("read must not inject save: %s", m.lastArgs)
	}
}

func TestFileWriteHostFailureReturnsErrorEnvelope(t *testing.T) {
	m := &mockHost{payload: json.RawMessage(`{"success":false,"error_message":"boom"}`)}
	Host = m
	defer func() { Host = nil }()

	out, _ := HandleFileWrite(context.Background(), nil, json.RawMessage(`{"path":"/x","content":"y"}`))
	if envStatus(t, out) != "error" {
		t.Errorf("status = %s, want error", envStatus(t, out))
	}
	if !strings.Contains(string(out), "boom") {
		t.Errorf("envelope should carry the host error: %s", out)
	}
}

func TestFileWriteMissingPath(t *testing.T) {
	Host = &mockHost{}
	defer func() { Host = nil }()
	out, _ := HandleFileWrite(context.Background(), nil, json.RawMessage(`{"content":"y"}`))
	if envStatus(t, out) != "error" {
		t.Errorf("missing path should be an error envelope")
	}
}

func TestFileWriteNoHostBridge(t *testing.T) {
	Host = nil
	out, _ := HandleFileWrite(context.Background(), nil, json.RawMessage(`{"path":"/x","content":"y"}`))
	if envStatus(t, out) != "error" || !strings.Contains(string(out), "host capability bridge unavailable") {
		t.Errorf("nil host should yield a clear error envelope: %s", out)
	}
}
