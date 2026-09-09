// Command council-plugin is the Council plugin's MCP backend for Minerva.
//
// Transport: JSON-RPC 2.0 over stdin/stdout, one message per line, exactly as
// every other Minerva stdio plugin. stdout carries protocol traffic and nothing
// else; all logging goes to stderr, where the host captures it.
//
// The backend owns no durable state. It holds the working copy of one Council
// snapshot, applies protocol commands to it, and returns the acknowledged
// revision in every reply so the native wrapper can persist the result. A
// snapshot that never reached the wrapper is lost when this process ends, which
// is why a run left in flight is demoted on load rather than resumed.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"sync"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

const (
	// protocolVersion is the MCP revision this server answers with. The host
	// initialises with a newer revision string and accepts this one, the same
	// way the cad and pcb backends do.
	protocolVersion = "2024-11-05"
	serverName      = "council"

	// serverVersion must equal the version in manifest.json; a test pins it.
	serverVersion = "0.1.0"

	// maxLine bounds one protocol line. It is generous next to the engine's own
	// transport budget so an oversized request is refused by the protocol with
	// a readable error rather than truncated by the reader. A line above it is
	// discarded and answered; it never ends the loop.
	maxLine = 4 << 20

	// readBuffer is the reader's working size. A message larger than it is
	// assembled across reads, up to maxLine.
	readBuffer = 64 << 10
)

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 envelopes
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func okResponse(id json.RawMessage, result any) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Result: result}
}

func errResponse(id json.RawMessage, code int, message string) rpcResponse {
	return rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: message}}
}

// toolResult renders a handler's JSON as an MCP tool result. A handler failure
// travels as content with isError set rather than as a JSON-RPC error, so the
// caller reads the explanation the same way it reads a success.
func toolResult(id json.RawMessage, body []byte, isError bool) rpcResponse {
	result := map[string]any{
		"content": []map[string]any{{"type": "text", "text": string(body)}},
	}
	if isError {
		result["isError"] = true
	}
	return okResponse(id, result)
}

// ---------------------------------------------------------------------------
// MCP methods
// ---------------------------------------------------------------------------

func handleInitialize(id json.RawMessage) rpcResponse {
	return okResponse(id, map[string]any{
		"protocolVersion": protocolVersion,
		"capabilities":    map[string]any{"tools": map[string]any{}},
		"serverInfo":      map[string]any{"name": serverName, "version": serverVersion},
	})
}

func handleToolsList(id json.RawMessage, reg *registry) rpcResponse {
	specs := reg.specs()
	listed := make([]map[string]any, 0, len(specs))
	for _, spec := range specs {
		listed = append(listed, map[string]any{
			"name":        spec.Name,
			"description": spec.Description,
			"inputSchema": spec.InputSchema,
		})
	}
	return okResponse(id, map[string]any{"tools": listed})
}

func handleToolsCall(id json.RawMessage, reg *registry, params json.RawMessage) rpcResponse {
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &call); err != nil {
		return errResponse(id, -32602, fmt.Sprintf("tools/call: parse params: %v", err))
	}
	handler, found := reg.lookup(call.Name)
	if !found {
		return errResponse(id, -32601, "method not found: "+call.Name)
	}
	body, err := handler(call.Arguments)
	if err != nil {
		failure, _ := json.Marshal(map[string]any{"ok": false, "error": err.Error()})
		return toolResult(id, failure, true)
	}
	return toolResult(id, body, false)
}

// ---------------------------------------------------------------------------
// serve
// ---------------------------------------------------------------------------

// stdoutWriter is the one door onto stdout. Every response and every outbound
// capability request goes through it, because the protocol loop now answers
// several requests at once and two encoders interleaving on one stream would
// produce lines that are not messages.
type stdoutWriter struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func (w *stdoutWriter) write(message any) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.enc.Encode(message)
}

// responseRouter is handed every JSON-RPC RESPONSE the reader sees. Council's
// chat adapter implements it: the reader classifies by shape and delivers a
// response to whichever exchange is waiting on its id, so nothing is ever
// swallowed by a handler that happened to be reading.
type responseRouter interface {
	// deliver reports whether an exchange claimed this response. An unclaimed
	// one is logged and dropped: it belongs to a call that already gave up, and
	// there is nothing it can now be mistaken for.
	deliver(id string, line []byte) bool
	// closed is called once when the host's stream ends, so an exchange still
	// waiting is failed rather than left forever.
	closed()
}

