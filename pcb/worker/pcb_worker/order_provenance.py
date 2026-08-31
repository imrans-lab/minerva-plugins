"""The design revision a board CARRIES, and the digest of the source it was
compiled from.

TWO FACTS, ONE OBJECT. A finished board prints its own identity in silkscreen —
``<board name> <rev> <digest-8>`` — so a bare PCB pulled out of a drawer can be
matched back to the YAML that produced it. The same digest rides in the order
manifest. This module owns both halves: computing the digest, and reading back
what the board says about itself.

THE SELF-REFERENCE, AND HOW IT IS BROKEN. The digest is taken over the board
source, and the provenance text is IN the board source, so hashing the file
verbatim would make the digest an input to itself: stamping a digest changes the
bytes, which changes the digest. The fix is an explicit PROJECTION. Before
hashing, the eight-character digest slot inside every provenance string is
replaced by :data:`DIGEST_SENTINEL`. The projection is therefore INVARIANT under
any change to that slot, so:

    digest(project(board with slot = X)) == digest(project(board with slot = Y))

for every X and Y. Writing the computed digest into the slot cannot move the
digest, which is what "reaches a fixed point" means here — and it reaches it in
ONE step, not by iterating.

WHAT IS STILL HASHED. Only the eight digest characters are normalized. The board
name and the revision inside the same string are hashed as authored, so bumping
a revision DOES move the digest. So does adding the provenance graphic at all:
its layer, position and size are ordinary board data. An author therefore stamps
in one pass — write the graphic with :data:`DIGEST_SENTINEL` (or any eight hex
characters) in the slot, compute, write the result back — and the second
computation returns the same value the first did.

WHAT COUNTS AS PROVENANCE. A ``board_graphics`` text entry whose string is the
board's own ``name``, then a revision token, then the digest slot. Anchoring on
the board's name is what keeps the projection from firing on unrelated silk that
happens to end in eight hex characters: a string that does not open with this
board's name is not this board's provenance and is hashed verbatim.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
from dataclasses import dataclass

#: What the digest slot becomes before hashing. Not hex, deliberately: no real
#: digest can equal it, so a projected string is never mistaken for an authored
#: one — and an author may write it into the slot as an explicit "not stamped
#: yet" placeholder that projects to itself.
DIGEST_SENTINEL = "________"

#: How many characters of the hex digest the silk carries. Short enough to print
#: at silk sizes, long enough that two revisions of one board do not collide.
DIGEST_CHARS = 8

_DIGEST_SLOT = rf"(?:[0-9a-f]{{{DIGEST_CHARS}}}|{DIGEST_SENTINEL})"


class ProvenanceError(ValueError):
    """The board's printed provenance disagrees with the board itself — a NAMED
    refusal. Absence is NOT this: a board carrying no provenance at all is an
    advisory, because a board is authored before it is stamped."""

    code = "assembly_provenance_mismatch"


@dataclass(frozen=True)
class ProvenanceStamp:
    """One provenance string found in ``board_graphics``, taken apart."""

    index: int
    layer: str
    rev: str
    digest: str
    text: str

    @property
    def stamped(self) -> bool:
        """False while the digest slot still holds the sentinel."""
        return self.digest != DIGEST_SENTINEL


def _pattern(board_name: str) -> re.Pattern:
    """The provenance grammar for ONE board: its own name, a revision token,
    the digest slot."""
    return re.compile(rf"^({re.escape(board_name)})\s+(\S+)\s+({_DIGEST_SLOT})$")


def provenance_text(board_name: str, rev: str, digest: str) -> str:
    """The exact string a board prints. ``digest`` may be a full hex digest (it
    is truncated), an eight-character prefix, or :data:`DIGEST_SENTINEL`."""
    slot = digest if digest == DIGEST_SENTINEL else digest[:DIGEST_CHARS]
    return f"{board_name} {rev} {slot}"


def _board_name(board: dict) -> str:
    name = board.get("name") if isinstance(board, dict) else None
    return name if isinstance(name, str) and name else ""


def _text_graphics(board: dict):
    """``(index, entry)`` for every text entry in ``board_graphics``, tolerating
    a malformed board: this module runs BEFORE the compiler on the raw dict and
    must not raise on shapes the compiler is the one to refuse."""
    raw = board.get("board_graphics") if isinstance(board, dict) else None
    if not isinstance(raw, list):
        return
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            continue
        if entry.get("kind") != "text" or not isinstance(entry.get("text"), str):
            continue
        yield index, entry


def stamps(board: dict) -> tuple[ProvenanceStamp, ...]:
    """Every provenance string the raw board carries, in board order."""
    name = _board_name(board)
    if not name:
        return ()
    pattern = _pattern(name)
    out: list[ProvenanceStamp] = []
    for index, entry in _text_graphics(board):
        match = pattern.match(entry["text"])
        if match is None:
            continue
        layer = entry.get("layer")
        out.append(ProvenanceStamp(
            index=index, layer=layer if isinstance(layer, str) else "",
            rev=match.group(2), digest=match.group(3), text=entry["text"]))
    return tuple(out)


def project(board: dict) -> dict:
    """The board as it is hashed: a deep copy with every provenance digest slot
    replaced by :data:`DIGEST_SENTINEL`."""
    projected = copy.deepcopy(board)
    name = _board_name(projected)
    if not name:
        return projected
    pattern = _pattern(name)
    for _, entry in _text_graphics(projected):
        match = pattern.match(entry["text"])
        if match is not None:
            entry["text"] = provenance_text(name, match.group(2), DIGEST_SENTINEL)
    return projected


def canonical_bytes(board: dict) -> bytes:
    """The projected board as ONE deterministic byte string.

    JSON with sorted keys rather than re-serialized YAML: YAML has several
    spellings for one value and no total key order, so two files that differ
    only in formatting must hash alike. ``default=str`` catches the non-JSON
    scalars a YAML loader can produce (a bare date, most often) and gives them
    one stable spelling rather than failing an export over a formatting choice.
    """
    return json.dumps(project(board), sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=str).encode("utf-8")


def source_digest(board: dict) -> str:
    """The full SHA-256 of the projected board source."""
    return hashlib.sha256(canonical_bytes(board)).hexdigest()


#: The three things a package can say about the revision printed on the board.
STATE_VERIFIED = "verified"     # printed digest reproduces from the source
STATE_ABSENT = "absent"         # nothing printed — advisory, never a refusal
STATE_UNSTAMPED = "unstamped"   # the slot is authored but still the sentinel

ADVISORY_ABSENT = "assembly_provenance_absent"
ADVISORY_UNSTAMPED = "assembly_provenance_unstamped"


def check(board: dict) -> tuple[dict, tuple[dict, ...]]:
    """Compare what the board PRINTS against what its source HASHES to.

    Returns ``(record, advisories)`` for the manifest, or raises
    :class:`ProvenanceError` when the two disagree.

    ABSENCE IS AN ADVISORY. A board is authored before it is stamped, and the
    stamping pass needs a package to have been generated first; refusing here
    would make the first package of every board impossible to produce. Only a
    board that states a revision the source does not reproduce is refused,
    because that one is actively misleading: the bare board would name a design
    it is not.
    """
    digest = source_digest(board)
    found = stamps(board)
    record = {"algorithm": "sha256", "projection": "provenance-digest-sentinel",
              "source_digest": digest, "design_revision": None,
              "printed_digest": None, "state": STATE_ABSENT}
    if not found:
        return record, ({
            "code": ADVISORY_ABSENT,
            "field": "board_graphics",
            "message": (
                f"this package carries no design revision on the board: nothing "
                f"in board_graphics prints "
                f"{provenance_text(_board_name(board) or '<name>', '<rev>', DIGEST_SENTINEL)!r}. "
                f"The bare boards will not identify the design they came from. "
                f"The source digest of this package is {digest[:DIGEST_CHARS]}"),
        },)

    # TWO WAYS the stamps can disagree, and the message names the one that
    # happened. Folding them into one "different design revisions" count made a
    # board whose revisions AGREE and whose digest slots do not — one stamped,
    # one still the sentinel — report a fault it does not have, sending a reader
    # to compare two revision tokens that are identical.
    revisions = {stamp.rev for stamp in found}
    slots = {stamp.digest for stamp in found}
    if len(revisions) > 1:
        printed = ", ".join(sorted(stamp.text for stamp in found))
        raise ProvenanceError(
            f"board {_board_name(board)!r} prints {len(revisions)} different "
            f"design revisions ({printed}) — the bare board would name more than "
            f"one design. Author one provenance string")
    if len(slots) > 1:
        printed = ", ".join(sorted(stamp.text for stamp in found))
        raise ProvenanceError(
            f"board {_board_name(board)!r} prints revision {found[0].rev!r} with "
            f"{len(slots)} different digest slots ({printed}) — the revisions "
            f"agree, the digests do not, so at least one stamp is stale or still "
            f"unstamped. Write {digest[:DIGEST_CHARS]!r} into every slot and "
            f"re-export: the slot is normalized before hashing, so stamping does "
            f"not move the digest")

    stamp = found[0]
    record["design_revision"] = stamp.rev
    record["printed_digest"] = stamp.digest
    if not stamp.stamped:
        record["state"] = STATE_UNSTAMPED
        return record, ({
            "code": ADVISORY_UNSTAMPED,
            "field": "board_graphics",
            "message": (
                f"the board prints revision {stamp.rev!r} with an unstamped digest "
                f"slot ({DIGEST_SENTINEL}). Write {digest[:DIGEST_CHARS]!r} into it "
                f"and re-export: the slot is normalized before hashing, so "
                f"stamping it does not move the digest"),
        },)

    if stamp.digest != digest[:DIGEST_CHARS]:
        raise ProvenanceError(
            f"board {_board_name(board)!r} prints design revision {stamp.rev!r} "
            f"digest {stamp.digest!r}, but this source projects to "
            f"{digest[:DIGEST_CHARS]!r} — the silkscreen would name a design "
            f"these files are not. Restamp the provenance graphic, or export the "
            f"source the board was stamped from")
    record["state"] = STATE_VERIFIED
    return record, ()
