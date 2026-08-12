package libraries

// ARBITRARY-SOURCE IMPORT (B4, docket 019ff568b56b): the supply-chain surface.
//
// acquire.go fetches from ONE pinned upstream whose provenance is the whole
// reason its parts auto-bless. This file is the opposite case: a git repo, a
// direct URL, or a vendor-export archive the user downloaded — SnapEDA,
// UltraLibrarian, a manufacturer's site, somebody's GitHub. Nothing about those
// addresses earns trust, so an imported part is STAGED FOR HUMAN BLESS and
// nothing here can produce a blessed entry. That is the one difference from
// acquisition that everything else in this file exists to protect.
//
// GO READS; THE WORKER STAGES — the same split acquire.go documents, for the
// same reason. Network code is Go-only in this plugin, archive parsing is Go
// too (a zip reader in the worker would be a second place path traversal has to
// be defended), and NOTHING HERE WRITES: the bytes are returned, not staged, so
// "refused" and "wrote nothing" are the same statement on every path below.
//
// EVERY REFUSAL IS NAMED. An import is the one place an LLM caller hands this
// plugin an address of its own choosing, so a refusal that said only "import
// failed" would leave a human unable to tell a typo from an attack. Each check
// below carries the address it refused and why that shape is refusable.
//
// SOURCE KIND IS DECIDED HERE, never carried through from the caller's string:
// ImportFootprint sets ImportedFootprint.SourceKind from the branch it took, so
// the value the worker records is a fact about which importer ran. The worker
// refuses any kind outside the three anyway (methods.py _IMPORT_SOURCE_KINDS) —
// the same both-sides duplication SplitFootprintRef documents, because a check
// that lives only on the far side of a bridge is a check this side does not
// have.

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The three importers. Values are also what lands in the lock's `source_kind`,
// so they are exactly the LOCK_SOURCE_KINDS spellings the census test accepts
// (pcb_worker/footprints.py) — not a parallel vocabulary that has to be mapped.
const (
	SourceKindGit          = "git"
	SourceKindURL          = "url"
	SourceKindVendorExport = "vendor_export"
)

// Archive caps. A vendor export is a handful of files — a .kicad_mod, a symbol,
// a datasheet, sometimes a STEP model — so these are generous ceilings on the
// SHAPE of a legitimate archive rather than tuned limits, and each one refuses a
// different denial-of-service: the compressed cap bounds what is read off disk,
// the entry cap bounds how many names have to be walked, and the uncompressed
// cap bounds the decompression ratio a zip bomb trades on. The DECLARED
// uncompressed sizes are what the total is computed from (the zip central
// directory), so the bomb is refused before a single byte is inflated.
const (
	ArchiveMaxCompressedBytes = 64 << 20  // the .zip file itself
	ArchiveMaxTotalBytes      = 256 << 20 // sum of declared uncompressed sizes
	ArchiveMaxEntries         = 4096
)

// gitTimeout bounds the whole git side of one import — clone plus blob read.
// A clone of a footprint repo is seconds; this is the ceiling at which a hung
// transport (a server that accepts and never speaks) becomes a refusal instead
// of a stuck tool call.
const gitTimeout = 180 * time.Second

// urlContentTypes is the ALLOWLIST for a direct-URL import, and it is an
// allowlist rather than a "not text/html" denylist on purpose: fail-closed is
// the whole posture of this file, and a denylist has to enumerate every wrong
// answer a server can give while an allowlist enumerates the two right ones.
//
// Real .kicad_mod URLs serve text/plain (GitHub and GitLab raw) or
// application/octet-stream (most file hosts). An ABSENT Content-Type is also
// accepted: a header nobody sent cannot be evidence of anything, and the shape
// check (checkKicadModShape) still has to pass. A legitimate host that sends an
// unusual type is refused BY NAME with the type it sent, and the user's recourse
// is to download the file and import it as a vendor_export — a worse experience
// than guessing, and a much better one than staging an error page.
var urlContentTypes = map[string]bool{
	"text/plain":               true,
	"application/octet-stream": true,
}

// gitObjectID matches a FULL git object id (sha1 or sha256 repositories).
// Abbreviations are refused along with branch and tag names — see the refusal in
// checkGitRev for why a name is not a pin.
var gitObjectID = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

