// Docket acquisition verifies the publisher's signature and every committed pin.
package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/ProtonMail/go-crypto/openpgp"
)

//go:embed release.lock.json
var lockJSON []byte

//go:embed release-signing-key.asc
var signingKey string

type platform struct{ Asset, SHA256, Entrypoint string }
type release struct {
	Tag, Source, URL, Primary, Signing string
	Platforms                          map[string]platform
}
type fetcher func(context.Context, string, io.Writer, int64) error

const metadataLimit int64 = 1 << 20
const archiveLimit int64 = 256 << 20
const expandedLimit int64 = 1 << 30

func pins() (release, error) {
	var r release
	err := json.Unmarshal(lockJSON, &r)
	return r, err
}

// fetchOfficial shares a single timeout across metadata and artifact acquisition.
func fetchOfficial(r release) fetcher {
	client := &http.Client{Timeout: 5 * time.Minute}
	return func(ctx context.Context, name string, dst io.Writer, limit int64) error {
		req, err := http.NewRequestWithContext(ctx, "GET", r.URL+name, nil)
		if err != nil {
			return err
		}
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return fmt.Errorf("%s: HTTP %d", name, res.StatusCode)
		}
		return copyBounded(dst, res.Body, limit)
	}
}

func copyBounded(dst io.Writer, src io.Reader, limit int64) error {
	n, err := io.Copy(dst, io.LimitReader(src, limit+1))
	if err != nil {
		return err
	}
	if n > limit {
		return errors.New("size limit exceeded")
	}
	return nil
}

// verifyPins is the sole signature/checksum oracle for CLI, acquisition and CI.
func verifyPins(ctx context.Context, r release, fetch fetcher) error {
	var sums, sig bytes.Buffer
	if err := fetch(ctx, "SHA256SUMS", &sums, metadataLimit); err != nil {
		return err
	}
	if err := fetch(ctx, "SHA256SUMS.asc", &sig, metadataLimit); err != nil {
		return err
	}
	keys, err := openpgp.ReadArmoredKeyRing(strings.NewReader(signingKey))
	if err != nil {
		return err
	}
	if len(keys) != 1 || !strings.EqualFold(hex.EncodeToString(keys[0].PrimaryKey.Fingerprint), r.Primary) {
		return errors.New("release primary key fingerprint mismatch")
	}
	signer, err := openpgp.CheckArmoredDetachedSignature(keys, bytes.NewReader(sums.Bytes()), bytes.NewReader(sig.Bytes()), nil)
	if err != nil {
		return fmt.Errorf("release signature: %w", err)
	}
	if !strings.EqualFold(hex.EncodeToString(signer.PrimaryKey.Fingerprint), r.Primary) {
		return errors.New("unexpected signer")
	}
	published := map[string]string{}
	for _, line := range strings.Split(sums.String(), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 || len(fields[0]) != 64 {
			return errors.New("malformed signed checksum")
		}
		if _, err := hex.DecodeString(fields[0]); err != nil {
			return err
		}
		name := strings.TrimPrefix(fields[1], "*")
		if _, exists := published[name]; exists {
			return errors.New("duplicate signed checksum")
		}
		published[name] = fields[0]
	}
	if len(r.Platforms) != 4 {
		return errors.New("incomplete platform lock")
	}
	for _, p := range r.Platforms {
		if len(p.SHA256) != 64 || published[p.Asset] != p.SHA256 {
			return fmt.Errorf("published pin mismatch: %s", p.Asset)
		}
	}
	return nil
}

