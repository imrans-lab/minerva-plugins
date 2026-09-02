"""board_health is RESOLVE-FIRST — bug 01a01b6bc649 (found by the payload-bug
01a007f1dd02 verification ladder, 2026-08-19).

THE BUG: the board_health ledger's two halves had different input contracts.
The assembly half (_assembly_tri_state) resolves tolerantly BEFORE measuring,
by documented contract. The completeness census read the given dict VERBATIM
— pin copper is located from resolve-attached pad geometry, so a canonical
(unresolved) component with no inline pins contributed no pins to the census
at all. Feed the method actual canonical source — which its own docstring
advertises ("anything `_load` accepts") — and the census under-reported in
the FAIL-OPEN direction: quadlayer.yaml returned {"complete": true} where the
truth is complete:false, SIG split into 2 pin_groups, GND indeterminate
(zone_copper). A false "complete" is the exact vocabulary the tri-state
census exists to make impossible.

WHY IT HID: the one production caller (the PCB panel load path) happened to
send the deserialize-ENRICHED dict, so the census always saw pads in
practice. The contract and the caller disagreed; the caller's accident
masked the method's gap.

WHAT THESE TESTS PIN:
  1. board_health over canonical source reports the split net (the direct
     red-then-green regression for 01a01b6bc649);
  2. canonical and enriched input produce the IDENTICAL ledger, across every
     board in the repo corpus — the property the panel's canonical-wire
     payload fix (01a007f1dd02) depends on;
  3. the resolve-attached `graphics` on a library part is provably UNREAD
     by both halves — poisoning it changes nothing — so the panel never has
     to ship it over the 64 KiB broker pipe.
"""

from __future__ import annotations

import copy
from pathlib import Path

import pytest

from pcb_worker import methods

TESTS_DIR = Path(__file__).parent
REPO_PCB = TESTS_DIR.parent.parent  # pcb/

# Every canonical board YAML in the repo that _load accepts (the spec vectors
# are schema-migration inputs, not boards, and stay out). A new board fixture
# joins the census by landing in one of these directories — testdata/ itself
# included, which is where the standalone benches sit (hitl_bench, zone_fill,
# coupon_jlc1, parity_corners, gd_handoff_cutout).
CORPUS = sorted(
    [
        *(REPO_PCB / "spikes").rglob("*.yaml"),
        *(TESTS_DIR / "testdata").glob("*.yaml"),
        *(TESTS_DIR / "testdata" / "assembly_boards").glob("*.yaml"),
        *(TESTS_DIR / "testdata" / "gerber_boards").glob("*.yaml"),
    ]
)

QUADLAYER = TESTS_DIR / "testdata" / "gerber_boards" / "quadlayer.yaml"


def _call(method: str, params: dict) -> dict:
    resp = methods.handle_request({"id": "bh1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "bh1"
    return resp


def _health_result(params: dict) -> dict:
    resp = _call("board_health", params)
    assert resp.get("ok") is True, resp
    return resp["result"]


def _enriched(board: dict) -> dict:
    """The deserialize-enriched dict the panel load path ships today —
    tolerant resolve attaching pads/graphics from the library chain."""
    resolved = methods._resolve_mapped(board, tolerant=True, layers=None)
    if isinstance(resolved, dict) and not methods._is_error_reply(resolved):
        return resolved
    return board


# ---------------------------------------------------------------------------
# 1. The direct regression: canonical quadlayer must report the split net.
# ---------------------------------------------------------------------------

def test_quadlayer_canonical_census_reports_split_net():
    """quadlayer's components carry pin geometry ONLY as library footprints
    (no inline pins). Pre-fix, canonical input made the census blind to every
    pin and it declared the board complete — a false pass on a board whose
    SIG net is provably in two islands."""
    result = _health_result({"yaml": QUADLAYER.read_text()})
    assert result.get("complete") is False, (
        "canonical input must NOT read as complete — the SIG net is split "
        f"(got: {result})"
    )
    partial = {p["net"]: p["pin_groups"] for p in result.get("partial", [])}
    assert partial.get("SIG") == 2, f"SIG must be 2 pin_groups (got: {result})"
    # GND rides a pour; the census computes the fill and judges the net for
    # real rather than declaring it unmeasurable.
    indet = {e["net"]: e["reason"] for e in result.get("indeterminate", [])}
    assert "GND" not in indet, f"GND must be judged, not indeterminate (got: {result})"
    assert partial.get("GND") == 2, f"GND must be 2 pin_groups (got: {result})"


# ---------------------------------------------------------------------------
# 2. Canonical == enriched, whole corpus, both halves of the ledger.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("path", CORPUS, ids=lambda p: p.name)
def test_canonical_and_enriched_agree(path: Path):
    """The property the 01a007f1dd02 panel fix rests on: the worker owes the
    SAME ledger whether the caller ships canonical source or the enriched
    dict. If these ever diverge, a lean canonical wire payload would silently
    change a verdict."""
    src = path.read_text()
    board = methods._load({"yaml": src})
    canonical = _health_result({"yaml": src})
    enriched_ledger = _health_result({"board": _enriched(board)})
    assert canonical == enriched_ledger, (
        f"{path.name}: canonical input diverges from enriched input"
    )


# ---------------------------------------------------------------------------
# 3. The render tail is unread: poison it, nothing may change.
# ---------------------------------------------------------------------------

# The one resolve-attached field a library part's enriched dict carries that
# the design does not: its footprint's silk graphics. `pads` is deliberately
# NOT here: the census legitimately reads pads when a board carries no inline
# pins (that is test 1's whole subject) — pads travel for non-library parts
# and are re-derived for library parts.
RENDER_TAIL = ["graphics"]


def _poison(value):
    if isinstance(value, dict):
        return {k: _poison(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_poison(v) for v in value]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value + 1000.0
    return value


@pytest.mark.parametrize("path", CORPUS, ids=lambda p: p.name)
def test_render_tail_is_unread(path: Path):
    board = methods._load({"yaml": path.read_text()})
    enriched = _enriched(board)
    baseline = _health_result({"board": enriched})

    mutated = copy.deepcopy(enriched)
    hits = 0
    for comp in mutated.get("components", []):
        for field in RENDER_TAIL:
            if field in comp:
                comp[field] = _poison(comp[field])
                hits += 1
    if hits == 0:
        pytest.skip(f"{path.name}: no render-tail fields to poison")

    assert _health_result({"board": mutated}) == baseline, (
        f"{path.name}: poisoning {hits} render-tail fields changed the "
        "ledger — a field the projection drops is being read"
    )
