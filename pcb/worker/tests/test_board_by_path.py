"""Regression: board-by-path + digest (work item 01a0223ec9e271269fd664fcf90dd20b).

pcb.route requests inlined the ENTIRE serialized board and died at the host
broker's 64 KiB payload cap on real boards ("Payload too large: 153578 bytes
(limit: 65536 bytes)" on smart-remote-v2 — routing ONE 2-pin hint failed
identically to routing everything, two attempts differed by 84 bytes). The
same cap kills pcb.serialize export and large inline pcb.deserialize loads:
three victims, one cause — an O(board) payload in a capped pipe.

The fix moves the board OUT of the capped pipe: the panel snapshots the
composed board to a file and the request carries {board_path, board_digest}
— O(hints), not O(board). This suite defines the worker half of that
contract, the third resolution arm of board_model.load_board:

  * params["board_path"] (absolute path) + params["board_digest"] (sha256
    hex of the file's BYTES) -> read file, verify digest, parse as YAML
    (JSON snapshots parse too — JSON is YAML).
  * digest is MANDATORY with board_path (fail-safe: an unverified file read
    is refused by name, never silently trusted).
  * mismatch / unreadable path / non-mapping content refuse via
    BoardParseError, matching the existing arms' failure idiom.
  * the existing "yaml" and "board" arms take precedence — behavior of every
    current caller is unchanged.

RED/GREEN contract: the NEW-ARM tests MUST fail before the arm exists
(load_board today raises "expected params.yaml (str) or params.board
(object)") — that proven red run is the regression baseline. The
PRECEDENCE tests are unchanged-behavior invariants and must pass before
AND after the fix; a red baseline here is deliberately partial, never
zero.

Same conventions as test_route_as_drawn.py (handle_request for the method
path; compilable PinSocket fixture for the ROUND E compile gate).
"""

from __future__ import annotations

import hashlib
import json

import pytest

from pcb_worker import board_model
from pcb_worker.methods import handle_request


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _minimal_board() -> dict:
    """Smallest structurally-canonical board (mirrors board_model.REQUIRED_TOP)."""
    return {
        "version": 1,
        "name": "by-path-min",
        "width_mm": 20,
        "height_mm": 10,
        "components": [],
        "nets": [],
    }


def _ir_two_pin_board() -> dict:
    """Compilable two-pin fixture — same topology as test_route_as_drawn.py's,
    so the route() method's compile gate resolves real seed-library pads."""
    return {
        "version": 1,
        "name": "by-path-ir",
        "width_mm": 60,
        "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "U1", "footprint": "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
             "x_mm": 15.24, "y_mm": 20.32, "rotation_deg": 0, "layer": "top"},
            {"ref": "J1", "footprint": "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
             "x_mm": 45.72, "y_mm": 20.32, "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "SIG", "pins": ["U1.1", "J1.1"]}],
    }


def _snapshot(tmp_path, board: dict, name: str = "board.json",
              as_json: bool = True) -> tuple[str, str]:
    """Write a board snapshot file; return (path, sha256-hex-of-bytes)."""
    if as_json:
        text = json.dumps(board)
    else:
        import yaml
        text = yaml.safe_dump(board)
    p = tmp_path / name
    p.write_text(text, encoding="utf-8")
    return str(p), hashlib.sha256(p.read_bytes()).hexdigest()


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "r1"
    return resp


# ---------------------------------------------------------------------------
# load_board third arm — acceptance
# ---------------------------------------------------------------------------


def test_board_path_round_trip_json(tmp_path):
    """A JSON snapshot (the panel writes JSON.stringify output) loads verbatim."""
    board = _minimal_board()
    path, digest = _snapshot(tmp_path, board, as_json=True)
    loaded = board_model.load_board({"board_path": path, "board_digest": digest})
    assert loaded == board


def test_board_path_round_trip_yaml(tmp_path):
    """A canonical YAML file loads by path too — the deserialize-by-path case
    can hand the worker the original on-disk YAML without re-encoding."""
    board = _minimal_board()
    path, digest = _snapshot(tmp_path, board, name="board.yaml", as_json=False)
    loaded = board_model.load_board({"board_path": path, "board_digest": digest})
    assert loaded == board


