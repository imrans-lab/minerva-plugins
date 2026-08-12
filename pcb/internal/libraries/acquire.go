package libraries

// ACQUISITION: one official KiCad footprint, on demand (S4/B3, docket 019ff5689732).
//
// FetchAll (fetch.go) downloads the WHOLE curated subset named by
// libraries.lock.json. This file is its per-part sibling: a caller who wants
// ONE footprint that the curated subset never listed asks for it by ref, and
// this fetches exactly that file from the SAME pinned upstream release.
//
// THE PIN IS READ, NEVER RESTATED. The release tag and the footprints repo both
// come out of libraries.lock.json (`tag` / `source.footprints_repo`), which is
// the single source of truth for WHICH official KiCad release this plugin
// tracks. A tag literal here would be a second authority that silently disagrees
// with the lock the moment the lock is regenerated, and the disagreement would
// show up as parts from two different releases sitting in one board.
//
// NOTHING HERE WRITES. The fetched bytes are returned, not staged: staging is
// the Python worker's B2 machinery (pcb_worker/bless.py), which parse-validates
// before it writes and owns the acquisition lock. A second staging path in Go
// would be a second place the bless gate could be forgotten. Go fetches; the
// worker stages and auto-blesses. That split is also why every refusal below is
// a plain error: with no writes to undo, "refused" and "wrote nothing" are the
// same statement.
//
// THE OFFLINE CONTRACT. Acquisition is the ONLY library operation that needs a
// network. Resolution — every compile, DRC, gerber and report path — reads
// already-acquired, sha-pinned bytes off disk and never opens a socket. So a
// network failure here is reported as a failure to ACQUIRE a new part, never as
// a library outage: existing boards keep resolving.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"
)

// FootprintMaxBytes bounds one acquired .kicad_mod. Real footprints are a few
// hundred bytes to a few tens of KB; the largest in the shipped seed library is
// under 20 KB. 1 MiB is ~50x the worst real case and still small enough that an
// HTML page, a tarball, or a repo-root listing is refused rather than buffered
// into memory and handed to a parser.
const FootprintMaxBytes = 1 << 20

// FootprintLicense is the license every file in kicad-footprints carries
// (LICENSE.md at the repo root). Recorded on the acquisition-lock entry so the
// provenance of a part is answerable without re-visiting the source.
const FootprintLicense = "CC-BY-SA-4.0 WITH KiCad-libraries-exception"

// AcquireError is an attributed acquisition refusal. Kind classifies WHY, so a
// caller can tell apart "you asked for something malformed" (ref), "this plugin
// install is broken" (lock), "the network is down" (network), "the server
// answered with something that is not a footprint" (http/content) and "the
// pinned upstream tried to send us somewhere else" (redirect) — five different
// next actions. URL is empty for refusals raised before a URL exists.
//
// "redirect" is deliberately its OWN kind rather than folded into "http": every
// other kind describes something the pinned upstream said about the part, while
// a redirect describes the ADDRESS changing out from under the pin. That is an
// operational event about this plugin's upstream — it means the lock's
// source.footprints_repo now points at a mover — and it must be readable as such
// instead of hiding among 404s.
type AcquireError struct {
	Kind    string // "ref" | "lock" | "network" | "http" | "content" | "redirect"
	Message string
	Ref     string
	URL     string
}

func (e *AcquireError) Error() string { return e.Message }

// FetchedFootprint is one acquired .kicad_mod, verified as far as bytes can be
// verified WITHOUT parsing (which is the worker's job). SHA256 is computed over
// the bytes as they came off the wire; the worker recomputes it independently
// over the text it receives and refuses on disagreement, so a corruption in the
// bridge cannot land in the lock as a valid pin.
type FetchedFootprint struct {
	Ref       string `json:"ref"`
	Lib       string `json:"lib"`
	Part      string `json:"part"`
	Tag       string `json:"tag"`
	URL       string `json:"url"`
	Text      string `json:"kicad_mod_text"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"size_bytes"`
	SourceRef string `json:"source_ref"`
	License   string `json:"license"`
}

