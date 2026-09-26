// Command orchview-plugin is the Orchestration View plugin's backend for
// Minerva: JSON-RPC 2.0 over stdin/stdout, one message per line. stdout
// carries protocol traffic only; logging goes to stderr, which the host keeps
// as the worker log.
//
// The backend reads W1 work records from Docket and harness-session evidence
// from Minerva through host capabilities (minerva/capability requests on the
// same stdio pair) and answers the panel's tree channel from the read model in
// internal/readmodel. It never writes anything.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"sync"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "orchview"
	// serverVersion equals the version in manifest.json.
	serverVersion = "0.1.0"
	// maxLine bounds one inbound line; Docket replies for large projects
	// arrive as single lines.
	maxLine = 32 << 20
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// inbound is any line the host writes: a request or notification (Method
// set) or the reply to one of this backend's capability calls.
type inbound struct {
	rpcRequest
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

// server owns the one stdout writer and the capability calls in flight.
// Tool calls run on their own goroutines so the stdin reader stays free to
// deliver the capability replies those calls wait for.
type server struct {
	outMu sync.Mutex
	enc   *json.Encoder

	capMu   sync.Mutex
	capSeq  int
	pending map[string]chan inbound
	closed  bool

	panel *panelService
}

func (s *server) send(message any) {
	s.outMu.Lock()
	defer s.outMu.Unlock()
	if err := s.enc.Encode(message); err != nil {
		log.Printf("write: %v", err)
	}
}

func (s *server) reply(id json.RawMessage, result any) {
	s.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (s *server) fail(id json.RawMessage, code int, message string) {
	s.send(map[string]any{"jsonrpc": "2.0", "id": id, "error": rpcError{Code: code, Message: message}})
}

// callCapability sends one minerva/capability request and waits for its
// reply or ctx's end. It returns the broker's envelope unopened.
func (s *server) callCapability(ctx context.Context, capability string, args map[string]any) (json.RawMessage, error) {
	s.capMu.Lock()
	if s.closed {
		s.capMu.Unlock()
		return nil, fmt.Errorf("%s: the host connection has ended", capability)
	}
	s.capSeq++
	id := fmt.Sprintf(`"cap-%d"`, s.capSeq)
	waiter := make(chan inbound, 1)
	s.pending[id] = waiter
	s.capMu.Unlock()
	defer func() {
		s.capMu.Lock()
		delete(s.pending, id)
		s.capMu.Unlock()
	}()

	s.send(map[string]any{
		"jsonrpc": "2.0", "id": json.RawMessage(id), "method": "minerva/capability",
		"params": map[string]any{"capability": capability, "args": args},
	})
	select {
	case msg, open := <-waiter:
		if !open {
			return nil, fmt.Errorf("%s: the host connection ended before it answered", capability)
		}
		if msg.Error != nil {
			return nil, fmt.Errorf("%s: %s", capability, msg.Error.Message)
		}
		return msg.Result, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("%s: %w", capability, ctx.Err())
	}
}

func (s *server) deliver(msg inbound) {
	s.capMu.Lock()
	waiter, ok := s.pending[string(msg.ID)]
	s.capMu.Unlock()
	if !ok {
		log.Printf("dropped a reply for %s: nothing is waiting on it", msg.ID)
		return
	}
	waiter <- msg
}

func (s *server) closeCapabilities() {
	s.capMu.Lock()
	defer s.capMu.Unlock()
	s.closed = true
	for id, waiter := range s.pending {
		close(waiter)
		delete(s.pending, id)
	}
}

func (s *server) serve(in io.Reader) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 1<<20), maxLine)
	defer s.closeCapabilities()
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var msg inbound
		if err := json.Unmarshal(line, &msg); err != nil {
			s.fail(json.RawMessage("null"), -32700, "Parse error")
			continue
		}
		if msg.Method == "" {
			s.deliver(msg)
			continue
		}
		if s.dispatch(msg.rpcRequest) {
			return nil
		}
	}
	return scanner.Err()
}

// dispatch answers one request; it reports true on shutdown.
func (s *server) dispatch(msg rpcRequest) bool {
	notification := len(msg.ID) == 0 || string(msg.ID) == "null"
	switch msg.Method {
	case "initialize":
		s.reply(msg.ID, map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": serverName, "version": serverVersion},
		})
	case "tools/list":
		s.reply(msg.ID, map[string]any{"tools": []any{panelTreeSpec()}})
	case "tools/call":
		go s.toolsCall(msg)
	case "ping":
		s.reply(msg.ID, map[string]any{})
	case "shutdown":
		s.reply(msg.ID, map[string]any{})
		return true
	default:
		if !notification {
			s.fail(msg.ID, -32601, "Method not found: "+msg.Method)
		}
	}
	return false
}

func (s *server) toolsCall(msg rpcRequest) {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(msg.Params, &call); err != nil {
		s.fail(msg.ID, -32602, "tools/call: "+err.Error())
		return
	}
	if call.Name != panelTreeTool {
		s.fail(msg.ID, -32601, "unknown tool: "+call.Name)
		return
	}
	body, err := s.panel.tree(context.Background(), call.Arguments)
	isError := err != nil
	if isError {
		body, _ = json.Marshal(map[string]any{"ok": false, "error": err.Error()})
	}
	result := map[string]any{"content": []map[string]any{{"type": "text", "text": string(body)}}}
	if isError {
		result["isError"] = true
	}
	s.reply(msg.ID, result)
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[orchview-plugin] ")
	log.SetOutput(os.Stderr)
	s := &server{enc: json.NewEncoder(os.Stdout), pending: map[string]chan inbound{}}
	s.panel = newPanelService(&hostClient{call: s.callCapability})
	log.Printf("starting (pid=%d)", os.Getpid())
	if err := s.serve(os.Stdin); err != nil {
		log.Printf("stdin: %v", err)
		os.Exit(1)
	}
	log.Printf("stdin closed; exiting")
}
