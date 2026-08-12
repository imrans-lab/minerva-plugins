package libraries

// ONE wide test for arbitrary-source import (B4, docket 019ff568b56b), in
// acquire_test.go's shape and for its reason: the claim is not "importing
// works" and not "zip-slip is caught" — it is that exactly the shapes named
// below become a footprint and EVERY other shape is refused, from one caller,
// against one server and one disk. Split per case, most of them would keep
// passing while one quietly stopped exercising the entry point.
//
// THE SECOND ORIGIN carries a NEGATIVE claim, same as acquire_test.go's: it
// serves a perfectly valid footprint, so nothing about the CONTENT can refuse
// it, and its request counter staying at zero is the only thing that says the
// redirect chain was never walked.
//
// WHAT "THE ARTIFACT IS ABSENT" MEANS HERE: import writes nothing on any path
// — staging is the worker's job (import.go's header) — so the property is
// checked over the whole test by pointing MINERVA_PLUGIN_DATA_DIR at an empty
// directory and asserting it is STILL empty after every happy path and every
// refusal (assertEmptyDir, shared with acquire_test.go). A future edit that
// cached a fetched blob to disk would red this.
//
// THE GIT FLOW IS HERMETIC: a real repository is built in a temp directory and
// imported over file://, so the pinned-revision path is exercised with no
// network at all. This test owns the READ half of that flow; its tail —
// stage → report → bless → resolve — is worker/tests/test_footprint_import.py,
// because there is no fake-worker seam in this repo's Go tests and inventing
// one to assert an argument map would test the mock.
//
// NOT COVERED HERE, deliberately: the declared-uncompressed-total cap
// (ArchiveMaxTotalBytes). Reaching it honestly means writing a quarter-gigabyte
// through a deflate writer, and reaching it dishonestly means hand-forging zip
// central-directory sizes — a fixture elaborate enough that a green result
// would be evidence about the fixture. The per-entry ceiling below is the bound
// that actually protects the parser; the total is a second, cheaper one read
// straight off the central directory.

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const importLicense = "CC-BY-SA-4.0"

// fileURL turns a local directory into a file:// URL that both url.Parse and
// git accept on every platform this plugin ships to — a Windows path becomes
// file:///C:/..., which needs the extra leading slash a POSIX path already has.
func fileURL(path string) string {
	p := filepath.ToSlash(path)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return "file://" + p
}

