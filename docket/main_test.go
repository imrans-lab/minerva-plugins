package main

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/ProtonMail/go-crypto/openpgp/armor"
	"time"
)

// DOCKET_RELEASE_FIXTURE is a retained official release directory, not mocks.
func TestOfficialRelease(t *testing.T) {
	fixture := os.Getenv("DOCKET_RELEASE_FIXTURE")
	if fixture == "" {
		t.Fatal("set DOCKET_RELEASE_FIXTURE to all official pinned release assets and signed checksums")
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
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := verifyPins(ctx, r, fetch); err != nil {
		t.Fatal(err)
	}
	// Executor-only fixture staging uses the same signed acquisition oracle.
	if os.Getenv("DOCKET_STAGE_PLUGIN") == "1" {
		if os.Getenv("MINERVA_PLUGIN_DATA_DIR") == "" {
			t.Fatal("fixture staging requires explicit scratch data override")
		}
		pluginRoot, err := pluginRoot()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := acquire(ctx, r, runtime.GOOS+"-"+runtime.GOARCH, pluginRoot, fetch); err != nil {
			t.Fatal(err)
		}
	}
	var lastGood string
	for target, p := range r.Platforms {
		executable, err := acquire(ctx, r, target, root, fetch)
		if err != nil {
			t.Fatalf("%s: %v", target, err)
		}
		lastGood = executable
		again, err := acquire(ctx, r, target, root, func(context.Context, string, io.Writer, int64) error {
			t.Fatal("installed cache attempted network")
			return nil
		})
		if err != nil || again != executable || filepath.Dir(again) == root {
			t.Fatal("installation did not converge on its versioned cache")
		}
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
	stagingRoot := privateTestRoot(t)
	for _, name := range []string{".acquire-stale", ".archive-stale", ".acquire-live"} {
		file := filepath.Join(stagingRoot, name)
		if err := os.WriteFile(file, nil, 0600); err != nil {
			t.Fatal(err)
		}
		if !strings.HasSuffix(name, "live") {
			old := time.Now().Add(-48 * time.Hour)
			if err := os.Chtimes(file, old, old); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := acquire(ctx, r, "linux-amd64", stagingRoot, fetch); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".acquire-stale", ".archive-stale", ".acquire-live"} {
		_, err := os.Stat(filepath.Join(stagingRoot, name))
		if strings.HasSuffix(name, "live") && err != nil || !strings.HasSuffix(name, "live") && !os.IsNotExist(err) {
			t.Fatalf("incorrect staging cleanup: %s: %v", name, err)
		}
	}
	before, err := os.ReadFile(lastGood)
	if err != nil {
		t.Fatal(err)
	}
	for _, failure := range []string{"signature", "artifact", "pin", "unsupported", "missing", "signer", "keyhash", "multiple-signatures"} {
		t.Run(failure, func(t *testing.T) {
			altered := r
			altered.Platforms = map[string]platform{}
			for k, v := range r.Platforms {
				altered.Platforms[k] = v
			}
			if failure == "signer" {
				altered.Signing = altered.Primary
			}
			if failure == "keyhash" {
				altered.KeySHA256 = strings.Repeat("0", 64)
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
				if failure == "multiple-signatures" && name == "SHA256SUMS.asc" {
					var original bytes.Buffer
					if err := fetch(ctx, name, &original, limit); err != nil {
						return err
					}
					body, err := armor.Decode(&original)
					if err != nil {
						return err
					}
					data, err := io.ReadAll(body.Body)
					if err != nil {
						return err
					}
					encoded, err := armor.Encode(dst, body.Type, nil)
					if err != nil {
						return err
					}
					if _, err := encoded.Write(append(data, data...)); err != nil {
						return err
					}
					return encoded.Close()
				}
				return fetch(ctx, name, dst, limit)
			}
			if _, err := acquire(ctx, altered, target, privateTestRoot(t), broken); err == nil {
				t.Fatal("accepted invalid acquisition")
			}
			after, err := os.ReadFile(lastGood)
			if err != nil || string(after) != string(before) {
				t.Fatal("previous installation changed")
			}
		})
	}
	for _, name := range []string{"../escape", "/absolute", "C:\\escape", "a/../escape", "CON", "CONIN$", "CONOUT$", "COM¹", "COM².txt", "COM³", "LPT¹", "LPT².txt", "LPT³", "trailing.", "duplicate", "case", "symlink"} {
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
			input, err := os.Open(archive)
			if err != nil {
				t.Fatal(err)
			}
			defer input.Close()
			if err := extract(input, "unsafe.zip", t.TempDir()); err == nil {
				t.Fatal("accepted unsafe archive")
			}
			after, err := os.ReadFile(lastGood)
			if err != nil || string(after) != string(before) {
				t.Fatal("previous installation changed")
			}
		})
	}
}

func privateTestRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestReleaseURLPolicy(t *testing.T) {
	for _, raw := range []string{"https://github.com/a", "https://objects.githubusercontent.com/a", "https://release-assets.githubusercontent.com/a", "http://github.com/a", "https://evil.example/a", "https://github.com.evil.example/a", "https://user@github.com/a", "https://github.com:443/a"} {
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		allowed := raw == "https://github.com/a" || raw == "https://objects.githubusercontent.com/a" || raw == "https://release-assets.githubusercontent.com/a"
		if (officialURL(u) == nil) != allowed {
			t.Fatalf("incorrect initial/redirect URL policy: %s", raw)
		}
	}
}
