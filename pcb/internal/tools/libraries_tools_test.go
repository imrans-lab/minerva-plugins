package tools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/imrans-lab/minerva-plugins/pcb/internal/libraries"
)

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// writeLock writes a tiny synthetic libraries.lock.json under root, pointing
// its one entry at srv (an httptest server) so no real network is touched.
func writeLock(t *testing.T, root string, srv *httptest.Server, sha, name string) {
	t.Helper()
	lock := libraries.Lock{
		SchemaVersion: 1, Tag: "test-tag",
		Entries: []libraries.Entry{
			{Name: name, Kind: "symbol_lib", Dest: name, URL: srv.URL + "/" + name, SHA256: sha},
		},
	}
	data, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "libraries.lock.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestHandleFetchLibrariesAndStatus_EndToEnd(t *testing.T) {
	body := []byte(`(kicad_symbol_lib (symbol "R"))`)
	mux := http.NewServeMux()
	mux.HandleFunc("/Device.kicad_sym", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(body)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	root := t.TempDir()
	dataDir := t.TempDir()
	writeLock(t, root, srv, sha256Hex(body), "Device.kicad_sym")

	SetPluginRoot(root)
	defer SetPluginRoot(".")
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)

	var notified []string
	SetNotifier(func(level, message string, details interface{}) {
		notified = append(notified, level+": "+message)
	})
	defer SetNotifier(nil)

	// Before fetching: status must report absent, never error.
	statusOut, err := HandleLibraryStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("HandleLibraryStatus (pre-fetch): %v", err)
	}
	var st libraries.Status
	if err := json.Unmarshal(statusOut, &st); err != nil {
		t.Fatal(err)
	}
	if st.Present {
		t.Fatalf("expected present=false before any fetch, got %+v", st)
	}

	// Fetch.
	fetchOut, err := HandleFetchLibraries(context.Background(), nil)
	if err != nil {
		t.Fatalf("HandleFetchLibraries: %v", err)
	}
	var result libraries.FetchResult
	if err := json.Unmarshal(fetchOut, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Fetched) != 1 || len(result.Failed) != 0 {
		t.Fatalf("unexpected fetch result: %+v", result)
	}
	if len(notified) == 0 {
		t.Errorf("expected at least one host.notify call during fetch")
	}

	// After fetching: status must report present.
	statusOut2, err := HandleLibraryStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("HandleLibraryStatus (post-fetch): %v", err)
	}
	var st2 libraries.Status
	if err := json.Unmarshal(statusOut2, &st2); err != nil {
		t.Fatal(err)
	}
	if !st2.Present || st2.EntriesVerified != 1 {
		t.Fatalf("expected present=true after fetch, got %+v", st2)
	}
}

func TestHandleLibraryStatus_MissingLockFileNeverErrors(t *testing.T) {
	SetPluginRoot(t.TempDir()) // no libraries.lock.json here
	defer SetPluginRoot(".")

	out, err := HandleLibraryStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("HandleLibraryStatus must never error, got: %v", err)
	}
	var st libraries.Status
	if jsonErr := json.Unmarshal(out, &st); jsonErr != nil {
		t.Fatal(jsonErr)
	}
	if st.Present {
		t.Errorf("expected present=false with no lock file, got %+v", st)
	}
}