// serve runs the protocol loop until the input ends or a shutdown arrives. It
// takes its streams as parameters so a test can drive the real loop over pipes
// instead of asserting against a re-implementation of it.
//
// The host may have any number of requests in flight at once, and Council needs
// that: a deliberation round is a long tools/call, and reads, run.await and
// run.cancel have to be answered while it runs. So each tools/call handler gets
// its own goroutine, and writes are serialised by the one stdout door above.
//
// Exactly one goroutine reads stdin for the life of the process. It routes by
// shape: requests to this loop, responses to the chat adapter's pending
// exchanges. Two readers on one *bufio.Reader would each swallow bytes the
// other was waiting for, and a handler that read stdin directly would swallow
// the very requests it is meant to leave room for.
func serve(in io.Reader, out io.Writer, reg *registry, chat *stdioChatHost, provider *chatProvider) error {
	writer := &stdoutWriter{enc: json.NewEncoder(out)}
	// done releases the reader goroutine when this loop returns. Without it a
	// shutdown leaves the reader blocked forever on a send nobody will take,
	// which leaks one goroutine per serve — harmless in the real backend, which
	// exits, and a real leak in any test that runs the loop more than once.
	done := make(chan struct{})
	defer close(done)

	var router responseRouter
	if chat != nil {
		chat.bind(writer)
		router = chat
	}
	// announced guards the one-shot startup handshake below. The host can send
	// initialize more than once over a connection's life, and registering twice
	// would be harmless but the model catalogue would be re-read for nothing.
	announced := false
	requests := readStdin(bufio.NewReaderSize(in, readBuffer), done, router)

	send := func(response rpcResponse) {
		if err := writer.write(response); err != nil {
			log.Printf("write response: %v", err)
		}
	}

	for {
		inbound, open := <-requests
		if !open {
			return nil
		}
		if err := inbound.err; err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		line, tooLong := inbound.data, inbound.tooLong
		if tooLong {
			// The message is gone, so there is no id to answer against. Say so
			// and keep serving: an oversized request must not take the backend
			// down with it.
			log.Printf("discarded a request above the %d byte line limit", maxLine)
			send(errResponse(json.RawMessage("null"), -32600,
				fmt.Sprintf("request exceeds the %d byte line limit and was discarded", maxLine)))
			continue
		}
		if len(line) == 0 {
			continue
		}
		var msg rpcRequest
		if err := json.Unmarshal(line, &msg); err != nil {
			send(errResponse(json.RawMessage("null"), -32700, "Parse error"))
			continue
		}

		// A notification carries no id and takes no reply.
		isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"

		switch msg.Method {
		case "initialize":
			if !isNotification {
				send(handleInitialize(msg.ID))
			}
			// Council introduces itself to the host only once the host has
			// introduced itself here: registering a chat provider means asking
			// the host a question, and the answer arrives on the very stream
			// this handshake just established. It runs on its own goroutine so
			// the reply above is not held behind two host round trips.
			if provider != nil && !announced {
				announced = true
				go provider.announce()
			}
		case "notifications/initialized":
			// No-op: the host sends it after our initialize result.
		case "tools/list":
			if !isNotification {
				send(handleToolsList(msg.ID, reg))
			}
		case "tools/call":
			if isNotification {
				break
			}
			// On its own goroutine: a Council round is a tools/call that can
			// last minutes, and the reads, waits and cancels that make it
			// bearable are tools/calls too. Answering them in order would mean
			// answering none of them until the round finished.
			go func(id json.RawMessage, params json.RawMessage) {
				send(handleToolsCall(id, reg, params))
			}(msg.ID, msg.Params)
		case "shutdown":
			if !isNotification {
				send(okResponse(msg.ID, map[string]any{"ok": true}))
			}
			// Withdraw before returning, and while the stream is still up: once
			// this function returns the reader stops and no reply could reach
			// the exchange. The wait is short, so a host that has already
			// stopped listening costs the exit a moment and no more.
			if provider != nil {
				provider.withdraw()
			}
			log.Printf("shutdown requested — exiting")
			return nil
		default:
			if !isNotification {
				send(errResponse(msg.ID, -32601, "Method not found: "+msg.Method))
			}
		}
	}
}

