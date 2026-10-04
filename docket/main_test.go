package main

import (
	"archive/zip"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// DOCKET_RELEASE_FIXTURE is a retained official release directory, not mocks.
func TestOfficialRelease(t *testing.T) {
	fixture := os.Getenv("DOCKET_RELEASE_FIXTURE")
	if fixture == "" {
		t.Fatal("set DOCKET_RELEASE_FIXTURE to all official rc.18 release assets and signed checksums")
	}
	fetch := func(_ context.Context, name string, dst io.Writer, limit int64) error {
		file, err := os.Open(filepath.Join(fixture, name))
		if err != nil {
			return err
		}
		defer file.Close()
		return copyBounded(dst, file, limit)
	}
	r, err := pins()
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	root := t.TempDir()
	if err := verifyPins(ctx, r, fetch); err != nil {
		t.Fatal(err)
	}
	var lastGood string
	for target, p := range r.Platforms {
		executable, err := acquire(ctx, r, target, root, fetch)
		if err != nil {
			t.Fatalf("%s: %v", target, err)
		}
		lastGood = executable
		sidecar := "libgdsqlite.linux.template_release.x86_64.so"
		if strings.HasPrefix(target, "windows") {
			sidecar = "libgdsqlite.windows.template_release.x86_64.dll"
		}
		if !strings.HasPrefix(target, "darwin") {
			for _, name := range []string{p.Entrypoint, sidecar, "LICENSE", "THIRD-PARTY-LICENSES.txt"} {
				if _, err := os.Stat(filepath.Join(filepath.Dir(executable), name)); err != nil {
					t.Fatal(err)
				}
			}
		} else if _, err := os.Stat(filepath.Join(filepath.Dir(executable), "../Frameworks")); err != nil {
			t.Fatal(err)
		}
	}
	before, err := os.ReadFile(lastGood)
	if err != nil {
		t.Fatal(err)
	}
	for _, failure := range []string{"signature", "artifact", "pin", "unsupported", "missing"} {
		t.Run(failure, func(t *testing.T) {
			altered := r
			altered.Platforms = map[string]platform{}
			for k, v := range r.Platforms {
				altered.Platforms[k] = v
			}
			target := "linux-amd64"
			if failure == "unsupported" {
				target = "linux-arm64"
			}
			if failure == "pin" {
				p := altered.Platforms[target]
				p.SHA256 = strings.Repeat("0", 64)
				altered.Platforms[target] = p
			}
			broken := func(ctx context.Context, name string, dst io.Writer, limit int64) error {
				if (failure == "signature" && name == "SHA256SUMS.asc") || (failure == "artifact" && name == r.Platforms[target].Asset) {
					_, err := io.WriteString(dst, "tampered")
					return err
				}
				if failure == "missing" && name == "SHA256SUMS" {
					return os.ErrNotExist
				}
				return fetch(ctx, name, dst, limit)
			}
			if _, err := acquire(ctx, altered, target, root, broken); err == nil {
				t.Fatal("accepted invalid acquisition")
			}
			after, err := os.ReadFile(lastGood)
			if err != nil || string(after) != string(before) {
				t.Fatal("previous installation changed")
			}
		})
	}
	for _, name := range []string{"../escape", "/absolute", "C:\\escape", "a/../escape", "CON", "trailing.", "duplicate", "case", "symlink"} {
		t.Run(name, func(t *testing.T) {
			archive := filepath.Join(t.TempDir(), "unsafe.zip")
			file, err := os.Create(archive)
			if err != nil {
				t.Fatal(err)
			}
			writer := zip.NewWriter(file)
			header := &zip.FileHeader{Name: name, Method: zip.Store}
			if name == "symlink" {
				header.SetMode(os.ModeSymlink | 0777)
			}
			entry, err := writer.CreateHeader(header)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := io.WriteString(entry, "payload"); err != nil {
				t.Fatal(err)
			}
			if name == "duplicate" || name == "case" {
				duplicate := name
				if name == "case" {
					duplicate = strings.ToUpper(name)
				}
				if _, err := writer.Create(duplicate); err != nil {
					t.Fatal(err)
				}
			}
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
			if err := file.Close(); err != nil {
				t.Fatal(err)
			}
			if err := extract(archive, "unsafe.zip", t.TempDir()); err == nil {
				t.Fatal("accepted unsafe archive")
			}
			after, err := os.ReadFile(lastGood)
			if err != nil || string(after) != string(before) {
				t.Fatal("previous installation changed")
			}
		})
	}
}