// ImportError is an attributed import refusal, the sibling of AcquireError.
// A SEPARATE type rather than a reused one because the two carry different
// consequences: an AcquireError means the pinned official upstream misbehaved
// (an operational event about this plugin's own dependency), while an
// ImportError almost always means the CALLER named something wrong. Kind
// classifies which next action the caller has:
//
//	ref      — the footprint ref is not a safe 'LibNick:PartName'
//	args     — the source arguments are missing, ambiguous, or malformed
//	license  — no license was stated (the policy gate; see ImportFootprint)
//	scheme   — the address uses a transport this importer will not speak
//	network  — the address could not be reached
//	http     — the server answered with something other than 200
//	content  — the bytes are not a plausible .kicad_mod
//	redirect — the address handed off to another one; not followed
//	git      — git itself refused (no such rev, no such path, clone failed)
//	archive  — the vendor archive is malformed, hostile, or ambiguous
//
// Source is the address or path that was refused, sanitized for a message.
type ImportError struct {
	Kind    string
	Message string
	Ref     string
	Source  string
}

func (e *ImportError) Error() string { return e.Message }

// ImportRequest is one import call, flattened. FLAT rather than nested under a
// `source` object because these fields are what the MCP tool schema declares and
// a nested object would have to be declared shape-for-shape anyway to survive
// the host's argument marshalling — with the combination rules still enforced
// here, by name, since no JSON schema can express "exactly these three fields
// when kind is git, and none of the others".
type ImportRequest struct {
	Ref         string
	SourceKind  string
	URL         string
	GitURL      string
	GitRev      string
	PathInRepo  string
	ArchivePath string
	License     string
}

// ImportedFootprint is one imported .kicad_mod plus the provenance the worker
// records against it. SourceKind is set by the importer that ran, never copied
// from the request. OriginalFilename is the name the file had AT ITS SOURCE
// (which the staged name is not — staging renames to <Part>.kicad_mod from the
// ref), and the worker preserves the source bytes under it; see the
// originals-directory note in pcb_worker/bless.py import_footprint.
type ImportedFootprint struct {
	Ref              string `json:"ref"`
	Lib              string `json:"lib"`
	Part             string `json:"part"`
	SourceKind       string `json:"source_kind"`
	SourceRef        string `json:"source_ref"`
	OriginalFilename string `json:"original_filename"`
	Text             string `json:"kicad_mod_text"`
	SHA256           string `json:"sha256"`
	SizeBytes        int64  `json:"size_bytes"`
	License          string `json:"license"`
}

// ImportFootprint reads ONE .kicad_mod from an arbitrary source and returns it
// with its provenance. It writes nothing and blesses nothing.
//
// ORDER: everything that can be refused from the ARGUMENTS ALONE is refused
// first — the ref, the license, the source-field combination — so a malformed
// call never opens a socket, spawns git, or reads a file off the user's disk.
// Only then does the importer for the named kind run.
//
// THE LICENSE GATE is here rather than at the worker because it is a policy
// refusal, not a validation one: the worker's stage_footprint already refuses an
// empty license, but by the time a call reaches it the bytes have been fetched
// and the user has been made to wait for a refusal that was decidable up front.
// Stating it here also puts the policy where the sources are, which is where a
// reader looks for "what is this plugin willing to take in".
func ImportFootprint(req ImportRequest) (ImportedFootprint, error) {
	lib, part, err := SplitFootprintRef(req.Ref)
	if err != nil {
		return ImportedFootprint{}, asImportError(err, req.Ref, "")
	}
	ref := strings.TrimSpace(req.Ref)

	if strings.TrimSpace(req.License) == "" {
		return ImportedFootprint{}, &ImportError{Kind: "license", Ref: ref,
			Message: "license is required and was not stated. An imported footprint carries " +
				"somebody else's terms, and an entry that cannot say which ones is a part this " +
				"plugin cannot answer for — the NOTICE inventory (pcb/NOTICE.md) is generated " +
				"from exactly this field. State the SPDX id or a LicenseRef; there is no " +
				"'unknown' value on purpose"}
	}

	kind := strings.TrimSpace(req.SourceKind)
	if err := checkSourceFields(kind, req, ref); err != nil {
		return ImportedFootprint{}, err
	}

	var (
		body      []byte
		original  string
		sourceRef string
		source    string
	)
	switch kind {
	case SourceKindURL:
		source = strings.TrimSpace(req.URL)
		body, original, sourceRef, err = importFromURL(source, ref)
	case SourceKindGit:
		source = strings.TrimSpace(req.GitURL)
		body, original, sourceRef, err = importFromGit(
			source, strings.TrimSpace(req.GitRev), strings.TrimSpace(req.PathInRepo), ref)
	case SourceKindVendorExport:
		source = strings.TrimSpace(req.ArchivePath)
		body, original, sourceRef, err = importFromArchive(source, ref)
	}
	if err != nil {
		return ImportedFootprint{}, err
	}

	if err := checkKicadModShape(body, ref, source); err != nil {
		return ImportedFootprint{}, asImportError(err, ref, source)
	}
	if err := checkOriginalFilename(original, ref, source); err != nil {
		return ImportedFootprint{}, err
	}

	sum := sha256.Sum256(body)
	return ImportedFootprint{
		Ref:              ref,
		Lib:              lib,
		Part:             part,
		SourceKind:       kind,
		SourceRef:        sourceRef,
		OriginalFilename: original,
		Text:             string(body),
		SHA256:           hex.EncodeToString(sum[:]),
		SizeBytes:        int64(len(body)),
		License:          strings.TrimSpace(req.License),
	}, nil
}

