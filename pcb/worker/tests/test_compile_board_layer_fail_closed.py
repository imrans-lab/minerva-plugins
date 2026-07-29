"""D9b (item 019fa73a8732) — copper on a layer the emitter cannot write must be
a compile ERROR, not a documentation-only WARNING.

Before this unit, ``_place_component`` folded EVERY unemitted layer id (pad
AND graphic, copper and non-copper alike) into one ``captured_geometry_not_emitted``
WARNING. A board with a footprint pad on ``In1.Cu`` compiled clean, generated
gerbers, and the copper was simply not there -- a K4 discards-clause violation
(the board authored a dimension of geometry that silently vanished) that also
fails closed for K14 (a fabrication-critical loss must not compile as success).

The fix is scoped to COPPER (``LayerRole.COPPER``) ONLY: non-copper capture on
an unemitted layer (fab, courtyard, paste, back silk) is legitimately
documentation-only and stays a warning -- widening the gate to all unemitted
layers would turn ordinary library footprints (which routinely carry F.Fab /
F.CrtYd / paste) into compile failures.

Two false-positive doors guard this gate, and both are pinned here:
  * copper-role check must be scoped -- else F.Fab/F.CrtYd/F.Paste break (the
    defect the acceptance criteria in the brief calls out explicitly).
  * ``Layer.from_id("top")``/``Layer.from_id("bottom")`` ALSO resolve to
    ``LayerRole.COPPER`` but are not literally in ``K3_EMITTED_LAYERS`` (which
    holds only the KiCad names ``F.Cu``/``B.Cu``) -- a footprint or board that
    spells its own two copper layers the CANONICAL way must not be
    misreported as declaring unemitted copper.

Hole 1 (whether the layers-absent board default admits inner-layer copper) is
argued and closed by ``test_inner_copper_fails_closed_even_when_board_omits_layers_key``:
the gate lives on PAD/GRAPHIC layer participation, which is independent of
whatever ``board["layers"]`` does or does not declare.

Hole 2 (the ``*.Cu`` wildcard truncating to two layers on a widened stack) is
UNREACHABLE at this SHA -- ``_build_layer_stack`` can only ever construct the
canonical two-layer stack -- and is explicitly OUT OF SCOPE (item
019fa73aee02, a two-layer-guard-widening unit, not this one). No test for it
is written here; a test that cannot fail is the defect this campaign exists to
prevent.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

from pcb_worker.compile_board import _Diagnostics, _place_component, compile_board
from pcb_worker.footprint_def import FootprintDefinition, LineGraphic
from pcb_worker.footprints import sha256_file
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    Layer,
    ResolutionFailure,
    ResolutionSuccess,
    Side,
)

TESTDATA = Path(__file__).parent / "testdata"


@pytest.fixture(scope="module")
def smart_remote_result():
    # Local copy of test_compile_board.py's fixture -- pytest fixtures are not
    # shared across test files without a conftest.py, and this module doesn't
    # need the rest of that file's fixtures/helpers.
    board = yaml.safe_load((TESTDATA / "smart_remote.yaml").read_text(encoding="utf-8"))
    return compile_board(board)

# ---------------------------------------------------------------------------
# Fixture plumbing: a throwaway one-entry library + lockfile per synthetic
# footprint, mirroring test_compile_board.py's real seed-library pipeline
# (resolve_footprint -> sha-pinned lockfile entry) rather than reaching into
# compiler internals -- this is the SAME path a real authored/hand-edited
# footprint takes, so "fails to compile" means the full pipeline, not a unit
# call.
# ---------------------------------------------------------------------------


def _seed_footprint(tmp_path: Path, name: str, body: str) -> tuple[str, Path, Path]:
    """Write *body* as ``TestLib:<name>``'s .kicad_mod under a fresh tmp
    library root, sha-pin it in a fresh one-entry lockfile, and return
    ``(ref, library_root, lockfile)`` ready for ``compile_board(...)``."""
    library_root = tmp_path / "library"
    pretty_dir = library_root / "TestLib.pretty"
    pretty_dir.mkdir(parents=True)
    fp_path = pretty_dir / f"{name}.kicad_mod"
    fp_path.write_text(body, encoding="utf-8")
    lockfile = tmp_path / "test.lock.json"
    ref = f"TestLib:{name}"
    lockfile.write_text(json.dumps({
        ref: {"path": f"TestLib.pretty/{name}.kicad_mod", "sha256": sha256_file(fp_path)},
    }), encoding="utf-8")
    return ref, library_root, lockfile


def _board(ref: str, *, omit_layers_key: bool = False) -> dict:
    board = {
        "version": 1, "name": "brd", "width_mm": 20, "height_mm": 20,
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "X1", "footprint": ref, "x_mm": 10, "y_mm": 10,
                        "rotation_deg": 0, "layer": "top"}],
    }
    if not omit_layers_key:
        board["layers"] = ["top", "bottom"]
    return board


def _compile(tmp_path: Path, name: str, body: str, *, omit_layers_key: bool = False):
    ref, library_root, lockfile = _seed_footprint(tmp_path, name, body)
    return compile_board(_board(ref, omit_layers_key=omit_layers_key),
                         library_root=library_root, lockfile=lockfile)


def _errors(result) -> list:
    return [d for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]


def _warnings(result) -> list:
    return [d for d in result.diagnostics if d.severity is DiagnosticSeverity.WARNING]


# ---------------------------------------------------------------------------
# 1. A pad declaring copper on a layer the emitter does not write FAILS to
#    compile, with a diagnostic naming the layer.
# ---------------------------------------------------------------------------


_INNER_CU_PAD_FOOTPRINT = """\
(footprint "INNER_CU_PAD" (version 20221018) (generator pcb_worker_seed)
  (layer "F.Cu")
  (pad "1" smd rect (at 0 0) (size 1 1) (layers "In1.Cu"))
)
"""


def test_pad_declaring_inner_copper_layer_fails_closed(tmp_path):
    result = _compile(tmp_path, "INNER_CU_PAD", _INNER_CU_PAD_FOOTPRINT)
    assert isinstance(result, ResolutionFailure), \
        "a pad on In1.Cu (an unemitted COPPER layer) must fail closed, not compile clean"
    errors = _errors(result)
    assert any(d.code == "unemitted_copper_layer" for d in errors), errors
    matching = [d for d in errors if d.code == "unemitted_copper_layer"]
    assert any("In1.Cu" in d.message for d in matching), matching


# ---------------------------------------------------------------------------
# 2. The SAME gate on the graphics path (the pad/graphic split is exactly the
#    kind of "guard applied to one case instead of all" half-mutation the
#    campaign's mutation-proof protocol targets).
#
# NOTE on reachability: the real kicad_mod parser never CAPTURES a graphic on
# a copper layer -- ``footprints.GRAPHIC_LAYERS`` is silk/fab/courtyard/paste
# only (footprints.py:42-45) -- so a graphic on "In2.Cu" is dropped at parse
# time and surfaces earlier, as a fatal ``unsupported_feature`` (uncaptured
# copper graphic) from marker adjudication, before ``_place_component`` is
# ever reached (verified: the .kicad_mod-shaped version of this test fails
# with THAT code, not ``unemitted_copper_layer``). So this calls
# ``_place_component`` directly with a hand-built ``FootprintDefinition`` --
# the exact same construction style ``test_compile_board.py``'s
# ``_synthetic_pad`` uses to reach code the parser path cannot drive today.
# The guard is still worth pinning here: ``FootprintDefinition``/
# ``_place_component`` are general-purpose, not parser-exclusive, and a
# reviewer reading ``_place_component`` should not find an asymmetric guard.
# ---------------------------------------------------------------------------


def test_graphic_declaring_inner_copper_layer_fails_closed():
    definition = FootprintDefinition(
        name="fp",
        pads=(),
        graphics=(LineGraphic(source_id="g:0", layer=Layer.from_id("In2.Cu"),
                              width_mm=0.1, a=(0.0, 0.0), b=(1.0, 1.0)),),
    )
    diags = _Diagnostics()
    comp = {"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0}
    placed = _place_component(comp, "component:1", definition, Side.TOP, {}, {}, "X1", diags)
    assert placed is not None
    assert diags.has_error
    matching = [d for d in diags.tuple() if d.code == "unemitted_copper_layer"]
    assert matching, diags.tuple()
    assert any("In2.Cu" in d.message for d in matching), matching


# ---------------------------------------------------------------------------
# 3. Ordinary non-copper capture (fab/courtyard/paste) stays a warning and the
#    board still compiles CLEAN -- the false positive the copper scoping
#    guards against.
# ---------------------------------------------------------------------------


_ORDINARY_FOOTPRINT = """\
(footprint "ORDINARY" (version 20221018) (generator pcb_worker_seed)
  (layer "F.Cu")
  (fp_line (start -1 -1) (end 1 -1) (layer "F.Fab") (width 0.1))
  (fp_line (start -1 -1) (end -1 1) (layer "B.CrtYd") (width 0.05))
  (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu" "F.Paste" "F.Mask"))
)
"""


def test_ordinary_fab_courtyard_paste_geometry_still_compiles_clean(tmp_path):
    result = _compile(tmp_path, "ORDINARY", _ORDINARY_FOOTPRINT)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert not _errors(result)
    warnings = _warnings(result)
    codes = {d.code for d in warnings}
    assert "captured_geometry_not_emitted" in codes, warnings
    assert "unemitted_copper_layer" not in codes
    # The unemitted set named in the warning is exactly the non-copper,
    # non-emitted ids.
    combined_message = " ".join(d.message for d in warnings)
    for layer_id in ("F.Fab", "B.CrtYd"):
        assert layer_id in combined_message, combined_message
    # F.Paste is NO LONGER in that set: the emitter writes real stencil apertures
    # now, so paste participation is emitted, not documentation-only. This
    # assertion is the deliberate inverse of the one it replaces -- if paste ever
    # stops being emitted, the warning must come BACK rather than the geometry
    # quietly vanishing.
    assert "F.Paste" not in combined_message, combined_message


# ---------------------------------------------------------------------------
# 4. [R2] THE FALSE-POSITIVE DOOR THE EARLIER BRIEF MISSED: canonical "top"/
#    "bottom" copper ids must not be misreported as unemitted copper merely
#    because K3_EMITTED_LAYERS spells them "F.Cu"/"B.Cu".
# ---------------------------------------------------------------------------


_CANONICAL_ID_FOOTPRINT = """\
(footprint "CANONICAL_ID" (version 20221018) (generator pcb_worker_seed)
  (layer "F.Cu")
  (pad "1" smd rect (at 0 0) (size 1 1) (layers "top"))
)
"""


def test_canonical_top_bottom_copper_ids_are_not_false_positives(tmp_path):
    # A footprint pad spelling its copper participation the CANONICAL way
    # ("top", not "F.Cu") declares the exact same emitted layer under a
    # different name (agent_router.layers.CANON_TO_KICAD) -- it must compile
    # exactly as clean as the KiCad-spelled equivalent.
    result = _compile(tmp_path, "CANONICAL_ID", _CANONICAL_ID_FOOTPRINT)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    codes = {d.code for d in result.diagnostics}
    assert "unemitted_copper_layer" not in codes


# ---------------------------------------------------------------------------
# 5. Hole 1: the layers-absent board default does not smuggle inner-layer
#    copper past the gate. The gate lives on PAD/GRAPHIC layer participation
#    (library-declared), which _require_two_layer's board["layers"] branch
#    never touches -- so absence changes nothing about reachability here.
# ---------------------------------------------------------------------------


def test_inner_copper_fails_closed_even_when_board_omits_layers_key(tmp_path):
    result = _compile(tmp_path, "INNER_CU_PAD", _INNER_CU_PAD_FOOTPRINT,
                      omit_layers_key=True)
    assert isinstance(result, ResolutionFailure), \
        "board.layers absence (the canonical two-layer default) must not " \
        "change whether a footprint's own In1.Cu pad is caught"
    assert any(d.code == "unemitted_copper_layer" for d in _errors(result))


# ---------------------------------------------------------------------------
# 6. Real seed-library evidence: the compile census (test_compile_board.py,
#    parametrized over every locked ref) already proves every REAL footprint
#    still resolves under the new gate. Re-assert it against the full
#    smart_remote board fixture here too, scoped to the new code specifically,
#    so a regression in this unit's own test file catches it without relying
#    on test_compile_board.py being run in the same invocation.
# ---------------------------------------------------------------------------


def test_smart_remote_seed_board_has_no_unemitted_copper_errors(smart_remote_result):
    assert isinstance(smart_remote_result, ResolutionSuccess)
    codes = {d.code for d in smart_remote_result.diagnostics
             if d.severity is DiagnosticSeverity.ERROR}
    assert "unemitted_copper_layer" not in codes
