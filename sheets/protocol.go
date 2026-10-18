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

// One reader serves outer requests and their nested capability replies. The
// host serializes backend requests; correlation also tolerates notifications.
type rpcStream struct {
	scanner  *bufio.Scanner
	encoder  *json.Encoder
	sequence int
	activeID json.RawMessage
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
	if err := s.write(ctx, map[string]any{"jsonrpc": "2.0", "id": id, "method": "minerva/capability",
		"params": map[string]any{"capability": capability, "args": args}}); err != nil {
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
