"""Python side of the committed cross-language board-v2 validation vectors.

Loads the SAME pcb/spec/vectors/ directory the Go suite loads
(internal/board/vectors_test.go) and asserts each vector's declared outcome
through the Python shared-boundary validator (pcb_worker.board_validate). Both
suites passing over the same vectors is the anti-drift guarantee mandated by
comment 629 — if the Go and Python validators diverge on any committed case, one
side goes red.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

from pcb_worker.board_validate import validate_board_v2

# pcb/worker/tests/ -> parents[2] == pcb/, so pcb/spec/vectors.
VECTORS = Path(__file__).resolve().parents[2] / "spec" / "vectors"
_MIN_VECTORS = 27  # committed floor — keep in lockstep with vectors_test.go minVectors


def _vector_names() -> list[str]:
    return sorted(p.name for p in VECTORS.iterdir() if p.is_dir())


@pytest.mark.parametrize("name", _vector_names())
def test_shared_validation_vector(name):
    d = VECTORS / name
    board = yaml.safe_load((d / "input.yaml").read_text(encoding="utf-8"))
    expect = json.loads((d / "expect.json").read_text(encoding="utf-8"))

    codes = validate_board_v2(board)
    got_valid = not codes
    assert got_valid == expect["valid"], f"{name}: expected valid={expect['valid']}, codes={codes}"
    if not expect["valid"] and expect.get("code"):
        assert expect["code"] in codes, f"{name}: expected code {expect['code']!r} in {codes}"


def test_committed_vector_floor():
    # Drift/loss guard — the committed vector set must not silently shrink.
    assert len(_vector_names()) >= _MIN_VECTORS


# D2 (finding 019f8b7fb07e comment 689): the pth_holes / npth_holes aliases share
# the "hole" persistent-id domain with mounting_holes. validate_board_v2 covers all
# three uniformly for a raw board that reaches the Python compiler without the Go
# fold — an id-less alias hole, a duplicate across the alias keys, and a null alias
# item all fail closed.
def _v2_hole_board(**collections) -> dict:
    board = {"version": 2, "id": "board:" + "a" * 32, "name": "H",
             "width_mm": 20, "height_mm": 20, "components": [], "nets": []}
    board.update(collections)
    return board


def test_v2_pth_hole_without_id_fails_validation():
    board = _v2_hole_board(pth_holes=[{"x_mm": 2, "y_mm": 2, "diameter_mm": 2.0}])
    assert "unminted_persistent_id" in validate_board_v2(board)


def test_v2_duplicate_hole_id_across_alias_keys_fails():
    dup = "hole:" + "b" * 32
    board = _v2_hole_board(
        mounting_holes=[{"id": dup, "x_mm": 1, "y_mm": 1, "diameter_mm": 3.0}],
        pth_holes=[{"id": dup, "x_mm": 2, "y_mm": 2, "diameter_mm": 2.0}])
    assert "duplicate_persistent_id" in validate_board_v2(board)


def test_v2_null_alias_hole_item_fails_structure():
    board = _v2_hole_board(npth_holes=[None])
    assert "invalid_board_structure" in validate_board_v2(board)


def test_v2_minted_alias_holes_across_keys_pass():
    board = _v2_hole_board(
        mounting_holes=[{"id": "hole:" + "1" * 32, "x_mm": 1, "y_mm": 1, "diameter_mm": 3.0}],
        pth_holes=[{"id": "hole:" + "2" * 32, "x_mm": 2, "y_mm": 2, "diameter_mm": 2.0}],
        npth_holes=[{"id": "hole:" + "3" * 32, "x_mm": 3, "y_mm": 3, "diameter_mm": 3.0}])
    assert validate_board_v2(board) == []
