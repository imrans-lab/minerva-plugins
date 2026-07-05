package libraries

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// fetchTimeout bounds a single entry's HTTP request. Library files are a few
// KB to a few MB; 120s is generous headroom even on a slow link.
const fetchTimeout = 120 * time.Second

// NotifyFunc receives fetch-progress events. event is one of
// "start" | "skip" | "fetched" | "failed" | "summary". detail carries
// event-specific fields (entry name, bytes, error message, ...). Either
// argument may be passed as nil/empty by a caller that doesn't want progress.
type NotifyFunc func(event string, detail map[string]interface{})

// FailedEntry records why a single lock entry could not be fetched.
type FailedEntry struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
}

// FetchResult summarizes one FetchAll run.
type FetchResult struct {
	Tag     string        `json:"tag"`
	Fetched []string      `json:"fetched"`
	Skipped []string      `json:"skipped"`
	Failed  []FailedEntry `json:"failed"`
}

// FetchAll downloads every entry in the lock manifest at lockPath into
// destDir, verifying each against its recorded sha256.
//
//   - Idempotent: an entry already present at its destination path with a
//     matching sha256 is skipped without any network request.
//   - Atomic: each file is downloaded to a temp file in the SAME directory as
//     its destination, sha256-verified while streaming, then renamed into
//     place only on success. A mismatch or a mid-stream I/O error deletes the
//     temp file and leaves any prior good destination file (if any) untouched
//     — a failed entry never corrupts or partially overwrites its destination.
//   - Never fails the whole batch for one bad entry: failures are collected
//     per-entry in FetchResult.Failed; FetchAll only returns a non-nil error
//     for a lock-manifest problem (missing file, malformed JSON) that makes
//     the whole run meaningless.
//
// notify may be nil.
func FetchAll(lockPath, destDir string, notify NotifyFunc) (FetchResult, error) {
	if notify == nil {
		notify = func(string, map[string]interface{}) {}
	}

	lock, err := LoadLock(lockPath)
	if err != nil {
		return FetchResult{}, err
	}

	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return FetchResult{}, fmt.Errorf("libraries.FetchAll: mkdir %s: %w", destDir, err)
	}

	result := FetchResult{Tag: lock.Tag}
	client := &http.Client{Timeout: fetchTimeout}

	for _, e := range lock.Entries {
		destPath := e.DestPath(destDir)

		if verifyFileSHA256(destPath, e.SHA256) {
			result.Skipped = append(result.Skipped, e.Name)
			notify("skip", map[string]interface{}{"name": e.Name, "dest": destPath})
			continue
		}

		notify("start", map[string]interface{}{"name": e.Name, "url": e.URL, "size_bytes": e.SizeBytes})
		if err := fetchOne(client, e, destPath); err != nil {
			result.Failed = append(result.Failed, FailedEntry{Name: e.Name, Reason: err.Error()})
			notify("failed", map[string]interface{}{"name": e.Name, "error": err.Error()})
			continue
		}
		result.Fetched = append(result.Fetched, e.Name)
		notify("fetched", map[string]interface{}{"name": e.Name, "dest": destPath, "size_bytes": e.SizeBytes})
	}

	notify("summary", map[string]interface{}{
		"tag": result.Tag, "fetched": len(result.Fetched),
		"skipped": len(result.Skipped), "failed": len(result.Failed),
	})
	return result, nil
}

// fetchOne downloads a single entry to a temp file beside destPath, verifies
// its sha256, and renames it into place atomically. On any failure the temp
// file is removed and destPath is left exactly as it was found.
func fetchOne(client *http.Client, e Entry, destPath string) error {
	destDirPath := filepath.Dir(destPath)
	if err := os.MkdirAll(destDirPath, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", destDirPath, err)
	}

	req, err := http.NewRequest(http.MethodGet, e.URL, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GET %s: %w", e.URL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: unexpected status %s", e.URL, resp.Status)
	}

	tmp, err := os.CreateTemp(destDirPath, ".tmp-fetch-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpPath := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
		}
	}()

	h := sha256.New()
	if _, err := io.Copy(tmp, io.TeeReader(resp.Body, h)); err != nil {
		return fmt.Errorf("download %s: %w", e.URL, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}

	gotSHA := hex.EncodeToString(h.Sum(nil))
	if !strings.EqualFold(gotSHA, e.SHA256) {
		return fmt.Errorf("sha256 mismatch for %s: got %s, want %s (rejected, not written)",
			e.Name, gotSHA, e.SHA256)
	}

	if err := os.Rename(tmpPath, destPath); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", tmpPath, destPath, err)
	}
	cleanup = false
	return nil
}

// verifyFileSHA256 reports whether destPath exists and its content sha256
// matches want (case-insensitive hex compare). Any read error (including
// "does not exist") is treated as "not verified" — never panics/errors out.
func verifyFileSHA256(destPath, want string) bool {
	f, err := os.Open(destPath)
	if err != nil {
		return false
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return false
	}
	got := hex.EncodeToString(h.Sum(nil))
	return strings.EqualFold(got, want)
}
