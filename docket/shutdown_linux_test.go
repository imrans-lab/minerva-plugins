//go:build linux

package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if state := os.Getenv("DOCKET_SHUTDOWN_HELPER"); state != "" {
		if len(os.Args) > 1 && os.Args[1] == "--quiet" {
			if os.Getenv("DOCKET_BUSY_HELPER") == "1" {
				time.Sleep(2 * time.Second) // Healthy child busy beyond the old watchdog.
				_, _ = io.Copy(os.Stdout, os.Stdin)
				os.Exit(0)
			}
			if _, err := os.Stdout.Write(bytes.Repeat([]byte("x"), 4<<20)); err != nil {
				_, _ = io.Copy(io.Discard, os.Stdin)
				_ = os.WriteFile(filepath.Join(filepath.Dir(state), "child-eof"), nil, 0600)
				os.Exit(0)
			}
			for {
				time.Sleep(time.Second)
			} // Deliberately ignores EOF and input.
		}
		if launch(os.Args[0], state) != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestShutdownWithBlockedHostOutput(t *testing.T) {
	for _, backpressure := range []bool{false, true} {
		t.Run(strconv.FormatBool(backpressure), func(t *testing.T) {
			root := t.TempDir()
			cmd := exec.Command(os.Args[0])
			cmd.Env = append(os.Environ(), "DOCKET_SHUTDOWN_HELPER="+filepath.Join(root, "state"))
			input, err := cmd.StdinPipe()
			if err != nil {
				t.Fatal(err)
			}
			output, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err = cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer cmd.Process.Kill()
			defer output.Close()
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			// Read one byte, then leave a multi-megabyte flood on an unread pipe.
			ready := make(chan error, 1)
			go func() { _, err := io.ReadFull(output, make([]byte, 1)); ready <- err }()
			select {
			case err := <-ready:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("child not ready")
			}
			pidBytes, err := os.ReadFile(filepath.Join(root, "child.pid"))
			pid, parseErr := strconv.Atoi(string(pidBytes))
			if err != nil || parseErr != nil {
				t.Fatalf("child PID: %v %v", err, parseErr)
			}
			defer syscall.Kill(pid, syscall.SIGKILL)
			if backpressure {
				go input.Write(bytes.Repeat([]byte("i"), 4<<20))
			}
			time.Sleep(200 * time.Millisecond)
			_ = input.Close()
			stopBound := 9 * time.Second
			if backpressure {
				stopBound = 12 * time.Second
				// Match GS: EOF hidden by a blocked write falls back to host kill.
				time.AfterFunc(10*time.Second, func() { _ = cmd.Process.Kill() })
			}
			select {
			case <-done: // Forced shutdown may report an error; it must still reap.
			case <-time.After(stopBound):
				t.Fatal("launcher blocked beyond host stop fallback")
			}
			if backpressure {
				// The child must not outlive the launcher: it either sees EOF (marker) or
				// dies on its broken stdout pipe (a Go child gets SIGPIPE writing fd 1).
				deadline := time.Now().Add(3 * time.Second)
				for {
					if _, err := os.Stat(filepath.Join(root, "child-eof")); err == nil {
						break
					}
					if syscall.Kill(pid, 0) == syscall.ESRCH {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("child outlived the killed launcher")
					}
					time.Sleep(10 * time.Millisecond)
				}
				return // Forced launcher death cannot run its PID-file cleanup defer.
			}
			if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
				t.Fatalf("child not reaped: %v", err)
			}
			if _, err := os.Stat(filepath.Join(root, "child.pid")); !os.IsNotExist(err) {
				t.Fatal("stale child PID")
			}
		})
	}
}

func TestBusyChildInput(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 9*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0])
	cmd.Env = append(os.Environ(), "DOCKET_SHUTDOWN_HELPER="+filepath.Join(t.TempDir(), "state"), "DOCKET_BUSY_HELPER=1")
	payload := bytes.Repeat([]byte("healthy busy input\n"), 1<<18)
	cmd.Stdin = bytes.NewReader(payload)
	var output bytes.Buffer
	cmd.Stdout = &output
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(output.Bytes(), payload) {
		t.Fatal("large request lost while child busy")
	}
}
