"""Runtime-input provenance for the packaged bundle (acceptance check K23,
work item 019ffc543d1d).

K23 asks whether every externally acquired prebuilt input has an immutable
identity and is VERIFIED BEFORE extraction or execution. The distinction this
suite exists to hold: `manifest.sha256`, which the bundle builder already
produces, hashes the bundle's OWN OUTPUT so post-extract tampering is
detectable. That says nothing about whether the bytes we downloaded, extracted
and then EXECUTED were the bytes we intended. A version pin is not an immutable
identity — the same release tag can serve different bytes after a re-upload,
through a compromised mirror, or via a truncated transfer that still exits 0.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
PCB_ROOT = HERE.parents[1]
LOCK = PCB_ROOT / "scripts" / "runtime-bundle.lock"
BUILDER = PCB_ROOT.parent / "scripts" / "build-python-runtime-bundle.sh"


def _lock_vars() -> dict[str, str]:
    """The lock is shell-sourceable KEY="VALUE" by design; read it as data."""
    out: dict[str, str] = {}
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        m = re.match(r'^([A-Z0-9_]+)="(.*)"$', line.strip())
        if m:
            out[m.group(1)] = m.group(2)
    return out


def test_the_builder_verifies_before_it_extracts():
    """MUTATION THIS CATCHES: moving or deleting the verification so extraction
    happens first. Verifying AFTER extracting is not verification — by then the
    archive has already written to disk, and for the rg case an executable has
    already been placed in the bundle."""
    src = BUILDER.read_text(encoding="utf-8")
    verify_at = src.index('verify_sha256 "$PBS_CACHED"')
    extract_at = src.index('tar -xzf "$PBS_CACHED"')
    assert verify_at < extract_at, "PBS is extracted before it is verified"

    rg_verify = src.index('verify_sha256 "$RG_CACHED"')
    rg_extract = src.index('RG_EXTRACT_DIR="$BUILD_DIR/rg-extract')
    assert rg_verify < rg_extract, "ripgrep is extracted before it is verified"


def test_verification_runs_on_a_CACHE_HIT_too():
    """MUTATION THIS CATCHES: verifying only on ONE branch of the download
    if/else. The cached artifact is the MORE dangerous case, not the safer one —
    it was fetched at some earlier time under conditions nobody can now inspect,
    and on CI the cache is a shared writable store keyed by a hash of the lock
    file rather than of the payload. A check that trusts the cache protects only
    the run that populated it.

    ORDERING ALONE IS NOT ENOUGH, which the review of this suite pointed out: a
    verification moved INSIDE the cache-hit branch still comes after the cached
    echo and before the extract, so an index comparison passes while fresh
    downloads go unverified. This asserts the structural fact instead — that the
    if/else has CLOSED before the verify call, so it is on the single path both
    branches converge to."""
    lines = BUILDER.read_text(encoding="utf-8").splitlines()
    cached_echo = next(i for i, l in enumerate(lines)
                       if 'PBS cached: $PBS_CACHED' in l)
    verify = next(i for i, l in enumerate(lines)
                  if 'verify_sha256 "$PBS_CACHED"' in l)
    between = [l.strip() for l in lines[cached_echo:verify]]
    assert "fi" in between, (
        "the PBS verification is inside the download if/else, so one branch "
        "reaches extraction unverified")
    # And it is at top level, not nested in some other block.
    assert not lines[verify].startswith((" ", "\t")), lines[verify]


def test_every_name_the_SCRIPT_derives_exists_in_the_lock():
    """THE REVIEW'S MOST SERIOUS FINDING, now pinned. The script selects a pin by
    upper-casing the build triple (macos-amd64 -> ..._MACOS_AMD64); the lock
    declared ..._MACOS_X86_64. Those variables were DEAD: unreadable by the
    script, so macOS Intel took the unverified path forever.

    Why the completeness check below could not catch it: that test asserts every
    lock value is non-empty. Populate all ten, delete its marker, and the record
    says K23 is closed while one platform ships unverified. A gap marker that
    cannot see a name mismatch is worse than no marker, because it certifies.

    MUTATION THIS CATCHES: renaming either side, or adding a build triple
    without adding its pins."""
    src = BUILDER.read_text(encoding="utf-8")
    lock_names = set(_lock_vars())

    # The BUILD triples are the case arms of the script's own target dispatch.
    # The host-detection case block below it uses the same arm shape (its arms
    # map a uname value onto a build triple, e.g. linux-aarch64 -> linux-arm64),
    # so those are excluded by the HOST_TRIPLE assignment that marks them.
    # Without that exclusion this test demands pins for host aliases that are
    # never built, and reds the gate for a reason that is not a defect — caught
    # by running this logic against the real files before trusting it.
    triples = {m.group(1) for m in
               re.finditer(r"^\s{2}((?:linux|macos|windows)-[a-z0-9_]+)\)(.*)$",
                           src, re.MULTILINE)
               if "HOST_TRIPLE" not in m.group(2)}
    assert triples, "could not find the script's build triples"

    missing = []
    for triple in sorted(triples):
        suffix = triple.upper().replace("-", "_")
        for prefix in ("PBS_SHA256_", "RG_SHA256_"):
            if prefix + suffix not in lock_names:
                missing.append(prefix + suffix)
    assert not missing, (
        f"the script will look for these and find nothing: {missing}; "
        f"lock declares {sorted(n for n in lock_names if 'SHA256' in n)}")


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash unavailable")
def test_corrupt_bytes_are_REFUSED_and_the_cache_entry_is_dropped():
    """THE NEGATIVE TEST K23 NAMES. Runs the real verify_sha256 out of the real
    script against bytes that do not match, and asserts a non-zero exit.

    MUTATION THIS CATCHES: a comparison that warns instead of exiting, or one
    that leaves the corrupt file cached. A poisoned cache entry that merely
    fails loudly is still a poisoned cache entry — every later build would fail
    identically with no path out but manual cleanup."""
    src = BUILDER.read_text(encoding="utf-8")
    start = src.index("verify_sha256() {")
    end = src.index("\n}\n", start) + 3
    func = src[start:end]

    with tempfile.TemporaryDirectory() as td:
        victim = Path(td) / "payload.tar.gz"
        victim.write_bytes(b"not the bytes you were promised")
        script = (
            "set -e\nTRIPLE=test\n" + func
            + f'\nverify_sha256 "{victim}" "{"0" * 64}" "fixture"\n'
        )
        proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)

        # INSIDE the with-block ON PURPOSE. TemporaryDirectory deletes the whole
        # tree on exit, so `not victim.exists()` outside it is true no matter what
        # the script did — the assertion carrying this test's headline claim was
        # passing vacuously, and a verifier that exited non-zero while LEAVING the
        # poisoned artifact cached would have satisfied it.
        assert proc.returncode != 0, "corrupt bytes were accepted"
        assert "FATAL" in proc.stderr
        assert not victim.exists(), "the corrupt artifact was left in the cache"


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash unavailable")
def test_matching_bytes_pass():
    """MUTATION THIS CATCHES: a verifier that rejects everything, which would
    pass the negative test above while making the build unusable. Both
    directions or neither."""
    src = BUILDER.read_text(encoding="utf-8")
    start = src.index("verify_sha256() {")
    end = src.index("\n}\n", start) + 3
    func = src[start:end]

    import hashlib
    with tempfile.TemporaryDirectory() as td:
        good = Path(td) / "payload.tar.gz"
        good.write_bytes(b"exactly these bytes")
        digest = hashlib.sha256(good.read_bytes()).hexdigest()
        script = ("set -e\nTRIPLE=test\n" + func
                  + f'\nverify_sha256 "{good}" "{digest}" "fixture"\n')
        proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)

        # INSIDE the with-block, same reason as above — but here the deleted
        # tree made the assertion always FALSE rather than always true, so this
        # test failed on its first ever execution instead of lying quietly.
        assert proc.returncode == 0, proc.stderr
        assert good.exists()


@pytest.mark.xfail(
    strict=True,
    reason="K23 GAP, TRACKED NOT HIDDEN (019ffc543d1d): the verification "
           "mechanism is in place but no expected sha256 has been populated "
           "yet — that requires fetching each asset once and recording the "
           "bytes, which is an owner/CI action. STRICT on purpose: the moment "
           "someone populates the pins this test XPASSes, strict turns that "
           "into a failure, and whoever populated them is told to delete this "
           "marker. A gap marker that does not notice being closed becomes a "
           "permanent lie.")
def test_every_declared_runtime_input_is_pinned_by_hash():
    """The acceptance property itself: every external input this bundle
    downloads, extracts and executes has expected bytes recorded."""
    v = _lock_vars()
    unpinned = [k for k, val in v.items()
                if (k.startswith("PBS_SHA256_") or k.startswith("RG_SHA256_"))
                and not val]
    assert not unpinned, f"runtime inputs with no expected sha256: {unpinned}"
    assert v.get("PIP_REQUIRE_HASHES_FILE"), (
        "wheels are pinned by version but not by hash; pip --require-hashes "
        "refuses the whole install if any wheel's bytes differ")
