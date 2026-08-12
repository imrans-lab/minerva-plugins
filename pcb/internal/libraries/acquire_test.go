package libraries

// ONE wide test for on-demand acquisition (S4/B3, docket 019ff5689732), plus a
// URL-construction pin.
//
// The happy path and every adversarial case live in the SAME test because the
// claim being made is not "fetching works" and not "404 is handled" — it is
// that exactly one shape of response becomes a footprint and every other shape
// is refused, from one caller, against one server. Splitting that into a test
// per shape would let most of them pass while one quietly stopped exercising the
// same entry point.
//
// THE SECOND SERVER is the exception to "one server", and it is not a fixture
// for a happy path: it is the origin a redirect would point at, and the claim it
// carries is a NEGATIVE one — that it is never contacted at all.
//
// WHAT "NOTHING IS WRITTEN" MEANS HERE: acquisition writes nothing at all, on
// any path — staging is the worker's job (acquire.go's header). So the property
// is checked once, over the whole test, by pointing MINERVA_PLUGIN_DATA_DIR at
// an empty directory and asserting it is STILL empty after the happy path and
// every refusal. A future edit that "helpfully" cached the fetched bytes to
// disk would red this, which is the point: a second write path is a second
// place the bless gate can be forgotten.
//
// The worker call itself is not exercised here. There is no fake-worker seam in
// this repo's Go tests (main_test.go spawns the REAL pcb-plugin binary and a
// REAL Python worker over stdio), and inventing one to assert an argument map
// would test the mock. What IS asserted is everything the handler passes across
// that boundary — ref, text, sha256, source_ref, license, and the URL those
// came from — computed by the same function the handler calls.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const testTag = "9.0.9.1-test"

// A minimal but REAL two-pad footprint: what upstream would serve.
const validKicadMod = `(footprint "R_0402_1005Metric" (version 20221018) (generator test)
  (layer "F.Cu")
  (pad "1" smd roundrect (at -0.51 0) (size 0.54 0.64) (layers "F.Cu" "F.Paste" "F.Mask"))
  (pad "2" smd roundrect (at 0.51 0) (size 0.54 0.64) (layers "F.Cu" "F.Paste" "F.Mask"))
)
`

// writeAcquireLock writes a lock manifest whose TAG and FOOTPRINTS REPO are the
// only things acquisition reads out of it — the entries exist solely because
// LoadLock refuses an empty manifest.
func writeAcquireLock(t *testing.T, dir, repo, tag string) string {
	t.Helper()
	lock := Lock{SchemaVersion: 1, Tag: tag, Entries: []Entry{
		{Name: "Device.kicad_sym", Kind: "symbol_lib", Dest: "Device.kicad_sym",
			URL: repo + "/-/raw/" + tag + "/Device.kicad_sym", SHA256: "00"},
	}}
	lock.Source.FootprintsRepo = repo
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

func assertEmptyDir(t *testing.T, dir, when string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read data dir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("acquisition wrote to the data directory %s: %v — acquisition must write NOTHING (staging is the worker's job)", when, entries)
	}
}

