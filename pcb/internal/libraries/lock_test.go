package libraries

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeLockFile(t *testing.T, dir string, lock Lock) string {
	t.Helper()
	data, err := json.Marshal(lock)
	if err != nil {
		t.Fatalf("marshal lock: %v", err)
	}
	path := filepath.Join(dir, "libraries.lock.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write lock: %v", err)
	}
	return path
}

func TestLoadLock_Parse(t *testing.T) {
	dir := t.TempDir()
	lock := Lock{
		SchemaVersion: 1,
		Tag:           "9.0.9.1",
		Entries: []Entry{
			{Name: "Device.kicad_sym", Kind: "symbol_lib", Dest: "Device.kicad_sym",
				URL: "https://example.invalid/Device.kicad_sym", SHA256: "deadbeef", SizeBytes: 123},
			{Name: "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod", Kind: "footprint",
				Dest: "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
				URL:  "https://example.invalid/R_0603_1608Metric.kicad_mod", SHA256: "cafef00d", SizeBytes: 456},
		},
	}
	path := writeLockFile(t, dir, lock)

	got, err := LoadLock(path)
	if err != nil {
		t.Fatalf("LoadLock: %v", err)
	}
	if got.Tag != "9.0.9.1" {
		t.Errorf("Tag = %q, want 9.0.9.1", got.Tag)
	}
	if len(got.Entries) != 2 {
		t.Fatalf("len(Entries) = %d, want 2", len(got.Entries))
	}

	dest := got.Entries[1].DestPath("/base")
	want := filepath.Join("/base", "Resistor_SMD.pretty", "R_0603_1608Metric.kicad_mod")
	if dest != want {
		t.Errorf("DestPath = %q, want %q", dest, want)
	}
}

func TestLoadLock_MissingFile(t *testing.T) {
	_, err := LoadLock(filepath.Join(t.TempDir(), "does-not-exist.json"))
	if err == nil {
		t.Fatal("expected error for missing lock file")
	}
}

func TestLoadLock_MalformedJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "libraries.lock.json")
	if err := os.WriteFile(path, []byte("{ not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := LoadLock(path)
	if err == nil {
		t.Fatal("expected error for malformed JSON")
	}
}

func TestLoadLock_NoEntries(t *testing.T) {
	dir := t.TempDir()
	path := writeLockFile(t, dir, Lock{SchemaVersion: 1, Tag: "x"})
	_, err := LoadLock(path)
	if err == nil {
		t.Fatal("expected error for a lock with no entries")
	}
}

func TestLoadLock_EntryMissingField(t *testing.T) {
	dir := t.TempDir()
	path := writeLockFile(t, dir, Lock{
		SchemaVersion: 1, Tag: "x",
		Entries: []Entry{{Name: "foo", Dest: "foo.kicad_sym", URL: "https://example.invalid/foo"}}, // no sha256
	})
	_, err := LoadLock(path)
	if err == nil {
		t.Fatal("expected error for entry missing sha256")
	}
}

func TestDefaultLockPath(t *testing.T) {
	got := DefaultLockPath(filepath.Join("some", "root"))
	want := filepath.Join("some", "root", "libraries.lock.json")
	if got != want {
		t.Errorf("DefaultLockPath = %q, want %q", got, want)
	}
}

func TestDefaultDir_HonorsDataDirEnv(t *testing.T) {
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", filepath.Join("custom", "data", "dir"))
	got := DefaultDir()
	want := filepath.Join("custom", "data", "dir", "libraries")
	if got != want {
		t.Errorf("DefaultDir = %q, want %q", got, want)
	}
}
