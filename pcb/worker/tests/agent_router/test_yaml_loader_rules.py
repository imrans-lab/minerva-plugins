"""Chore 019f9d0c20 (epoch GA-6) — ONE read of the board YAML.

load_board_with_hints now fills board.design_rules from the same parse that
yields the hints; cli._design_rules_from_yaml (the second read, which had
already diverged once on error semantics) is deleted. What must hold, per
the item's own note: missing-or-empty file -> rules None (absent guidance is
legitimate and falls through to engine defaults); UNREADABLE file or rules
block -> raise. Absent-vs-unreadable is load-bearing (hint 019f9d061f13).
"""

import pytest
import yaml

from agent_router.board import RoutingRulesError
from agent_router.yaml_loader import load_board_with_hints

_MIN_PCB = (
    '(kicad_pcb (version 20221018) (generator pcbnew)\n'
    '  (general (thickness 1.6))\n'
    '  (layers\n'
    '    (0 "F.Cu" signal)\n'
    '    (31 "B.Cu" signal)\n'
    '    (44 "Edge.Cuts" user)\n'
    '  )\n'
    '  (net 0 "")\n'
    '  (gr_rect (start 0 0) (end 30 20) (layer "Edge.Cuts") (width 0.1))\n'
    ')\n')


@pytest.fixture()
def pcb_path(tmp_path):
    p = tmp_path / "b.kicad_pcb"
    p.write_text(_MIN_PCB)
    return p


def test_authored_rules_ride_the_one_read(pcb_path, tmp_path):
    y = tmp_path / "b.yaml"
    y.write_text(yaml.safe_dump({
        "name": "b",
        "design_rules": {"trace_width_mm": 0.42, "clearance_mm": 0.21}}))
    board, _hints, _inets = load_board_with_hints(pcb_path, y)
    assert board.design_rules is not None
    assert board.design_rules.defaults.trace_width_mm == pytest.approx(0.42)


def test_missing_yaml_leaves_rules_none(pcb_path, tmp_path):
    board, hints, inets = load_board_with_hints(
        pcb_path, tmp_path / "nope.yaml")
    assert board.design_rules is None
    assert inets == {}


def test_empty_yaml_is_absent_guidance_not_an_error(pcb_path, tmp_path):
    y = tmp_path / "empty.yaml"
    y.write_text("")
    board, _hints, _inets = load_board_with_hints(pcb_path, y)
    assert board.design_rules is None


def test_non_mapping_yaml_fails_closed(pcb_path, tmp_path):
    y = tmp_path / "list.yaml"
    y.write_text("- not\n- a\n- mapping\n")
    with pytest.raises(RoutingRulesError, match="not a mapping"):
        load_board_with_hints(pcb_path, y)


def test_rules_free_board_yaml_still_yields_hints(pcb_path, tmp_path):
    y = tmp_path / "b.yaml"
    y.write_text(yaml.safe_dump({"name": "b"}))
    board, hints, _inets = load_board_with_hints(pcb_path, y)
    assert board.design_rules is None
    assert hints is not None