func TestAcquireFootprint_FetchesOfficialPartAndRefusesEverythingElse(t *testing.T) {
	var requested atomic.Value // last requested path
	requested.Store("")
	var hits int64

	// A SECOND origin, standing in for wherever a redirect could point. It serves
	// a perfectly valid footprint on purpose: content checks cannot tell this
	// apart from the real thing, so the only thing that can refuse it is the
	// redirect policy itself. Its counter is the actual assertion — "refused" has
	// to mean "never contacted", not "contacted and then disliked".
	var elsewhereHits int64
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&elsewhereHits, 1)
		_, _ = w.Write([]byte(validKicadMod))
	}))
	defer elsewhere.Close()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&hits, 1)
		requested.Store(r.URL.Path)
		switch {
		case strings.HasSuffix(r.URL.Path, "/Resistor_SMD.pretty/Moved.kicad_mod"):
			// The pinned URL answering with "go ask that other host instead" —
			// the hop Go's default policy would happily follow.
			http.Redirect(w, r, elsewhere.URL+"/part.kicad_mod", http.StatusFound)
		case strings.HasSuffix(r.URL.Path, "/Resistor_SMD.pretty/R_0402_1005Metric.kicad_mod"):
			_, _ = w.Write([]byte(validKicadMod))
		case strings.HasSuffix(r.URL.Path, "/Resistor_SMD.pretty/Huge.kicad_mod"):
			// Over the ceiling, and shaped like a footprint so ONLY the size
			// check can refuse it.
			_, _ = w.Write([]byte("(footprint \"Huge\"" + strings.Repeat(" ", FootprintMaxBytes+64) + ")"))
		case strings.HasSuffix(r.URL.Path, "/Resistor_SMD.pretty/ErrorPage.kicad_mod"):
			// A 200 that is an HTML page — the exact failure a status check
			// alone would let through and stage as "the footprint".
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte("<!DOCTYPE html>\n<html><body>Sign in to GitLab</body></html>"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	lockDir := t.TempDir()
	dataDir := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)
	lockPath := writeAcquireLock(t, lockDir, srv.URL, testTag)

	// ---- the one shape that becomes a footprint ---------------------------
	got, err := AcquireFootprint(lockPath, "Resistor_SMD:R_0402_1005Metric")
	if err != nil {
		t.Fatalf("AcquireFootprint on a good ref: %v", err)
	}
	wantPath := "/-/raw/" + testTag + "/Resistor_SMD.pretty/R_0402_1005Metric.kicad_mod"
	if p := requested.Load().(string); p != wantPath {
		t.Errorf("fetched path = %q, want %q (the URL must be built from the lock's PINNED tag, not a literal)", p, wantPath)
	}
	if got.Text != validKicadMod {
		t.Errorf("text mismatch:\n got: %q\nwant: %q", got.Text, validKicadMod)
	}
	if got.SHA256 != sha256Hex([]byte(validKicadMod)) {
		t.Errorf("sha256 = %s, want %s (the value the worker cross-checks against)", got.SHA256, sha256Hex([]byte(validKicadMod)))
	}
	if want := "kicad-footprints@" + testTag + "/Resistor_SMD.pretty/R_0402_1005Metric.kicad_mod"; got.SourceRef != want {
		t.Errorf("source_ref = %q, want %q", got.SourceRef, want)
	}
	if got.License != FootprintLicense {
		t.Errorf("license = %q, want %q", got.License, FootprintLicense)
	}
	if got.Tag != testTag || got.Lib != "Resistor_SMD" || got.Part != "R_0402_1005Metric" {
		t.Errorf("unexpected identity: %+v", got)
	}
	if got.SizeBytes != int64(len(validKicadMod)) {
		t.Errorf("size_bytes = %d, want %d", got.SizeBytes, len(validKicadMod))
	}
	assertEmptyDir(t, dataDir, "after a SUCCESSFUL acquire")

	// ---- everything else is refused, and touches nothing -------------------
	for _, tc := range []struct {
		name        string
		ref         string
		wantKind    string
		wantInMsg   string
		wantNoFetch bool // a refusal that must happen BEFORE any request
	}{
		{name: "404 — no such part at this release", ref: "Resistor_SMD:NoSuchPart",
			wantKind: "http", wantInMsg: "404"},
		{name: "oversized body", ref: "Resistor_SMD:Huge",
			wantKind: "content", wantInMsg: "more than"},
		{name: "HTML error page served with status 200", ref: "Resistor_SMD:ErrorPage",
			wantKind: "content", wantInMsg: "markup"},
		// The refusal must NAME where it was being sent. "Redirected" alone
		// would leave an operator unable to tell a moved upstream from a
		// hijacked one, which is the whole decision this refusal exists to hand
		// back to a human.
		{name: "redirect to another origin", ref: "Resistor_SMD:Moved",
			wantKind: "redirect", wantInMsg: elsewhere.URL + "/part.kicad_mod"},
		{name: "ref with a traversal segment", ref: "Resistor_SMD:../../../../etc/passwd",
			wantKind: "ref", wantInMsg: "traversal", wantNoFetch: true},
		// Percent-encoded traversal: the shape that reads as one harmless
		// segment to a textual check and decodes into three upstream.
		{name: "ref with a percent-encoded traversal segment", ref: "Resistor_SMD:..%2f..%2fetc",
			wantKind: "ref", wantInMsg: "percent", wantNoFetch: true},
		{name: "ref with a path separator in the library nickname", ref: "a/b:Name",
			wantKind: "ref", wantInMsg: "path separator", wantNoFetch: true},
		{name: "ref without a colon", ref: "R_0402_1005Metric",
			wantKind: "ref", wantInMsg: "LibNick:PartName", wantNoFetch: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := atomic.LoadInt64(&hits)
			out, err := AcquireFootprint(lockPath, tc.ref)
			if err == nil {
				t.Fatalf("expected a refusal for %q, got %+v", tc.ref, out)
			}
			ae, ok := err.(*AcquireError)
			if !ok {
				t.Fatalf("expected *AcquireError (the attributed refusal the tool turns into a structured error), got %T: %v", err, err)
			}
			if ae.Kind != tc.wantKind {
				t.Errorf("kind = %q, want %q (message: %s)", ae.Kind, tc.wantKind, ae.Message)
			}
			if !strings.Contains(ae.Message, tc.wantInMsg) {
				t.Errorf("message does not mention %q: %s", tc.wantInMsg, ae.Message)
			}
			if out.Text != "" || out.SHA256 != "" {
				t.Errorf("a refusal must return no content at all, got %+v", out)
			}
			if tc.wantNoFetch && atomic.LoadInt64(&hits) != before {
				t.Errorf("a malformed ref must be refused BEFORE any request is made (the ref becomes a URL path); %d request(s) were sent",
					atomic.LoadInt64(&hits)-before)
			}
			if !tc.wantNoFetch && ae.URL == "" {
				t.Errorf("a refusal raised after a URL exists must name it, got empty URL: %s", ae.Message)
			}
		})
	}
	assertEmptyDir(t, dataDir, "after every refusal")

	// The load-bearing half of the redirect case. A refusal that still fetched
	// the target has already handed arbitrary bytes to the caller's judgement;
	// only a zero here says acquisition stopped at the pinned origin.
	if n := atomic.LoadInt64(&elsewhereHits); n != 0 {
		t.Errorf("the redirect target received %d request(s); official acquisition must refuse a "+
			"redirect fail-closed and never contact another origin — bytes from there would still be "+
			"recorded as source_kind=official_kicad and auto-blessed", n)
	}

	// ---- a network that is simply not there --------------------------------
	// The offline contract, stated in the refusal itself: this failure blocks
	// ACQUIRING a new part and says so, rather than reading as a library outage.
	srv.Close()
	if _, err := AcquireFootprint(lockPath, "Resistor_SMD:R_0402_1005Metric"); err == nil {
		t.Fatal("expected a refusal once the server is gone")
	} else if ae, ok := err.(*AcquireError); !ok || ae.Kind != "network" {
		t.Fatalf("expected a network-kind AcquireError, got %T: %v", err, err)
	} else if !strings.Contains(ae.Message, "RESOLUTION never does") || !strings.Contains(ae.Message, ae.URL) {
		t.Errorf("a network refusal must name the URL and state the offline contract: %s", ae.Message)
	}
	assertEmptyDir(t, dataDir, "after a network failure")
}

