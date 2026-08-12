"""RENDERED BLESS -- the trust boundary a staged footprint must cross (S3/B2).

WHY THIS MODULE EXISTS
----------------------
The coincidence guard (``resolve``) compares a declared pin position against
the resolved footprint pad's CENTRE. That is a real check, and it is nowhere
near a trust boundary: it says nothing about pad SIZE, shape, drill diameter,
courtyard, pad NUMBERING, or whether the part is the one the datasheet
describes at all. A footprint whose pads are all half a millimetre too small,
or whose pins 1 and 2 are swapped, passes coincidence and fabricates garbage.

So the trust boundary is a HUMAN looking at a RENDERED footprint beside a FACT
TABLE and comparing both to the datasheet. This module produces exactly those
two artifacts and records the human's verdict in the acquisition lock, and it
makes an UNBLESSED part unable to supply copper.

TIERING (which parts need a human, and which do not)
---------------------------------------------------
=================  ===============  ==========================================
``source_kind``    tier             rationale
=================  ===============  ==========================================
``official_kicad`` ``auto``         upstream KiCad libraries are themselves
                                    reviewed and mass-verified; re-blessing
                                    each one by hand buys nothing and would
                                    train the reviewer to click through.
``git`` ``url``    ``human``        third-party text of unknown review depth:
``vendor_export``                   staged, then rendered-checked.
``hand_authored``  ``human``        WE typed the numbers. The rendered check
                   (MANDATORY)      is the ONLY thing standing between a typo
                                    and a fabricated board.
``generated``      ``human``        a synthesizer's output is only as good as
                                    its generator; treated like third-party.
=================  ===============  ==========================================

:data:`AUTO_BLESS_SOURCE_KINDS` is the single authority for that split, and
:func:`bless_footprint` REFUSES a manual verdict on an auto-tier entry (rather
than accepting and ignoring it) so a reviewer can never believe they signed off
on something the system actually decided by policy.

THE RESOLUTION GATE (the property that makes this a boundary, not a checklist)
-----------------------------------------------------------------------------
A staged-but-unblessed footprint must not be able to become copper by ANY path.
Two independent mechanisms, and neither one touches
``resolve_footprint_layered``'s core:

1. **The WIP layer's lock view EXCLUDES unblessed entries.**
   :func:`blessed_wip_layer` loads the WIP lock and hands back a
   :class:`~pcb_worker.footprints.LoadedLibraryLayer` whose ``lock`` dict
   contains ONLY blessed entries. ``lookup_footprint_layer`` decides the
   supplying layer purely by ``ref in loaded.lock``, so an unblessed ref is
   STRUCTURALLY ABSENT from the chain -- there is no code path in the resolver
   that could serve it, because the resolver is never told it exists. This is
   why the gate is a lock-VIEW filter and not a post-resolution check: a
   post-check can be forgotten by a new call site, a missing lock key cannot.
   It also fails in the safe direction -- an unblessed override of a seed part
   resolves to the SEED part (correct, pinned, blessed), never to the staged
   bytes.

2. **This module's own resolve entry point REFUSES by name.**
   :func:`resolve_wip_footprint` reads the RAW WIP lock first and, when the ref
   is staged but unblessed, raises :class:`BlessError` naming the ref and its
   bless state ("staged but not blessed"). Mechanism 1 alone would let such a
   ref fall silently through to a lower layer; for the staging surface -- where
   the caller has just staged the part and expects it -- silence is the wrong
   answer, so the attributed refusal lives here.

The raw, unfiltered WIP layer is never returned by any public function in this
module. It is built privately (:func:`_raw_wip_layer`) for exactly ONE purpose:
RENDERING an unblessed part so a human can look at it. Reporting sees staged
content; resolution does not. That asymmetry is the whole design, and it is why
there is no public constructor a caller could accidentally hand to a compile.

DETERMINISM
-----------
Nothing here reads the clock: ``blessed_at`` (and ``retrieved_at``) arrive from
the CALLER. The worker-method layer (``methods.py``) is where "now" is
supplied, so the library stays a pure function of its arguments and its tests
assert exact records.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
from typing import Any, Iterable, Union

from . import geometry
from .footprints import (
    LOCK_SCHEMA_VERSION,
    LOCK_SOURCE_KINDS,
    WIP_LAYER,
    FootprintLookupError,
    LibraryLayer,
    LoadedLibraryLayer,
    ResolvedFootprint,
    load_library_chain,
    load_lock_document,
    parse_kicad_mod,
    resolve_footprint_layered,
    sha256_file,
)


class BlessError(Exception):
    """Raised for every refusal this module owns: a malformed ref, missing or
    empty provenance, unparseable staged text, an illegal verdict, a tier
    violation, or a resolve of a staged-but-unblessed ref. Always attributed --
    the message names the ref and what specifically is wrong, because these
    refusals reach a human who is deciding whether to trust a part."""


# ---------------------------------------------------------------------------
# Tiering vocabulary.
# ---------------------------------------------------------------------------

TIER_AUTO = "auto"
TIER_HUMAN = "human"

VERDICT_APPROVED = "approved"
VERDICT_REJECTED = "rejected"
BLESS_VERDICTS = (VERDICT_APPROVED, VERDICT_REJECTED)

#: Source kinds whose provenance ALONE is sufficient (see the tiering table).
#: Deliberately a set of ONE: every widening of this set removes a human from
#: the loop for a whole class of parts, which is a decision, not a refactor.
AUTO_BLESS_SOURCE_KINDS = frozenset({"official_kicad"})

#: Source kinds where the rendered check is not merely required but is THE
#: control (we authored the numbers; nothing upstream reviewed them).
RENDER_CHECK_MANDATORY_SOURCE_KINDS = frozenset({"hand_authored"})

#: Attribution recorded as ``who`` for an auto-tier bless, so the lock never
#: carries a human name against a decision no human made.
AUTO_BLESS_ATTRIBUTION = "auto:source_kind=official_kicad"


def bless_tier_for(source_kind: str) -> str:
    """The tier a given ``source_kind`` blesses at (:data:`TIER_AUTO` or
    :data:`TIER_HUMAN`). Refuses an unknown kind rather than defaulting: an
    unrecognised provenance defaulting to ``auto`` would auto-trust exactly the
    parts nobody classified, and defaulting to ``human`` would silently accept
    a lock entry the census test (``test_library_lock``) considers malformed."""
    if source_kind not in LOCK_SOURCE_KINDS:
        raise BlessError(
            f"unknown source_kind {source_kind!r}; expected one of "
            f"{'/'.join(sorted(LOCK_SOURCE_KINDS))}")
    return TIER_AUTO if source_kind in AUTO_BLESS_SOURCE_KINDS else TIER_HUMAN


# ---------------------------------------------------------------------------
# WIP layer layout.
# ---------------------------------------------------------------------------
#
# The WIP root mirrors the shipped seed library's layout exactly -- footprints
# under ``footprints/<Lib>.pretty/<Name>.kicad_mod`` beside a
# ``footprints.lock.json`` -- so a staged library IS a library: it can be
# promoted to the user or project layer by moving a directory, with no
# rewriting, and ``LibraryLayer.profiles``' sibling convention lands on
# ``<wip_root>/profiles`` the same way the seed's does.

WIP_FOOTPRINT_DIRNAME = "footprints"
WIP_LOCK_FILENAME = "footprints.lock.json"


def wip_footprint_root(wip_root: Union[str, Path]) -> Path:
    """``<wip_root>/footprints`` -- the directory staged ``.pretty`` libraries
    live in (the ``root`` of the WIP :class:`LibraryLayer`)."""
    return Path(wip_root) / WIP_FOOTPRINT_DIRNAME


def wip_lock_path(wip_root: Union[str, Path]) -> Path:
    """``<wip_root>/footprints.lock.json`` -- the WIP layer's OWN acquisition
    lock (schema v2), independent of the shipped seed's."""
    return Path(wip_root) / WIP_LOCK_FILENAME


