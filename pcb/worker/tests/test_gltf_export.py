"""The two judgements the board export makes on its own, tested WITHOUT a file.

Everything else in ``gltf_export`` is assembly — it asks another module and
passes the answer on — and is checked through the exported bytes by an
independent glTF reader in ``tests/oracle/test_gltf_export_oracle.py``. These
two are decisions, and a decision deserves a test that names it:

* ``d 0.0`` IS IGNORED AND EVERY PART IS OPAQUE. This is the one assertion in
  the whole export that no structural check can stand in for: a board whose
  every part is invisible loads, validates, has the right mesh count and the
  right transforms, and shows nothing. The rendered proof is a person opening
  the file; this is the proof that survives to the next change.
* THE ASSUMPTION'S FALSIFIER FIRES. The ruling rests on "no vendor ever
  authored this field", which is a measurement over the models seen so far. A
  model with any other dissolve must SAY SO in the export's notes — still drawn
  opaque, because the ruling is a person's to revisit, but never silently.

The materials under test are parsed from ``test_wavefront_obj``'s ``BOX``, the
vendor dialect exactly as it arrives — inline ``newmtl`` blocks, ``d 0.0`` on
every one of them, and the two real ``Kd`` values (0.251 body grey, 1.0 bare
metal) — rather than from hand-built ``Material`` objects, so this cannot pass
against a shape the vendor does not actually ship.
"""

from __future__ import annotations

import pytest

from pcb_worker.gltf_export import (DISSOLVE_SURPRISE, KNOWN_DISSOLVES,
                                    NEUTRAL_PART_RGB, part_base_color,
                                    srgb_to_linear)
from pcb_worker.wavefront_obj import Material, parse_obj
from tests.test_wavefront_obj import BOX


def test_the_vendor_dissolve_is_ignored_and_the_authored_colour_is_kept():
    """Every material of a real vendor model: opaque, in its own ``Kd``."""
    materials = parse_obj(BOX).materials
    assert {m.dissolve for m in materials.values()} == {0.0}, \
        "the fixture must carry the trap, or this test proves nothing"

    for name, material in materials.items():
        rgba, note = part_base_color(material)
        assert rgba[3] == 1.0, f"material {name} came out see-through"
        assert note is None
        # And the colour is the file's, converted once for glTF's linear factor.
        assert rgba[:3] == pytest.approx(
            tuple(srgb_to_linear(c) for c in material.diffuse))

    # The two Kd values are meaningfully different and stay different: a body
    # grey that came out as white would be a colour we invented.
    grey, metal = (part_base_color(materials[k])[0] for k in ("1", "2"))
    assert grey[0] < 0.1 < metal[0] == 1.0


def test_a_dissolve_outside_the_measured_set_is_reported_and_still_opaque():
    """The falsifier: a vendor that starts authoring ``d`` must be heard."""
    surprising = Material(name="lens", diffuse=(0.2, 0.4, 0.9), dissolve=0.5)
    rgba, note = part_base_color(surprising)

    assert 0.5 not in KNOWN_DISSOLVES
    assert rgba[3] == 1.0, "the ruling stands until a person revisits it"
    assert note is not None and note.startswith(DISSOLVE_SURPRISE)
    assert "0.5" in note

    # A material with no `d` at all is the measured normal case, not a surprise.
    assert part_base_color(Material(name="plain", diffuse=(1.0, 1.0, 1.0)))[1] is None


def test_a_material_with_no_colour_is_neutral_and_says_so():
    """Vendor colours are consumed, never invented — and where there is none to
    consume, the grey that stands in is announced rather than passed off as
    measured."""
    rgba, note = part_base_color(Material(name="bare"))

    assert rgba[:3] == pytest.approx(tuple(srgb_to_linear(c) for c in NEUTRAL_PART_RGB))
    assert rgba[3] == 1.0
    assert note is not None and "no Kd" in note