// TestAcquireFootprint_LockIsTheOnlyAuthorityForTheRelease pins the property the
// brief calls out by name: no tag or upstream is written into the Go code. A
// lock missing either one refuses rather than falling back to a default, because
// a default would silently acquire from a DIFFERENT release than the one the
// rest of the library came from — and mixed-release parts in one board is the
// failure this pin exists to prevent.
func TestAcquireFootprint_LockIsTheOnlyAuthorityForTheRelease(t *testing.T) {
	dir := t.TempDir()

	noRepo := Lock{SchemaVersion: 1, Tag: testTag, Entries: []Entry{
		{Name: "x", Kind: "symbol_lib", Dest: "x", URL: "https://example.invalid/x", SHA256: "00"},
	}}
	data, err := json.Marshal(noRepo)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "libraries.lock.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := AcquireFootprint(path, "Resistor_SMD:R_0402_1005Metric"); err == nil {
		t.Error("a lock with no source.footprints_repo must refuse, not fall back to a hard-coded upstream")
	} else if ae, ok := err.(*AcquireError); !ok || ae.Kind != "lock" {
		t.Errorf("expected a lock-kind AcquireError, got %T: %v", err, err)
	}

	if _, err := AcquireFootprint(filepath.Join(dir, "absent.json"), "Resistor_SMD:R_0402_1005Metric"); err == nil {
		t.Error("an absent lock must refuse: there is no release to pin to")
	} else if ae, ok := err.(*AcquireError); !ok || ae.Kind != "lock" {
		t.Errorf("expected a lock-kind AcquireError, got %T: %v", err, err)
	}

	// The URL shape itself, pinned against scripts/gen_libraries_lock.py's
	// RAW_URL_FMT — an acquired part and a locked one must be addressed
	// identically, or the two paths can drift onto different upstream layouts.
	got := FootprintRawURL("https://gitlab.com/kicad/libraries/kicad-footprints/", "9.0.9.1",
		"Resistor_SMD", "R_0402_1005Metric")
	want := "https://gitlab.com/kicad/libraries/kicad-footprints/-/raw/9.0.9.1/Resistor_SMD.pretty/R_0402_1005Metric.kicad_mod"
	if got != want {
		t.Errorf("FootprintRawURL:\n got: %s\nwant: %s", got, want)
	}

	// Escaping, pinned from the other side: SplitFootprintRef refuses these
	// halves before they ever reach here, but this function is exported and the
	// two guards must not both be able to go missing in one edit. A separator
	// must survive as an ESCAPE, never as a path boundary.
	esc := FootprintRawURL("https://example.invalid/repo", "9.0.9.1", "Lib", "../../etc/passwd")
	if strings.Contains(strings.TrimPrefix(esc, "https://example.invalid/repo/-/raw/9.0.9.1/"), "/../") {
		t.Errorf("FootprintRawURL interpolated a traversal segment raw into the URL path: %s", esc)
	}
	if !strings.Contains(esc, "%2F") && !strings.Contains(esc, "%2f") {
		t.Errorf("FootprintRawURL did not percent-escape the separator in the part name: %s", esc)
	}
}
