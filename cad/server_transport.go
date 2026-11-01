package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/ipeerbhai/plugins/cad/internal/tools"
)

const (
	maxPayloadBytes    = 8 << 20
	maxFrameBytes      = 16 << 20
	maxRequestTasks    = 16
	maxRequestBytes    = 32 << 20
	maxCollectionTasks = 8
	maxCollectionBytes = 8 << 20
)

// readRequestFrame retains at most the frame cap plus one possible CR byte.
// Overlong input is drained using the fixed reader buffer, never decoded as
// a prefix. The next call always starts after the discarded frame's newline.
func readRequestFrame(ctx context.Context, r *bufio.Reader) ([]byte, bool, error) {
	var line []byte
	oversized := false
	for {
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		part, err := r.ReadSlice('\n')
		terminated := len(part) > 0 && part[len(part)-1] == '\n'
		if terminated {
			part = part[:len(part)-1]
		}
		if !oversized {
			needed := len(line) + len(part)
			if needed > maxFrameBytes+1 {
				line, oversized = nil, true
			} else {
				if needed > cap(line) {
					n := max(needed, min(maxFrameBytes+1, max(4096, 2*cap(line))))
					grown := make([]byte, len(line), n)
					copy(grown, line)
					line = grown
				}
				line = append(line, part...)
			}
		}
		if terminated || err != bufio.ErrBufferFull {
			line = bytes.TrimSuffix(line, []byte{'\r'})
			if len(line) > maxFrameBytes {
				line, oversized = nil, true
			}
			return line, oversized, err
		}
	}
}

func (s *server) serve(ctx context.Context, input io.Reader, enc *json.Encoder) error {
	r := bufio.NewReaderSize(input, 64<<10)
	for {
		line, oversized, err := readRequestFrame(ctx, r)
		if err != nil && !errors.Is(err, io.EOF) {
			return fmt.Errorf("read request: %w", err)
		}
		if oversized {
			send(enc, errResponse(json.RawMessage("null"), -32600, "Request frame exceeds 16 MiB transport limit"))
		} else if len(line) > 0 {
			var msg rpcRequest
			if parseErr := json.Unmarshal(line, &msg); parseErr != nil {
				send(enc, errResponse(json.RawMessage("null"), -32700, "Parse error"))
			} else if !s.dispatch(enc, &msg) {
				return nil
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
	}
}

func (s *server) admitRequest(size int, collection bool) bool {
	s.admissionMu.Lock()
	defer s.admissionMu.Unlock()
	if s.ctx.Err() != nil {
		return false
	}
	if collection {
		if s.collectionCount >= maxCollectionTasks || size > maxCollectionBytes-s.collectionBytes {
			return false
		}
		s.collectionCount++
		s.collectionBytes += size
	} else {
		if s.requestCount >= maxRequestTasks || size > maxRequestBytes-s.requestBytes {
			return false
		}
		s.requestCount++
		s.requestBytes += size
	}
	return true
}

func (s *server) releaseRequest(size int, collection bool) {
	s.admissionMu.Lock()
	defer s.admissionMu.Unlock()
	if collection {
		s.collectionCount--
		s.collectionBytes -= size
	} else {
		s.requestCount--
		s.requestBytes -= size
	}
}

// shutdown cancels the process lifetime first. CommandContext closes the child
// and its pipes even if startup or a frame write is blocked. The bridge still
// verifies actual process and I/O retirement after the request pump joins.
func (s *server) shutdown(ctx context.Context) error {
	s.cancel()
	requestsDone := make(chan struct{})
	go func() { s.tasks.Wait(); close(requestsDone) }()
	select {
	case <-requestsDone:
	case <-ctx.Done():
		return fmt.Errorf("join requests: %w", ctx.Err())
	}
	if err := tools.WaitExports(ctx); err != nil {
		return err
	}
	s.runnerMu.Lock()
	runner := s.runner
	s.runnerMu.Unlock()
	if runner != nil {
		select {
		case <-runner.done:
		case <-ctx.Done():
			return fmt.Errorf("join worker runner (bridge shutdown withheld): %w", ctx.Err())
		}
	}
	if s.worker != nil {
		if err := s.worker.ShutdownOwned(ctx); err != nil {
			return fmt.Errorf("finish worker retirement: %w", err)
		}
	}
	return nil
}

// Keep the shutdown deadline separate from the canceled worker lifetime.
const serverShutdownTimeout = 10 * time.Second
