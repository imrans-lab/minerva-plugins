package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestChildIsolation(t *testing.T) {
	for _, platform := range []string{"linux", "windows", "darwin"} {
		state := t.TempDir()
		env, err := childEnvironment(state, platform, []string{"HOME=/unchanged", "APPDATA=/owner", "LOCALAPPDATA=/owner", "XDG_DATA_HOME=/owner", "XDG_RUNTIME_DIR=/session", "PATH=/bin"})
		if err != nil {
			t.Fatal(err)
		}
		values := map[string]string{}
		for _, entry := range env {
			pair := strings.SplitN(entry, "=", 2)
			values[pair[0]] = pair[1]
		}
		if values["HOME"] != "/unchanged" || values["XDG_RUNTIME_DIR"] != "/session" {
			t.Fatal("inherited HOME or session runtime changed")
		}
		keys := []string{}
		if platform == "linux" {
			keys = []string{"XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"}
		}
		if platform == "windows" {
			keys = []string{"APPDATA", "LOCALAPPDATA"}
		}
		for _, key := range keys {
			dir := values[key]
			if !filepath.IsAbs(dir) || !strings.HasPrefix(dir, state+string(os.PathSeparator)) {
				t.Fatalf("%s escaped private state", key)
			}
			info, err := os.Stat(dir)
			if err != nil || !info.IsDir() {
				t.Fatalf("%s absent: %v", key, err)
			}
		}
	}
}
