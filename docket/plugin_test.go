package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestStandaloneProfile(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", root)
	t.Setenv("APPDATA", root)
	t.Setenv("XDG_DATA_HOME", root)
	want := filepath.Join(root, "godot", "app_userdata", "Docket")
	if runtime.GOOS == "windows" {
		want = filepath.Join(root, "Godot", "app_userdata", "Docket")
	}
	if runtime.GOOS == "darwin" {
		want = filepath.Join(root, "Library", "Application Support", "Godot", "app_userdata", "Docket")
	}
	got, err := standaloneProfile()
	if err != nil || got != want {
		t.Fatalf("profile = %q, %v; want %q", got, err, want)
	}
}

func TestDiscover(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNotFound) }))
	defer server.Close()
	port, err := strconv.Atoi(strings.TrimPrefix(server.URL, "http://127.0.0.1:"))
	if err != nil {
		t.Fatal(err)
	}
	profile := t.TempDir()
	record := map[string]any{"pid": os.Getpid(), "endpoint": map[string]any{"host": "127.0.0.1", "port": port}, "version": "live-version"}
	write := func() {
		data, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(profile, "instance.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write()
	status, err := discover(context.Background(), profile)
	if err != nil || status.Status != "attached" || status.PID != os.Getpid() || status.Version != "live-version" {
		t.Fatalf("discover = %+v, %v", status, err)
	}
	server.Close()
	if _, err := discover(context.Background(), profile); err == nil {
		t.Fatal("accepted live PID with a closed HTTP port")
	}
	record["pid"] = -1
	write()
	if _, err := discover(context.Background(), profile); err == nil {
		t.Fatal("accepted invalid PID")
	}
	record["pid"] = os.Getpid()
	record["endpoint"] = map[string]any{"host": "example.com", "port": port}
	write()
	if _, err := discover(context.Background(), profile); err == nil {
		t.Fatal("accepted non-loopback registration")
	}
}
