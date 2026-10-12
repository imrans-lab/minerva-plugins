//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// The executable fixture takes the same --quiet argv as the real exported GUI.
func TestMain(m *testing.M) {
	if profile := os.Getenv("DOCKET_LAUNCH_FIXTURE"); profile != "" {
		if len(os.Args) == 2 && os.Args[1] == "--quiet" {
			if err := os.MkdirAll(profile, 0700); err != nil {
				panic(err)
			}
			if err := os.WriteFile(filepath.Join(profile, "fixture.pid"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
				panic(err)
			}
			if os.Getenv("DOCKET_FIXTURE_TIMEOUT") == "1" {
				for {
					time.Sleep(time.Second)
				}
			}
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				panic(err)
			}
			record := map[string]any{"pid": os.Getpid(), "endpoint": map[string]any{"host": "127.0.0.1", "port": listener.Addr().(*net.TCPAddr).Port}, "version": "fixture-live-version"}
			data, err := json.Marshal(record)
			if err != nil {
				panic(err)
			}
			if err := os.WriteFile(filepath.Join(profile, "instance.json"), data, 0600); err != nil {
				panic(err)
			}
			if err := http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })); err != nil {
				panic(err)
			}
		}
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fixtureLauncher(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	t.Setenv("XDG_DATA_HOME", root)
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", filepath.Join(root, "plugins"))
	profile, err := standaloneProfile()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("DOCKET_LAUNCH_FIXTURE", profile)
	r, err := pins()
	if err != nil {
		t.Fatal(err)
	}
	install, err := pluginRoot()
	if err != nil {
		t.Fatal(err)
	}
	target := runtime.GOOS + "-" + runtime.GOARCH
	dest := filepath.Join(install, r.Tag+"-"+target)
	entry := filepath.Join(dest, r.Platforms[target].Entrypoint)
	if err := os.MkdirAll(filepath.Dir(entry), 0700); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entry, data, 0700); err != nil {
		t.Fatal(err)
	}
	receipt, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "acquisition.lock.json"), receipt, 0600); err != nil {
		t.Fatal(err)
	}
	return profile, dest
}

func runLauncher(t *testing.T) (launchStatus, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0])
	output, err := cmd.Output()
	code := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Fatal(err)
		}
		code = exit.ExitCode()
	}
	var status launchStatus
	if err := json.Unmarshal(output, &status); err != nil {
		t.Fatalf("one JSON status line: %q: %v", output, err)
	}
	return status, code
}

func TestLauncherDetachedLifecycle(t *testing.T) {
	profile, _ := fixtureLauncher(t)
	status, code := runLauncher(t)
	if code != 0 || status.Status != "spawned" || status.Version != "fixture-live-version" {
		t.Fatalf("spawn: %+v exit %d", status, code)
	}
	t.Cleanup(func() {
		if err := syscall.Kill(status.PID, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
			t.Error(err)
		}
	})
	if !processAlive(status.PID) {
		t.Fatal("child died with launcher")
	}
	sid, _, errno := syscall.Syscall(syscall.SYS_GETSID, uintptr(status.PID), 0, 0)
	if errno != 0 || int(sid) != status.PID {
		t.Fatalf("child not session leader: %d %v", sid, errno)
	}
	// Attachment must succeed even when creating the plugin installation root
	// would fail: the running instance owns the version, not the pinned payload.
	blocked := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocked, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", blocked)
	again, code := runLauncher(t)
	if code != 0 || again.Status != "attached" || again.PID != status.PID || again.Version != "fixture-live-version" {
		t.Fatalf("reattach: %+v exit %d", again, code)
	}
	data, err := os.ReadFile(filepath.Join(profile, "fixture.pid"))
	if err != nil || string(data) != strconv.Itoa(status.PID) {
		t.Fatalf("spawned another child: %s %v", data, err)
	}
}

func TestLauncherTimeout(t *testing.T) {
	profile, _ := fixtureLauncher(t)
	t.Setenv("DOCKET_FIXTURE_TIMEOUT", "1")
	// A separate process is never a target for the launcher's timeout cleanup.
	other := exec.Command("sleep", "45")
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	otherDone := make(chan struct{})
	var otherWaitErr error
	go func() {
		otherWaitErr = other.Wait()
		close(otherDone)
	}()
	defer func() {
		select {
		case <-otherDone:
			return // The survival assertion reports an unexpected early exit.
		default:
		}
		if err := other.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
			t.Error(err)
		}
		<-otherDone
		var exit *exec.ExitError
		if otherWaitErr != nil && !errors.As(otherWaitErr, &exit) {
			t.Error(otherWaitErr)
		}
	}()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	// A stale endpoint can name a live, unrelated process. Cleanup must target
	// the child we spawned, never the PID read from the registration.
	record, err := json.Marshal(map[string]any{"pid": other.Process.Pid, "endpoint": map[string]any{"host": "127.0.0.1", "port": port}, "version": "unrelated"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(profile, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profile, "instance.json"), record, 0600); err != nil {
		t.Fatal(err)
	}
	status, code := runLauncher(t)
	if code != 2 || status.Status != "failed" || status.Reason == "" {
		t.Fatalf("timeout: %+v exit %d", status, code)
	}
	data, err := os.ReadFile(filepath.Join(profile, "fixture.pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(data))
	if err != nil {
		t.Fatal(err)
	}
	if processAlive(pid) {
		t.Fatalf("owned child %d remains after timeout", pid)
	}
	// Wait reaps promptly: kill(pid, 0) alone also accepts a killed zombie.
	select {
	case <-otherDone:
		t.Fatalf("unrelated registered process exited: %v", otherWaitErr)
	case <-time.After(100 * time.Millisecond):
	}
	fmt.Println("timeout killed only the spawned PID")
}