// checkSourceFields refuses an unknown kind, a kind whose own fields are
// missing, and — the case a JSON schema cannot state — a kind carrying ANOTHER
// kind's fields.
//
// The cross-field refusal is not pedantry. {kind:"url", url:X, archive_path:Y}
// is a caller that does not know which source it means, and silently honouring
// the one the switch happens to read would import from X while the caller's
// notes, and any human reading the call, say Y. Refusing BY FIELD NAME says
// which of the two to delete.
func checkSourceFields(kind string, req ImportRequest, ref string) error {
	type field struct {
		name  string
		value string
	}
	all := []field{
		{"url", strings.TrimSpace(req.URL)},
		{"git_url", strings.TrimSpace(req.GitURL)},
		{"git_rev", strings.TrimSpace(req.GitRev)},
		{"path_in_repo", strings.TrimSpace(req.PathInRepo)},
		{"archive_path", strings.TrimSpace(req.ArchivePath)},
	}
	// Ordered, not a map: a call with several fields wrong must always name the
	// same one first, or the refusal text changes run to run.
	owned := map[string][]string{
		SourceKindURL:          {"url"},
		SourceKindGit:          {"git_url", "git_rev", "path_in_repo"},
		SourceKindVendorExport: {"archive_path"},
	}
	mine, ok := owned[kind]
	if !ok {
		return &ImportError{Kind: "args", Ref: ref,
			Message: fmt.Sprintf("source_kind %q is not an importer; expected one of %s/%s/%s. "+
				"official_kicad is NOT importable here — it is the auto-blessing provenance "+
				"minerva_pcb_acquire_footprint owns, and this tool cannot produce a blessed entry "+
				"under any source_kind", kind, SourceKindGit, SourceKindURL, SourceKindVendorExport)}
	}
	isMine := map[string]bool{}
	for _, name := range mine {
		isMine[name] = true
	}
	for _, f := range all {
		if isMine[f.name] {
			if f.value == "" {
				return &ImportError{Kind: "args", Ref: ref,
					Message: fmt.Sprintf("source_kind %q requires %s, which is missing or empty "+
						"(it needs %s)", kind, f.name, strings.Join(mine, " + "))}
			}
			continue
		}
		if f.value != "" {
			return &ImportError{Kind: "args", Ref: ref,
				Message: fmt.Sprintf("source_kind %q does not take %s (that field belongs to a "+
					"different importer); a call carrying both its own source and another one's "+
					"does not say which source it means. Drop %s, or change source_kind",
					kind, f.name, f.name)}
		}
	}
	return nil
}

// checkOriginalFilename refuses a source-side filename that could not become a
// safe path component.
//
// This name is NOT cosmetic and NOT discarded: the worker preserves the source
// bytes at <wip_root>/originals/<Lib>.pretty/<Part>/<name>, so the name a git
// repo or a zip archive chose becomes a filesystem path on this machine. The
// worker's import_footprint refuses the same shapes for the same reason (the
// SplitFootprintRef duplication argument), so neither side is the weak one.
func checkOriginalFilename(name, ref, source string) error {
	if strings.TrimSpace(name) == "" {
		return &ImportError{Kind: "content", Ref: ref, Source: source,
			Message: fmt.Sprintf("could not derive a filename for the original source bytes from "+
				"%q; the original is preserved under its SOURCE name and there is nothing here to "+
				"use", source)}
	}
	if name == "." || name == ".." || strings.ContainsAny(name, "/\\\x00") {
		return &ImportError{Kind: "content", Ref: ref, Source: source,
			Message: fmt.Sprintf("the source filename %q contains a path separator or traversal "+
				"segment; it becomes a path component under the WIP originals directory and must "+
				"not be able to escape it", name)}
	}
	return nil
}

