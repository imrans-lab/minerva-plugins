package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func newHostClient(respLines string) (*hostClient, *bytes.Buffer) {
	var out bytes.Buffer
	return &hostClient{
		enc:     json.NewEncoder(&out),
		scanner: bufio.NewScanner(strings.NewReader(respLines)),
	}, &out
}

func TestHostClientCallRoundTrip(t *testing.T) {
	hc, out := newHostClient(`{"jsonrpc":"2.0","id":1,"result":{"success":true,"result":{"ok":1}}}` + "\n")
	res, err := hc.Call("mcp.proxy:minerva_doc_read", json.RawMessage(`{"path":"/x"}`))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !strings.Contains(string(res), `"success":true`) {
		t.Errorf("result payload = %s", res)
	}
	req := out.String()
	for _, want := range []string{
		`"method":"minerva/capability"`,
		`"capability":"mcp.proxy:minerva_doc_read"`,
		`"id":1`,
		`"path":"/x"`,
	} {
		if !strings.Contains(req, want) {
			t.Errorf("emitted request %s missing %s", req, want)
		}
	}
}

func TestHostClientErrorResponse(t *testing.T) {
	hc, _ := newHostClient(`{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"denied"}}` + "\n")
	if _, err := hc.Call("mcp.proxy:x", json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "denied") {
		t.Errorf("want denied error, got %v", err)
	}
}

func TestHostClientIDMismatch(t *testing.T) {
	hc, _ := newHostClient(`{"jsonrpc":"2.0","id":99,"result":{}}` + "\n")
	if _, err := hc.Call("x", json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "id mismatch") {
		t.Errorf("want id mismatch, got %v", err)
	}
}

func TestHostClientUnexpectedMethodGuard(t *testing.T) {
	hc, _ := newHostClient(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{}}` + "\n")
	if _, err := hc.Call("x", json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "unexpected inbound method") {
		t.Errorf("want re-entrancy guard, got %v", err)
	}
}

func TestHostClientStdinClosed(t *testing.T) {
	hc, _ := newHostClient("")
	if _, err := hc.Call("x", json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "stdin closed") {
		t.Errorf("want stdin-closed error, got %v", err)
	}
}
