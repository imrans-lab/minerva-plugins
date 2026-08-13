package pcbruntime

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

// The placeholder scheme's one invariant (epoch GA-4): the embedded bundle
// and its checksum are EITHER both placeholders (empty — dev tree, where
// sharedruntime falls through to the dev tiers) OR both real (CI package job
// after the bundle build), never mixed. A bundle with no checksum could not
// be verified before extraction; a checksum with no bundle would make
// PythonPath attempt tier 1 against zero bytes.
func TestBundleAndChecksumArePlaceholderConsistent(t *testing.T) {
	bundleEmpty := len(EmbeddedBundle) == 0
	shaEmpty := EmbeddedSHA256 == ""
	if bundleEmpty != shaEmpty {
		t.Fatalf("embedded bundle and checksum disagree about being placeholders: "+
			"len(bundle)=%d, sha=%q", len(EmbeddedBundle), EmbeddedSHA256)
	}
	if bundleEmpty {
		t.Log("placeholder bundle (dev tree) — checksum verification not applicable")
		return
	}
	// Real bundle (CI after the bundle build): the .sha256 sidecar must match
	// the embedded bytes, or extraction would refuse at runtime on every
	// user machine — catch it here instead.
	sum := sha256.Sum256(EmbeddedBundle)
	if got := hex.EncodeToString(sum[:]); got != EmbeddedSHA256 {
		t.Fatalf("embedded bundle sha mismatch: computed %s, sidecar %s", got, EmbeddedSHA256)
	}
}
