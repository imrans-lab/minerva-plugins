"""Tests for the `fab_preview` worker method (WYSIWYG goal 019ff4a5a75a, gap
G5; approved DCR 019ffc52b455; acceptance check K27).

WHAT MAKES THIS PREVIEW "EXACT", and therefore what these tests must pin: the
method runs the PRODUCTION emission path and then reads the emitted artifacts
back with gerbonara — a different library from the gerber_writer that wrote
them. So the preview is an independent read of the shipped bytes, not the
emitter agreeing with itself. Each test below names the mutation it is designed
to fail against, because a preview test that passes against a broken preview is
worse than no test: it certifies the one view the user is meant to trust.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

import yaml

from pcb_worker.methods import handle_request

HERE = Path(__file__).resolve().parent
SPIKE_BOARD = HERE.parents[1] / "spikes" / "gerber" / "board.yaml"


def _board() -> dict:
    return yaml.safe_load(SPIKE_BOARD.read_text(encoding="utf-8"))


def _preview(**extra) -> dict:
    params = {"board": _board()}
    params.update(extra)
    resp = handle_request({"id": "fp", "method": "fab_preview", "params": params})
    assert resp["ok"] is True, resp
    return resp["result"]


def _emitted() -> dict:
    """The same board's artifacts through the SHIPPING path — an independent
    derivation of the byte set the preview claims to be showing."""
    resp = handle_request({"id": "g", "method": "gerbers", "params": {"board": _board()}})
    assert resp["ok"] is True, resp
    return resp["result"]["files"]


def test_every_emitted_file_is_accounted_for_exactly_once():
    """MUTATION THIS CATCHES: dropping a file the preview cannot handle (an
    early `continue` that appends to neither list). A preview that silently
    omits an emitted layer presents a KNOWN-INCOMPLETE artifact set as complete,
    which is the exact false-clean this goal exists to remove."""
    result = _preview()
    emitted = set(_emitted().keys())
    shown = [lay["name"] for lay in result["layers"]]
    skipped = [u["name"] for u in result["unrendered"]]

    assert set(shown) | set(skipped) == emitted
    # Exactly once, not merely covered: a file in both lists would let a viewer
    # draw it AND report it as missing.
    assert len(shown) + len(skipped) == len(emitted)
    assert not (set(shown) & set(skipped))


def test_every_skip_carries_a_reason():
    """MUTATION THIS CATCHES: recording a skip with an empty reason. "This layer
    is missing" without "because…" is unactionable, and the .gbrjob case proves
    the reason field is populated on the one skip every board has."""
    result = _preview()
    assert result["unrendered"], "the .gbrjob manifest should always be skipped"
    for entry in result["unrendered"]:
        assert entry["reason"].strip(), entry
    job = [u for u in result["unrendered"] if u["name"].lower().endswith(".gbrjob")]
    assert len(job) == 1
    assert "manifest" in job[0]["reason"].lower()


def test_all_layers_share_one_coordinate_frame():
    """MUTATION THIS CATCHES: dropping force_bounds, so each layer renders to
    its OWN extent. Every SVG would still look correct in isolation and the
    stack would misregister — copper landing off its own pads. This is the
    defect a per-layer eyeball cannot see and only a cross-layer assertion can."""
    result = _preview()
    assert len(result["layers"]) > 1
    boxes = set()
    for lay in result["layers"]:
        m = re.search(r'viewBox="([^"]+)"', lay["svg"])
        assert m, f"{lay['name']} rendered without a viewBox"
        boxes.add(m.group(1))
    assert len(boxes) == 1, f"layers disagree about the board's extent: {boxes}"


def test_identity_hashes_the_emitted_bytes_not_the_rendering():
    """MUTATION THIS CATCHES: hashing the SVG (or anything else) instead of the
    artifact. The sha256 exists so a reviewer can tie what they are looking at
    to the file that ships; hashing the picture of it would be worse than
    omitting the field, because it would look authoritative and mean nothing."""
    result = _preview()
    emitted = _emitted()
    for lay in result["layers"]:
        raw = emitted[lay["name"]].encode("utf-8")
        assert lay["sha256"] == hashlib.sha256(raw).hexdigest(), lay["name"]
        assert lay["byte_length"] == len(raw)
        # And explicitly NOT the rendering's hash.
        assert lay["sha256"] != hashlib.sha256(lay["svg"].encode("utf-8")).hexdigest()


def test_drill_files_are_previewed_too():
    """MUTATION THIS CATCHES: treating only .gbr as renderable, so drills vanish
    from the preview. Holes are fabrication-affecting geometry; a preview that
    shows copper but not drills is precisely the partial honesty K27 rejects."""
    result = _preview()
    kinds = {lay["name"]: lay["kind"] for lay in result["layers"]}
    drills = [n for n in kinds if n.lower().endswith(".drl")]
    assert drills, f"no drill artifact previewed; layers were {sorted(kinds)}"
    for name in drills:
        assert kinds[name] == "drill"


def test_bounds_are_reported_for_a_real_board():
    """MUTATION THIS CATCHES: returning bounds_mm unconditionally as None, which
    would leave a viewer unable to place the preview and would silently disagree
    with the forced frame the layers were actually rendered in."""
    result = _preview()
    bounds = result["bounds_mm"]
    assert bounds is not None
    assert bounds["max_x"] > bounds["min_x"]
    assert bounds["max_y"] > bounds["min_y"]


def test_only_the_job_manifest_is_labelled_not_artwork():
    """A viewer cannot raise an honest "incomplete" alarm without knowing which
    skips are missing ARTWORK and which are files that never had any. Every
    emission carries a .gbrjob, so a viewer that counted it raised the alarm on
    every board — and an alarm that is always on is one nobody reads, which is
    how a genuinely missing copper layer would pass the gate.

    ORACLE: the emitted filenames, from the SHIPPING path. The label is checked
    against the suffix each file actually has, not against the label itself.

    MUTATIONS THIS CATCHES: dropping the ``kind`` field (the viewer has nothing
    to filter on); labelling every skip "job" (which would hide a real
    unreadable layer behind the manifest's excuse); labelling the manifest
    "artwork" (the alarm comes back on every board).
    """
    result = _preview()
    emitted = set(_emitted().keys())
    for entry in result["unrendered"]:
        assert entry["name"] in emitted, entry
        expected = "job" if entry["name"].lower().endswith(".gbrjob") else "artwork"
        assert entry.get("kind") == expected, entry

    # The whole point, stated as the viewer sees it: a healthy board has NOTHING
    # missing from its picture, so nothing for it to alarm about.
    missing = [u for u in result["unrendered"] if u.get("kind") != "job"]
    assert missing == [], missing
    assert [u for u in result["unrendered"] if u.get("kind") == "job"], \
        "the .gbrjob manifest is always skipped and must still be reported"


def test_bounds_come_back_in_the_caller_s_own_coordinates():
    """The preview is only placeable over the board it describes if its extent
    is expressed the way the caller expresses the board. The emitter negates y
    on the way into Gerber, so ``bounds_mm`` — read back off the artifacts — is
    y-up and describes a rectangle BELOW the origin. A viewer handed only that
    either draws the board upside down or re-derives the emitter's sign
    convention for itself.

    ORACLE: the board YAML's own outline, which is an independent derivation of
    where the board is — nothing in the preview path produced it.

    MUTATIONS THIS CATCHES: copying ``bounds_mm`` through unflipped (the y range
    would not contain the board at all); flipping x instead of y; swapping the
    min/max pair only, or negating only one of them (either leaves an inverted
    rectangle).
    """
    board = _board()
    width = float(board["width_mm"])
    height = float(board["height_mm"])
    bounds = _preview()["bounds_board_mm"]
    assert bounds is not None

    # A well-formed rectangle, in the direction board coordinates run.
    assert bounds["max_x"] > bounds["min_x"]
    assert bounds["max_y"] > bounds["min_y"]

    # THE BOARD IS INSIDE IT. The artwork's extent is the union of every layer,
    # so it is the outline plus at most a stroke half-width of margin — never
    # the outline reflected through the origin, which is what the unflipped
    # bounds would be.
    margin = 1.0
    assert -margin <= bounds["min_x"] <= margin, bounds
    assert -margin <= bounds["min_y"] <= margin, bounds
    assert width - margin <= bounds["max_x"] <= width + margin, bounds
    assert height - margin <= bounds["max_y"] <= height + margin, bounds

    # ...and it is genuinely a conversion, not the Gerber rectangle relabelled.
    gerber = _preview()["bounds_mm"]
    assert bounds["min_y"] == -gerber["max_y"]
    assert bounds["max_y"] == -gerber["min_y"]
    assert bounds["min_x"] == gerber["min_x"]