// asImportError re-attributes a refusal raised by the shared acquisition
// helpers (SplitFootprintRef, checkKicadModShape) as an import refusal. The
// KIND carries across unchanged — "ref" and "content" mean the same thing on
// both surfaces — so this only changes who the error says it came from, never
// what it says is wrong.
func asImportError(err error, ref, source string) error {
	var ae *AcquireError
	if errors.As(err, &ae) {
		return &ImportError{Kind: ae.Kind, Message: ae.Message, Ref: ref, Source: source}
	}
	return &ImportError{Kind: "args", Message: err.Error(), Ref: ref, Source: source}
}

// ---------------------------------------------------------------------------
// url: one .kicad_mod at an address the caller names.
// ---------------------------------------------------------------------------

// importFromURL GETs rawURL and returns its bytes, the filename the URL implies,
// and the provenance string to record.
//
// It reuses acquisitionClient() — the redirect-refusing client from acquire.go —
// because the POLICY is identical even though the consequence is not: there,
// following a hop would let arbitrary bytes inherit an official_kicad
// auto-bless; here it would let them inherit the address a HUMAN is about to be
// shown as the thing they are approving. Both are the same mistake, that the
// only thing backing an address claim is the address we asked for.
func importFromURL(rawURL, ref string) ([]byte, string, string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, "", "", &ImportError{Kind: "args", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("url %q is not a URL: %v", rawURL, err)}
	}
	if u.Scheme != "https" {
		return nil, "", "", &ImportError{Kind: "scheme", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("url %q uses scheme %q; only https is imported. A plaintext or "+
				"non-web transport gives a network position the ability to choose the footprint "+
				"geometry a human is then shown and asked to approve", rawURL, u.Scheme)}
	}
	if u.Host == "" {
		return nil, "", "", &ImportError{Kind: "args", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("url %q names no host", rawURL)}
	}

	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", "", &ImportError{Kind: "network", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("cannot build a request for %s: %v", rawURL, err)}
	}
	resp, err := acquisitionClient().Do(req)
	if err != nil {
		var moved *redirectRefused
		if errors.As(err, &moved) {
			return nil, "", "", &ImportError{Kind: "redirect", Ref: ref, Source: rawURL,
				Message: fmt.Sprintf("GET %s was redirected to %s and the redirect was NOT "+
					"followed. An import records the address the caller named as the provenance a "+
					"human blesses against, so bytes taken from somewhere else would be filed "+
					"under an address that never served them. Import %s directly if that is the "+
					"source you mean", rawURL, moved.To, moved.To)}
		}
		return nil, "", "", &ImportError{Kind: "network", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("GET %s failed: %v. Importing needs network access to that host; "+
				"RESOLUTION never does — already-imported parts resolve from sha-pinned bytes on "+
				"disk, so this blocks adding %s and nothing else", rawURL, err, ref)}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, "", "", &ImportError{Kind: "http", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("GET %s: unexpected status %s", rawURL, resp.Status)}
	}
	if err := checkURLContentType(resp.Header.Get("Content-Type"), rawURL, ref); err != nil {
		return nil, "", "", err
	}

	// One byte past the ceiling, so "exactly at the limit" and "over it" are
	// distinguishable and an oversized body is refused without ever being
	// buffered whole.
	body, err := io.ReadAll(io.LimitReader(resp.Body, FootprintMaxBytes+1))
	if err != nil {
		return nil, "", "", &ImportError{Kind: "network", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("reading %s failed mid-stream: %v (nothing was staged)", rawURL, err)}
	}
	if len(body) > FootprintMaxBytes {
		return nil, "", "", &ImportError{Kind: "content", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("%s returned more than %d bytes; a .kicad_mod is KB-scale, so an "+
				"oversized body is an archive, a directory listing, or an error page rather than a "+
				"footprint. If it IS an archive, import it as source_kind=%s",
				rawURL, FootprintMaxBytes, SourceKindVendorExport)}
	}

	return body, path.Base(u.Path), "url+" + rawURL, nil
}

// checkURLContentType applies the urlContentTypes allowlist. Parameters
// (charset) are ignored: they say how to decode text, not what kind of thing it
// is, and the UTF-8 check in checkKicadModShape is the real decoder gate.
func checkURLContentType(header, rawURL, ref string) error {
	if strings.TrimSpace(header) == "" {
		return nil
	}
	media, _, err := mime.ParseMediaType(header)
	if err != nil {
		return &ImportError{Kind: "content", Ref: ref, Source: rawURL,
			Message: fmt.Sprintf("%s answered with an unparseable Content-Type %q: %v",
				rawURL, header, err)}
	}
	if urlContentTypes[strings.ToLower(media)] {
		return nil
	}
	return &ImportError{Kind: "content", Ref: ref, Source: rawURL,
		Message: fmt.Sprintf("%s answered with Content-Type %q; a direct footprint import accepts "+
			"only text/plain or application/octet-stream (or no Content-Type at all). %q is what a "+
			"server sends when the address resolves to a page, an archive or an API response "+
			"rather than to the file — download it and import the file as source_kind=%s if it "+
			"really is a footprint", rawURL, media, media, SourceKindVendorExport)}
}

