//go:build linux

package main

import (
	"bytes"
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
			_, _ = os.Stdout.Write(bytes.Repeat([]byte("x"), 4<<20))
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
			select {
			case <-done: // Forced shutdown may report an error; it must still reap.
			case <-time.After(9 * time.Second):
				t.Fatal("launcher blocked beyond shutdown bound")
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