// acquire returns a new private, absolute executable path. Publication is a
// rename within the root; failures remove staging and never alter older installs.
func acquire(ctx context.Context, r release, target, root string, fetch fetcher) (string, error) {
	p, ok := r.Platforms[target]
	if !ok {
		return "", fmt.Errorf("unsupported platform: %s", target)
	}
	if !filepath.IsAbs(root) {
		return "", errors.New("installation root must be absolute")
	}
	if err := verifyPins(ctx, r, fetch); err != nil {
		return "", err
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return "", err
	}
	info, err := os.Lstat(root)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || (runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		return "", errors.New("installation root must be a private directory")
	}
	stage, err := os.MkdirTemp(root, ".acquire-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stage)
	artifact, err := os.CreateTemp(root, ".archive-")
	if err != nil {
		return "", err
	}
	defer os.Remove(artifact.Name())
	defer artifact.Close()
	hash := sha256.New()
	if err := fetch(ctx, p.Asset, io.MultiWriter(artifact, hash), archiveLimit); err != nil {
		return "", err
	}
	if hex.EncodeToString(hash.Sum(nil)) != p.SHA256 {
		return "", errors.New("artifact checksum mismatch")
	}
	if err := artifact.Close(); err != nil {
		return "", err
	}
	if err := extract(artifact.Name(), p.Asset, stage); err != nil {
		return "", err
	}
	entry := filepath.Join(stage, filepath.FromSlash(p.Entrypoint))
	info, err = os.Stat(entry)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || (target[:strings.IndexByte(target, '-')] != "windows" && info.Mode().Perm()&0111 == 0) {
		return "", errors.New("release entrypoint is not executable")
	}
	// Keep acquisition receipts beside the complete, unmodified exported payload.
	if err := os.WriteFile(filepath.Join(stage, "acquisition.lock.json"), lockJSON, 0600); err != nil {
		return "", err
	}
	dest := filepath.Join(root, r.Tag+"-"+target+"-"+strings.TrimPrefix(filepath.Base(stage), ".acquire-"))
	if err := os.Rename(stage, dest); err != nil {
		return "", err
	}
	return filepath.Join(dest, filepath.FromSlash(p.Entrypoint)), nil
}

func extract(filename, asset, root string) (result error) {
	seen := map[string]bool{}
	spellings := map[string]string{}
	var total int64
	count := 0
	directories := map[string]os.FileMode{}
	defer func() {
		for directory, mode := range directories {
			if err := os.Chmod(directory, mode); result == nil {
				result = err
			}
		}
	}()
	write := func(name string, mode os.FileMode, size int64, reader io.Reader) error {
		name = strings.TrimSuffix(strings.TrimPrefix(name, "./"), "/")
		if (name == "" || name == ".") && mode.IsDir() {
			return nil
		}
		if name == "" || path.IsAbs(name) || strings.ContainsAny(name, "\\:\x00") || path.Clean(name) != name || name == "." || strings.HasPrefix(name, "../") {
			return fmt.Errorf("unsafe archive path: %q", name)
		}
		for i, component := range strings.Split(name, "/") {
			stem := strings.ToUpper(strings.SplitN(component, ".", 2)[0])
			if strings.TrimRight(component, " .") != component || stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || (len(stem) == 4 && (strings.HasPrefix(stem, "COM") || strings.HasPrefix(stem, "LPT")) && stem[3] >= '1' && stem[3] <= '9') {
				return fmt.Errorf("unsafe portable path: %s", name)
			}
			prefix := strings.Join(strings.Split(name, "/")[:i+1], "/")
			lower := strings.ToLower(prefix)
			if prior, ok := spellings[lower]; ok && prior != prefix {
				return errors.New("case alias in archive")
			}
			spellings[lower] = prefix
		}
		key := strings.ToLower(name)
		if seen[key] {
			return fmt.Errorf("duplicate archive path: %s", name)
		}
		seen[key] = true
		count++
		if count > 10000 || size < 0 || size > expandedLimit-total {
			return errors.New("expanded archive limit exceeded")
		}
		total += size
		dest := filepath.Join(root, filepath.FromSlash(name))
		if mode.IsDir() {
			directories[dest] = mode.Perm()
			return os.MkdirAll(dest, 0700)
		}
		if !mode.IsRegular() {
			return fmt.Errorf("unsupported archive member: %s", name)
		}
		if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
			return err
		}
		file, err := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode.Perm())
		if err != nil {
			return err
		}
		err = copyBounded(file, reader, size)
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		return os.Chmod(dest, mode.Perm())
	}
	if strings.HasSuffix(asset, ".zip") {
		archive, err := zip.OpenReader(filename)
		if err != nil {
			return err
		}
		defer archive.Close()
		for _, file := range archive.File {
			if file.UncompressedSize64 > uint64(expandedLimit) {
				return errors.New("expanded archive limit exceeded")
			}
			reader, err := file.Open()
			if err != nil {
				return err
			}
			err = write(file.Name, file.Mode(), int64(file.UncompressedSize64), reader)
			reader.Close()
			if err != nil {
				return err
			}
		}
		return nil
	}
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gz.Close()
	archive := tar.NewReader(gz)
	for {
		header, err := archive.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA && header.Typeflag != tar.TypeDir {
			return errors.New("unsupported tar member")
		}
		if err := write(header.Name, header.FileInfo().Mode(), header.Size, archive); err != nil {
			return err
		}
	}
}

func main() {
	r, err := pins()
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		fetch := fetchOfficial(r)
		switch {
		case len(os.Args) == 2 && os.Args[1] == "verify-pins":
			err = verifyPins(ctx, r, fetch)
		case len(os.Args) == 3 && os.Args[1] == "acquire":
			var executable string
			executable, err = acquire(ctx, r, runtime.GOOS+"-"+runtime.GOARCH, os.Args[2], fetch)
			if err == nil {
				fmt.Println(executable)
			}
		default:
			err = errors.New("usage: acquire verify-pins | acquire acquire /absolute/private/root")
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