// SplitFootprintRef splits "LibNick:PartName" into its halves, refusing
// anything that could not become a safe relative path.
//
// These refusals mirror pcb_worker/bless.py's _split_ref one for one, and the
// duplication is deliberate: the ref becomes a URL PATH here and a FILESYSTEM
// PATH there, the caller is an LLM, and a check that lives only on the far side
// of a network fetch is a check the fetch itself does not have. Both sides
// refuse the same shapes, so neither can be the weak one.
func SplitFootprintRef(ref string) (string, string, error) {
	trimmed := strings.TrimSpace(ref)
	if trimmed == "" {
		return "", "", &AcquireError{Kind: "ref", Ref: ref,
			Message: "footprint ref must be a non-empty 'LibNick:PartName' string"}
	}
	if strings.Count(trimmed, ":") != 1 {
		return "", "", &AcquireError{Kind: "ref", Ref: ref,
			Message: fmt.Sprintf("footprint ref %q must be exactly 'LibNick:PartName' (one ':'); "+
				"the library nickname names the .pretty directory upstream", ref)}
	}
	parts := strings.SplitN(trimmed, ":", 2)
	lib, part := parts[0], parts[1]
	// Ordered, not a map: a ref with BOTH halves malformed must always name the
	// same one first, or the refusal text changes run to run.
	for _, half := range []struct{ label, value string }{
		{"library nickname", lib}, {"part name", part},
	} {
		label, value := half.label, half.value
		if value == "" {
			return "", "", &AcquireError{Kind: "ref", Ref: ref,
				Message: fmt.Sprintf("footprint ref %q has an empty %s", ref, label)}
		}
		if value == "." || value == ".." ||
			strings.ContainsAny(value, "/\\") || strings.ContainsAny(value, "\x00") {
			return "", "", &AcquireError{Kind: "ref", Ref: ref,
				Message: fmt.Sprintf("footprint ref %q has a %s (%q) containing a path separator or "+
					"traversal segment; the ref becomes a URL path upstream and a file path under the "+
					"WIP root, and must not be able to escape either", ref, label, value)}
		}
		// Belt to the escaping's braces. FootprintRawURL percent-escapes both
		// halves, so "..%2f.." can no longer reach upstream as a separator — but
		// the checks above are TEXTUAL, and a '%' is the one character that lets
		// a half mean something other than what it reads as. Upstream footprint
		// libraries and part names never contain one, so refusing is free here
		// and keeps this function's refusals true of the literal ref rather than
		// true only after somebody else escapes it.
		if strings.Contains(value, "%") {
			return "", "", &AcquireError{Kind: "ref", Ref: ref,
				Message: fmt.Sprintf("footprint ref %q has a %s (%q) containing a percent sign; "+
					"percent-encoding is how a separator or traversal segment hides from a textual "+
					"check, and no official KiCad %s contains one", ref, label, value, label)}
		}
	}
	return lib, part, nil
}

// FootprintRawURL builds the GitLab raw-blob URL for one footprint at a pinned
// tag — the same shape scripts/gen_libraries_lock.py writes into the lock
// (RAW_URL_FMT), so an acquired part and a locked one come from byte-identical
// addressing rather than two hand-built conventions that can drift apart.
//
// The lib and part segments are PERCENT-ESCAPED, not interpolated raw. They
// originate in a ref an LLM handed us, and SplitFootprintRef's refusals are
// textual: escaping is what makes those textual refusals also true of the
// resulting URL PATH, so a segment cannot decode upstream into separators the
// check never saw. For every legal ref — the alphanumerics, underscores, dots
// and hyphens real KiCad names are made of — escaping is the identity function,
// so the addressing stays byte-identical to the lock's. The tag is not escaped:
// it comes from the plugin's own lock manifest, not from a caller, and it is the
// one field whose exact bytes the lock is the authority for.
func FootprintRawURL(repo, tag, lib, part string) string {
	return fmt.Sprintf("%s/-/raw/%s/%s.pretty/%s.kicad_mod",
		strings.TrimSuffix(repo, "/"), tag, url.PathEscape(lib), url.PathEscape(part))
}

// FootprintSourceRef is the provenance string recorded on the acquisition-lock
// entry: "kicad-footprints@<tag>/<Lib>.pretty/<Name>.kicad_mod". It names the
// RELEASE and the path within it, which together are reproducible; the full URL
// is not used because a host/scheme change would make old entries look like
// they came from somewhere else when they did not.
func FootprintSourceRef(tag, lib, part string) string {
	return fmt.Sprintf("kicad-footprints@%s/%s.pretty/%s.kicad_mod", tag, lib, part)
}

