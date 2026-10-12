package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	plugruntime "github.com/imrans-lab/minerva-plugins/shared/runtime"
)

// Explicit .exe output works with Go and the native host spawn on every OS;
// setup exec resolves only argv[0], so no arguments rely on its working directory.
//
//go:embed manifest.json
var manifestJSON []byte

func privateDir(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("private directory must be absolute")
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || (runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		return fmt.Errorf("not a private directory: %s", path)
	}
	return nil
}

func pluginRoot() (string, error) {
	// DataDir can name an existing host-owned directory; only our child must be 0700.
	root := filepath.Join(plugruntime.DataDir("docket"), "official")
	return root, privateDir(root)
}

func syncReceipt(stage string, receipt []byte) error {
	file, err := os.OpenFile(filepath.Join(stage, "acquisition.lock.json"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(receipt)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	return err
}

// Windows does not support flushing directory handles via os.File.Sync.
func syncDirectory(path string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func syncDirectories(root string) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			if err := syncDirectories(filepath.Join(root, entry.Name())); err != nil {
				return err
			}
		}
	}
	return syncDirectory(root)
}

// Preparation is a setup operation, never part of the manager's startup budget.
func pluginCommand(ctx context.Context, r release, args []string) error {
	root, err := pluginRoot()
	if err != nil {
		return err
	}
	target := runtime.GOOS + "-" + runtime.GOARCH
	switch {
	case len(args) == 1 && args[0] == "prepare", len(args) == 2 && args[0] == "manifest":
		if _, err := acquire(ctx, r, target, root, fetchOfficial(r)); err != nil {
			return err
		}
		if err := privateDir(filepath.Join(root, "state")); err != nil {
			return err
		}
		if args[0] == "manifest" {
			// Generated beside this source-built executable, independent of cwd.
			executable, err := os.Executable()
			if err != nil {
				return err
			}
			output := filepath.Join(filepath.Dir(executable), args[1])
			if filepath.Base(args[1]) != args[1] {
				return errors.New("manifest expects a filename beside the launcher")
			}
			return os.WriteFile(output, manifestJSON, 0600)
		}
		return nil
	case len(args) == 0:
		p, ok := r.Platforms[target]
		if !ok {
			return fmt.Errorf("unsupported platform: %s", target)
		}
		dest := filepath.Join(root, r.Tag+"-"+target)
		// Marketplace archives carry the already verified official payload.
		// The payload receipt remains the setup verification boundary.
		if executable, err := os.Executable(); err == nil {
			bundled := filepath.Join(filepath.Dir(executable), "official", r.Tag+"-"+target)
			if _, err := os.Stat(bundled); err == nil {
				dest = bundled
			}
		}
		receipt, err := os.ReadFile(filepath.Join(dest, "acquisition.lock.json"))
		if err != nil {
			return fmt.Errorf("run plugin setup first: %w", err)
		}
		expected, err := json.Marshal(r)
		if err != nil {
			return err
		}
		if string(receipt) != string(expected) {
			return errors.New("installation receipt mismatch")
		}
		profile, err := standaloneProfile()
		if err != nil {
			return err
		}
		if status, err := discover(ctx, profile); err == nil {
			return json.NewEncoder(os.Stdout).Encode(status)
		}
		status, err := launch(ctx, filepath.Join(dest, filepath.FromSlash(p.Entrypoint)), profile)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(status)
	}
	return errors.New("usage: docket-plugin.exe [prepare | manifest filename | verify-pins | acquire /absolute/private/root]")
}

// Docket owns this standalone profile, its registration, and its lifetime.
func standaloneProfile() (string, error) {
	var base string
	switch runtime.GOOS {
	case "windows":
		base = os.Getenv("APPDATA")
	case "darwin":
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, "Library", "Application Support")
	case "linux":
		base = os.Getenv("XDG_DATA_HOME")
		if !filepath.IsAbs(base) {
			home, err := os.UserHomeDir()
			if err != nil {
				return "", err
			}
			base = filepath.Join(home, ".local", "share")
		}
	default:
		return "", fmt.Errorf("unsupported platform: %s", runtime.GOOS)
	}
	if !filepath.IsAbs(base) {
		return "", errors.New("Docket user-data base must be absolute")
	}
	godot := "Godot"
	if runtime.GOOS == "linux" {
		godot = "godot"
	}
	return filepath.Join(base, godot, "app_userdata", "Docket"), nil
}

type launchStatus struct {
	Status   string `json:"status"`
	PID      int    `json:"pid,omitempty"`
	Endpoint string `json:"endpoint,omitempty"`
	Version  string `json:"version,omitempty"`
	Reason   string `json:"reason,omitempty"`
}

func discover(ctx context.Context, profile string) (launchStatus, error) {
	data, err := os.ReadFile(filepath.Join(profile, "instance.json"))
	if err != nil {
		return launchStatus{}, err
	}
	var record struct {
		PID      int `json:"pid"`
		Endpoint struct {
			Host string `json:"host"`
			Port int    `json:"port"`
		} `json:"endpoint"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(data, &record); err != nil {
		return launchStatus{}, err
	}
	if record.PID <= 0 || record.Endpoint.Host != "127.0.0.1" || record.Endpoint.Port < 1 || record.Endpoint.Port > 65535 {
		return launchStatus{}, errors.New("invalid Docket registration")
	}
	if !processAlive(record.PID) {
		return launchStatus{}, errors.New("stale Docket registration")
	}
	endpoint := fmt.Sprintf("127.0.0.1:%d", record.Endpoint.Port)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+endpoint+"/", nil)
	if err != nil {
		return launchStatus{}, err
	}
	client := &http.Client{Timeout: 500 * time.Millisecond, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true},
		CheckRedirect: func(req *http.Request, via []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(req)
	if err != nil {
		return launchStatus{}, err
	}
	if err := response.Body.Close(); err != nil {
		return launchStatus{}, err
	}
	return launchStatus{Status: "attached", PID: record.PID, Endpoint: endpoint, Version: record.Version}, nil
}

// No pipes or parent-owned lease: the registered GUI survives launcher exit.
func launch(ctx context.Context, executable, profile string) (launchStatus, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	child := exec.Command(executable, "--quiet")
	configureDetached(child)
	if err := child.Start(); err != nil {
		return launchStatus{}, fmt.Errorf("start Docket: %w", err)
	}
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		if status, err := discover(ctx, profile); err == nil {
			status.Status = "spawned"
			if err := child.Process.Release(); err != nil {
				return launchStatus{}, fmt.Errorf("release Docket: %w", err)
			}
			return status, nil
		}
		select {
		case <-ctx.Done():
			killErr := child.Process.Kill()
			if errors.Is(killErr, os.ErrProcessDone) {
				killErr = nil
			}
			waitErr := child.Wait()
			var exitErr *exec.ExitError
			if errors.As(waitErr, &exitErr) {
				waitErr = nil
			} // Expected after owned-child termination.
			return launchStatus{}, errors.Join(fmt.Errorf("Docket registration failed: %w", ctx.Err()), killErr, waitErr)
		case <-ticker.C:
		}
	}
}
