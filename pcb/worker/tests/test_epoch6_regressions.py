"""Regression guards for the epoch-6 HITL fix batch (owner ruling amendment of
2026-07-30: regressions for HITL-found defects are filed as docket test items
and authored where automatable).

* ``TestIsTopFailClosed`` — docket 019fb64efff8: ``is_top`` raises on a named
  layer outside the two fabricable sides (fixed at ea55ca3) instead of
  silently bucketing in1..in30 copper onto the top Gerber/DRC side; an
  UNSPECIFIED layer (None / empty) still defaults to top.
* ``TestZoneNetlessKeepoutParity`` — docket 019fb64f22b3: the Python boundary
  validator's zone rules match Go's ``validateZones`` on the keepout net
  exemption (owner ruling "Keepouts don't need net connections", 85f90ed).
  The Go side of the parity pair is
  internal/board/epoch6_regression_test.go::TestValidateZonesKeepoutNetless —
  same five cases, same expected codes, by construction.
"""

from __future__ import annotations

import pytest

from pcb_worker import board_validate
from pcb_worker.geometry import is_top


class TestIsTopFailClosed:
    @pytest.mark.parametrize("val", [None, "", "top", "TOP", "F.Cu", " front "])
    def test_top_family_and_unspecified(self, val):
        assert is_top(val) is True

    @pytest.mark.parametrize("val", ["bottom", "B.Cu", "back", " BOTTOM "])
    def test_bottom_family(self, val):
        assert is_top(val) is False

    @pytest.mark.parametrize("val", ["in1", "In3.Cu", "copper", "F.SilkS", 3, {}])
    def test_named_unfabricable_raises(self, val):
        with pytest.raises(ValueError):
            is_top(val)


TRIANGLE = [[0, 0], [10, 0], [0, 10]]


def _zone_codes(zone: dict) -> list[str]:
    codes: list[str] = []
    board = {"nets": [{"name": "GND"}], "layers": ["top", "bottom"]}
    board_validate._check_zones([zone], board, codes)
    return codes


class TestZoneNetlessKeepoutParity:
    def test_keepout_with_no_net_is_valid(self):
        assert _zone_codes({"kind": "keepout", "layer": "top", "outline": TRIANGLE}) == []

    def test_keepout_with_declared_net_stays_valid(self):
        assert _zone_codes(
            {"kind": "keepout", "net": "GND", "layer": "top", "outline": TRIANGLE}
        ) == []

    def test_keepout_naming_undeclared_net_is_still_checked(self):
        assert _zone_codes(
            {"kind": "keepout", "net": "NOPE", "layer": "top", "outline": TRIANGLE}
        ) == ["zone_unknown_net"]

    def test_pour_with_no_net_is_refused(self):
        assert _zone_codes(
            {"kind": "copper_pour", "layer": "top", "outline": TRIANGLE}
        ) == ["zone_unknown_net"]

    def test_unknown_kind_is_refused_before_the_net_rule(self):
        assert _zone_codes(
            {"kind": "exclusion", "net": "GND", "layer": "top", "outline": TRIANGLE}
        ) == ["invalid_zone_kind"]