// AcquireFootprint fetches ONE official footprint named by ref, using the tag
// and footprints repo pinned in the lock manifest at lockPath.
//
// It returns the bytes and their sha256 and writes nothing (see the file
// header). The verification it CAN do without a parser is done here — no
// redirects at all, then status, size, UTF-8 validity, and the s-expression head
// token — so an off-origin hand-off or an HTML error page is refused at the
// boundary that knows the URL, instead of arriving at the worker as
// "unparseable text" with the address lost.
func AcquireFootprint(lockPath, ref string) (FetchedFootprint, error) {
	lib, part, err := SplitFootprintRef(ref)
	if err != nil {
		return FetchedFootprint{}, err
	}

	lock, err := LoadLock(lockPath)
	if err != nil {
		return FetchedFootprint{}, &AcquireError{Kind: "lock", Ref: ref,
			Message: fmt.Sprintf("cannot read the pinned KiCad release from %s: %v. "+
				"The lock manifest is the single source of truth for which official release this "+
				"plugin acquires from; without it there is no tag to fetch AT, and guessing one "+
				"would mix releases inside one board", lockPath, err)}
	}
	if strings.TrimSpace(lock.Tag) == "" {
		return FetchedFootprint{}, &AcquireError{Kind: "lock", Ref: ref,
			Message: fmt.Sprintf("%s declares no release tag; acquisition has nothing to pin to", lockPath)}
	}
	repo := strings.TrimSpace(lock.Source.FootprintsRepo)
	if repo == "" {
		return FetchedFootprint{}, &AcquireError{Kind: "lock", Ref: ref,
			Message: fmt.Sprintf("%s declares no source.footprints_repo; acquisition has no upstream "+
				"to fetch from", lockPath)}
	}

	url := FootprintRawURL(repo, lock.Tag, lib, part)
	body, err := fetchFootprintBytes(acquisitionClient(), url, ref)
	if err != nil {
		return FetchedFootprint{}, err
	}

	sum := sha256.Sum256(body)
	return FetchedFootprint{
		Ref:       strings.TrimSpace(ref),
		Lib:       lib,
		Part:      part,
		Tag:       lock.Tag,
		URL:       url,
		Text:      string(body),
		SHA256:    hex.EncodeToString(sum[:]),
		SizeBytes: int64(len(body)),
		SourceRef: FootprintSourceRef(lock.Tag, lib, part),
		License:   FootprintLicense,
	}, nil
}

// redirectRefused is what the acquisition client's CheckRedirect returns instead
// of following a hop. It is a TYPE rather than a formatted string because
// http.Client wraps whatever CheckRedirect returns inside a *url.Error, and the
// caller has to be able to tell a refused redirect apart from a genuine
// transport failure after that wrapping — errors.As can, a substring match on
// the message cannot.
type redirectRefused struct {
	From string
	To   string
}

func (e *redirectRefused) Error() string {
	return fmt.Sprintf("refused a redirect from %s to %s", e.From, e.To)
}

// acquisitionClient is the ONLY client acquisition uses, and it FOLLOWS NO
// REDIRECTS.
//
// Go's default policy caps the hop count and nothing else — not the host, not
// the scheme. Following a hop would therefore let the pinned GitLab URL hand off
// to any origin, including a plaintext one, and the bytes that came back would
// still be labelled source_kind=official_kicad and auto-blessed by the worker:
// the "official" claim rests entirely on the URL we ASKED for, which no later
// check re-examines. Refusing outright is the fail-closed reading of that. It
// costs nothing today (the pinned raw-blob URL answers 200 directly) and if
// upstream ever does start redirecting we want to SEE that as a loud refusal
// naming the new address, then decide deliberately whether that address is still
// official — not discover it after arbitrary bytes have been blessed.
func acquisitionClient() *http.Client {
	return &http.Client{
		Timeout: fetchTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			from := ""
			if len(via) > 0 {
				from = via[len(via)-1].URL.String()
			}
			return &redirectRefused{From: from, To: req.URL.String()}
		},
	}
}