// writeZip builds a zip archive from an ordered list of name/content pairs.
// ORDERED (a slice, not a map) because two of the cases below assert on a
// refusal that names entries, and a map's iteration order would make that
// message change run to run.
func writeZip(t *testing.T, path string, entries [][2]string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, e := range entries {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: e[0], Method: zip.Deflate})
		if err != nil {
			t.Fatalf("zip entry %q: %v", e[0], err)
		}
		if _, err := w.Write([]byte(e[1])); err != nil {
			t.Fatalf("zip write %q: %v", e[0], err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// makeGitRepo builds a real repository containing files and returns its path
// and the full object id of the single commit. Skips the whole git half of the
// test when git is unavailable rather than failing it: git is a runtime
// dependency of ONE importer, and its absence is a refusal that importFromGit
// already states by name.
func makeGitRepo(t *testing.T, files map[string]string) (string, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not on PATH; the git importer refuses by name in that case")
	}
	dir := t.TempDir()
	run := func(args ...string) string {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		// A replaced environment for the same reason importFromGit replaces
		// one: a developer's ~/.gitconfig (hooks, templates, insteadOf) must
		// not decide what this fixture becomes.
		cmd.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "HOME="+dir,
			"GIT_CONFIG_GLOBAL="+filepath.Join(dir, "nonexistent-gitconfig"))
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	run("init", "--quiet")
	for name, content := range files {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("add", "-A")
	run("-c", "user.email=test@example.invalid", "-c", "user.name=Test",
		"commit", "--quiet", "-m", "fixture")
	return dir, run("rev-parse", "HEAD")
}

func TestImportFootprint_ImportsEveryNamedSourceAndRefusesEverythingElse(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("MINERVA_PLUGIN_DATA_DIR", dataDir)

	// The origin a redirect chain leads to. It serves a VALID footprint on
	// purpose: no content check can tell it from the real thing, so only the
	// redirect policy can refuse it, and only its counter can prove that.
	var elsewhereHits int64
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&elsewhereHits, 1)
		_, _ = w.Write([]byte(validKicadMod))
	}))
	defer elsewhere.Close()

	// The second hop of the chain, on the ORIGIN server, is /hop2. Refusing the
	// FIRST hop means /hop2 is never requested either, which is a stronger
	// statement than "the last address was not contacted".
	var hop2Hits int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/good.kicad_mod":
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = w.Write([]byte(validKicadMod))
		case "/octet.kicad_mod":
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write([]byte(validKicadMod))
		case "/silent.kicad_mod":
			// No Content-Type at all — accepted, because a header nobody sent
			// is not evidence. Go would sniff one, so it is cleared explicitly.
			w.Header()["Content-Type"] = nil
			_, _ = w.Write([]byte(validKicadMod))
		case "/moved.kicad_mod":
			http.Redirect(w, r, "/hop2", http.StatusFound)
		case "/hop2":
			atomic.AddInt64(&hop2Hits, 1)
			http.Redirect(w, r, elsewhere.URL+"/part.kicad_mod", http.StatusFound)
		case "/huge.kicad_mod":
			// Over the ceiling and shaped like a footprint, so ONLY the size
			// check can refuse it.
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte("(footprint \"Huge\"" + strings.Repeat(" ", FootprintMaxBytes+64) + ")"))
		case "/page.kicad_mod":
			// The type a server sends when the address resolves to a PAGE.
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte("<!DOCTYPE html>\n<html><body>Sign in</body></html>"))
		case "/markup.kicad_mod":
			// Markup wearing an ALLOWED Content-Type: the case that proves the
			// type check and the shape check are two independent defenses
			// rather than one restated.
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte("<!DOCTYPE html>\n<html><body>Sign in</body></html>"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	repoDir, rev := makeGitRepo(t, map[string]string{
		"footprints/MyLib.pretty/Part_A.kicad_mod": validKicadMod,
		"README.md": "not a footprint",
		"footprints/MyLib.pretty/Huge.kicad_mod": "(footprint \"Huge\"" +
			strings.Repeat(" ", FootprintMaxBytes+64) + ")",
	})
	repoURL := fileURL(repoDir)

	archiveDir := t.TempDir()
	goodZip := writeZip(t, filepath.Join(archiveDir, "vendor.zip"), [][2]string{
		{"SnapEDA/readme.txt", "downloaded by a human"},
		{"SnapEDA/Part_A.kicad_mod", validKicadMod},
	})

	// ---- the shapes that become a footprint --------------------------------

	for _, tc := range []struct {
		name      string
		req       ImportRequest
		wantKind  string
		wantRef   string
		wantOrig  string
		wantBytes string
	}{
		{
			name: "url — text/plain",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/good.kicad_mod", License: importLicense},
			wantKind: SourceKindURL, wantRef: "url+" + srv.URL + "/good.kicad_mod",
			wantOrig: "good.kicad_mod", wantBytes: validKicadMod,
		},
		{
			name: "url — application/octet-stream",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/octet.kicad_mod", License: importLicense},
			wantKind: SourceKindURL, wantRef: "url+" + srv.URL + "/octet.kicad_mod",
			wantOrig: "octet.kicad_mod", wantBytes: validKicadMod,
		},
		{
			name: "url — no Content-Type at all",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/silent.kicad_mod", License: importLicense},
			wantKind: SourceKindURL, wantRef: "url+" + srv.URL + "/silent.kicad_mod",
			wantOrig: "silent.kicad_mod", wantBytes: validKicadMod,
		},
		{
			// THE HERMETIC GIT FLOW's read half: a real repository, a full
			// object id, one blob out of the object store, no network.
			name: "git — a pinned revision of a local repository",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: rev,
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod",
				License:    importLicense},
			wantKind: SourceKindGit,
			wantRef: fmt.Sprintf("git+%s@%s:footprints/MyLib.pretty/Part_A.kicad_mod",
				repoURL, rev),
			wantOrig: "Part_A.kicad_mod", wantBytes: validKicadMod,
		},
		{
			name: "vendor_export — one .kicad_mod in a local zip",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: goodZip, License: importLicense},
			wantKind: SourceKindVendorExport,
			wantOrig: "Part_A.kicad_mod", wantBytes: validKicadMod,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ImportFootprint(tc.req)
			if err != nil {
				t.Fatalf("ImportFootprint: %v", err)
			}
			if got.Text != tc.wantBytes {
				t.Errorf("text mismatch:\n got: %q\nwant: %q", got.Text, tc.wantBytes)
			}
			if got.SHA256 != sha256Hex([]byte(tc.wantBytes)) {
				t.Errorf("sha256 = %s, want %s (the value the worker cross-checks against)",
					got.SHA256, sha256Hex([]byte(tc.wantBytes)))
			}
			// SourceKind is what the IMPORTER decided, and the worker records
			// it verbatim: an importer that returned the caller's string
			// instead would be the hole the whole kind vocabulary exists to
			// close.
			if got.SourceKind != tc.wantKind {
				t.Errorf("source_kind = %q, want %q", got.SourceKind, tc.wantKind)
			}
			if tc.wantRef != "" && got.SourceRef != tc.wantRef {
				t.Errorf("source_ref = %q, want %q", got.SourceRef, tc.wantRef)
			}
			// The SOURCE's filename, not the ref's: it is the one thing the
			// staged copy loses (staging renames to <Part>.kicad_mod), and it
			// becomes a path component under the WIP originals directory.
			if got.OriginalFilename != tc.wantOrig {
				t.Errorf("original_filename = %q, want %q", got.OriginalFilename, tc.wantOrig)
			}
			if got.Lib != "MyLib" || got.Part != "PART_A" || got.License != importLicense {
				t.Errorf("unexpected identity: %+v", got)
			}
			if got.SizeBytes != int64(len(tc.wantBytes)) {
				t.Errorf("size_bytes = %d, want %d", got.SizeBytes, len(tc.wantBytes))
			}
			assertEmptyDir(t, dataDir, "after a SUCCESSFUL import of "+tc.name)
		})
	}

	// The vendor_export provenance names the archive by BASENAME and digest,
	// never by its path on this machine: source_ref is rendered into the
	// generated NOTICE inventory, and a home directory does not belong in a
	// published license file (nor is it reproducible anywhere else).
	vendored, err := ImportFootprint(ImportRequest{Ref: "MyLib:PART_A",
		SourceKind: SourceKindVendorExport, ArchivePath: goodZip, License: importLicense})
	if err != nil {
		t.Fatalf("vendor import: %v", err)
	}
	wantPrefix := "vendor_export+vendor.zip@sha256:"
	if !strings.HasPrefix(vendored.SourceRef, wantPrefix) ||
		!strings.HasSuffix(vendored.SourceRef, "!SnapEDA/Part_A.kicad_mod") {
		t.Errorf("vendor source_ref = %q, want %q<digest>!SnapEDA/Part_A.kicad_mod",
			vendored.SourceRef, wantPrefix)
	}
	if strings.Contains(vendored.SourceRef, archiveDir) {
		t.Errorf("vendor source_ref leaks the local archive directory into the lock "+
			"(and from there into the generated NOTICE): %s", vendored.SourceRef)
	}

	// ---- everything else is refused, and nothing is written -----------------

	zipSlip := writeZip(t, filepath.Join(archiveDir, "slip.zip"), [][2]string{
		{"SnapEDA/Part_A.kicad_mod", validKicadMod},
		{"../../../../tmp/evil.kicad_mod", validKicadMod},
	})
	zipAbs := writeZip(t, filepath.Join(archiveDir, "abs.zip"), [][2]string{
		{"/etc/cron.d/evil.kicad_mod", validKicadMod},
	})
	zipBackslash := writeZip(t, filepath.Join(archiveDir, "backslash.zip"), [][2]string{
		{`..\..\evil.kicad_mod`, validKicadMod},
	})
	zipNone := writeZip(t, filepath.Join(archiveDir, "none.zip"), [][2]string{
		{"SnapEDA/readme.txt", "no footprint in here"},
	})
	zipTwo := writeZip(t, filepath.Join(archiveDir, "two.zip"), [][2]string{
		{"SnapEDA/Part_A.kicad_mod", validKicadMod},
		{"SnapEDA/Part_B.kicad_mod", validKicadMod},
	})
	zipHuge := writeZip(t, filepath.Join(archiveDir, "huge.zip"), [][2]string{
		{"SnapEDA/Part_A.kicad_mod", "(footprint \"Huge\"" +
			strings.Repeat(" ", FootprintMaxBytes+64) + ")"},
	})
	notAZip := filepath.Join(archiveDir, "plain.zip")
	if err := os.WriteFile(notAZip, []byte(validKicadMod), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name      string
		req       ImportRequest
		wantKind  string
		wantInMsg string
	}{
		// --- the policy gate, refused before anything is read ---------------
		{name: "no license stated",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/good.kicad_mod"},
			wantKind: "license", wantInMsg: "license is required"},
		{name: "a ref that could not become a safe path",
			req: ImportRequest{Ref: "MyLib:../../etc/passwd", SourceKind: SourceKindURL,
				URL: srv.URL + "/good.kicad_mod", License: importLicense},
			wantKind: "ref", wantInMsg: "traversal"},

		// --- the source-combination refusals a schema cannot express --------
		{name: "no source_kind at all",
			req:      ImportRequest{Ref: "MyLib:PART_A", License: importLicense},
			wantKind: "args", wantInMsg: "is not an importer"},
		{name: "official_kicad is not importable",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: "official_kicad",
				URL: srv.URL + "/good.kicad_mod", License: importLicense},
			wantKind: "args", wantInMsg: "official_kicad is NOT importable"},
		{name: "a kind carrying another importer's field",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/good.kicad_mod", ArchivePath: goodZip, License: importLicense},
			wantKind: "args", wantInMsg: "does not take archive_path"},
		{name: "a kind missing its own field",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: "0123456789abcdef0123456789abcdef01234567",
				License: importLicense},
			wantKind: "args", wantInMsg: "requires path_in_repo"},

		// --- the URL importer's defenses ------------------------------------
		{name: "a redirect chain, refused at the first hop",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/moved.kicad_mod", License: importLicense},
			wantKind: "redirect", wantInMsg: "/hop2"},
		{name: "a body over the ceiling",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/huge.kicad_mod", License: importLicense},
			wantKind: "content", wantInMsg: "more than"},
		{name: "the wrong Content-Type",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/page.kicad_mod", License: importLicense},
			wantKind: "content", wantInMsg: "Content-Type"},
		{name: "markup wearing an allowed Content-Type",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/markup.kicad_mod", License: importLicense},
			wantKind: "content", wantInMsg: "markup"},
		{name: "a 404",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: srv.URL + "/nope.kicad_mod", License: importLicense},
			wantKind: "http", wantInMsg: "404"},
		{name: "a plaintext URL",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
				URL: "http://example.invalid/part.kicad_mod", License: importLicense},
			wantKind: "scheme", wantInMsg: "only https"},

		// --- the git importer's defenses ------------------------------------
		{name: "a branch name where a pin belongs",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: "main",
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod", License: importLicense},
			wantKind: "args", wantInMsg: "is not a full git object id"},
		{name: "an abbreviated object id",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: rev[:12],
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod", License: importLicense},
			wantKind: "args", wantInMsg: "is not a full git object id"},
		{name: "an ssh remote",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: "ssh://git@example.invalid/repo.git", GitRev: rev,
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod", License: importLicense},
			wantKind: "scheme", wantInMsg: "only https://"},
		{name: "an scp-style remote",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: "git@example.invalid:repo.git", GitRev: rev,
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod", License: importLicense},
			wantKind: "scheme", wantInMsg: "no scheme"},
		{name: "a git_url that would be read as an option",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: "--upload-pack=touch /tmp/pwned", GitRev: rev,
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod", License: importLicense},
			wantKind: "args", wantInMsg: "git would read it as an option"},
		{name: "a path that walks out of the repository",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: rev,
				PathInRepo: "../../../../etc/passwd.kicad_mod", License: importLicense},
			wantKind: "args", wantInMsg: "'..' segment"},
		{name: "a path that is not a footprint",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: rev, PathInRepo: "README.md", License: importLicense},
			wantKind: "args", wantInMsg: "does not end in .kicad_mod"},
		{name: "a revision that is not in this repository",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: "0123456789abcdef0123456789abcdef01234567",
				PathInRepo: "footprints/MyLib.pretty/Part_A.kicad_mod", License: importLicense},
			wantKind: "git", wantInMsg: "could not read"},
		{name: "a blob over the ceiling",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindGit,
				GitURL: repoURL, GitRev: rev,
				PathInRepo: "footprints/MyLib.pretty/Huge.kicad_mod", License: importLicense},
			wantKind: "content", wantInMsg: "larger than"},

		// --- the archive importer's defenses --------------------------------
		{name: "zip-slip — a '..' entry",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: zipSlip, License: importLicense},
			wantKind: "archive", wantInMsg: "zip-slip"},
		{name: "zip-slip — an absolute entry",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: zipAbs, License: importLicense},
			wantKind: "archive", wantInMsg: "absolute path"},
		{name: "zip-slip — a backslash entry",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: zipBackslash, License: importLicense},
			wantKind: "archive", wantInMsg: "backslash"},
		{name: "an archive with no footprint",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: zipNone, License: importLicense},
			wantKind: "archive", wantInMsg: "contains 0 .kicad_mod files"},
		{name: "an archive with several footprints",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: zipTwo, License: importLicense},
			wantKind: "archive", wantInMsg: "contains 2 .kicad_mod files"},
		{name: "an archive entry over the ceiling",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: zipHuge, License: importLicense},
			wantKind: "content", wantInMsg: "inflates to more than"},
		{name: "a file that is not a zip",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: notAZip, License: importLicense},
			wantKind: "archive", wantInMsg: "not a readable zip"},
		{name: "a relative archive path",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: "vendor.zip", License: importLicense},
			wantKind: "args", wantInMsg: "is relative"},
		{name: "an archive that is not there",
			req: ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindVendorExport,
				ArchivePath: filepath.Join(archiveDir, "absent.zip"), License: importLicense},
			wantKind: "archive", wantInMsg: "cannot read the vendor archive"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			out, err := ImportFootprint(tc.req)
			if err == nil {
				t.Fatalf("expected a refusal, got %+v", out)
			}
			ie, ok := err.(*ImportError)
			if !ok {
				t.Fatalf("expected *ImportError (the attributed refusal the tool turns into a "+
					"structured error), got %T: %v", err, err)
			}
			if ie.Kind != tc.wantKind {
				t.Errorf("kind = %q, want %q (message: %s)", ie.Kind, tc.wantKind, ie.Message)
			}
			if !strings.Contains(ie.Message, tc.wantInMsg) {
				t.Errorf("message does not mention %q: %s", tc.wantInMsg, ie.Message)
			}
			if out.Text != "" || out.SHA256 != "" {
				t.Errorf("a refusal must return no content at all, got %+v", out)
			}
			assertEmptyDir(t, dataDir, "after the refusal: "+tc.name)
		})
	}

	// The load-bearing half of the redirect case, and the reason the chain has
	// two hops: a refusal that still walked the chain has already let somebody
	// else choose the geometry a human is about to be shown and asked to
	// approve. Only zeros on BOTH counters say the import stopped at the
	// address the caller actually named.
	if n := atomic.LoadInt64(&hop2Hits); n != 0 {
		t.Errorf("the second hop was requested %d time(s); the FIRST redirect must be refused", n)
	}
	if n := atomic.LoadInt64(&elsewhereHits); n != 0 {
		t.Errorf("the redirect target received %d request(s); an import must never take bytes "+
			"from an address the caller did not name — the recorded provenance is what a human "+
			"blesses against", n)
	}

	// A server that is simply gone: an import failure blocks adding THIS part
	// and says so, rather than reading as a library outage. Resolution never
	// opens a socket.
	srv.Close()
	_, err = ImportFootprint(ImportRequest{Ref: "MyLib:PART_A", SourceKind: SourceKindURL,
		URL: srv.URL + "/good.kicad_mod", License: importLicense})
	if err == nil {
		t.Fatal("expected a refusal once the server is gone")
	} else if ie, ok := err.(*ImportError); !ok || ie.Kind != "network" {
		t.Fatalf("expected a network-kind ImportError, got %T: %v", err, err)
	} else if !strings.Contains(ie.Message, "RESOLUTION never does") {
		t.Errorf("a network refusal must state the offline contract: %s", ie.Message)
	}
	assertEmptyDir(t, dataDir, "after a network failure")
}

