"""DEFERRED TEST P1 (docket 019fb06dee0e, authored at epoch GA-5) — the
``solder_paste_margin_ratio`` refusal fires, names its field, and does NOT
swallow the paths that must survive.

Epoch 4 shipped the refusal site (footprints.py's per-side unsupported
marker) with zero tests; the cold triage found the negative halves entirely
unguarded — the paste-margin suite drives the RAW emitter and never parses a
.kicad_mod through this site, so a refusal that fired unconditionally would
have shipped green. The fixture (PASTE_RATIO.kicad_mod) carries every case
in one footprint:

  pad 1 — ratio -0.15 on F.Paste  -> refusal marker, F.Paste attributed
  pad 2 — ratio 0                 -> NO marker (KiCad writes literal zeros;
                                     zero means "no proportional margin")
  pad 3 — ABSOLUTE margin only    -> NO marker, and the margin THREADS
  pad 4 — no margin fields at all -> NO marker
  pad 5 — ratio on *.Paste (TH)   -> one marker PER paste side

The blocking half (marker -> fatal compile for paste-critical outputs) rides
the already-pinned machinery: paste ∈ FABRICATION_CRITICAL_OUTPUTS
(test_fab_capability) and the unsupported-marker promotion covered by
test_compile_board's policy matrix — what THIS file pins is that the marker
exists exactly when it should, which is the half nothing else reaches.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from pcb_worker.footprints import parse_kicad_mod
from pcb_worker.resolve import _pads_from_parsed

_FIXTURE = Path(__file__).resolve().parent / "testdata" / "k1_lossless" / "PASTE_RATIO.kicad_mod"


def _pads_by_number() -> dict:
    return {p["number"]: p for p in parse_kicad_mod(_FIXTURE)["pads"]}


def _ratio_markers(pad: dict) -> list[dict]:
    return [u for u in pad.get("unsupported", [])
            if u.get("feature") == "solder_paste_margin_ratio"]


def test_a_declared_ratio_refuses_and_names_the_field():
    markers = _ratio_markers(_pads_by_number()["1"])
    assert len(markers) == 1, "one F.Paste pad -> one per-side marker"
    m = markers[0]
    assert m["layer"] == "F.Paste"
    # The diagnostic names the field AND the value — an operator reading the
    # refusal must learn what to remove, not just that something is wrong.
    assert "solder_paste_margin_ratio" in m["detail"]
    assert "-0.15" in m["detail"]


def test_a_wildcard_paste_ratio_marks_every_paste_side():
    markers = _ratio_markers(_pads_by_number()["5"])
    assert {m["layer"] for m in markers} == {"F.Paste", "B.Paste"}


def test_an_authored_zero_ratio_is_not_refused():
    """KiCad writes literal (solder_paste_margin_ratio 0); zero means "no
    proportional margin" and refusing it would break real library parts —
    the over-firing direction the corpus half-mutant
    footprints_paste_ratio_refusal_overfires_on_zero exists to kill."""
    assert _ratio_markers(_pads_by_number()["2"]) == []


def test_the_absolute_margin_path_survives_the_refusal():
    """The blessed path: an ABSOLUTE solder_paste_margin must not be
    swallowed — no marker, and the value threads through the resolve
    projection to the key the emitters read."""
    pads = _pads_by_number()
    assert _ratio_markers(pads["3"]) == []
    projected = {p["number"]: p for p in _pads_from_parsed(
        parse_kicad_mod(_FIXTURE)["pads"])}
    assert projected["3"]["solder_paste_margin"] == pytest.approx(-0.02)


def test_a_field_free_pad_is_untouched():
    pad = _pads_by_number()["4"]
    assert _ratio_markers(pad) == []