// ---------------------------------------------------------------------------
// git: one blob, at one pinned revision.
// ---------------------------------------------------------------------------

// importFromGit clones gitURL with NO WORKING TREE and reads exactly one blob
// out of the object store at gitRev.
//
// WHY THE git CLI rather than an HTTPS raw fetch: a raw fetch would work for the
// two forges whose raw-URL layout we happen to know, and would silently not work
// for every other git host — including a plain self-hosted repo, which is
// exactly the "arbitrary source" case this importer exists for. git speaks to
// all of them, and it is the only thing that can resolve a full object id
// against the actual object graph. The cost is a subprocess, and it is paid
// under the hardening below rather than by trusting the local environment.
//
// WHY --no-checkout: a checkout materializes attacker-named paths, attacker
// symlinks and attacker file modes on this machine before anything has been
// validated. `cat-file blob` reads ONE object out of the object store and writes
// nothing outside the temp clone, so the hostile-name surface of a repository
// never touches the filesystem at all.
//
// THE ENVIRONMENT IS REPLACED, not inherited. HOME points into the temp
// directory and GIT_CONFIG_NOSYSTEM is set, so neither the user's ~/.gitconfig
// nor /etc/gitconfig can apply a `url.<base>.insteadOf` rewrite — that is a
// config-file redirect, and a redirect is precisely what the URL importer above
// refuses to follow; it would be incoherent to refuse it over HTTP and accept it
// from a config file. GIT_TERMINAL_PROMPT=0 turns a private repo into a prompt
// refusal instead of a hung tool call, and GIT_ALLOW_PROTOCOL re-states the
// scheme allowlist at the transport layer so a submodule or a redirect inside
// git itself cannot reach a protocol the textual check refused.
func importFromGit(gitURL, gitRev, pathInRepo, ref string) ([]byte, string, string, error) {
	if err := checkGitURL(gitURL, ref); err != nil {
		return nil, "", "", err
	}
	if err := checkGitRev(gitRev, ref, gitURL); err != nil {
		return nil, "", "", err
	}
	if err := checkPathInRepo(pathInRepo, ref, gitURL); err != nil {
		return nil, "", "", err
	}

	gitBin, err := exec.LookPath("git")
	if err != nil {
		return nil, "", "", &ImportError{Kind: "git", Ref: ref, Source: gitURL,
			Message: "git is not on PATH, so a git-source import cannot run. Clone the repository " +
				"yourself and import the file with source_kind=url or " + SourceKindVendorExport}
	}

	tmp, err := os.MkdirTemp("", "pcb-import-git-")
	if err != nil {
		return nil, "", "", &ImportError{Kind: "git", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("cannot create a temporary directory for the clone: %v", err)}
	}
	defer os.RemoveAll(tmp)
	repo := filepath.Join(tmp, "repo")

	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()
	env := []string{
		"HOME=" + tmp,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ALLOW_PROTOCOL=https:file",
		"PATH=" + filepath.Dir(gitBin),
	}

	clone := exec.CommandContext(ctx, gitBin, "clone", "--quiet", "--no-checkout",
		"-c", "core.symlinks=false", "--", gitURL, repo)
	clone.Env = env
	var cloneErr bytes.Buffer
	clone.Stderr = &cloneErr
	if err := clone.Run(); err != nil {
		return nil, "", "", &ImportError{Kind: "git", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git clone of %s failed: %v. git said: %s", gitURL, err,
				firstBytes(strings.TrimSpace(cloneErr.String())))}
	}

	// The size ceiling is enforced on the STREAM, not on a declared size: git
	// reports the blob size honestly, but a bound that depends on the source
	// agreeing to be bounded is not a bound.
	out := &cappedBuffer{limit: FootprintMaxBytes + 1}
	var catErr bytes.Buffer
	cat := exec.CommandContext(ctx, gitBin, "-C", repo, "cat-file", "blob", gitRev+":"+pathInRepo)
	cat.Env = env
	cat.Stdout = out
	cat.Stderr = &catErr
	runErr := cat.Run()
	if out.over {
		return nil, "", "", &ImportError{Kind: "content", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("%s at %s:%s is larger than %d bytes; a .kicad_mod is KB-scale, so "+
				"an oversized blob is an archive or a bundle rather than a footprint",
				pathInRepo, gitURL, gitRev, FootprintMaxBytes)}
	}
	if runErr != nil {
		return nil, "", "", &ImportError{Kind: "git", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git could not read %s at revision %s of %s: %v. git said: %s. "+
				"Either the revision is not in this repository or nothing is at that path in it",
				pathInRepo, gitRev, gitURL, runErr, firstBytes(strings.TrimSpace(catErr.String())))}
	}

	sourceRef := fmt.Sprintf("git+%s@%s:%s", gitURL, gitRev, pathInRepo)
	return out.buf.Bytes(), path.Base(pathInRepo), sourceRef, nil
}

