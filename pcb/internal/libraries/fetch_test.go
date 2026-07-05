package libraries

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
)

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// newFixtureServer serves fixed byte content per path, counting requests per
// path so tests can assert idempotency (no re-fetch of an already-verified
// entry hits the network at all).
type fixtureServer struct {
	*httptest.Server
	content map[string][]byte
	hits    map[string]*int64
}

func newFixtureServer(t *testing.T, content map[string][]byte) *fixtureServer {
	t.Helper()
	fs := &fixtureServer{content: content, hits: map[string]*int64{}}
	for p := range content {
		var n int64
		fs.hits[p] = &n
	}
	mux := http.NewServeMux()
	for p, body := range content {
		p, body := p, body
		mux.HandleFunc(p, func(w http.ResponseWriter, r *http.Request) {
			atomic.AddInt64(fs.hits[p], 1)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body)
		})
	}
	fs.Server = httptest.NewServer(mux)
	t.Cleanup(fs.Server.Close)
	return fs
}

func (fs *fixtureServer) hitCount(path string) int64 {
	return atomic.LoadInt64(fs.hits[path])
}

func writeRawLock(t *testing.T, dir string, lock Lock) string {
	t.Helper()
	data, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "libraries.lock.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestFetchAll_FreshFetch(t *testing.T) {
	deviceBody := []byte(`(kicad_symbol_lib (symbol "R"))`)
	footprintBody := []byte(`(footprint "R_0603_1608Metric")`)

	srv := newFixtureServer(t, map[string][]byte{
		"/Device.kicad_sym":                             deviceBody,
		"/Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod": footprintBody,
	})

	lockDir := t.TempDir()
	destDir := t.TempDir()
	lock := Lock{SchemaVersion: 1, Tag: "9.0.9.1", Entries: []Entry{
		{Name: "Device.kicad_sym", Kind: "symbol_lib", Dest: "Device.kicad_sym",
			URL: srv.URL + "/Device.kicad_sym", SHA256: sha256Hex(deviceBody), SizeBytes: int64(len(deviceBody))},
		{Name: "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod", Kind: "footprint",
			Dest: "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
			URL:  srv.URL + "/Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
			SHA256: sha256Hex(footprintBody), SizeBytes: int64(len(footprintBody))},
	}}
	lockPath := writeRawLock(t, lockDir, lock)

	var events []string
	result, err := FetchAll(lockPath, destDir, func(event string, detail map[string]interface{}) {
		events = append(events, event)
	})
	if err != nil {
		t.Fatalf("FetchAll: %v", err)
	}
	if len(result.Fetched) != 2 {
		t.Fatalf("Fetched = %v, want 2 entries", result.Fetched)
	}
	if len(result.Skipped) != 0 || len(result.Failed) != 0 {
		t.Fatalf("expected no skipped/failed on fresh fetch, got %+v", result)
	}

	got, err := os.ReadFile(filepath.Join(destDir, "Device.kicad_sym"))
	if err != nil {
		t.Fatalf("read fetched Device.kicad_sym: %v", err)
	}
	if string(got) != string(deviceBody) {
		t.Errorf("Device.kicad_sym content mismatch")
	}
	fpPath := filepath.Join(destDir, "Resistor_SMD.pretty", "R_0603_1608Metric.kicad_mod")
	got2, err := os.ReadFile(fpPath)
	if err != nil {
		t.Fatalf("read fetched footprint: %v", err)
	}
	if string(got2) != string(footprintBody) {
		t.Errorf("footprint content mismatch")
	}

	foundSummary := false
	for _, e := range events {
		if e == "summary" {
			foundSummary = true
		}
	}
	if !foundSummary {
		t.Errorf("expected a summary notify event, got %v", events)
	}
}

