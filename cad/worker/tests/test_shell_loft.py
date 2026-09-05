"""Hollowing a lofted body.

``shell`` is the one hollowing primitive and ``loft:`` is the one organic-form
primitive, and OCCT's thick-solid offset refuses the combination: the side faces
of a loft are ruled and their inward offsets do not meet cleanly at the section
corners. The translator now falls back to insetting the 2D sections and lofting
the cavity, which needs no face offset at all.

ORACLE. An independent observation that would show this wrong: slice the
exported body at any z between the floor and the ceiling and measure the wall
in a CAD tool. It is the requested thickness measured horizontally. The probes
below ask the B-Rep the same question — a point one third of a wall inside the
surface is material, one and a half walls in is air.
"""

import pytest
from build123d import Vector

from mcad.parser import parse
from mcad.translator import Translator, TranslatorError

# Four rect sections, the shape of an ergonomic enclosure: it grows, holds, and
# tapers. Centred on (40, 30) so nothing is at the origin.
LOFT_SOURCE = """body = loft:
    z=-8: translate([40,30,0], rect(60, 40))
    z=3: translate([40,30,0], rect(80, 55))
    z=14: translate([40,30,0], rect(76, 52))
    z=19: translate([40,30,0], rect(50, 34))
"""

WALL = 2.0


def _translate(source: str) -> Translator:
    translator = Translator()
    translator.translate(parse(source))
    return translator


class TestShellOnALoft:
    def test_a_four_section_loft_shells(self):
        plain = _translate(LOFT_SOURCE).env["body"]
        shelled = _translate(LOFT_SOURCE + "shell body, 2\n").env["body"]
        assert shelled.volume > 0.0
        assert shelled.volume < plain.volume

    def test_the_wall_is_the_requested_thickness(self):
        shelled = _translate(LOFT_SOURCE + "shell body, 2\n").env["body"]
        # At z=3 the section is 80 x 55 centred on (40, 30), so the +X wall
        # runs from x=80 inward.
        assert shelled.is_inside(Vector(80.0 - WALL / 3.0, 30.0, 3.0))
        assert not shelled.is_inside(Vector(80.0 - WALL * 1.5, 30.0, 3.0))
        # The cavity is a cavity: the middle is empty.
        assert not shelled.is_inside(Vector(40.0, 30.0, 3.0))

    def test_the_body_keeps_a_floor_and_a_ceiling(self):
        shelled = _translate(LOFT_SOURCE + "shell body, 2\n").env["body"]
        assert shelled.is_inside(Vector(40.0, 30.0, -8.0 + WALL / 3.0))
        assert not shelled.is_inside(Vector(40.0, 30.0, -8.0 + WALL * 1.5))
        assert shelled.is_inside(Vector(40.0, 30.0, 19.0 - WALL / 3.0))

    def test_a_wall_thicker_than_the_body_names_the_intent(self):
        with pytest.raises(TranslatorError) as caught:
            _translate(LOFT_SOURCE + "shell body, 40\n")
        message = str(caught.value)
        assert "shell body, 40" in message
        # The message has to be about the shape, not about OCCT internals.
        assert "TopoDS" not in message

    def test_a_solid_with_no_recoverable_intent_names_the_fallback(self):
        # A lofted body that was transformed after the loft has no recorded
        # sections to inset, so the refusal must tell the author what to write.
        source = LOFT_SOURCE + "body = translate([0,0,0], body)\nshell body, 2\n"
        with pytest.raises(TranslatorError) as caught:
            _translate(source)
        message = str(caught.value)
        assert "inset" in message
        assert "body = body - inner" in message

    def test_shelling_a_cube_still_uses_the_offset(self):
        shelled = _translate("body = cube(20,20,20)\nshell body, 2\n").env["body"]
        assert 0.0 < shelled.volume < 8000.0