def test_board_path_digest_case_insensitive(tmp_path):
    """Hex digests compare case-insensitively — Godot and Python hex-encode
    with different default cases; a casing difference is not a mismatch."""
    board = _minimal_board()
    path, digest = _snapshot(tmp_path, board)
    loaded = board_model.load_board(
        {"board_path": path, "board_digest": digest.upper()})
    assert loaded == board


def test_board_path_unicode_path(tmp_path):
    """Non-ASCII path components survive the Godot -> Python handoff."""
    sub = tmp_path / "плата-试验"
    sub.mkdir()
    board = _minimal_board()
    path, digest = _snapshot(sub, board)
    loaded = board_model.load_board({"board_path": path, "board_digest": digest})
    assert loaded == board


# ---------------------------------------------------------------------------
# load_board third arm — refusals (all BoardParseError, matching arm idiom)
# ---------------------------------------------------------------------------


def test_board_path_requires_digest(tmp_path):
    """No digest, no read: an unverified file reference is refused by name."""
    path, _ = _snapshot(tmp_path, _minimal_board())
    with pytest.raises(board_model.BoardParseError, match="digest"):
        board_model.load_board({"board_path": path})


def test_board_path_digest_mismatch_refused(tmp_path):
    path, _ = _snapshot(tmp_path, _minimal_board())
    wrong = "0" * 64
    with pytest.raises(board_model.BoardParseError, match="digest"):
        board_model.load_board({"board_path": path, "board_digest": wrong})


def test_board_path_missing_file_refused(tmp_path):
    ghost = str(tmp_path / "nope.json")
    with pytest.raises(board_model.BoardParseError, match="nope.json"):
        board_model.load_board({"board_path": ghost, "board_digest": "0" * 64})


def test_board_path_non_mapping_refused(tmp_path):
    p = tmp_path / "list.yaml"
    p.write_text("- 1\n- 2\n", encoding="utf-8")
    digest = hashlib.sha256(p.read_bytes()).hexdigest()
    with pytest.raises(board_model.BoardParseError, match="mapping"):
        board_model.load_board({"board_path": str(p), "board_digest": digest})


def test_board_path_empty_file_refused(tmp_path):
    # match="empty" so this cannot pass vacuously off the no-arm error today,
    # and post-fix distinguishes "refused because empty" (the yaml arm's
    # "YAML source is empty" idiom) from any other refusal (cold review, f2).
    p = tmp_path / "empty.yaml"
    p.write_text("", encoding="utf-8")
    digest = hashlib.sha256(p.read_bytes()).hexdigest()
    with pytest.raises(board_model.BoardParseError, match="empty"):
        board_model.load_board({"board_path": str(p), "board_digest": digest})


# ---------------------------------------------------------------------------
# Precedence — existing arms are unchanged by the new one
# ---------------------------------------------------------------------------


def test_yaml_arm_takes_precedence_over_board_path(tmp_path):
    """A request carrying both keys resolves via the OLD arm — the new arm is
    strictly additive; no current caller changes behavior."""
    path, _ = _snapshot(tmp_path, _minimal_board())
    inline = dict(_minimal_board(), name="inline-wins")
    import yaml
    loaded = board_model.load_board({
        "yaml": yaml.safe_dump(inline),
        "board_path": path,
        "board_digest": "0" * 64,  # would refuse if the path arm ran
    })
    assert loaded["name"] == "inline-wins"


def test_board_arm_takes_precedence_over_board_path(tmp_path):
    path, _ = _snapshot(tmp_path, _minimal_board())
    inline = dict(_minimal_board(), name="dict-wins")
    loaded = board_model.load_board({
        "board": inline,
        "board_path": path,
        "board_digest": "0" * 64,
    })
    assert loaded["name"] == "dict-wins"


def test_no_arm_error_names_board_path(tmp_path):
    """The nothing-provided error must now name all three accepted keys, so a
    caller who sent a typo'd key learns the path arm exists."""
    with pytest.raises(board_model.BoardParseError, match="board_path"):
        board_model.load_board({})


# ---------------------------------------------------------------------------
# Method path — the route() victim, end to end through handle_request
# ---------------------------------------------------------------------------