func TestFetchAll_IdempotentSkipsWithoutNetwork(t *testing.T) {
	body := []byte(`(kicad_symbol_lib (symbol "C"))`)
	srv := newFixtureServer(t, map[string][]byte{"/Device.kicad_sym": body})

	lockDir, destDir := t.TempDir(), t.TempDir()
	lockPath := writeRawLock(t, lockDir, Lock{SchemaVersion: 1, Tag: "t", Entries: []Entry{
		{Name: "Device.kicad_sym", Dest: "Device.kicad_sym", URL: srv.URL + "/Device.kicad_sym",
			SHA256: sha256Hex(body), SizeBytes: int64(len(body))},
	}})

	if _, err := FetchAll(lockPath, destDir, nil); err != nil {
		t.Fatalf("first FetchAll: %v", err)
	}
	if got := srv.hitCount("/Device.kicad_sym"); got != 1 {
		t.Fatalf("expected exactly 1 request after first fetch, got %d", got)
	}

	result, err := FetchAll(lockPath, destDir, nil)
	if err != nil {
		t.Fatalf("second FetchAll: %v", err)
	}
	if len(result.Skipped) != 1 || len(result.Fetched) != 0 {
		t.Fatalf("expected the second run to skip, got %+v", result)
	}
	if got := srv.hitCount("/Device.kicad_sym"); got != 1 {
		t.Fatalf("idempotent re-run must not hit the network; hit count = %d", got)
	}
}

func TestFetchAll_TamperedContentRejectedAndNotWritten(t *testing.T) {
	realBody := []byte(`(kicad_symbol_lib (symbol "L"))`)
	srv := newFixtureServer(t, map[string][]byte{"/Device.kicad_sym": realBody})

	lockDir, destDir := t.TempDir(), t.TempDir()
	// Lock declares a sha256 that does NOT match what the server actually
	// serves — simulates a tampered/corrupted download.
	lockPath := writeRawLock(t, lockDir, Lock{SchemaVersion: 1, Tag: "t", Entries: []Entry{
		{Name: "Device.kicad_sym", Dest: "Device.kicad_sym", URL: srv.URL + "/Device.kicad_sym",
			SHA256: sha256Hex([]byte("not-the-real-content-at-all")), SizeBytes: int64(len(realBody))},
	}})

	result, err := FetchAll(lockPath, destDir, nil)
	if err != nil {
		t.Fatalf("FetchAll: %v", err)
	}
	if len(result.Failed) != 1 {
		t.Fatalf("expected 1 failed entry, got %+v", result)
	}
	if result.Failed[0].Name != "Device.kicad_sym" {
		t.Errorf("Failed[0].Name = %q", result.Failed[0].Name)
	}

	destPath := filepath.Join(destDir, "Device.kicad_sym")
	if _, err := os.Stat(destPath); !os.IsNotExist(err) {
		t.Errorf("destination must NOT exist after a sha256 mismatch, stat err = %v", err)
	}
	assertNoLeftoverTempFiles(t, destDir)
}

func TestFetchAll_PartialDownloadCleanedUp(t *testing.T) {
	fullBody := []byte(`(kicad_symbol_lib (symbol "verylongname_padding_to_make_this_longer_than_the_truncated_write"))`)

	mux := http.NewServeMux()
	mux.HandleFunc("/Device.kicad_sym", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(len(fullBody)))
		w.WriteHeader(http.StatusOK)
		// Write fewer bytes than the declared Content-Length, then abort the
		// connection by hijacking and closing it raw — the client must see a
		// stream error (short/unexpected EOF), not a truncated "success".
		half := len(fullBody) / 3
		_, _ = w.Write(fullBody[:half])
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Fatalf("ResponseWriter does not support hijacking")
		}
		conn, _, err := hj.Hijack()
		if err != nil {
			t.Fatalf("hijack: %v", err)
		}
		_ = conn.Close()
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	lockDir, destDir := t.TempDir(), t.TempDir()
	lockPath := writeRawLock(t, lockDir, Lock{SchemaVersion: 1, Tag: "t", Entries: []Entry{
		{Name: "Device.kicad_sym", Dest: "Device.kicad_sym", URL: srv.URL + "/Device.kicad_sym",
			SHA256: sha256Hex(fullBody), SizeBytes: int64(len(fullBody))},
	}})

	result, err := FetchAll(lockPath, destDir, nil)
	if err != nil {
		t.Fatalf("FetchAll: %v", err)
	}
	if len(result.Failed) != 1 {
		t.Fatalf("expected the truncated download to be reported as failed, got %+v", result)
	}

	destPath := filepath.Join(destDir, "Device.kicad_sym")
	if _, err := os.Stat(destPath); !os.IsNotExist(err) {
		t.Errorf("destination must NOT exist after a partial/aborted download, stat err = %v", err)
	}
	assertNoLeftoverTempFiles(t, destDir)
}

