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
_MIN_VECTORS = 19  # committed floor — keep in lockstep with vectors_test.go minVectors


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