// checkGitURL restricts what git will be pointed at. https for a real remote,
// file for a repository already on this machine (which is also what makes the
// git flow testable without a network).
//
// The leading-dash refusal is separate from the scheme one because it is a
// different attack: an argument beginning with '-' is read by git as an OPTION,
// and options like --upload-pack= execute a command. The `--` separator in the
// clone above already stops that, and this refuses it anyway — the two guards
// must not both be able to go missing in one edit.
func checkGitURL(gitURL, ref string) error {
	if strings.HasPrefix(gitURL, "-") {
		return &ImportError{Kind: "args", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git_url %q begins with '-'; git would read it as an option, and "+
				"some git options name a command to run", gitURL)}
	}
	if strings.ContainsAny(gitURL, "\x00\n\r") {
		return &ImportError{Kind: "args", Ref: ref, Source: gitURL,
			Message: "git_url contains a control character"}
	}
	u, err := url.Parse(gitURL)
	if err != nil {
		return &ImportError{Kind: "args", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git_url %q is not a URL: %v", gitURL, err)}
	}
	switch u.Scheme {
	case "https":
		if u.Host == "" {
			return &ImportError{Kind: "args", Ref: ref, Source: gitURL,
				Message: fmt.Sprintf("git_url %q names no host", gitURL)}
		}
		return nil
	case "file":
		return nil
	case "":
		return &ImportError{Kind: "scheme", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git_url %q has no scheme; scp-style addresses (user@host:path) "+
				"are not accepted because what they mean depends on the local ssh configuration. "+
				"Use an https:// URL, or file:// for a repository already on this machine", gitURL)}
	default:
		return &ImportError{Kind: "scheme", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git_url %q uses scheme %q; only https:// (a remote) and file:// "+
				"(a repository already on this machine) are imported. git:// and ssh:// carry no "+
				"transport authentication we can state to the human who blesses the result, and "+
				"ext:: names a command to run", gitURL, u.Scheme)}
	}
}

// checkGitRev requires a FULL object id. A branch or tag name is refused, and
// that refusal is the point of the whole importer: the lock records what was
// imported so a future reader can get the same bytes back, and a name resolves
// to different bytes on different days. An abbreviation is refused for the
// weaker version of the same reason — it is a prefix, and a prefix is not an
// identity.
func checkGitRev(gitRev, ref, gitURL string) error {
	if !gitObjectID.MatchString(gitRev) {
		return &ImportError{Kind: "args", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("git_rev %q is not a full git object id (40 lowercase hex "+
				"characters, or 64 for a sha256 repository). A branch or tag name is NOT a pin: it "+
				"resolves to different bytes as the repository moves, so the provenance recorded "+
				"against a human's bless would stop describing what they approved", gitRev)}
	}
	return nil
}

// checkPathInRepo refuses a path that could not name one file inside a
// repository. The `..` and absolute refusals are not about this machine (nothing
// is checked out) but about the SOURCE REF: a path that walks out of the tree
// describes a location the recorded provenance cannot be read back against.
func checkPathInRepo(p, ref, gitURL string) error {
	bad := func(why string) error {
		return &ImportError{Kind: "args", Ref: ref, Source: gitURL,
			Message: fmt.Sprintf("path_in_repo %q %s; it must be a repository-relative path to "+
				"one .kicad_mod file, e.g. 'footprints/MyLib.pretty/Part.kicad_mod'", p, why)}
	}
	switch {
	case strings.ContainsAny(p, "\x00\n\r"):
		return bad("contains a control character")
	case strings.HasPrefix(p, "-"):
		return bad("begins with '-', which git reads as an option")
	case strings.HasPrefix(p, "/") || filepath.IsAbs(p):
		return bad("is absolute")
	case strings.Contains(p, "\\"):
		return bad("contains a backslash (git paths use '/')")
	case hasDotDotSegment(p):
		return bad("contains a '..' segment")
	case !strings.HasSuffix(strings.ToLower(p), ".kicad_mod"):
		return bad("does not end in .kicad_mod")
	}
	return nil
}