func assertNoLeftoverTempFiles(t *testing.T, destDir string) {
	t.Helper()
	entries, err := os.ReadDir(destDir)
	if err != nil {
		t.Fatalf("readdir %s: %v", destDir, err)
	}
	for _, e := range entries {
		if len(e.Name()) >= 10 && e.Name()[:10] == ".tmp-fetch" {
			t.Errorf("leftover temp file not cleaned up: %s", e.Name())
		}
	}
}

func TestGetStatus_PresentAndPartial(t *testing.T) {
	bodyA := []byte("aaa")
	bodyB := []byte("bbb")
	lockDir, destDir := t.TempDir(), t.TempDir()
	lockPath := writeRawLock(t, lockDir, Lock{SchemaVersion: 1, Tag: "9.0.9.1", Entries: []Entry{
		{Name: "A", Dest: "A.kicad_sym", URL: "https://example.invalid/A", SHA256: sha256Hex(bodyA)},
		{Name: "B", Dest: "B.kicad_sym", URL: "https://example.invalid/B", SHA256: sha256Hex(bodyB)},
	}})

	st, err := GetStatus(lockPath, destDir)
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if st.Present || st.EntriesVerified != 0 || len(st.Missing) != 2 {
		t.Fatalf("expected fully-absent status, got %+v", st)
	}

	if err := os.WriteFile(filepath.Join(destDir, "A.kicad_sym"), bodyA, 0o644); err != nil {
		t.Fatal(err)
	}
	st, err = GetStatus(lockPath, destDir)
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if st.Present || st.EntriesVerified != 1 || len(st.Missing) != 1 || st.Missing[0] != "B" {
		t.Fatalf("expected partial status (1/2, B missing), got %+v", st)
	}
	if st.VersionTag != "9.0.9.1" {
		t.Errorf("VersionTag = %q", st.VersionTag)
	}

	if err := os.WriteFile(filepath.Join(destDir, "B.kicad_sym"), bodyB, 0o644); err != nil {
		t.Fatal(err)
	}
	st, err = GetStatus(lockPath, destDir)
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if !st.Present || st.EntriesVerified != 2 || len(st.Missing) != 0 {
		t.Fatalf("expected fully-present status, got %+v", st)
	}
}

func TestGetStatus_TamperedFileCountsAsMissing(t *testing.T) {
	body := []byte("real content")
	lockDir, destDir := t.TempDir(), t.TempDir()
	lockPath := writeRawLock(t, lockDir, Lock{SchemaVersion: 1, Tag: "t", Entries: []Entry{
		{Name: "A", Dest: "A.kicad_sym", URL: "https://example.invalid/A", SHA256: sha256Hex(body)},
	}})
	// Wrong content at the destination path (e.g. hand-edited or corrupted).
	if err := os.WriteFile(filepath.Join(destDir, "A.kicad_sym"), []byte("tampered"), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := GetStatus(lockPath, destDir)
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if st.Present || st.EntriesVerified != 0 {
		t.Fatalf("tampered file must not count as verified, got %+v", st)
	}
}