// stdinLine is one message off the process's single stdin reader. Exactly one
// of err being set, or data/tooLong describing a line, is meaningful.
type stdinLine struct {
	data    []byte
	tooLong bool
	err     error
}

// readStdin starts the process's ONE stdin reader and returns the channel the
// protocol loop takes its REQUESTS from.
//
// Classification is by shape, which is all JSON-RPC gives: a message carrying a
// method is a request, and one carrying an id and no method is a response to
// something this process asked. Responses go to the router, so a capability
// reply reaches the exchange waiting for it however many other requests the
// host has in flight, and a request is never consumed by a handler.
//
// The requests channel is unbuffered and every send watches done, because a
// shutdown arrives while the reader is holding the next line and the goroutine
// must not wait on a receiver that has already gone home.
func readStdin(reader *bufio.Reader, done <-chan struct{}, replies responseRouter) <-chan stdinLine {
	requests := make(chan stdinLine)
	go func() {
		defer close(requests)
		if replies != nil {
			defer replies.closed()
		}
		for {
			data, tooLong, err := readLine(reader)
			next := stdinLine{data: data, tooLong: tooLong}
			if err != nil {
				next = stdinLine{err: err}
			}
			if err == nil && !tooLong && len(data) > 0 && replies != nil {
				var probe struct {
					Method string          `json:"method"`
					ID     json.RawMessage `json:"id"`
				}
				if json.Unmarshal(data, &probe) == nil && probe.Method == "" && len(probe.ID) > 0 && string(probe.ID) != "null" {
					if !replies.deliver(idKey(probe.ID), data) {
						log.Printf("dropped an unclaimed response on stdin (id=%s)", string(probe.ID))
					}
					continue
				}
			}
			select {
			case requests <- next:
			case <-done:
				return
			}
			if err != nil {
				return
			}
		}
	}()
	return requests
}

// idKey renders a JSON-RPC id as the string the pending map is keyed by. Godot
// serialises every number as a float, so an id sent as 1 can come back as 1.0;
// normalising through the numeric form here means a match does not depend on
// how the host chose to write it.
func idKey(raw json.RawMessage) string {
	var asString string
	if err := json.Unmarshal(raw, &asString); err == nil {
		return asString
	}
	var asNumber float64
	if err := json.Unmarshal(raw, &asNumber); err == nil {
		return strconv.FormatInt(int64(asNumber), 10)
	}
	return string(raw)
}

// readLine reads one newline-terminated message. A line longer than maxLine is
// consumed to its end and discarded, and tooLong is reported instead, so the
// caller can answer the fault and carry on reading the stream in step.
func readLine(reader *bufio.Reader) (line []byte, tooLong bool, err error) {
	var buf []byte
	for {
		chunk, isPrefix, err := reader.ReadLine()
		if err != nil {
			return nil, false, err
		}
		if !tooLong && len(buf)+len(chunk) > maxLine {
			tooLong = true
			buf = nil
		}
		if !tooLong {
			buf = append(buf, chunk...)
		}
		if !isPrefix {
			return buf, tooLong, nil
		}
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[council-plugin] ")
	log.SetOutput(os.Stderr)

	store, err := session.New()
	if err != nil {
		// The schemas are embedded, so this can only fail on a build whose
		// contract package is broken. Say so and stop rather than serve a
		// backend that cannot validate anything.
		log.Fatalf("cannot load the Council schemas: %v", err)
	}
	reg := newRegistry(store)

	// The engine consults models through the host, and the host is reachable
	// only over this process's own stdio pair, so the adapter is created here
	// and bound by the protocol loop below.
	chat := &stdioChatHost{}
	store.SetChatHost(chat)
	store.SetModelCatalog(&hostModelCatalog{host: chat})
	provider := &chatProvider{host: chat, store: store}

	log.Printf("starting (pid=%d, version=%s)", os.Getpid(), serverVersion)
	if err := serve(os.Stdin, os.Stdout, reg, chat, provider); err != nil {
		log.Printf("stdin read error: %v", err)
		os.Exit(1)
	}
}
