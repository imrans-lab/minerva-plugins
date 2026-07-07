package runtime

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// --- resolvePythonOnPath: candidate-selection logic (acceptance criteria 1-5) ---
//
// These are pure unit tests against injected lookPath/probe funcs, per the
// docket's guidance: no real store shim or real interpreter is required to
// exercise shim-rejection, fallback, or hang-avoidance behavior.

func TestResolvePythonOnPath(t *testing.T) {
	okProbe := func(string) error { return nil }
	failProbe := func(p string) error { return fmt.Errorf("probe of %s failed", p) }

	tests := []struct {
		name     string
		lookPath func(string) (string, error)
		probe    func(string) error
		wantPath string
		wantErr  bool
		errMust  []string // substrings that must appear in the error
	}{
		{
			// Criterion 1: python3 preferred when it's a real interpreter.
			name: "python3 preferred when it works",
			lookPath: func(name string) (string, error) {
				switch name {
				case "python3":
					return `C:\Python312\python3.exe`, nil
				case "python":
					return `C:\Python312\python.exe`, nil
				}
				return "", exec.ErrNotFound
			},
			probe:    okProbe,
			wantPath: `C:\Python312\python3.exe`,
		},
		{
			// POSIX-shaped case: only python3 exists on PATH (bare python
			// absent), still resolves — unchanged Linux/macOS behavior.
			name: "posix: only python3 on PATH",
			lookPath: func(name string) (string, error) {
				if name == "python3" {
					return "/usr/bin/python3", nil
				}
				return "", exec.ErrNotFound
			},
			probe:    okProbe,
			wantPath: "/usr/bin/python3",
		},
		{
			// Criterion 2: python3 absent entirely -> falls back to python.
			name: "python3 absent falls back to python",
			lookPath: func(name string) (string, error) {
				if name == "python" {
					return `C:\Python312\python.exe`, nil
				}
				return "", exec.ErrNotFound
			},
			probe:    okProbe,
			wantPath: `C:\Python312\python.exe`,
		},
		{
			// Criterion 2/3: python3 resolves but it's the Windows Store
			// shim -> rejected, falls back to real python.
			name: "python3 is store shim falls back to python",
			lookPath: func(name string) (string, error) {
				switch name {
				case "python3":
					return `C:\Users\dev\AppData\Local\Microsoft\WindowsApps\python3.exe`, nil
				case "python":
					return `C:\Python312\python.exe`, nil
				}
				return "", exec.ErrNotFound
			},
			probe:    okProbe,
			wantPath: `C:\Python312\python.exe`,
		},
		{
			// Criterion 3: store shim path must never be returned, even
			// case-varied and even with forward slashes.
			name: "store shim rejected regardless of case or slash style",
			lookPath: func(name string) (string, error) {
				switch name {
				case "python3":
					return `c:/users/dev/appdata/local/microsoft/WINDOWSAPPS/python3.exe`, nil
				case "python":
					return "", exec.ErrNotFound
				}
				return "", exec.ErrNotFound
			},
			probe:   okProbe,
			wantErr: true,
			errMust: []string{"python3", "python", "rejected"},
		},
		{
			// Criterion 4: a resolved-but-non-functional python3 must not be
			// returned; python (which works) should be tried next.
			name: "python3 resolves but fails probe falls back to python",
			lookPath: func(name string) (string, error) {
				switch name {
				case "python3":
					return `C:\stale\python3.exe`, nil
				case "python":
					return `C:\Python312\python.exe`, nil
				}
				return "", exec.ErrNotFound
			},
			probe: func(p string) error {
				if p == `C:\stale\python3.exe` {
					return errors.New("simulated hang/timeout")
				}
				return nil
			},
			wantPath: `C:\Python312\python.exe`,
		},
		{
			// Criterion 5: nothing resolves -> clear, wrapped error
			// mentioning both candidates were tried.
			name: "neither candidate present yields clear error",
			lookPath: func(name string) (string, error) {
				return "", exec.ErrNotFound
			},
			probe:   okProbe,
			wantErr: true,
			errMust: []string{"python3", "python", "not found on PATH"},
		},
		{
			// Criterion 5 (variant): both resolve but both fail their
			// probe -> clear error, no candidate returned.
			name: "both resolve but both fail probe yields clear error",
			lookPath: func(name string) (string, error) {
				return `C:\bad\` + name + `.exe`, nil
			},
			probe:   failProbe,
			wantErr: true,
			errMust: []string{"python3", "python", "failed to run"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolvePythonOnPath(tc.lookPath, tc.probe)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got path %q", got)
				}
				for _, sub := range tc.errMust {
					if !strings.Contains(err.Error(), sub) {
						t.Errorf("error %q missing expected substring %q", err.Error(), sub)
					}
				}
				if got != "" {
					t.Errorf("expected empty path alongside error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.wantPath {
				t.Errorf("got path %q, want %q", got, tc.wantPath)
			}
		})
	}
}

// --- isWindowsStoreShim ---

func TestIsWindowsStoreShim(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{`C:\Users\dev\AppData\Local\Microsoft\WindowsApps\python3.exe`, true},
		{`c:\users\dev\appdata\local\microsoft\windowsapps\python.exe`, true},
		{`C:/Users/dev/AppData/Local/Microsoft/WindowsApps/python3.exe`, true},
		{`C:\Python312\python3.exe`, false},
		{`/usr/bin/python3`, false},
		{`/home/dev/.venv/bin/python`, false},
		{"", false},
	}
	for _, tc := range tests {
		if got := isWindowsStoreShim(tc.path); got != tc.want {
			t.Errorf("isWindowsStoreShim(%q) = %v, want %v", tc.path, got, tc.want)
		}
	}
}

// --- probePython: exercises the real exec.CommandContext + timeout wiring ---
//
// These use real subprocesses (no store shim required) to confirm the probe
// itself distinguishes a working interpreter from one that errors or hangs.

func TestProbePython_NonexecutablePathFails(t *testing.T) {
	// A directory can never be executed; this exercises the "resolves to a
	// path but doesn't actually run" branch without needing a real broken
	// interpreter on disk.
	dir := t.TempDir()
	if err := probePython(dir); err == nil {
		t.Fatalf("expected error probing a directory as an interpreter")
	}
}

func TestProbePython_KnownGoodInterpreterSucceeds(t *testing.T) {
	// Best-effort: use whatever real "--version"-capable executable is on
	// PATH in this environment (git is a safe, near-universal bet on dev
	// boxes and CI). Skip if unavailable rather than failing the suite.
	candidate, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not on PATH; skipping known-good probe smoke test")
	}
	if err := probePython(candidate); err != nil {
		t.Fatalf("expected probe of a real executable to succeed, got: %v", err)
	}
}

func TestProbePython_TimeoutIsTreatedAsFailure(t *testing.T) {
	// Shrink the timeout so a normally-fast real executable can't possibly
	// finish before the context deadline fires, exercising the ctx.Err()
	// branch deterministically without needing a purpose-built slow binary.
	old := probeTimeout
	probeTimeout = 1 * time.Nanosecond
	defer func() { probeTimeout = old }()

	candidate, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not on PATH; skipping timeout probe test")
	}
	start := time.Now()
	err = probePython(candidate)
	if err == nil {
		t.Fatalf("expected probe to fail under a 1ns timeout")
	}
	if !strings.Contains(err.Error(), "timed out") {
		t.Errorf("expected a timeout error, got: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("probePython took too long to fail: %s", elapsed)
	}
}