// cappedBuffer collects at most limit bytes and FAILS the write past it, which
// is what makes the cap a real bound on a subprocess: returning an error from
// Write breaks the child's stdout pipe, so git exits promptly instead of the
// parent having to stop reading and then wait on a process blocked writing.
type cappedBuffer struct {
	limit int
	buf   bytes.Buffer
	over  bool
}

var errCappedBufferFull = errors.New("output exceeded the size ceiling")

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if c.buf.Len()+len(p) > c.limit {
		c.over = true
		return 0, errCappedBufferFull
	}
	return c.buf.Write(p)
}

// ---------------------------------------------------------------------------
// vendor_export: one .kicad_mod out of an archive already on this disk.
// ---------------------------------------------------------------------------

// importFromArchive reads a LOCAL vendor-export zip (SnapEDA, UltraLibrarian, a
// manufacturer's download) and extracts the single .kicad_mod inside it.
//
// LOCAL ONLY, deliberately: these archives sit behind logins, click-throughs and
// captchas, so the download is a thing the human already did. That also keeps
// the whole archive surface — the part of this file with the most defenses —
// off the network.
//
// NOTHING IS EXTRACTED TO DISK. One entry's bytes are read into memory and
// returned; no other entry is decompressed at all. Zip-slip is still refused
// over EVERY name in the archive (not merely the one read) for two reasons: the
// matched entry's base name DOES become a path component when the worker
// preserves the original, and a single escaping name is evidence about the
// archive rather than about that entry — an archive built to escape is not one
// to take a footprint out of.
func importFromArchive(archivePath, ref string) ([]byte, string, string, error) {
	if !filepath.IsAbs(archivePath) {
		return nil, "", "", &ImportError{Kind: "args", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("archive_path %q is relative; it must be an absolute path. The "+
				"plugin's working directory is not the one the archive was downloaded into, so a "+
				"relative path names a different file here than it does to the caller", archivePath)}
	}
	// ONE open, ONE read (Codex 1173 F3): the size cap, the provenance digest
	// and the zip parse all consume THIS captured snapshot. Stat-then-hash-
	// then-open would be three independent path resolutions, and a path
	// swapped between any two of them yields a source_ref digest describing an
	// archive other than the one that was parsed — the exact lie the digest
	// exists to make impossible. O_NOFOLLOW is not used on purpose: a symlink
	// to the real download is a legitimate caller shape, and following it ONCE
	// is safe precisely because nothing re-resolves the path afterwards.
	f, err := os.Open(archivePath)
	if err != nil {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("cannot read the vendor archive %s: %v", archivePath, err)}
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("cannot read the vendor archive %s: %v", archivePath, err)}
	} else if !st.Mode().IsRegular() {
		// Advisory-only precheck on the OPEN handle (same inode the read
		// consumes): the real bound is the capped read below.
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s is not a regular file", archivePath)}
	}
	data, err := io.ReadAll(io.LimitReader(f, ArchiveMaxCompressedBytes+1))
	if err != nil {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("reading the vendor archive %s failed: %v", archivePath, err)}
	}
	if int64(len(data)) > ArchiveMaxCompressedBytes {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s is more than %d bytes; vendor exports are capped there. A "+
				"larger file is a library dump or a full distribution rather than one part's export",
				archivePath, ArchiveMaxCompressedBytes)}
	}
	body, original, entryName, err := importFromZipBytes(data, archivePath, ref)
	if err != nil {
		return nil, "", "", err
	}
	sum := sha256.Sum256(data)
	sourceRef := fmt.Sprintf("vendor_export+%s@sha256:%s!%s",
		filepath.Base(archivePath), hex.EncodeToString(sum[:]), entryName)
	return body, original, sourceRef, nil
}

