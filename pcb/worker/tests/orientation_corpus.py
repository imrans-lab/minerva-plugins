"""The part-orientation facts the TEST CORPUS's own drawings carry.

WHY THIS EXISTS
---------------
``assembly_orientation`` refuses to emit a position file for a part that is
bought as a catalogue part and whose (footprint, house, catalogue number) pair
nobody has measured. That is the point of it.

Some boards in this corpus are drawn on land patterns that exist only in this
repository and that the SHIPPED declarations do not already account for.
``Diode_SMD:D_SMA`` is the one such drawing: hand-authored in-repo from the
DO-214AC package convention, paired with no vendor payload, and therefore
UNKNOWN in the shipped ledger. The other in-repo fixture lands the corpus
places — ``C_0805`` and ``R_0805`` among them — are already declared in
``pcb/library/part_orientation_declared.json``, so nothing here needs to say
anything about them.

Suites that emit assembly outputs from those boards are measuring BOM grouping,
frame arithmetic, gates, service checks and package assembly — not orientation,
which has its own suite. :func:`install` gives them a ledger that is the SHIPPED
one plus a declared "there is nothing to measure here" for each drawing in
:data:`FIXTURE_DRAWINGS`, so the corpus states that fact ONCE instead of each
suite working around the gate its own way.

A STANDING GUARD, NOT A LIVE WORKAROUND. As things stand no board in this
corpus reaches the gate at all: the gate fires only on a placement that names
``assembly.house_parts[<house>]``, and the boards these suites emit either name
no catalogue number (``assembly.mpn`` alone does not join — see
``assembly_orientation``'s KNOWN GAP) or sit on a drawing the SHIPPED
declarations already cover. Emptying :data:`FIXTURE_DRAWINGS` today leaves every
suite green. It is kept because the day a corpus board gains a house catalogue
number on an in-repo drawing, the refusal lands in eight suites at once with a
message about production orders, and this is where the answer belongs.

WHAT THIS DELIBERATELY IS NOT. It does not weaken the gate for any real part:
every added row is a DECLARED no-reference, which ``OrientationRecord``
validates can carry no numbers at all, and it names each fixture drawing
explicitly. A board that buys a REAL footprint under an unmeasured catalogue
number still refuses, in every suite, exactly as it does in production.
"""

from __future__ import annotations

import pytest

from pcb_worker import assembly_orientation as aor
from pcb_worker import orientation_ledger as ol
from pcb_worker import part_orientation as po

#: Drawings this corpus places that no vendor has a counterpart for AND that
#: the shipped declarations do not already carry. Each must be ABSENT from the
#: shipped ledger's declarations — a duplicate key is a refusal, which is the
#: check that keeps this list from quietly shadowing a real row, and which
#: :func:`test_orientation_ledger` sees the moment a shipped declaration is
#: added for one of these.
FIXTURE_DRAWINGS = (
    "Diode_SMD:D_SMA",
)

REASON = ("a test-corpus drawing: synthesized or hand-authored in-repo, with no "
          "vendor package drawing anywhere to measure it against")


def corpus_ledger() -> ol.OrientationLedger:
    """The shipped ledger plus this corpus's own declarations."""
    shipped = ol.load_ledger()
    declared = shipped.declared + tuple(
        ol.OrientationRecord(footprint=ref, house=None, part=None,
                             verdict=po.VERDICT_NO_REFERENCE, declared=True,
                             reason=REASON)
        for ref in FIXTURE_DRAWINGS)
    return ol.OrientationLedger(declared=declared, measured=shipped.measured)


def install(monkeypatch) -> ol.OrientationLedger:
    """Make :func:`corpus_ledger` the ledger every emitter in this test reads.

    Substitutes the module-level CACHE, not the lookup logic: the emitters
    still do the real join and the real three-state fold — they are simply
    reading a ledger that knows about the drawings this corpus is built on.
    """
    ledger = corpus_ledger()
    monkeypatch.setattr(aor, "_DEFAULT", ledger)
    return ledger


@pytest.fixture(autouse=True)
def corpus_orientation(monkeypatch) -> ol.OrientationLedger:
    """THE ONE BODY every assembly-emitting suite here installs.

    Imported into a suite's own namespace, where pytest collects it and its
    ``autouse`` applies to that module alone::

        from tests.orientation_corpus import corpus_orientation  # noqa: F401

    Those suites emit assembly outputs from boards drawn on this repository's
    own land patterns, so the part-orientation gate would otherwise refuse
    every emission for pairs that could never have been measured. Orientation
    itself is measured by ``test_assembly_orientation.py``, not by them.
    """
    return install(monkeypatch)