// TestImportFromArchive_DigestDescribesTheParsedSnapshot is the seal for
// Codex 1173 F3 (vendor-archive TOCTOU): the size gate, the provenance digest
// and the zip parse must all consume ONE captured read of the archive. The
// refactor makes that structural — importFromArchive reads the path exactly
// once and hands the same []byte to sha256 and to importFromZipBytes (which
// has no path to re-open) — and this test pins the observable half: the
// digest recorded in source_ref is the digest of the exact bytes the parser
// extracted the footprint from, computed here independently from the same
// on-disk file the importer was pointed at.
func TestImportFromArchive_DigestDescribesTheParsedSnapshot(t *testing.T) {
	dir := t.TempDir()
	archive := writeZip(t, filepath.Join(dir, "vendor.zip"),
		[][2]string{{"Part.kicad_mod", validKicadMod}})
	raw, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	wantDigest := fmt.Sprintf("%x", sha256.Sum256(raw))

	body, original, sourceRef, err := importFromArchive(archive, "Lib:Part")
	if err != nil {
		t.Fatalf("importFromArchive: %v", err)
	}
	if string(body) != validKicadMod {
		t.Fatalf("extracted bytes differ from the entry written")
	}
	if original != "Part.kicad_mod" {
		t.Fatalf("original = %q", original)
	}
	want := "vendor_export+vendor.zip@sha256:" + wantDigest + "!Part.kicad_mod"
	if sourceRef != want {
		t.Fatalf("source_ref = %q, want %q — the digest must describe the bytes the "+
			"parser consumed", sourceRef, want)
	}

	// The same snapshot fed directly (no filesystem at all): the parse result
	// is identical, which is what "the digest describes the parsed bytes"
	// means — there is no second read the digest could have described.
	body2, original2, entryName, err := importFromZipBytes(raw, archive, "Lib:Part")
	if err != nil {
		t.Fatalf("importFromZipBytes over the captured snapshot: %v", err)
	}
	if string(body2) != string(body) || original2 != original || entryName != "Part.kicad_mod" {
		t.Fatalf("snapshot parse disagrees with the path parse")
	}
}