// importFromZipBytes parses ONE captured zip snapshot and extracts its single
// .kicad_mod. Split from importFromArchive so the single-snapshot property is
// structural (this function has no path to re-open) and directly testable:
// hand it bytes, and the digest importFromArchive records is by construction
// the digest of exactly what this function parsed.
func importFromZipBytes(data []byte, archivePath, ref string) ([]byte, string, string, error) {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s is not a readable zip archive: %v. Vendor exports are .zip; a "+
				"bare .kicad_mod is imported with source_kind=%s or %s",
				archivePath, err, SourceKindURL, SourceKindGit)}
	}

	if len(zr.File) > ArchiveMaxEntries {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s declares %d entries; vendor exports are capped at %d",
				archivePath, len(zr.File), ArchiveMaxEntries)}
	}

	var (
		total      uint64
		candidates []*zip.File
	)
	for _, f := range zr.File {
		if err := checkArchiveEntryName(f.Name, archivePath, ref); err != nil {
			return nil, "", "", err
		}
		// Compare BEFORE adding (Codex 1173 F3): UncompressedSize64 is
		// attacker-declared, and two entries near math.MaxUint64 would wrap
		// the running sum back under the cap if the add came first.
		if f.UncompressedSize64 > ArchiveMaxTotalBytes-total {
			return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
				Message: fmt.Sprintf("%s declares more than %d bytes of uncompressed content; that "+
					"compression ratio is a zip bomb, not a footprint export. Refused from the "+
					"central directory, so nothing was inflated", archivePath, ArchiveMaxTotalBytes)}
		}
		total += f.UncompressedSize64
		if f.FileInfo().IsDir() || !strings.HasSuffix(strings.ToLower(f.Name), ".kicad_mod") {
			continue
		}
		candidates = append(candidates, f)
	}

	if len(candidates) != 1 {
		names := make([]string, 0, len(candidates))
		for _, f := range candidates {
			names = append(names, f.Name)
		}
		detail := "none"
		if len(names) > 0 {
			detail = strings.Join(names, ", ")
		}
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s contains %d .kicad_mod files (%s); an import stages exactly "+
				"one part under one ref, and choosing among several on the caller's behalf would "+
				"pick the geometry a human then blesses. Unzip it and import the one you mean with "+
				"source_kind=%s", archivePath, len(candidates), detail, SourceKindURL)}
	}

	entry := candidates[0]
	if !entry.FileInfo().Mode().IsRegular() {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s: entry %q is not a regular file (mode %s); a symlink or device "+
				"entry has no footprint bytes to read", archivePath, entry.Name,
				entry.FileInfo().Mode())}
	}

	rc, err := entry.Open()
	if err != nil {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s: cannot read entry %q: %v", archivePath, entry.Name, err)}
	}
	defer rc.Close()
	// LimitReader over the DECLARED size again: UncompressedSize64 is a number
	// the archive states about itself, and this is the only bound that holds
	// when it lies.
	body, err := io.ReadAll(io.LimitReader(rc, FootprintMaxBytes+1))
	if err != nil {
		return nil, "", "", &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s: reading entry %q failed: %v", archivePath, entry.Name, err)}
	}
	if len(body) > FootprintMaxBytes {
		return nil, "", "", &ImportError{Kind: "content", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s: entry %q inflates to more than %d bytes; a .kicad_mod is "+
				"KB-scale", archivePath, entry.Name, FootprintMaxBytes)}
	}

	return body, path.Base(entry.Name), entry.Name, nil
}

// checkArchiveEntryName is the zip-slip gate: an entry name that resolves
// anywhere other than inside the archive's own tree is refused, and the whole
// import with it.
//
// Zip names are '/'-separated by specification, so a backslash is not a
// separator this reader would honour — which is exactly why it is refused: it is
// a separator on the OTHER platform this plugin ships to, and a name that means
// two different things on two platforms cannot be checked once.
func checkArchiveEntryName(name, archivePath, ref string) error {
	bad := func(why string) error {
		return &ImportError{Kind: "archive", Ref: ref, Source: archivePath,
			Message: fmt.Sprintf("%s contains an entry named %q, which %s (zip-slip). The matched "+
				"entry's own name becomes a path component when the original source bytes are "+
				"preserved, and an archive that contains an escaping name is refused whole rather "+
				"than entry by entry", archivePath, name, why)}
	}
	switch {
	case strings.TrimSpace(name) == "":
		return bad("is empty")
	case strings.ContainsRune(name, '\x00'):
		return bad("contains a NUL byte")
	case strings.Contains(name, "\\"):
		return bad("contains a backslash, which is a path separator on Windows")
	case strings.HasPrefix(name, "/"):
		return bad("is an absolute path")
	case len(name) >= 2 && name[1] == ':':
		return bad("begins with a drive letter")
	case hasDotDotSegment(name):
		return bad("contains a '..' segment")
	case strings.HasPrefix(path.Clean(name), "../") || path.Clean(name) == "..":
		return bad("resolves outside the archive tree")
	}
	return nil
}

// hasDotDotSegment reports whether p has a literal ".." PATH SEGMENT, under both
// separators. Segment-wise rather than a substring search, so a legitimate name
// like "Vendor..Export.kicad_mod" is not refused for containing the characters.
func hasDotDotSegment(p string) bool {
	for _, seg := range strings.FieldsFunc(p, func(r rune) bool { return r == '/' || r == '\\' }) {
		if seg == ".." {
			return true
		}
	}
	return false
}