def _raw_wip_layer(wip_root: Union[str, Path]) -> LibraryLayer:
    """The UNFILTERED WIP layer. PRIVATE ON PURPOSE -- see the module docstring:
    handing this to a resolver would resolve unblessed bytes into copper, which
    is the one thing this module exists to prevent. Its only callers are the
    reporting path (which must see unblessed content so a human can look at it)
    and :func:`blessed_wip_layer` (which filters it)."""
    return LibraryLayer(name=WIP_LAYER, root=wip_footprint_root(wip_root),
                        lockfile=wip_lock_path(wip_root))


# ---------------------------------------------------------------------------
# WIP lock I/O.
# ---------------------------------------------------------------------------


def _atomic_write_text(path: Path, text: str) -> None:
    """Write *text* to *path* via temp+rename, so a crash mid-write can never
    leave a half-written lock (which would refuse the whole layer) or a
    truncated ``.kicad_mod`` (which would refuse the ref on sha mismatch).

    BYTES, not text mode: Windows' newline translation would turn each ``\\n``
    into ``\\r\\n`` on disk, so the staged file's sha256 would differ from the
    sha of the text that was pinned — every stage on Windows would then fail
    the disk-vs-wire cross-check and stay unblessed (caught by exactly that
    check on the windows-latest CI leg). Same rule as the seed library's
    ``.gitattributes -text``: the pinned sha covers the bytes, so nothing may
    rewrite them in transit."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(text.encode("utf-8"))
    os.replace(tmp, path)


def load_wip_lock(wip_root: Union[str, Path]) -> dict:
    """Load the WIP layer's lock DOCUMENT (``{schema_version, entries}``).

    An ABSENT lock is "nothing staged yet", not an error -- a fresh data
    directory has no WIP library and must not make every report/resolve fail.
    A PRESENT lock that is not schema v2 IS an error: v1 has no ``bless`` slot,
    so a v1 WIP lock could not express the gate at all, and quietly upgrading
    it would invent bless state nobody recorded."""
    lock_path = wip_lock_path(wip_root)
    if not lock_path.exists():
        return {"schema_version": LOCK_SCHEMA_VERSION, "entries": {}}
    doc = load_lock_document(lock_path)
    if doc.get("schema_version") != LOCK_SCHEMA_VERSION:
        raise BlessError(
            f"WIP lock {lock_path} is schema_version "
            f"{doc.get('schema_version')!r}; the bless gate requires v"
            f"{LOCK_SCHEMA_VERSION} (a v1 entry has no 'bless' slot, so its "
            f"blessed/unblessed state is unrepresentable rather than merely "
            f"unknown)")
    return doc


def _write_wip_lock(wip_root: Union[str, Path], doc: dict) -> None:
    """Persist the WIP lock document, key-sorted so a diff of two staging runs
    shows only what actually changed."""
    _atomic_write_text(wip_lock_path(wip_root),
                       json.dumps(doc, indent=2, sort_keys=True) + "\n")


def is_blessed(entry: Any) -> bool:
    """True only for a WELL-FORMED APPROVED bless record.

    Every departure from that -- ``None``, a non-dict, a rejected verdict, a
    missing tier/artifact/who -- is NOT blessed. A malformed record means
    nobody can say what was reviewed, and "cannot say" must never read as
    "approved" (the entire fail-closed premise of this module)."""
    bless = (entry or {}).get("bless") if isinstance(entry, dict) else None
    if not isinstance(bless, dict):
        return False
    if bless.get("verdict") != VERDICT_APPROVED:
        return False
    if bless.get("tier") not in (TIER_AUTO, TIER_HUMAN):
        return False
    if not isinstance(bless.get("artifact_sha256"), str) or not bless["artifact_sha256"]:
        return False
    if not isinstance(bless.get("who"), str) or not bless["who"]:
        return False
    if not isinstance(bless.get("blessed_at"), str) or not bless["blessed_at"]:
        return False
    return True


# ---------------------------------------------------------------------------
# The resolution gate.
# ---------------------------------------------------------------------------


def blessed_wip_layer(wip_root: Union[str, Path]) -> LoadedLibraryLayer:
    """The WIP layer AS A RESOLVER MAY SEE IT: a loaded layer whose lock view
    contains ONLY blessed entries (mechanism 1 in the module docstring).

    An unblessed or rejected ref is simply not a key of the returned ``lock``,
    so ``lookup_footprint_layer`` never selects the WIP layer for it and the
    chain continues to the layers below. There is no branch to forget and no
    flag to check: the resolver cannot serve what it was never handed."""
    doc = load_wip_lock(wip_root)
    entries = doc.get("entries") or {}
    return LoadedLibraryLayer(
        layer=_raw_wip_layer(wip_root),
        lock={ref: entry for ref, entry in entries.items() if is_blessed(entry)},
        # The capability bit (Codex 1160 P1): resolution refuses any WIP view
        # without it, and this filtered view is one of exactly two authorized
        # constructors (the other is footprint_report's render-only raw view).
        wip_view_authorized=True,
    )


def blessed_library_chain(
    wip_root: Union[str, Path],
    *,
    layers: Union[Iterable, None] = None,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> tuple[LoadedLibraryLayer, ...]:
    """The full resolution chain with the BLESSED WIP layer on top.

    ``layers`` configures the lower layers exactly as
    :func:`~pcb_worker.footprints.load_library_chain` does (the seed is
    appended automatically and cannot be dropped). Declaring a ``wip`` layer
    THERE is refused: it would put an unfiltered WIP lock into the chain beside
    the filtered one, and ``normalize_library_layers`` would then reject the
    duplicate name anyway -- refusing here names the real mistake instead."""
    base = load_library_chain(layers, library_root=library_root, lockfile=lockfile)
    for loaded in base:
        if loaded.layer.name == WIP_LAYER:
            raise BlessError(
                "a 'wip' layer must not be configured through `layers`: the WIP "
                "layer is supplied by blessed_library_chain itself, with its "
                "lock view filtered to BLESSED entries only. Passing a raw wip "
                "layer would bypass the bless gate entirely")
    # `base` is already precedence-sorted and contains no wip layer, and wip is
    # the highest-precedence name, so prepending preserves the chain order.
    return (blessed_wip_layer(wip_root),) + tuple(base)


def resolve_wip_footprint(
    ref: str,
    wip_root: Union[str, Path],
    *,
    layers: Union[Iterable, None] = None,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> ResolvedFootprint:
    """Resolve *ref* through the blessed chain, refusing BY NAME when the ref is
    staged in WIP but not blessed (mechanism 2 in the module docstring).

    Without this explicit check the ref would merely fall through to a lower
    layer -- correct (nothing unblessed is served) but SILENT, and silence here
    reads as "my staged part is live" to the one caller who just staged it."""
    entries = (load_wip_lock(wip_root).get("entries") or {})
    entry = entries.get(ref)
    if entry is not None and not is_blessed(entry):
        raise BlessError(_unblessed_message(ref, wip_root, entry))
    return resolve_footprint_layered(
        ref,
        chain=blessed_library_chain(wip_root, layers=layers,
                                    library_root=library_root, lockfile=lockfile),
    )


def _unblessed_message(ref: str, wip_root: Union[str, Path], entry: dict) -> str:
    """The attributed refusal text for a staged-but-unblessed ref. States the
    CURRENT bless state explicitly, because "rejected" and "never reviewed" call
    for opposite next actions (re-author vs. review)."""
    bless = entry.get("bless") if isinstance(entry, dict) else None
    if not isinstance(bless, dict):
        state = "never reviewed (bless is null)"
    elif bless.get("verdict") == VERDICT_REJECTED:
        state = (f"REJECTED by {bless.get('who')!r} at {bless.get('blessed_at')!r}")
    else:
        state = f"a malformed bless record ({bless!r}) which does not count as approval"
    kind = entry.get("source_kind")
    return (
        f"footprint ref {ref!r} is STAGED BUT NOT BLESSED in the wip library "
        f"layer at {Path(wip_root)}: {state}. A staged footprint supplies copper "
        f"only after a rendered check is recorded against it (source_kind "
        f"{kind!r} blesses at tier {_tier_or_unknown(kind)!r}); until then it is "
        f"excluded from every resolution chain rather than silently shadowing a "
        f"lower layer's part"
    )


def _tier_or_unknown(source_kind: Any) -> str:
    try:
        return bless_tier_for(source_kind)
    except BlessError:
        return "unknown"


# ---------------------------------------------------------------------------
# Staging.
# ---------------------------------------------------------------------------


def _split_ref(ref: Any) -> tuple[str, str]:
    """Split a ``"Lib:Name"`` ref into its library nickname and part name.

    Refuses anything that could not become a safe relative path: a missing or
    doubled ``:``, an empty half, a path separator, or a ``..`` segment. The ref
    becomes a FILESYSTEM PATH under the WIP root, so an unvalidated ref is a
    write-anywhere primitive -- and the caller of the staging tool is an LLM."""
    if not isinstance(ref, str) or not ref.strip():
        raise BlessError(f"footprint ref must be a non-empty string; got {ref!r}")
    if ref.count(":") != 1:
        raise BlessError(
            f"footprint ref {ref!r} must be exactly 'LibNick:PartName' "
            f"(one ':'); the library nickname names the .pretty directory the "
            f"staged file is written into")
    lib, part = ref.split(":", 1)
    for label, value in (("library nickname", lib), ("part name", part)):
        if not value:
            raise BlessError(f"footprint ref {ref!r} has an empty {label}")
        if value in (".", "..") or any(sep in value for sep in ("/", "\\", os.sep)):
            raise BlessError(
                f"footprint ref {ref!r} has a {label} ({value!r}) containing a "
                f"path separator or traversal segment; the ref becomes a path "
                f"under the WIP root and must not be able to escape it")
    return lib, part


def _require_nonempty(name: str, value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BlessError(
            f"{name} is required and must be a non-empty string; got {value!r}. "
            f"An entry without it cannot state where the part came from, which "
            f"is the whole point of the acquisition lock")
    return value


def _validate_kicad_mod_text(ref: str, text: Any) -> dict:
    """Parse staged ``.kicad_mod`` text, refusing anything that is not one.

    Called BEFORE a single byte is written: the "unparseable text writes
    nothing" property is a consequence of the ORDER, not of any cleanup path.

    ``parse_kicad_mod`` is deliberately lenient (it is also fed real-world
    library text with unknown tokens), so it does NOT raise on arbitrary
    prose -- ``parse_kicad_mod("not a footprint")`` returns an empty-pad dict.
    The three checks here are what turn that leniency into a gate: an
    s-expression container headed by ``footprint``/``module``, balanced
    parentheses (catches truncation, the most likely real corruption), and at
    least one pad (a footprint with no pads cannot be placed and cannot be
    rendered-checked against a datasheet)."""
    if not isinstance(text, str) or not text.strip():
        raise BlessError(f"{ref}: kicad_mod_text is empty")
    stripped = text.strip()
    if not stripped.startswith("("):
        raise BlessError(
            f"{ref}: kicad_mod_text is not a KiCad s-expression (it does not "
            f"start with '('); refusing before writing anything")
    head = stripped[1:].split(None, 1)[0] if len(stripped) > 1 else ""
    if head not in ("footprint", "module"):
        raise BlessError(
            f"{ref}: kicad_mod_text's root node is {head!r}; a .kicad_mod must "
            f"be headed by 'footprint' (KiCad 6+) or 'module' (KiCad 5)")
    if not _parens_balanced(stripped):
        raise BlessError(
            f"{ref}: kicad_mod_text has unbalanced parentheses (truncated or "
            f"corrupted); refusing before writing anything")
    try:
        parsed = parse_kicad_mod(stripped)
    except Exception as exc:  # noqa: BLE001 - any parser fault is a refusal
        raise BlessError(f"{ref}: kicad_mod_text failed to parse: {exc}") from exc
    if not parsed.get("pads"):
        raise BlessError(
            f"{ref}: the parsed footprint has NO pads; a padless footprint "
            f"cannot be placed, cannot be rendered-checked against a datasheet, "
            f"and would resolve to a component with no copper")
    return parsed


def _parens_balanced(text: str) -> bool:
    """Paren balance OUTSIDE quoted strings (KiCad quotes may contain parens,
    and backslash escapes them -- the same two rules the module's tokenizer
    applies)."""
    depth = 0
    in_str = False
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                return False
        i += 1
    return depth == 0 and not in_str


def cross_check_fetched_sha256(ref: str, kicad_mod_text: Any,
                               fetched_sha256: Any) -> str:
    """Refuse unless *kicad_mod_text* hashes to *fetched_sha256*. Returns the hash.

    The acquisition path (S4/B3) fetches bytes in GO and stages them HERE, so the
    text crosses a process boundary between the only two places that can see it.
    Go hashes what came off the wire; this hashes what arrived. Agreement is the
    claim "the bytes about to be pinned are the bytes that were fetched", and it
    is worth stating precisely because the sha this staging writes into the lock
    is computed from the text on THIS side -- a corruption in transit would
    otherwise be pinned as a perfectly self-consistent entry, with the lock
    swearing to bytes nobody upstream ever served.

    Called BEFORE :func:`stage_footprint`, so a mismatch writes nothing at all --
    the same ordering rule staging itself follows.
    """
    if not isinstance(kicad_mod_text, str) or not kicad_mod_text.strip():
        raise BlessError(f"{ref}: kicad_mod_text is empty")
    expected = _require_nonempty("fetched_sha256", fetched_sha256).strip().lower()
    got = hashlib.sha256(kicad_mod_text.encode("utf-8")).hexdigest()
    if got != expected:
        raise BlessError(
            f"{ref}: sha256 CROSS-CHECK FAILED -- the fetcher reported "
            f"{expected} for the bytes it downloaded, but the text that arrived "
            f"hashes to {got}. The two are independent derivations of what is "
            f"supposed to be one file, so a disagreement means the content "
            f"changed in transit; nothing was staged and no lock was touched")
    return got


def _blank_assembly() -> dict:
    """The reserved ``assembly`` slot, declared explicitly (never implied) --
    the same shape every shipped seed entry carries, so the census test's
    "reserved slots exist" predicate holds for staged entries too."""
    return {"mpn": None, "dist_part_numbers": [], "package": None,
            "orientation_convention": None}


def stage_footprint(
    ref: str,
    kicad_mod_text: str,
    wip_root: Union[str, Path],
    *,
    source_kind: str,
    source_ref: str,
    license: str,
    retrieved_at: str,
    provenance_note: Union[str, None] = None,
    original_source_path: Union[str, None] = None,
    converter_version: Union[str, None] = None,
) -> dict:
    """Stage a ``.kicad_mod`` into the WIP layer and pin it. Returns the entry.

    (The brief names the first parameter ``name``; it is ``ref`` here because
    what the caller passes is the FULL ``"Lib:Name"`` ref -- the same string
    every other resolution API in this package calls ``ref`` -- while the
    footprint's own internal ``name`` is a different value read out of the text.
    Two different things must not share one parameter name in a module whose
    job is provenance.)

    ORDER IS THE CONTRACT, and it is what makes the "bad input writes NOTHING"
    property true rather than merely usually-true:

    1. validate the ref (it becomes a path), the provenance, and the TEXT --
       all before touching the filesystem;
    2. write ``<wip_root>/footprints/<Lib>.pretty/<Name>.kicad_mod`` (atomic);
    3. sha-pin the bytes actually on disk and write the WIP lock (atomic).

    A crash between 2 and 3 leaves an ORPHAN FILE that nothing references --
    harmless, because a ref with no lock entry resolves from no layer. The
    opposite order would leave a lock entry pointing at a missing file, which
    is a hard refusal of that ref (anti-shadowing). Given a choice between an
    inert leftover and a poisoned lock, this takes the leftover.

    ``bless`` is written as ``None``: staging is ACQUISITION, never approval,
    including for ``official_kicad`` (whose auto-bless is still an explicit
    :func:`auto_bless_footprint` call that regenerates and records a render).
    Re-staging an existing ref REPLACES its entry and RESETS ``bless`` to
    ``None`` -- new bytes were never reviewed, and carrying the old verdict
    across a content change would bless something nobody saw.
    """
    lib, part = _split_ref(ref)
    source_kind = _require_nonempty("source_kind", source_kind)
    bless_tier_for(source_kind)  # refuses an unknown kind before any write
    license = _require_nonempty("license", license)
    source_ref = _require_nonempty("source_ref", source_ref)
    retrieved_at = _require_nonempty("retrieved_at", retrieved_at)
    _validate_kicad_mod_text(ref, kicad_mod_text)

    rel = f"{lib}.pretty/{part}.kicad_mod"
    dest = wip_footprint_root(wip_root) / f"{lib}.pretty" / f"{part}.kicad_mod"
    _atomic_write_text(dest, kicad_mod_text)

    entry = {
        "path": rel,
        "sha256": sha256_file(dest),
        "size_bytes": dest.stat().st_size,
        "source_kind": source_kind,
        "source_ref": source_ref,
        "license": license,
        "retrieved_at": retrieved_at,
        "layer": WIP_LAYER,
        "original_source_path": original_source_path,
        "converter_version": converter_version,
        "model3d_ref": None,
        "assembly": _blank_assembly(),
        "bless": None,
    }
    if provenance_note:
        entry["provenance_note"] = provenance_note

    doc = load_wip_lock(wip_root)
    doc.setdefault("entries", {})[ref] = entry
    doc["schema_version"] = LOCK_SCHEMA_VERSION
    _write_wip_lock(wip_root, doc)
    return dict(entry)


# ---------------------------------------------------------------------------
# Bless records.
# ---------------------------------------------------------------------------


def _staged_entry(wip_root: Union[str, Path], ref: str) -> tuple[dict, dict]:
    doc = load_wip_lock(wip_root)
    entries = doc.get("entries") or {}
    entry = entries.get(ref)
    if not isinstance(entry, dict):
        raise BlessError(
            f"footprint ref {ref!r} is not staged in the wip layer at "
            f"{Path(wip_root)}; stage_footprint must run before a bless can "
            f"name what was reviewed")
    return doc, entry


def _record_bless(wip_root, ref, *, tier, verdict, who, blessed_at,
                  expected_artifact_sha256=None, layers=None) -> dict:
    """Regenerate the report, then write the bless record. Shared by both tiers.

    THE REPORT IS REGENERATED HERE, not accepted from the caller, for two
    reasons. First, a bless must be impossible for a footprint that cannot be
    rendered at all -- otherwise the tier that most needs the picture is the
    one that can skip it. Second, the recorded ``artifact_sha256`` has to
    identify the artifact THIS record blesses; a caller-supplied hash would let
    a reviewer approve one picture and pin another.

    ``expected_artifact_sha256`` is the binding half (Codex 1160 P1): the HUMAN
    tier passes the digest of the report the reviewer actually looked at, and a
    mismatch against the regeneration REFUSES with the entry untouched -- if the
    staged bytes (or the report's contents) changed between review and bless,
    the approval must not transfer to the new artifact. The regenerated report
    and the recorded entry come from the same lock read below, so the record
    can never bind a digest to bytes other than the ones it just rendered."""
    report = footprint_report(ref, wip_root=wip_root, layers=layers)
    if (expected_artifact_sha256 is not None
            and report["artifact_sha256"] != expected_artifact_sha256):
        raise BlessError(
            f"{ref!r}: the staged content or its report changed since the "
            f"review — expected artifact {expected_artifact_sha256}, but the "
            f"current staged entry renders {report['artifact_sha256']}. "
            f"Re-run footprint_report, review the CURRENT artifact, and bless "
            f"that. Nothing was recorded")
    doc, entry = _staged_entry(wip_root, ref)
    entry["bless"] = {
        "tier": tier,
        "verdict": verdict,
        "who": who,
        "artifact_sha256": report["artifact_sha256"],
        "content_sha256": entry.get("sha256"),
        "blessed_at": blessed_at,
    }
    doc["entries"][ref] = entry
    _write_wip_lock(wip_root, doc)
    return dict(entry)


def bless_footprint(
    ref: str,
    wip_root: Union[str, Path],
    verdict: str,
    who: str,
    blessed_at: str,
    expected_artifact_sha256: str,
    *,
    layers: Union[Iterable, None] = None,
) -> dict:
    """Record a HUMAN verdict on a staged footprint. Returns the updated entry.

    ``verdict`` is ``"approved"`` or ``"rejected"``; ``who`` names the human;
    ``blessed_at`` is supplied by the caller (this module never reads the
    clock -- see the module docstring).

    ``expected_artifact_sha256`` is REQUIRED and is the ``artifact_sha256`` of
    the :func:`footprint_report` the human actually reviewed. If the staged
    content (or anything the report covers) changed since that review, the
    bless REFUSES rather than silently transferring the approval to an
    artifact nobody looked at (Codex 1160 P1).

    An ``official_kicad`` entry REFUSES here and names
    :func:`auto_bless_footprint` instead. Accepting the manual verdict would be
    worse than useless: it would leave a lock recording a human review of a part
    the policy auto-trusts either way, so nobody could later tell which entries
    a human actually looked at.

    A ``rejected`` verdict is RECORDED, not deleted -- the entry stays staged
    and stays unresolvable (:func:`is_blessed` is false), so the rejection is
    durable evidence rather than a hole where a part used to be.
    """
    _, entry = _staged_entry(wip_root, ref)
    source_kind = entry.get("source_kind")
    tier = bless_tier_for(source_kind)
    if tier == TIER_AUTO:
        raise BlessError(
            f"{ref!r} has source_kind {source_kind!r}, which AUTO-BLESSES: it "
            f"does not take a human verdict. Call auto_bless_footprint instead. "
            f"(Recording a manual verdict here would make the lock unable to "
            f"distinguish parts a human actually reviewed from parts policy "
            f"trusted on provenance alone.)")
    if verdict not in BLESS_VERDICTS:
        raise BlessError(
            f"{ref}: verdict must be one of {'/'.join(BLESS_VERDICTS)}; got "
            f"{verdict!r}")
    who = _require_nonempty("who", who)
    blessed_at = _require_nonempty("blessed_at", blessed_at)
    expected_artifact_sha256 = _require_nonempty(
        "expected_artifact_sha256", expected_artifact_sha256)
    return _record_bless(wip_root, ref, tier=TIER_HUMAN, verdict=verdict,
                         who=who, blessed_at=blessed_at,
                         expected_artifact_sha256=expected_artifact_sha256,
                         layers=layers)


def auto_bless_footprint(
    ref: str,
    wip_root: Union[str, Path],
    blessed_at: str,
    *,
    who: Union[str, None] = None,
    layers: Union[Iterable, None] = None,
) -> dict:
    """Record an AUTO-tier bless for a provenance-trusted staged footprint.

    Refuses every source kind outside :data:`AUTO_BLESS_SOURCE_KINDS`, naming
    the tier that kind actually requires -- most importantly ``hand_authored``,
    where the rendered check is the only control that exists.

    The report is still generated and its sha recorded (see
    :func:`_record_bless`): "auto" means no HUMAN verdict, not "no artifact".
    An auto-blessed entry a viewer cannot render is a lock entry nobody could
    ever audit.
    """
    _, entry = _staged_entry(wip_root, ref)
    source_kind = entry.get("source_kind")
    tier = bless_tier_for(source_kind)
    if tier != TIER_AUTO:
        mandatory = (" the rendered check is MANDATORY for this kind -- we "
                     "authored the numbers, so nothing upstream reviewed them"
                     if source_kind in RENDER_CHECK_MANDATORY_SOURCE_KINDS else "")
        raise BlessError(
            f"{ref!r} has source_kind {source_kind!r}, which blesses at tier "
            f"{tier!r} and requires an explicit human verdict "
            f"(bless_footprint).{mandatory}")
    blessed_at = _require_nonempty("blessed_at", blessed_at)
    return _record_bless(wip_root, ref, tier=TIER_AUTO, verdict=VERDICT_APPROVED,
                         who=who or AUTO_BLESS_ATTRIBUTION,
                         blessed_at=blessed_at, layers=layers)


# ---------------------------------------------------------------------------
# The report: fact table + SVG.
# ---------------------------------------------------------------------------


def footprint_report(
    ref: str,
    *,
    wip_root: Union[str, Path, None] = None,
    layers: Union[Iterable, None] = None,
    chain: Union[Iterable[LoadedLibraryLayer], None] = None,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
) -> dict:
    """The two artifacts a human blesses: a FACT TABLE and an SVG RENDER.

    Returns::

        {ref, facts: {...}, svg: "<svg …>", svg_sha256, not_rendered: [...]}

    ``wip_root`` puts the RAW (unfiltered) WIP layer at the top of the chain --
    the one place unblessed content is visible, because a part nobody can look
    at can never be blessed. Every OTHER path through this module resolves
    through :func:`blessed_library_chain`. Omit it and the report reads the
    ordinary chain (seed alone by default).

    ``not_rendered`` is the honesty contract: EVERY element of the parsed
    footprint that the renderer does not draw is listed, with a reason. An
    empty ``not_rendered`` therefore means "the picture is complete" -- which is
    the only condition under which a human comparing the picture to a datasheet
    is checking the whole part. A renderer that silently skipped an unmodelled
    primitive would hand a reviewer a picture that looks finished and is not,
    and the reviewer would sign it.

    Raises :class:`~pcb_worker.footprints.FootprintLookupError` (attributed,
    naming the ref and the layers searched) when the ref does not resolve.
    """
    if chain is None:
        base = load_library_chain(layers, library_root=library_root,
                                  lockfile=lockfile)
        if wip_root is not None:
            doc = load_wip_lock(wip_root)
            # RAW view, deliberately: a part nobody can render can never be
            # blessed. wip_view_authorized marks this as the ONE authorized raw
            # consumer — the resolution the report performs stays inside this
            # function and its output is a picture, never compiled geometry.
            chain = (LoadedLibraryLayer(layer=_raw_wip_layer(wip_root),
                                        lock=dict(doc.get("entries") or {}),
                                        wip_view_authorized=True),) + base
        else:
            chain = base
    resolved = resolve_footprint_layered(ref, chain=chain)

    facts, geom = _facts(resolved)
    svg, not_rendered = _render_svg(resolved.parsed, geom)
    # MASK HONESTY (Codex 1160 P1): the SVG draws copper, not mask apertures.
    # For a pad with no margin override the aperture is the land (nothing to
    # show beyond the pad already drawn), but a declared mask/paste margin
    # CHANGES fabricated geometry the picture does not depict — so every such
    # pad gets a not_rendered entry pointing at the fact rows. A reviewer who
    # sees an empty not_rendered on a margin-carrying pad would be signing
    # mask geometry they never saw.
    not_rendered = list(not_rendered)
    for p in (resolved.parsed.get("pads") or []):
        for field in ("solder_mask_margin", "solder_paste_margin"):
            if p.get(field) is not None:
                not_rendered.append({
                    "kind": "pad_margin_not_drawn",
                    "pad": p.get("number"),
                    "field": field,
                    "value": p.get(field),
                    "detail": (
                        f"pad {p.get('number')!r} declares {field}={p.get(field)!r}; "
                        f"the aperture this fabricates is NOT drawn in the SVG — "
                        f"verify it from the fact table row"),
                })
    svg_sha = hashlib.sha256(svg.encode("utf-8")).hexdigest()
    # THE ARTIFACT DIGEST a bless must quote back (Codex 1160 P1: a human
    # approval must bind to the artifact the human reviewed, not to whatever a
    # later regeneration produces). It covers the staged bytes' content sha,
    # the COMPLETE fact table, the honesty list, and the picture — change any
    # of them and the digest moves, so a bless quoting the old digest refuses.
    artifact_sha256 = hashlib.sha256(json.dumps({
        "content_sha256": resolved.entry.get("sha256"),
        "facts": facts,
        "not_rendered": not_rendered,
        "svg_sha256": svg_sha,
    }, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return {
        "ref": ref,
        "facts": facts,
        "svg": svg,
        "svg_sha256": svg_sha,
        "artifact_sha256": artifact_sha256,
        "not_rendered": not_rendered,
    }


def _pad_sort_key(number: Any) -> tuple:
    """Numeric pad numbers sort numerically, everything else lexicographically
    after them. ``"10"`` must not sort before ``"2"`` in a table a human reads
    against a datasheet pinout."""
    s = str(number)
    try:
        return (0, float(s), "")
    except ValueError:
        return (1, 0.0, s)


#: Layers the SVG draws. Paste is deliberately absent: a stencil aperture is
#: not part of "is this the right part" and drawing it over copper would make
#: the pad picture ambiguous. Its geometry is reported in ``not_rendered``.
_RENDERED_GRAPHIC_LAYERS = {
    "F.SilkS": "silk-top", "B.SilkS": "silk-bot",
    "F.CrtYd": "crtyd", "B.CrtYd": "crtyd",
    "F.Fab": "fab", "B.Fab": "fab",
}

_COURTYARD_LAYERS = ("F.CrtYd", "B.CrtYd")
_BODY_LAYERS = ("F.Fab", "B.Fab")


def _bbox_of(points: Iterable) -> Union[dict, None]:
    xs, ys = [], []
    for (x, y) in points:
        if x is None or y is None:
            continue
        xs.append(float(x))
        ys.append(float(y))
    if not xs:
        return None
    return {"min_x_mm": min(xs), "min_y_mm": min(ys),
            "max_x_mm": max(xs), "max_y_mm": max(ys),
            "width_mm": max(xs) - min(xs), "height_mm": max(ys) - min(ys)}


def _graphic_points(g: dict) -> list:
    """Every defining point of a parsed graphic, in footprint-local coords.

    Used for bounding boxes only, so an arc contributes its three defining
    points and a circle its centre +/- radius box corners -- CENTRELINE
    geometry, with no stroke width added. A bbox that silently included half a
    silk stroke would disagree with the numbers a caller measures off the
    picture."""
    kind = g.get("kind")
    if kind == "line":
        return [tuple(g.get("start") or (None, None)), tuple(g.get("end") or (None, None))]
    if kind == "circle":
        cx, cy = g.get("center") or (None, None)
        r = g.get("radius")
        if cx is None or cy is None or r is None:
            return []
        return [(cx - r, cy - r), (cx + r, cy + r)]
    if kind in ("poly", "arc"):
        return [tuple(p) for p in (g.get("points") or []) if p]
    return []


def _pad_corner_points(pad: dict) -> list:
    """The four corners of a pad's bounding box in footprint-local coords, with
    the pad's own local rotation applied through the ONE pinned rotation
    authority (:func:`pcb_worker.geometry.rotate_local_offset` -- KiCad's
    clockwise-in-a-y-down-frame convention, pinned by tests/test_rotation.py).
    Re-deriving the sign here would create a second rotation convention in the
    worker, which is the exact defect that module was consolidated to remove."""
    x, y = pad.get("x_mm"), pad.get("y_mm")
    size = pad.get("size") or []
    if x is None or y is None or len(size) < 2 or size[0] is None or size[1] is None:
        return []
    hw, hh = float(size[0]) / 2.0, float(size[1]) / 2.0
    rot = float(pad.get("rotation") or 0.0)
    out = []
    for dx, dy in ((-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)):
        ox, oy = geometry.rotate_local_offset(dx, dy, rot)
        out.append((float(x) + ox, float(y) + oy))
    return out


def _facts(resolved: ResolvedFootprint) -> tuple[dict, dict]:
    """Build the fact table, and the geometry summary the renderer reuses.

    The fact table is the SECOND artifact of the bless (the picture is the
    first) and answers what a picture cannot: exact pad numbering, exact
    dimensions, and where the bytes came from. All coordinates are in
    footprint-LOCAL space with KiCad's y-DOWN sign -- i.e. verbatim what the
    ``.kicad_mod`` says, so a reviewer can diff the table against the file.
    (The SVG flips y; see :func:`_render_svg`. The table does not, because its
    job is to agree with the source text.)"""
    parsed = resolved.parsed
    entry = resolved.entry
    pads = sorted((parsed.get("pads") or []),
                  key=lambda p: _pad_sort_key(p.get("number")))
    graphics = parsed.get("graphics") or []

    # EVERY fab-affecting pad field is a row in this table (Codex 1160 P1: two
    # footprints differing only by a mask margin MUST produce different facts —
    # the compiler carries these into the fab IR, so a table that omits them
    # lets a reviewer approve mask geometry they never saw). Keys are always
    # present (None when the source doesn't carry the field) so two tables
    # diff cleanly row-by-row.
    pad_facts = [{
        "number": p.get("number"),
        "type": p.get("type"),
        "shape": p.get("shape"),
        "x_mm": p.get("x_mm"),
        "y_mm": p.get("y_mm"),
        "size": list(p["size"]) if isinstance(p.get("size"), list) else p.get("size"),
        "drill": p.get("drill"),
        "drill_shape": p.get("drill_shape"),
        "drill_size": list(p["drill_size"]) if isinstance(p.get("drill_size"), list) else p.get("drill_size"),
        "layers": list(p.get("layers") or []),
        "rotation": p.get("rotation"),
        "roundrect_rratio": p.get("roundrect_rratio"),
        "solder_mask_margin": p.get("solder_mask_margin"),
        "solder_paste_margin": p.get("solder_paste_margin"),
    } for p in pads]

    courtyard_pts, body_pts, all_pts = [], [], []
    for g in graphics:
        pts = _graphic_points(g)
        all_pts.extend(pts)
        if g.get("layer") in _COURTYARD_LAYERS:
            courtyard_pts.extend(pts)
        elif g.get("layer") in _BODY_LAYERS:
            body_pts.extend(pts)
    for p in pads:
        all_pts.extend(_pad_corner_points(p))

    facts = {
        "ref": resolved.ref,
        "footprint_name": parsed.get("name"),
        "layer": resolved.layer,
        "source_kind": entry.get("source_kind"),
        "license": entry.get("license"),
        "source_ref": entry.get("source_ref"),
        "pad_count": len(pad_facts),
        "pad_numbers": [p["number"] for p in pad_facts],
        "pads": pad_facts,
        "courtyard_bbox": _bbox_of(courtyard_pts),
        "body_bbox": _bbox_of(body_pts),
        # Package/assembly identity rides the report so the reviewer sees the
        # same part-identity fields the lock will carry (Codex 1160 P1).
        "assembly": entry.get("assembly"),
    }
    return facts, {"extent": _bbox_of(all_pts)}


# ---------------------------------------------------------------------------
# SVG rendering.
# ---------------------------------------------------------------------------

_SVG_MARGIN_MM = 0.6
_SVG_PX_PER_MM = 24.0
_DEFAULT_STROKE_MM = 0.05

_SVG_STYLE = """
.bg{fill:#ffffff}
.pad-top{fill:#c0392b;fill-opacity:0.85;stroke:#7b1f16;stroke-width:0.02}
.pad-bot{fill:#2471a3;fill-opacity:0.85;stroke:#154360;stroke-width:0.02}
.pad-both{fill:#8e44ad;fill-opacity:0.85;stroke:#4a235a;stroke-width:0.02}
.pad-none{fill:none;stroke:#616a6b;stroke-width:0.04}
.drill{fill:#ffffff;stroke:#212f3d;stroke-width:0.02}
.silk-top{fill:none;stroke:#f4f6f6;stroke-linecap:round}
.silk-bot{fill:none;stroke:#aeb6bf;stroke-linecap:round;stroke-dasharray:0.3 0.15}
.fab{fill:none;stroke:#b7950b;stroke-linecap:round}
.crtyd{fill:none;stroke:#ec7063;stroke-dasharray:0.4 0.2}
.origin{stroke:#5d6d7e;stroke-width:0.02}
"""


def _svg_escape(value: Any) -> str:
    return (str(value).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _f(value: Any) -> str:
    """Deterministic short decimal. Rendering must be byte-stable so
    ``artifact_sha256`` identifies a picture rather than a float mood."""
    if value is None:
        return "0"
    r = round(float(value), 4) + 0.0  # +0.0 normalises -0.0 to 0.0
    if r == int(r):
        return str(int(r))
    return f"{r:.4f}".rstrip("0").rstrip(".")


def _pad_copper_class(pad: dict) -> str:
    layers = [str(layer) for layer in (pad.get("layers") or [])]
    top = any(layer in ("F.Cu", "*.Cu") for layer in layers)
    bot = any(layer in ("B.Cu", "*.Cu") for layer in layers)
    if top and bot:
        return "pad-both"
    if top:
        return "pad-top"
    if bot:
        return "pad-bot"
    return "pad-none"


def _arc_from_three_points(p0, p1, p2):
    """Circumcircle of three points -> (cx, cy, r, large_arc_flag, sweep_flag).

    Returns ``None`` for collinear/degenerate input (which is then reported as
    not rendered rather than drawn as a straight line -- a straight "arc" in a
    bless render would misstate the part's geometry)."""
    (x0, y0), (x1, y1), (x2, y2) = p0, p1, p2
    d = 2.0 * (x0 * (y1 - y2) + x1 * (y2 - y0) + x2 * (y0 - y1))
    if abs(d) < 1e-12:
        return None
    s0 = x0 * x0 + y0 * y0
    s1 = x1 * x1 + y1 * y1
    s2 = x2 * x2 + y2 * y2
    cx = (s0 * (y1 - y2) + s1 * (y2 - y0) + s2 * (y0 - y1)) / d
    cy = (s0 * (x2 - x1) + s1 * (x0 - x2) + s2 * (x1 - x0)) / d
    r = math.hypot(x0 - cx, y0 - cy)
    if r <= 0.0:
        return None
    a0 = math.atan2(y0 - cy, x0 - cx)
    a1 = math.atan2(y1 - cy, x1 - cx)
    a2 = math.atan2(y2 - cy, x2 - cx)
    two_pi = 2.0 * math.pi
    d01 = (a1 - a0) % two_pi
    d02 = (a2 - a0) % two_pi
    if d01 <= d02:  # the mid point lies on the increasing-angle path
        sweep, total = 1, d02
    else:
        sweep, total = 0, two_pi - d02
    return cx, cy, r, (1 if total > math.pi else 0), sweep


def _arc_extreme_points(cx, cy, r, a_start, a_total, sweep):
    """The axis-crossing points an arc actually reaches, so its bounding box is
    exact instead of "the three defining points" (which under-covers a bulging
    arc and would clip it out of the viewBox)."""
    pts = []
    for k in range(4):
        ang = k * math.pi / 2.0
        delta = ((ang - a_start) % (2.0 * math.pi)) if sweep else ((a_start - ang) % (2.0 * math.pi))
        if delta <= a_total + 1e-12:
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return pts


def _render_svg(parsed: dict, geom: dict) -> tuple[str, list]:
    """Render the footprint to a self-contained SVG, and report what it did NOT
    draw.

    ORIENTATION (stated here because a picture with an unstated convention is
    worse than no picture): a ``.kicad_mod`` stores footprint-LOCAL coordinates
    with **y growing DOWNWARD**. This renderer NEGATES y, so the SVG is a
    CONVENTIONAL TOP VIEW with y growing UP -- the orientation a datasheet
    drawing uses. x is NOT mirrored, so back-side geometry (B.SilkS, B.Cu pads)
    is drawn as seen THROUGH the board (x-ray), not as it would look flipped
    over. Both facts are repeated in an SVG comment inside the output, because
    the SVG travels without this docstring.

    Pad local rotation is emitted as an SVG ``rotate(R, cx, cy)`` about the pad
    centre, which is exactly KiCad's convention once y is negated: KiCad applies
    a pad/footprint angle as ``radians(-R)`` in its y-DOWN frame
    (``pcb_worker.geometry`` module docstring, pinned by tests/test_rotation.py),
    and negating y turns that into ``+R`` in the SVG frame -- the same matrix
    SVG's ``rotate`` applies. Bounding boxes use ``geometry.rotate_local_offset``
    directly (see :func:`_pad_corner_points`) so the numbers and the picture
    cannot drift.
    """
    not_rendered: list = []
    pad_elements: list = []
    graphic_elements: dict = {"fab": [], "silk-bot": [], "silk-top": [], "crtyd": []}
    extra_points: list = []

    # ---- pads -------------------------------------------------------------
    for pad in sorted((parsed.get("pads") or []),
                      key=lambda p: _pad_sort_key(p.get("number"))):
        number = pad.get("number")
        shape = pad.get("shape")
        pad_type = pad.get("type")
        x, y = pad.get("x_mm"), pad.get("y_mm")
        size = pad.get("size") or []
        for marker in (pad.get("unsupported") or []):
            not_rendered.append({
                "feature": marker.get("feature", "pad_unsupported"),
                "pad": number,
                "detail": marker.get("detail", ""),
            })
        if x is None or y is None or len(size) < 2 or size[0] is None or size[1] is None:
            not_rendered.append({
                "feature": "pad_without_geometry", "pad": number,
                "detail": (f"pad {number!r} has no usable (at …)/(size …) "
                           f"(x={x!r} y={y!r} size={size!r}); nothing was drawn "
                           f"for it"),
            })
            continue
        w, h = float(size[0]), float(size[1])
        cls = _pad_copper_class(pad)
        rot = float(pad.get("rotation") or 0.0)
        # y is negated for the SVG frame (see the docstring); the rotation
        # angle then applies with its ORIGINAL sign.
        cx, cy = float(x), -float(y)
        transform = ("" if rot == 0.0
                     else f' transform="rotate({_f(rot)},{_f(cx)},{_f(cy)})"')
        common = (f' class="{cls}" data-pad="{_svg_escape(number)}"'
                  f' data-pad-type="{_svg_escape(pad_type)}"{transform}/>')

        if shape in ("rect", "roundrect"):
            rx = ""
            if shape == "roundrect":
                ratio = pad.get("roundrect_rratio")
                if ratio is not None:
                    radius = float(ratio) * min(w, h)
                    rx = f' rx="{_f(radius)}" ry="{_f(radius)}"'
            pad_elements.append(
                f'<rect x="{_f(cx - w / 2.0)}" y="{_f(cy - h / 2.0)}" '
                f'width="{_f(w)}" height="{_f(h)}"{rx}{common}')
        elif shape in ("oval", "circle"):
            pad_elements.append(
                f'<ellipse cx="{_f(cx)}" cy="{_f(cy)}" rx="{_f(w / 2.0)}" '
                f'ry="{_f(h / 2.0)}"{common}')
        else:
            not_rendered.append({
                "feature": "pad_shape", "pad": number, "shape": shape,
                "detail": (f"pad {number!r} has shape {shape!r}, which this "
                           f"renderer does not model (only rect/roundrect/oval/"
                           f"circle); no copper was drawn for it"),
            })
            continue

        drill = pad.get("drill")
        if drill is not None:
            drill_size = pad.get("drill_size") or []
            if len(drill_size) >= 2 and None not in drill_size[:2]:
                drx, dry = float(drill_size[0]) / 2.0, float(drill_size[1]) / 2.0
            else:
                drx = dry = float(drill) / 2.0
            pad_elements.append(
                f'<ellipse cx="{_f(cx)}" cy="{_f(cy)}" rx="{_f(drx)}" '
                f'ry="{_f(dry)}" class="drill" '
                f'data-drill="{_svg_escape(number)}"{transform}/>')

    # ---- graphics ---------------------------------------------------------
    for g in (parsed.get("graphics") or []):
        layer = g.get("layer")
        kind = g.get("kind")
        cls = _RENDERED_GRAPHIC_LAYERS.get(layer)
        if cls is None:
            not_rendered.append({
                "feature": "graphic_layer_not_drawn", "layer": layer, "kind": kind,
                "detail": (f"an fp_{kind} on layer {layer!r} was parsed but is "
                           f"outside the layer set this render draws "
                           f"({'/'.join(sorted(_RENDERED_GRAPHIC_LAYERS))})"),
            })
            continue
        width = g.get("width")
        sw = _f(width if width else _DEFAULT_STROKE_MM)

        if kind == "line":
            (sx, sy), (ex, ey) = g.get("start"), g.get("end")
            graphic_elements[cls].append(
                f'<line x1="{_f(sx)}" y1="{_f(-sy)}" x2="{_f(ex)}" '
                f'y2="{_f(-ey)}" class="{cls}" stroke-width="{sw}"/>')
        elif kind == "circle":
            cxc, cyc = g.get("center")
            graphic_elements[cls].append(
                f'<circle cx="{_f(cxc)}" cy="{_f(-cyc)}" '
                f'r="{_f(g.get("radius"))}" class="{cls}" stroke-width="{sw}"/>')
        elif kind == "poly":
            pts = [p for p in (g.get("points") or [])
                   if p and p[0] is not None and p[1] is not None]
            if len(pts) < 2:
                not_rendered.append({
                    "feature": "degenerate_polygon", "layer": layer, "kind": kind,
                    "detail": f"an fp_poly on {layer!r} has {len(pts)} usable points",
                })
                continue
            coords = " ".join(f"{_f(px)},{_f(-py)}" for px, py in pts)
            graphic_elements[cls].append(
                f'<polygon points="{coords}" class="{cls}" stroke-width="{sw}"/>')
            # The parser drops KiCad's (fill …) token, so this render shows the
            # OUTLINE and cannot know whether the part intends a solid patch.
            # A filled silk polygon and its outline look different to the human
            # doing the comparison, so the difference is declared, not assumed.
            not_rendered.append({
                "feature": "polygon_fill_unknown", "layer": layer, "kind": "poly",
                "detail": (f"an fp_poly on {layer!r} is drawn as an OUTLINE; the "
                           f"parser does not carry KiCad's (fill …) token, so "
                           f"whether this polygon is a solid patch is unknown "
                           f"from the render alone"),
            })
        elif kind == "arc":
            pts = [p for p in (g.get("points") or [])
                   if p and p[0] is not None and p[1] is not None]
            if len(pts) != 3 or "angle" in g:
                not_rendered.append({
                    "feature": "arc_form_not_modelled", "layer": layer, "kind": kind,
                    "detail": (f"an fp_arc on {layer!r} is in the KiCad 6 "
                               f"start/end/angle form (or is malformed): the "
                               f"parsed dict does not distinguish its centre "
                               f"from its endpoints, so drawing it would be a "
                               f"guess. Only the three-point (start/mid/end) "
                               f"form is rendered"),
                })
                continue
            fp = [(px, -py) for px, py in pts]
            circ = _arc_from_three_points(*fp)
            if circ is None:
                not_rendered.append({
                    "feature": "degenerate_arc", "layer": layer, "kind": kind,
                    "detail": (f"an fp_arc on {layer!r} has collinear or "
                               f"coincident defining points; no circle exists "
                               f"through them, so nothing was drawn"),
                })
                continue
            cxa, cya, r, large, sweep = circ
            (sx, sy), _mid, (ex, ey) = fp
            graphic_elements[cls].append(
                f'<path d="M {_f(sx)} {_f(sy)} A {_f(r)} {_f(r)} 0 {large} '
                f'{sweep} {_f(ex)} {_f(ey)}" class="{cls}" stroke-width="{sw}"/>')
            a_start = math.atan2(sy - cya, sx - cxa)
            a_end = math.atan2(ey - cya, ex - cxa)
            total = ((a_end - a_start) % (2.0 * math.pi)) if sweep \
                else ((a_start - a_end) % (2.0 * math.pi))
            # Arc extremes are collected in the SVG (y-negated) frame, then
            # flipped back so they join the footprint-local extent below.
            extra_points.extend(
                (px, -py) for px, py in
                _arc_extreme_points(cxa, cya, r, a_start, total, sweep))
        else:
            not_rendered.append({
                "feature": "graphic_kind_not_drawn", "layer": layer, "kind": kind,
                "detail": f"a parsed graphic of kind {kind!r} on {layer!r} is not drawn",
            })

    # ---- everything the PARSER itself could not capture --------------------
    for marker in (parsed.get("unsupported") or []):
        not_rendered.append({
            "feature": marker.get("feature", "unsupported"),
            "layer": marker.get("layer"),
            "kind": marker.get("kind"),
            "detail": marker.get("detail", ""),
        })
    if parsed.get("reference_text") is not None:
        not_rendered.append({
            "feature": "reference_designator_text",
            "detail": ("the footprint's own reference-designator fp_text "
                       "placement is parsed but not drawn: it carries no part "
                       "geometry, and rendering the placeholder text would add "
                       "a mark to the picture that no datasheet dimension "
                       "corresponds to"),
        })

    # ---- frame ------------------------------------------------------------
    extent = geom.get("extent")
    pts = []
    if extent:
        pts = [(extent["min_x_mm"], extent["min_y_mm"]),
               (extent["max_x_mm"], extent["max_y_mm"])]
    pts.extend(extra_points)
    box = _bbox_of(pts) or {"min_x_mm": -1.0, "min_y_mm": -1.0,
                            "max_x_mm": 1.0, "max_y_mm": 1.0,
                            "width_mm": 2.0, "height_mm": 2.0}
    min_x = box["min_x_mm"] - _SVG_MARGIN_MM
    max_x = box["max_x_mm"] + _SVG_MARGIN_MM
    # y is negated for the view, so the local MAX y becomes the view MIN y.
    min_y = -box["max_y_mm"] - _SVG_MARGIN_MM
    max_y = -box["min_y_mm"] + _SVG_MARGIN_MM
    vw, vh = max_x - min_x, max_y - min_y

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="{_f(min_x)} {_f(min_y)} {_f(vw)} {_f(vh)}" '
        f'width="{_f(vw * _SVG_PX_PER_MM)}" height="{_f(vh * _SVG_PX_PER_MM)}" '
        f'data-footprint="{_svg_escape(parsed.get("name"))}">',
        "<!-- Minerva PCB rendered-bless view. Units are MILLIMETRES in "
        "footprint-LOCAL space. KiCad stores footprint y growing DOWNWARD; this "
        "render NEGATES y, so it is a CONVENTIONAL TOP VIEW with y growing UP. "
        "x is NOT mirrored, so back-side geometry (B.Cu pads, B.SilkS) is drawn "
        "as seen THROUGH the board, not flipped over. Nothing here is a "
        "fabrication output. -->",
        f"<style>{_SVG_STYLE}</style>",
        f'<rect class="bg" x="{_f(min_x)}" y="{_f(min_y)}" '
        f'width="{_f(vw)}" height="{_f(vh)}"/>',
    ]
    parts.append(
        f'<g class="origin"><line x1="{_f(min_x)}" y1="0" x2="{_f(max_x)}" '
        f'y2="0"/><line x1="0" y1="{_f(min_y)}" x2="0" y2="{_f(max_y)}"/></g>')
    for cls in ("fab", "crtyd", "silk-bot"):
        if graphic_elements[cls]:
            parts.append(f'<g class="g-{cls}">' + "".join(graphic_elements[cls]) + "</g>")
    if pad_elements:
        parts.append('<g class="g-pads">' + "".join(pad_elements) + "</g>")
    if graphic_elements["silk-top"]:
        parts.append('<g class="g-silk-top">' + "".join(graphic_elements["silk-top"]) + "</g>")
    parts.append("</svg>")
    return "\n".join(parts), not_rendered
