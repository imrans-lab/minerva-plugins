package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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
	case len(args) == 0, len(args) == 1 && args[0] == "--host-authority", len(args) == 2 && args[0] == "--host-authority" && args[1] == "--headless":
		p, ok := r.Platforms[target]
		if !ok {
			return fmt.Errorf("unsupported platform: %s", target)
		}
		dest := filepath.Join(root, r.Tag+"-"+target)
		// Marketplace archives carry the already verified official payload.
		// State still lives in the host's data directory across upgrades.
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
		state := filepath.Join(root, "state")
		if err := privateDir(state); err != nil {
			return err
		}
		return launch(filepath.Join(dest, filepath.FromSlash(p.Entrypoint)), state, args...)
	}
	return errors.New("usage: docket-plugin.exe [--host-authority | prepare | manifest filename | verify-pins | acquire /absolute/private/root]")
}

func childEnvironment(state, platform string, inherited []string) ([]string, error) {
	overrides := map[string]string{}
	switch platform {
	case "linux":
		for _, key := range []string{"XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"} {
			overrides[key] = filepath.Join(state, strings.ToLower(key))
		}
	case "windows":
		overrides["APPDATA"] = filepath.Join(state, "appdata")
		overrides["LOCALAPPDATA"] = filepath.Join(state, "localappdata")
	case "darwin":
		overrides["HOME"] = filepath.Join(state, "home")
	}
	for _, dir := range overrides {
		if err := privateDir(dir); err != nil {
			return nil, err
		}
	}
	env := make([]string, 0, len(inherited)+len(overrides))
	for _, entry := range inherited {
		key := strings.SplitN(entry, "=", 2)[0]
		replaced := false
		for override := range overrides {
			if strings.EqualFold(key, override) {
				replaced = true
			}
		}
		if !replaced {
			env = append(env, entry)
		}
	}
	for key, value := range overrides {
		env = append(env, key+"="+value)
	}
	return env, nil
}

// No protocol requests or namespace translation: the exported GUI owns its lease.
func launch(executable, state string, mode ...string) error {
	env, err := childEnvironment(filepath.Join(filepath.Dir(state), "child-env"), runtime.GOOS, os.Environ())
	if err != nil {
		return err
	}
	// Host mode is explicit; its per-child token stays in the inherited environment.
	engineArgs := []string{"--quiet"}
	if len(mode) == 2 && mode[1] == "--headless" {
		engineArgs = append(engineArgs, "--headless")
		mode = mode[:1]
	}
	args := append(append(engineArgs, "--", "--stdio", "--state-dir", state), mode...)
	child := exec.Command(executable, args...)
	child.Env, child.Stderr = env, os.Stderr
	// Own the pipes: Wait must reap independently of a blocked host writer.
	stdin, input, err := os.Pipe()
	if err != nil {
		return err
	}
	defer stdin.Close()
	defer input.Close()
	stdout, output, err := os.Pipe()
	if err != nil {
		return err
	}
	defer stdout.Close()
	defer output.Close()
	child.Stdin, child.Stdout = stdin, output
	if err := child.Start(); err != nil {
		return err
	}
	_ = stdin.Close()
	_ = output.Close()
	pidFile := filepath.Join(filepath.Dir(state), "child.pid")
	if err := os.WriteFile(pidFile, []byte(fmt.Sprint(child.Process.Pid)), 0600); err != nil {
		_ = child.Process.Kill()
		_ = child.Wait()
		return err
	}
	defer os.Remove(pidFile)
	shutdown := make(chan error, 2)
	go func() {
		// Healthy child backpressure may block forwarding. If that hides EOF,
		// Minerva's stop deadline terminates this launcher and closes its pipes.
		_, err := io.Copy(input, os.Stdin)
		_ = input.Close()
		shutdown <- err
	}()
	outputDone := make(chan error, 1)
	go func() {
		buffer := make([]byte, 32768)
		for {
			n, readErr := stdout.Read(buffer)
			if n > 0 {
				if _, err := os.Stdout.Write(buffer[:n]); err != nil {
					shutdown <- err
					outputDone <- err
					return
				}
			}
			if readErr != nil {
				shutdown <- nil
				outputDone <- nil
				return
			}
		}
	}()
	settled := make(chan error, 1)
	go func() { settled <- child.Wait() }()
	select {
	case err := <-settled:
		// Flush normal final output, but never depend on the host reading it.
		select {
		case outputErr := <-outputDone:
			return errors.Join(err, outputErr)
		case <-time.After(500 * time.Millisecond):
			return err
		}
	case cause := <-shutdown:
		go input.Close() // Windows close may wait for an outstanding write.
		// Leave headroom inside the host's ten-second graceful stop window.
		select {
		case err := <-settled:
			if err != nil {
				return err
			}
			select {
			case <-outputDone:
			case <-time.After(500 * time.Millisecond):
			}
			return cause
		case <-time.After(8 * time.Second):
			_ = child.Process.Kill()
			<-settled
			return errors.New("Docket did not settle within eight seconds of shutdown")
		}
	}
}
