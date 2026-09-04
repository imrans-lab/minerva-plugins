package cadruntime

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"testing"
)

// Cad tracks empty bundle placeholders so go:embed can compile in a fresh
// clone.  The package-leg CI step replaces them with the real target bundle;
// there, these tests prove that the bytes which ship are complete and paired.
//
// Everything here is about the pair (EmbeddedBundle, EmbeddedSHA256) that
// main.go hands to sharedruntime.PythonPath. The extraction path in
// shared/runtime/extract.go verifies that pair at runtime — but only when the
// checksum string is non-empty, which is precisely why an empty one has to
// fail here.

// hex64 is the exact shape extract.go compares against: 64 hex digits and
// nothing else.
var hex64 = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

// The bundle must be real, whole, and self-consistent with its sidecar.
func TestEmbeddedBundleMatchesItsChecksum(t *testing.T) {
	if len(EmbeddedBundle) == 0 {
		t.Fatal("EmbeddedBundle is empty — go:embed consumed a zero-byte file; " +
			"the binary would refuse to start its Python worker with ErrPlatformNotBundled")
	}

	// A CPython + build123d/OCP bundle is ~150-250MB compressed. Anything in
	// the kilobytes is a truncated or wrong-file embed that still has bytes,
	// which the checksum below would happily bless if the sidecar were
	// regenerated from the same truncated file.
	const floorBytes = 20 << 20
	if len(EmbeddedBundle) < floorBytes {
		t.Fatalf("EmbeddedBundle is only %d bytes (floor %d) — truncated or wrong file",
			len(EmbeddedBundle), floorBytes)
	}

	// zstd frame magic (RFC 8478 §3.1.1). extract.go streams this through a
	// zstd reader; a tarball that was never compressed, or a sidecar embedded
	// in the bundle slot, fails there with an opaque decode error on a user
	// machine instead of here.
	magic := []byte{0x28, 0xB5, 0x2F, 0xFD}
	for i, b := range magic {
		if EmbeddedBundle[i] != b {
			t.Fatalf("EmbeddedBundle is not a zstd stream: first 4 bytes are %x, want %x",
				EmbeddedBundle[:4], magic)
		}
	}

	// An EMPTY checksum is not a benign "unset": extract.go skips verification
	// entirely when EmbeddedSHA256 == "", so a bundle shipped with an empty
	// sidecar is extracted UNVERIFIED on every user machine. cad has no
	// placeholder tier, so there is no state in which that is acceptable.
	if EmbeddedSHA256 == "" {
		t.Fatal("EmbeddedSHA256 is empty — extract.go would skip integrity " +
			"verification entirely and extract the bundle unchecked")
	}

	// The sidecar must be the bare hex digest. `sha256sum <file>` prints
	// "<hash>  <name>" (and "<hash> *<name>" in binary mode on Git-for-Windows);
	// either form survives EmbeddedSHA256's TrimSpace and then never matches,
	// turning every launch into a sha-mismatch refusal.
	if !hex64.MatchString(EmbeddedSHA256) {
		t.Fatalf("EmbeddedSHA256 is not a bare 64-char hex digest: %q "+
			"(a sha256sum/shasum line with the filename column does not compare equal)", EmbeddedSHA256)
	}

	sum := sha256.Sum256(EmbeddedBundle)
	if got := hex.EncodeToString(sum[:]); !strings.EqualFold(got, EmbeddedSHA256) {
		t.Fatalf("embedded bundle sha mismatch: computed %s, sidecar %s — "+
			"bundle and sidecar came from different builds", got, EmbeddedSHA256)
	}
}
