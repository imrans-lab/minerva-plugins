"""STANDING GUARD — NO PRODUCT BOARD DESIGNS IN THE PUBLIC REPOS.

``tests/testdata/POLICY.md`` bans real product board designs from this corpus:
"A real design in a fixture is an IP leak the moment it is pushed, and git
history keeps it forever." On 2026-07-30 one was removed. This file is the test
that says it stayed removed — and, unlike the shipped CI workflow, it looks for
the DESIGN rather than for a filename.

WHY THIS EXISTS ALONGSIDE ``.github/workflows/corpus-policy.yml``
----------------------------------------------------------------
That workflow checks two things, both cheap and both narrow:

  1. no tracked file is NAMED after the product; and
  2. no ``*.yml`` / ``*.yaml`` file declares the product's board identity.

Neither survives a rename. A board pasted into a ``.md``, a ``.py`` fixture, a
``.json`` snapshot or a docket record walks straight through both, because the
identity check is scoped to two globs and the name check to a path. This suite
closes that: it scans EVERY tracked text file of EVERY type, and it recognises a
board by its CONTENT.

HOW A BOARD IS RECOGNISED — AND WHY THE PATTERNS ARE NOT IN THIS FILE
--------------------------------------------------------------------
A guard that hard-codes the banned net names has to CONTAIN the banned net names,
which would make it the leak it is guarding against. So the identifying tokens
are read at run time from the board's PRIVATE home
(``~/gitlab/ccsandbox/...``), never committed here. Where that home is absent —
a CI runner, another developer's machine — the content half SKIPS. The identity
and filename halves still run, so the public repo is never left unguarded, and a
skip is visible in the pytest report rather than silently passing.

The recogniser is DENSITY, not presence. Per POLICY.md, "the design is the
netlist + placement, not the parts": a bug report that names three nets is a
mention, whereas a board file carries the whole netlist in one contiguous block.
So the score is *the number of distinct identifying tokens appearing inside one
sliding window of lines*, and the threshold sits in the empty gap between the two
populations — measured, with headroom pinned on both sides by
:func:`test_the_recogniser_has_headroom_above_prose_and_below_the_real_board`.

NEVER "fix" a failure here by deleting tokens from the private board, by widening
the window, or by raising the threshold. The failure means design data reached a
public repo; the fix is to remove it and rotate the containment record.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

HERE = Path(__file__).resolve().parent
#: The repo this suite lives in — always available, always scanned.
PLUGINS_ROOT = HERE.parent.parent.parent
#: The other public repo the campaign check names. Absent on a CI runner, which
#: is a skip for that repo alone rather than for the whole scan.
MINERVA_ROOT = Path(os.environ.get("MINERVA_ROOT",
                                   Path.home() / "github" / "Minerva"))
#: The board's PRIVATE home. Its existence is half the containment claim: the
#: design has to live SOMEWHERE, and that somewhere must not be a public repo.
PRIVATE_HOME = (Path.home() / "gitlab" / "ccsandbox" / "smart-remote" / "EDA"
                / "minerva-fab")
PRIVATE_BOARD = PRIVATE_HOME / "smart-remote-canonical.yaml"
#: A SECOND representation of the same design, used as an independent positive
#: control: if the recogniser only fired on the YAML it would be a YAML checker.
PRIVATE_BOARD_KICAD = PRIVATE_HOME / "smart-remote.kicad_pcb"

#: Lines per sliding window. Wide enough to span a netlist block, narrow enough
#: that tokens scattered through a 10k-line docket never accumulate.
WINDOW_LINES = 120
#: Distinct identifying tokens inside one window that mean "this IS the board".
#: Calibrated with 8 tokens of headroom on each side — see the headroom test.
LEAK_THRESHOLD = 24
#: The headroom each population must keep from the threshold. If either side
#: closes in, the threshold stopped separating and a human must re-measure
#: rather than nudge the number.
HEADROOM = 6

_needs_private = pytest.mark.skipif(
    not PRIVATE_BOARD.exists(),
    reason=f"the product board's private home ({PRIVATE_BOARD}) is not on this "
           f"machine, so the identifying tokens cannot be read; the identity and "
           f"filename halves of this suite still run")


# ---------------------------------------------------------------------------
# The recogniser
# ---------------------------------------------------------------------------


def _identity_tokens() -> list[str]:
    """The board's identifying vocabulary: every net name, every component
    reference, every footprint id, read from the PRIVATE board.

    Deliberately the union of all three. Any one of them alone is weak — nets
    like a ground rail and refs like ``U1`` belong to every board ever made —
    but the SET is the netlist, and the netlist is the design.
    """
    board = yaml.safe_load(PRIVATE_BOARD.read_text(encoding="utf-8"))
    tokens = {net["name"] for net in board.get("nets", ())}
    tokens |= {c["ref"] for c in board.get("components", ())}
    tokens |= {c["footprint"] for c in board.get("components", ())
               if c.get("footprint")}
    return sorted(t for t in tokens if t)


def _patterns(tokens):
    # Word-boundary-ish: a token must not be a substring of a longer identifier,
    # or "GND" would match "GND_PLANE_UNRELATED" and every score would inflate.
    return {t: re.compile(r"(?<![A-Za-z0-9_.\-])" + re.escape(t)
                          + r"(?![A-Za-z0-9_])") for t in tokens}


def _density(text: str, patterns) -> int:
    """Highest number of DISTINCT tokens co-occurring in one WINDOW_LINES-line
    window. See the module docstring on why this is density and not presence."""
    lines = text.splitlines() or [""]
    per_line = [{t for t, p in patterns.items() if p.search(line)}
                for line in lines]
    best = 0
    for start in range(len(lines)):
        window = per_line[start:start + WINDOW_LINES]
        if window:
            best = max(best, len(set().union(*window)))
    return best


def _repos() -> list[Path]:
    repos = [PLUGINS_ROOT]
    if (MINERVA_ROOT / ".git").exists():
        repos.append(MINERVA_ROOT)
    return repos


def _scan(repo: Path, tokens, patterns) -> list[tuple[int, str]]:
    """Score every tracked TEXT file in ``repo`` that mentions any token.

    Two steps for speed and for honesty: ``git grep -lI`` narrows thousands of
    tracked files to the handful worth reading (and ``-I`` is what keeps a
    binary from being scored as prose), then each candidate is scored in full.
    Files git cannot read are counted as unscanned rather than skipped silently.
    """
    args = ["git", "-C", str(repo), "grep", "-lI", "-F"]
    for token in tokens:
        args += ["-e", token]
    found = subprocess.run(args, capture_output=True, text=True,
                           check=False).stdout.split("\n")
    scored = []
    for name in filter(None, found):
        try:
            text = (repo / name).read_text(encoding="utf-8", errors="ignore")
        except OSError:  # pragma: no cover - a file listed but unreadable
            continue
        scored.append((_density(text, patterns), name))
    scored.sort(reverse=True)
    return scored


@pytest.fixture(scope="module")
def scan_results():
    tokens = _identity_tokens()
    patterns = _patterns(tokens)
    return tokens, patterns, {repo: _scan(repo, tokens, patterns)
                              for repo in _repos()}


# ---------------------------------------------------------------------------
# 1. CONTAINMENT — the design exists, and it is not here.
# ---------------------------------------------------------------------------


@_needs_private
def test_the_product_board_still_lives_in_its_private_home():
    """The other half of "it was removed": it was removed TO somewhere.

    A removal with no surviving private copy is data loss dressed as compliance,
    and it is also the state in which somebody "restores" the fixture from git
    history — the one repair this policy forbids outright.
    """
    assert PRIVATE_BOARD.exists() and PRIVATE_BOARD.stat().st_size > 0
    board = yaml.safe_load(PRIVATE_BOARD.read_text(encoding="utf-8"))
    assert board.get("nets"), "the private copy carries no netlist"
    assert board.get("components"), "the private copy carries no placement"


@_needs_private
def test_no_tracked_file_in_either_public_repo_carries_the_product_design(
        scan_results):
    """THE GATE. Both repos are PUBLIC (turnrocklabs/Minerva,
    imrans-lab/minerva-plugins). No tracked file in either may carry the
    product's netlist.

    Scores every tracked text file and fails on any that reaches the leak
    threshold — naming the file and its score, because "policy violation" with no
    file path is an alarm nobody can act on.
    """
    _tokens, _patterns_, per_repo = scan_results
    offenders = [(repo, score, name)
                 for repo, scored in per_repo.items()
                 for score, name in scored if score >= LEAK_THRESHOLD]
    assert not offenders, "\n".join(
        [f"PRODUCT DESIGN DATA in a PUBLIC repo — {len(offenders)} file(s):"]
        + [f"  [{repo.name}] {name}: {score} identifying tokens within "
           f"{WINDOW_LINES} lines (threshold {LEAK_THRESHOLD})"
           for repo, score, name in offenders]
        + ["Remove the design data. Do NOT raise the threshold, and do NOT "
           "resolve this by editing the private board."])


@_needs_private
def test_the_recogniser_actually_recognises_the_real_board(scan_results):
    """POSITIVE CONTROL — without this the gate above is unfalsifiable.

    A recogniser that scored zero on everything would pass the gate on a repo
    with the board committed at its root. So run it on the real design, in TWO
    independent representations (the canonical YAML and the KiCad board), and
    demand both clear the threshold. The KiCad file matters specifically: it
    shares no syntax with the YAML, so a recogniser that had quietly become a
    YAML-shape checker fails here.
    """
    _tokens, patterns, _ = scan_results
    for control in (PRIVATE_BOARD, PRIVATE_BOARD_KICAD):
        if not control.exists():  # pragma: no cover - second control is a bonus
            continue
        score = _density(control.read_text(encoding="utf-8", errors="ignore"),
                         patterns)
        assert score >= LEAK_THRESHOLD, (
            f"the recogniser scores the REAL board ({control.name}) at {score}, "
            f"below its own leak threshold {LEAK_THRESHOLD} — it would not "
            f"notice that board being committed here")


@_needs_private
def test_the_recogniser_has_headroom_above_prose_and_below_the_real_board(
        scan_results):
    """The threshold is only meaningful while the two populations stay apart.

    Design data and prose are separated by a wide empty band today. Pinning the
    band — rather than only the pass/fail — turns a gradual accumulation of
    product identifiers in a docket or a doc into a WARNING before it becomes a
    breach, and turns a private-board edit that thins the vocabulary into a
    failure instead of a quietly weaker gate.
    """
    _tokens, patterns, per_repo = scan_results
    control = _density(PRIVATE_BOARD.read_text(encoding="utf-8"), patterns)
    assert control >= LEAK_THRESHOLD + HEADROOM, (
        f"the real board scores {control}, only {control - LEAK_THRESHOLD} above "
        f"the threshold — re-measure both populations rather than trusting it")

    worst = max(((score, repo.name, name)
                 for repo, scored in per_repo.items() for score, name in scored),
                default=(0, "-", "-"))
    assert worst[0] <= LEAK_THRESHOLD - HEADROOM, (
        f"[{worst[1]}] {worst[2]} scores {worst[0]}, within {HEADROOM} of the "
        f"leak threshold {LEAK_THRESHOLD}. Nothing has breached policy yet, but "
        f"product identifiers are accumulating in a public file — look now.")


# ---------------------------------------------------------------------------
# 2. IDENTITY + FILENAME — the halves that need no private data, so they run
#    on every CI runner. Deliberately broader than the shipped workflow.
# ---------------------------------------------------------------------------


#: The board contract declares its own identity in a ``name:`` field. This is the
#: workflow's regex — but this suite applies it to EVERY tracked text file, not
#: only to two globs. The bare product string is NOT banned: it legitimately
#: appears as a symbol (``SMART_REMOTE_BASELINE``, pytest ids, corpus.py) in
#: about fifteen source files, and banning it would train people to route around
#: this guard.
_IDENTITY = re.compile(r"^[ \t]*name:[ \t]*[\"']?smart[-_ ]?remote",
                       re.IGNORECASE | re.MULTILINE)


def _tracked_text_files(repo: Path) -> list[str]:
    """Every tracked file git considers text (``-I`` excludes binaries)."""
    out = subprocess.run(
        ["git", "-C", str(repo), "grep", "-lI", "-e", ""],
        capture_output=True, text=True, check=False).stdout
    return [n for n in out.split("\n") if n]


@pytest.mark.parametrize("repo", _repos(), ids=lambda p: p.name)
def test_no_tracked_file_declares_the_product_board_identity(repo):
    """A renamed board still says what it is. The shipped workflow checks this
    for ``*.yml``/``*.yaml`` only; a board pasted into a ``.md``, a ``.py``
    fixture or a ``.json`` snapshot is invisible to it. This is the same check
    over every tracked text file."""
    offenders = [name for name in _tracked_text_files(repo)
                 if _IDENTITY.search(
                     (repo / name).read_text(encoding="utf-8", errors="ignore"))]
    assert not offenders, (
        f"[{repo.name}] these tracked files declare the banned board identity: "
        f"{offenders} — see pcb/worker/tests/testdata/POLICY.md")


@pytest.mark.parametrize("repo", _repos(), ids=lambda p: p.name)
def test_no_tracked_file_is_named_after_the_product(repo):
    """A file NAMED after the product is banned outright, whatever it contains —
    a path is public the moment it is pushed, even when the blob is empty."""
    tracked = subprocess.run(["git", "-C", str(repo), "ls-files"],
                             capture_output=True, text=True,
                             check=False).stdout.split("\n")
    banned = re.compile(r"smart[-_]?remote", re.IGNORECASE)
    offenders = [n for n in tracked if n and banned.search(n)]
    assert not offenders, (
        f"[{repo.name}] files named after the product are banned: {offenders}")


#: A PATH reference to the product, not board data. ``test_bus_routing.py``
#: (removed 2026-08-02, see docket 019fc1559f3c) hardcoded a path into the
#: owner's private ``ccsandbox`` checkout, with the product's own name as the
#: directory component — no netlist, no nets, nothing the density scan above
#: would ever see, but it is exactly
#: the "somewhere outside the repo" the private board is supposed to live,
#: spelled out in a public file. The bare product string is explicitly NOT
#: banned (``_IDENTITY``'s comment above), so this pattern is narrower than
#: "contains the token": it fires only when the token appears as a PATH
#: SEGMENT — immediately preceded by a bare ``/`` with no quote or space in
#: between. That catches a real filesystem path (``.../ccsandbox/smart-
#: remote/eda/...``) while leaving alone a symbol like
#: ``SMART_REMOTE_BASELINE`` or this file's own
#: ``Path.home() / "gitlab" / "ccsandbox" / "smart-remote"`` construction —
#: there the token is its own quoted literal, not path-adjacent text.
# KNOWN-ACCEPTED GAP (review F2, adjudicated): a filename that CONTINUES past
# the product name (``smart_remote_board.kicad_pcb``) is not matched — the
# boundary lookahead stops at a path separator/quote/space deliberately.
# Widening the tail to [-_.] was tried and flags 12 files of HISTORICAL PROSE
# (POLICY.md's own history note, ir_parity comments citing the REMOVED
# ``testdata/smart_remote.yaml``) — a regex cannot tell a live reference from
# a citation of a deleted one. The observed leak classes (a path INTO the
# private tree, the bare directory segment) are covered; the continuing-
# filename hypothetical is accepted and recorded here so the next widening
# attempt starts from this measurement.
_PATH_REFERENCE = re.compile(r"/smart[-_]?remote(?=[/\"'\s]|$)", re.IGNORECASE)


#: Scope decision: PLUGINS_ROOT only, deliberately narrower than ``_repos()``.
#: This pattern targets a CODE-level hazard — a test/fixture that DEFAULTS to
#: reading a private path, exactly what ``test_bus_routing.py`` did — which is
#: a property of this repo's own test corpus. It is not applied to MINERVA_ROOT
#: because that repo's tracked docket database (``Docs/minerva.dct``) is
#: project-management prose that discusses this very cleanup (and the
#: historical board removal) in the course of describing it — a different
#: governance question than "does a test hardcode a private default", and one
#: this suite has no authority to remediate (a different repo, and its docket
#: is live state, not source). The identity/filename bans above stay
#: cross-repo because THEIR hazard — a board file or identity declaration
#: landing anywhere public — is real in both repos regardless of file kind.
_PATH_REFERENCE_REPOS = [PLUGINS_ROOT]


@pytest.mark.parametrize("repo", _PATH_REFERENCE_REPOS, ids=lambda p: p.name)
def test_no_tracked_file_references_the_product_via_a_path_literal(repo):
    """A hardcoded PATH to the private board is not board data — the density
    scan above would never see it — but it is the same reference class:
    naming where the private design lives, in a public file. See
    ``_PATH_REFERENCE`` for why this is narrower than the bare-string ban,
    and ``_PATH_REFERENCE_REPOS`` for why the repo scope is narrower too.

    ``.dct`` docket databases are exempt for exactly the reason MINERVA_ROOT
    is (bug 01a0225bb250): they are project-management prose, and a record
    NARRATING this policy's own cleanup must be able to quote the banned
    construction without becoming an offender. The hazard this test targets
    — a test/fixture DEFAULTING to a private path — cannot live in a .dct:
    nothing executes it."""
    offenders = [name for name in _tracked_text_files(repo)
                 if not name.endswith(".dct")
                 and _PATH_REFERENCE.search(
                     (repo / name).read_text(encoding="utf-8", errors="ignore"))]
    assert not offenders, (
        f"[{repo.name}] these tracked files hardcode a path referencing the "
        f"banned product board: {offenders} — see "
        f"pcb/worker/tests/testdata/POLICY.md")


def test_the_path_reference_pattern_catches_a_hardcoded_private_path():
    """POSITIVE CONTROL, synthetic — proves the pattern has teeth without
    re-adding the real private path to this repo. This is structurally the
    line ``test_bus_routing.py`` carried before its removal (docket
    019fc1559f3c): a bare ``/`` immediately in front of the product token,
    inside a path string.

    Built by concatenation, not as one literal, so THIS file's own source
    bytes never contain the contiguous ``/smart-remote`` substring — the scan
    test above would otherwise flag this fixture as its own violation."""
    dash = "-"
    offending = ('    pcb_file = "/home/imran/gitlab/ccsandbox/smart' + dash
                 + 'remote/eda/output/smart_remote_board.kicad_pcb"')
    assert _PATH_REFERENCE.search(offending), (
        "the path-reference pattern does not catch a hardcoded private-board "
        "path — it would have missed the exact violation it was written for")


def test_the_path_reference_pattern_does_not_flag_the_bare_symbol():
    """NEGATIVE CONTROL — the bare product string is explicitly allowed
    (``_IDENTITY``'s own comment: it "legitimately appears as a symbol... in
    about fifteen source files"). A pattern that flagged every mention would
    make this suite itself an offender and would train people to route
    around the guard rather than trust it."""
    benign = 'SMART_REMOTE_BASELINE = "corpus fixture id, not a path"'
    assert not _PATH_REFERENCE.search(benign)
    quoted_join = 'Path.home() / "gitlab" / "ccsandbox" / "smart-remote"'
    assert not _PATH_REFERENCE.search(quoted_join), (
        "the pattern flagged this file's own Path()-join construction — "
        "each segment there is its own quoted literal, not a path-adjacent "
        "reference, and must stay unflagged")


def test_the_identity_scan_really_covers_more_than_the_workflow_does():
    """ANTI-VACUITY for the two tests above.

    Their whole claim over the shipped workflow is REACH: the workflow greps two
    YAML globs, these scan every tracked text file. If the file set silently
    collapsed to YAML — a bad ``git grep`` flag, an empty result read as "clean" —
    both tests would pass while checking almost nothing, which is precisely the
    failure mode this suite was written to close.

    So assert the reach directly: the scanned set must be large, and must contain
    the non-YAML extensions a pasted board would hide in.
    """
    scanned = _tracked_text_files(PLUGINS_ROOT)
    assert len(scanned) > 100, (
        f"only {len(scanned)} tracked text files scanned — the file enumeration "
        f"is broken, and both identity tests are passing vacuously")
    suffixes = {Path(name).suffix for name in scanned}
    for needed in (".md", ".py", ".json", ".yml"):
        assert needed in suffixes, (
            f"{needed} files are not being scanned; a board pasted into one "
            f"would walk through exactly as it does through the workflow")


def test_the_policy_document_is_present_and_states_the_rule():
    """The tests enforce a rule somebody has to be able to READ. If POLICY.md
    goes missing, every failure message above points at nothing."""
    policy = HERE / "testdata" / "POLICY.md"
    text = policy.read_text(encoding="utf-8")
    assert "banned" in text.lower() and "synthetic" in text.lower()
    assert "public" in text.lower()
