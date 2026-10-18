package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
)

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type queuedRequest struct {
	packet []byte
	id     json.RawMessage
}

// One reader preserves host requests that arrive during nested capability waits.
type rpcStream struct {
	scanner     *bufio.Scanner
	encoder     *json.Encoder
	sequence    int
	activeID    json.RawMessage
	queued      []queuedRequest
	queuedBytes int
	current     []byte
}

func (s *rpcStream) next(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}
	if len(s.queued) != 0 {
		s.current = s.queued[0].packet
		s.queuedBytes -= len(s.current)
		s.queued = s.queued[1:]
		return true
	}
	if !s.scan(ctx) {
		return false
	}
	s.current = s.scanner.Bytes()
	return true
}

func newStream(input io.Reader, output io.Writer) *rpcStream {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 16<<20)
	return &rpcStream{scanner: scanner, encoder: json.NewEncoder(output)}
}

func (s *rpcStream) scan(ctx context.Context) bool {
	return ctx.Err() == nil && s.scanner.Scan() && ctx.Err() == nil
}

func (s *rpcStream) readError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.scanner.Err()
}

func (s *rpcStream) write(ctx context.Context, message any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := s.encoder.Encode(message); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("write RPC: %w", err)
	}
	return nil
}

func (s *rpcStream) capability(ctx context.Context, capability string, args map[string]any) (map[string]any, error) {
	s.sequence++
	id := fmt.Sprintf("sheets-cap-%d", s.sequence)
	params := map[string]any{"capability": capability, "args": args}
	if len(s.activeID) != 0 && string(s.activeID) != "null" {
		params["parent_request_id"] = s.activeID
	}
	if err := s.write(ctx, map[string]any{"jsonrpc": "2.0", "id": id, "method": "minerva/capability",
		"params": params}); err != nil {
		return nil, err
	}
	for s.scan(ctx) {
		var response request
		if err := json.Unmarshal(s.scanner.Bytes(), &response); err != nil {
			return nil, fmt.Errorf("decode capability reply: %w", err)
		}
		if response.Method == "notifications/cancelled" {
			var cancellation struct {
				RequestID json.RawMessage `json:"requestId"`
			}
			if err := json.Unmarshal(response.Params, &cancellation); err != nil {
				return nil, fmt.Errorf("decode cancellation: %w", err)
			}
			if string(cancellation.RequestID) == string(s.activeID) {
				return nil, context.Canceled
			}
			for index, queued := range s.queued {
				if string(queued.id) == string(cancellation.RequestID) {
					if err := s.write(ctx, map[string]any{"jsonrpc": "2.0", "id": queued.id,
						"error": map[string]any{"code": -32800, "message": "Request cancelled before execution"}}); err != nil {
						return nil, err
					}
					s.queuedBytes -= len(queued.packet)
					s.queued = append(s.queued[:index], s.queued[index+1:]...)
					break
				}
			}
		}
		if response.Method != "" && len(response.ID) != 0 && string(response.ID) != "null" {
			if len(s.queued) >= 64 || s.queuedBytes+len(s.scanner.Bytes()) > 16<<20 {
				if err := s.write(ctx, map[string]any{"jsonrpc": "2.0", "id": response.ID,
					"error": map[string]any{"code": -32000, "message": "Sheets request queue is full; retry later"}}); err != nil {
					return nil, err
				}
			} else {
				packet := append([]byte(nil), s.scanner.Bytes()...)
				s.queued = append(s.queued, queuedRequest{packet: packet, id: response.ID})
				s.queuedBytes += len(packet)
			}
			continue
		}
		if string(response.ID) != fmt.Sprintf("%q", id) || response.Method != "" {
			log.Printf("ignoring unrelated RPC while awaiting capability %s", id)
			continue
		}
		if response.Error != nil {
			return nil, fmt.Errorf("host capability %s: %d %s", capability, response.Error.Code, response.Error.Message)
		}
		var envelope struct {
			Success bool           `json:"success"`
			Result  map[string]any `json:"result"`
		}
		if err := json.Unmarshal(response.Result, &envelope); err != nil {
			return nil, fmt.Errorf("decode capability result: %w", err)
		}
		if !envelope.Success {
			var failure map[string]any
			if err := json.Unmarshal(response.Result, &failure); err != nil {
				return nil, fmt.Errorf("decode capability refusal: %w", err)
			}
			return failure, nil
		}
		if envelope.Result == nil {
			return nil, fmt.Errorf("host capability %s returned no result", capability)
		}
		return envelope.Result, nil
	}
	if err := s.readError(ctx); err != nil {
		return nil, err
	}
	return nil, io.ErrUnexpectedEOF
}