def test_route_method_accepts_board_path(tmp_path):
    """The primary victim: a route request whose board arrives by reference
    compiles and routes exactly as an inline board does."""
    path, digest = _snapshot(tmp_path, _ir_two_pin_board())
    resp = _call("route", {"board_path": path, "board_digest": digest,
                           "route_hints": [], "selection": {"mode": "open"}})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["success"] is True, r
    assert [rt for rt in r["routes"] if rt["net"] == "SIG"], \
        "SIG must route from a by-path board exactly as from an inline one"


def test_promote_check_accepts_board_path(tmp_path):
    """The promote GATE rides the same capped pipe (fix cold review F1): an
    oversized board arrives by reference and must resolve into the gate's
    inline-dict contract instead of refusing the board's very shape."""
    path, digest = _snapshot(tmp_path, _ir_two_pin_board())
    resp = _call("promote_check", {"board_path": path, "board_digest": digest})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert "promotable" in r, r
    assert not any("requires a canonical board dict" in s
                   for s in r.get("refusals", [])), r["refusals"]


def test_promote_check_board_path_mismatch_is_gate_refusal(tmp_path):
    """A stale/corrupt gate snapshot is a fail-closed GATE refusal naming the
    digest — never a crash, never a silently-passed gate."""
    path, _ = _snapshot(tmp_path, _ir_two_pin_board())
    resp = _call("promote_check", {"board_path": path, "board_digest": "f" * 64})
    assert resp["ok"] is True, resp
    r = resp["result"]
    assert r["promotable"] is False
    assert any("digest" in s for s in r.get("refusals", [])), r["refusals"]


def test_route_method_digest_mismatch_is_parse_error(tmp_path):
    """A stale/corrupt snapshot surfaces as the route method's structured
    parse error — the same envelope an invalid inline board gets — never a
    crash and never a silent route against the wrong world."""
    path, _ = _snapshot(tmp_path, _ir_two_pin_board())
    resp = _call("route", {"board_path": path, "board_digest": "f" * 64,
                           "route_hints": [], "selection": {"mode": "open"}})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"
    assert "digest" in resp["error"]["message"]


# ---------------------------------------------------------------------------
# The DRC methods behind minerva_pcb_drc / minerva_pcb_drc_geometric
# ---------------------------------------------------------------------------


def _findings_of(resp: dict) -> list:
    assert resp["ok"] is True, resp
    return resp["result"].get("findings")


def test_drc_methods_accept_board_path(tmp_path):
    """The panel now sends the LIVE board to both DRC methods by reference when
    it is over the broker cap. ORACLE: the same board fed inline as yaml — the
    by-path call must produce byte-equal findings (and, for the geometric
    check, the same verdict), or the live-board verb would be checking
    something other than what the export path checks."""
    import yaml
    board = _ir_two_pin_board()
    board["traces"] = [{"net": "SIG", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 15.24, "y_mm": 20.32},
                                   {"x_mm": 30.0, "y_mm": 20.32}]}]
    text = yaml.safe_dump(board)
    path, digest = _snapshot(tmp_path, board)

    by_yaml = _call("drc", {"yaml": text})
    by_path = _call("drc", {"board_path": path, "board_digest": digest})
    assert _findings_of(by_path) == _findings_of(by_yaml), (by_path, by_yaml)
    assert by_path["result"]["counts"] == by_yaml["result"]["counts"]
    assert _findings_of(by_yaml), "the dangling SIG trace must be reported, or the pair is vacuous"

    geo_yaml = _call("drc_geometric", {"yaml": text})
    geo_path = _call("drc_geometric", {"board_path": path, "board_digest": digest})
    assert geo_path["ok"] is True and geo_yaml["ok"] is True
    assert geo_path["result"]["verdict"] == geo_yaml["result"]["verdict"]
    assert geo_path["result"].get("findings") == geo_yaml["result"].get("findings")


def test_drc_board_path_digest_mismatch_is_parse_error(tmp_path):
    """A by-path DRC never checks an unverified snapshot: the digest arm's own
    refusal surfaces as the method's structured parse error."""
    path, _digest = _snapshot(tmp_path, _ir_two_pin_board())
    resp = _call("drc", {"board_path": path, "board_digest": "0" * 64})
    assert resp["ok"] is False, resp
    assert resp["error"]["kind"] == "parse", resp