// fetchFootprintBytes GETs url with the discipline fetchOne applies to a locked
// entry — one bounded request, status 200 only — MINUS redirects, which this
// path refuses outright (see acquisitionClient), plus the two checks a locked
// entry does not need. A locked entry is verified against a RECORDED sha256, so
// its content sanity is total and free; an acquired part has no recorded sha to
// compare against (that is the whole point of acquiring it), so size and shape
// have to be checked directly or an HTML error page becomes "the footprint".
func fetchFootprintBytes(client *http.Client, url, ref string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, &AcquireError{Kind: "network", Ref: ref, URL: url,
			Message: fmt.Sprintf("cannot build a request for %s: %v", url, err)}
	}
	resp, err := client.Do(req)
	if err != nil {
		// A refused redirect arrives here wrapped in a *url.Error. It is not a
		// network failure and must not be reported as one: nothing is wrong with
		// the link, the pinned address answered and pointed elsewhere.
		var moved *redirectRefused
		if errors.As(err, &moved) {
			return nil, &AcquireError{Kind: "redirect", Ref: ref, URL: url,
				Message: fmt.Sprintf("GET %s was redirected to %s; official acquisition refuses "+
					"redirects fail-closed and did NOT follow it. Bytes fetched from a redirect target "+
					"would still be recorded as source_kind=official_kicad and auto-blessed, so the "+
					"only thing backing that claim is the address we asked for — which %s is not. If "+
					"the official upstream has genuinely moved, update source.footprints_repo in the "+
					"lock manifest so the new address is pinned deliberately", url, moved.To, moved.To)}
		}
		return nil, &AcquireError{Kind: "network", Ref: ref, URL: url,
			Message: fmt.Sprintf("GET %s failed: %v. ACQUIRING a new footprint needs network access "+
				"to gitlab.com; RESOLUTION never does — already-acquired parts resolve from "+
				"sha-pinned bytes on disk, so this failure blocks adding %s and nothing else",
				url, err, ref)}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		hint := ""
		if resp.StatusCode == http.StatusNotFound {
			hint = fmt.Sprintf(" — no such footprint at this release: check the library nickname and "+
				"part name against the upstream .pretty directory (%s)", ref)
		}
		return nil, &AcquireError{Kind: "http", Ref: ref, URL: url,
			Message: fmt.Sprintf("GET %s: unexpected status %s%s", url, resp.Status, hint)}
	}

	// Read one byte past the ceiling so "exactly at the limit" and "over it" are
	// distinguishable; anything over is refused without the whole body ever
	// being buffered.
	body, err := io.ReadAll(io.LimitReader(resp.Body, FootprintMaxBytes+1))
	if err != nil {
		return nil, &AcquireError{Kind: "network", Ref: ref, URL: url,
			Message: fmt.Sprintf("reading %s failed mid-stream: %v (nothing was staged)", url, err)}
	}
	if len(body) > FootprintMaxBytes {
		return nil, &AcquireError{Kind: "content", Ref: ref, URL: url,
			Message: fmt.Sprintf("%s returned more than %d bytes; a .kicad_mod is KB-scale, so an "+
				"oversized body is an archive, a directory listing, or an error page rather than a "+
				"footprint", url, FootprintMaxBytes)}
	}
	if err := checkKicadModShape(body, ref, url); err != nil {
		return nil, err
	}
	return body, nil
}

// checkKicadModShape refuses a body that is not plausibly .kicad_mod TEXT.
//
// This is a boundary check, not a parse: the worker's _validate_kicad_mod_text
// does the real one (balanced parens, at least one pad) before it writes a byte.
// What is checked HERE is what only this side knows — that the bytes came from
// this URL — so the refusal can name the address that served an HTML page
// instead of leaving the worker to report anonymous unparseable text.
//
// UTF-8 validity is load-bearing rather than cosmetic: the text crosses the
// worker bridge as JSON, and the worker cross-checks its own sha256 of the
// decoded string against the sha computed here over the raw bytes. Non-UTF-8
// bytes would not survive that round trip byte-for-byte, so the cross-check
// would fail confusingly later; refusing here says why.
func checkKicadModShape(body []byte, ref, url string) error {
	if !utf8.Valid(body) {
		return &AcquireError{Kind: "content", Ref: ref, URL: url,
			Message: fmt.Sprintf("%s returned bytes that are not valid UTF-8; a .kicad_mod is text, "+
				"and non-text bytes cannot cross the worker bridge unchanged", url)}
	}
	trimmed := strings.TrimSpace(string(body))
	if trimmed == "" {
		return &AcquireError{Kind: "content", Ref: ref, URL: url,
			Message: fmt.Sprintf("%s returned an empty body", url)}
	}
	if !strings.HasPrefix(trimmed, "(") {
		looksHTML := strings.HasPrefix(trimmed, "<")
		what := "is not a KiCad s-expression (it does not start with '(')"
		if looksHTML {
			what = "is markup, not a footprint — an error/login/redirect page was served with status 200"
		}
		return &AcquireError{Kind: "content", Ref: ref, URL: url,
			Message: fmt.Sprintf("%s returned content that %s; refusing rather than staging it "+
				"(first bytes: %q)", url, what, firstBytes(trimmed))}
	}
	head := trimmed[1:]
	if idx := strings.IndexAny(head, " \t\r\n()"); idx >= 0 {
		head = head[:idx]
	}
	if head != "footprint" && head != "module" {
		return &AcquireError{Kind: "content", Ref: ref, URL: url,
			Message: fmt.Sprintf("%s returned an s-expression headed by %q; a .kicad_mod must be "+
				"headed by 'footprint' (KiCad 6+) or 'module' (KiCad 5)", url, head)}
	}
	return nil
}

// firstBytes is a short, quote-safe excerpt for a refusal message.
func firstBytes(s string) string {
	const n = 60
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
