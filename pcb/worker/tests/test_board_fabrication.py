"""The ordered appearance: the board records the choice, the profile the menu.

A board now records what it was ORDERED to look like — solder-mask colour,
surface finish, overall thickness — and that choice is checked against what the
selected manufacturer profile says the board house actually offers. The two
facts are on two objects on purpose: a menu is a property of the VENDOR, a
choice is a property of THIS ORDER, and collapsing them forces a profile fork
per colour.

Four claims, each with an oracle that does not simply restate the code:

  * the choice reaches the compiled board and the human order checklist, while
    the COPPER is untouched — proved by compiling one board twice and comparing
    the fabrication artifacts byte-for-byte;
  * a populated menu that does not contain the choice REFUSES, naming the field
    and what is on offer;
  * a profile that publishes no menu has said nothing, so the choice stands;
  * a board with no ``fabrication`` block compiles exactly as it did before the
    block existed — the compatibility claim the whole design rests on.

The board is the shipped coupon (tests/testdata/coupon_jlc1.yaml) compiled
against the shipped jlcpcb-2layer profile: real paths, real published values,
no fixture that could agree with the code by construction.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
import yaml

from pcb_worker import order_package
from pcb_worker.compile_board import compile_board
from pcb_worker.gerber import build_gerbers_ir
from pcb_worker.manufacturer_profile import load_rule_profile
from pcb_worker.resolved_board import ResolutionFailure, ResolutionSuccess

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"
PROFILES = Path(__file__).resolve().parents[2] / "library" / "profiles"
SERVICE_ID = "jlcpcb-economic"


def _board(**fabrication) -> dict:
    """The shipped coupon, optionally carrying an appearance. Deep-copied per
    call so a mutation in one test cannot reach another."""
    board = yaml.safe_load(COUPON.read_text(encoding="utf-8"))
    if fabrication:
        board["fabrication"] = dict(fabrication)
    return board


def _compiled(board: dict):
    result = compile_board(copy.deepcopy(board))
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _errors(board: dict) -> list[tuple[str, str]]:
    result = compile_board(copy.deepcopy(board))
    return [(d.code, d.message) for d in result.diagnostics
            if d.severity.value == "error"]


def _fab_files(compiled) -> dict:
    """The fabrication artifacts themselves — Gerbers and drills, as bytes."""
    return dict(build_gerbers_ir(compiled))


def test_the_chosen_appearance_travels_and_the_copper_does_not_move():
    """THE SPLIT, end to end. Two boards with IDENTICAL copper and different
    order-form choices must differ in what they RECORD and in what the human
    checklist prints, and must not differ by one byte in what gets fabricated.

    The oracle is the fabrication output itself, not a field readback: if the
    appearance had leaked into the emitters, the Gerbers would differ, and if it
    had not reached a consumer, the checklist would not.
    """
    plain = _compiled(_board())
    fancy = _compiled(_board(mask_colour="Black", finish="ENIG", thickness_mm=1.0))

    assert (plain.fabrication.mask_colour, plain.fabrication.finish,
            plain.fabrication.thickness_mm) == ("green", "HASL", 1.6)
    assert (fancy.fabrication.mask_colour, fancy.fabrication.finish,
            fancy.fabrication.thickness_mm) == ("Black", "ENIG", 1.0)

    # NOT ONE FABRICATED BYTE MOVES. No Gerber or drill file carries a mask
    # colour; a change here would mean the appearance had leaked into geometry.
    assert _fab_files(plain) == _fab_files(fancy)

    # But the human half of the order DOES change, which is the point: the
    # person ordering matches three fields against the vendor's form.
    plain_list = order_package.build(
        _board(), plain, SERVICE_ID).files["ORDER-CHECKLIST.md"]
    fancy_list = order_package.build(
        _board(mask_colour="Black", finish="ENIG", thickness_mm=1.0),
        fancy, SERVICE_ID).files["ORDER-CHECKLIST.md"]
    assert "- [ ] Solder-mask colour: green" in plain_list
    assert "- [ ] Surface finish: HASL" in plain_list
    assert "- [ ] Board thickness: 1.6 mm" in plain_list
    assert "- [ ] Solder-mask colour: Black" in fancy_list
    assert "- [ ] Surface finish: ENIG" in fancy_list
    assert "- [ ] Board thickness: 1 mm" in fancy_list


def test_a_choice_the_profile_does_not_offer_is_refused_by_name():
    """A POPULATED menu that does not contain the choice refuses, and the
    refusal names the field, the choice and the whole menu — "OSP is not
    offered" without the list leaves the author guessing what is.

    OSP is the honest case rather than a nonsense value: JLCPCB publishes it,
    restricted to copper-core boards, and this FR4 profile therefore does not
    offer it.
    """
    errors = _errors(_board(finish="OSP"))
    assert [code for code, _ in errors] == ["unoffered_fabrication_choice"]
    message = errors[0][1]
    assert "fabrication.finish" in message
    assert "'OSP'" in message
    assert "jlcpcb-2layer" in message
    for offered in load_rule_profile("jlcpcb-2layer").surface_finishes:
        assert offered in message


def test_a_profile_that_publishes_no_menu_accepts_any_choice():
    """SILENCE ACCEPTS. v1-fab-conservative declares no capabilities at all, so
    it has said nothing about colour — and refusing on silence would reject
    every board compiled against it, including the defaults.

    The premise is asserted against the shipped file rather than assumed: if
    someone gives that profile a menu, this test says so instead of quietly
    testing nothing.
    """
    shipped = json.loads((PROFILES / "v1-fab-conservative.json").read_text())
    assert "capabilities" not in shipped

    board = _board(mask_colour="chartreuse", finish="cold fusion", thickness_mm=7.0)
    board["design_rules"]["rule_profile"] = "v1-fab-conservative"
    compiled = _compiled(board)
    assert compiled.fabrication.mask_colour == "chartreuse"
    assert compiled.fabrication.thickness_mm == 7.0


def test_a_board_with_no_fabrication_block_compiles_as_before():
    """THE COMPATIBILITY CLAIM, in the three ways it could break.

    1. The compiler must not REWRITE the board. A board with no block still
       digests as the bytes on disk do, so nothing about its identity moved.
    2. Stating the defaults explicitly must be indistinguishable from stating
       nothing — same digest for the copper, same fabrication artifacts.
    3. The profile BACKFILL must not have repinned anything: the shipped JLC
       profiles' digests must equal what the same files digest to with the
       three appearance menus stripped out. That is the independent oracle for
       "recording what JLCPCB has always offered changed no board's rules".
    """
    silent = _board()
    # Compiled WITHOUT a defensive copy on purpose: the claim is that the
    # compiler does not write the defaults back into the document.
    result = compile_board(silent)
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    compiled = result.board
    assert "fabrication" not in silent
    assert compiled.fabrication.mask_colour == "green"
    assert compiled.fabrication.finish == "HASL"
    assert compiled.fabrication.thickness_mm == 1.6

    spelled_out = _compiled(
        _board(mask_colour="green", finish="HASL", thickness_mm=1.6))
    assert _fab_files(compiled) == _fab_files(spelled_out)
    assert compiled.design_rules.rule_profile == spelled_out.design_rules.rule_profile


def test_the_appearance_backfill_repins_no_profile(tmp_path):
    """The menus are NOT in the profile digest, unlike max_copper_layers: no
    fabricated file carries a mask colour, so recording the vendor's menu must
    not change the identity of a profile boards are already pinned to.

    Oracle: the same shipped file with the three menus deleted must digest to
    the same value. A digest that moved would mean every board compiled against
    jlcpcb-2layer had its rules re-stamped by an editorial change.
    """
    for profile_id in ("jlcpcb-2layer", "jlcpcb-4layer"):
        shipped = json.loads((PROFILES / f"{profile_id}.json").read_text())
        menus = {"mask_colours", "surface_finishes", "board_thickness_mm"}
        assert menus <= set(shipped["capabilities"]), profile_id
        stripped = copy.deepcopy(shipped)
        for key in menus:
            del stripped["capabilities"][key]
        (tmp_path / f"{profile_id}.json").write_text(json.dumps(stripped))
        before = load_rule_profile(profile_id, library_root=tmp_path)
        after = load_rule_profile(profile_id)
        assert before.ref.digest == after.ref.digest, profile_id


def test_a_key_the_block_does_not_have_is_refused_naming_it():
    """An unknown key inside the block is refused like any other block's, and
    the message names the entity and the key — the Python half of a refusal the
    Go codec derives from its struct tags. `mask_color` is the realistic typo:
    silently accepting it would leave the board green while its author believed
    otherwise.
    """
    from pcb_worker.board_model import BoardParseError, load_board

    board = _board()
    board["fabrication"] = {"mask_color": "black"}
    codes = [code for code, _ in _errors(board)]
    assert codes and all(code == "invalid_board_structure" for code in codes)

    # The file-parse boundary is the one that can say WHICH key to delete; the
    # shared code above is what Go returns for the same document.
    with pytest.raises(BoardParseError, match="fabrication.*mask_color"):
        load_board({"yaml": yaml.safe_dump(board)})


def test_a_malformed_thickness_is_refused_rather_than_defaulted():
    """A value of the wrong type is a defect, not a silent fall back to 1.6:
    a board asking for a thickness this pipeline cannot read must say so.

    The code is pinned rather than accepted from a set. A malformed block is
    caught by the shared boundary, the same authority Go's positive-schema walk
    answers with, so ``invalid_board_structure`` is the ONLY code a compile can
    produce for it — accepting a second one would hide a refusal that had
    quietly moved somewhere else.
    """
    result = compile_board(_board(thickness_mm="thick"))
    assert isinstance(result, ResolutionFailure)
    assert [d.code for d in result.diagnostics
            if d.severity.value == "error"] == ["invalid_board_structure"]


def test_a_stated_value_is_used_as_stated_and_only_absence_takes_a_default():
    """MUTATION THIS CATCHES: `block.get(field) or DEFAULT`. It reads correctly
    on every board anyone has written and is a different rule from the one the
    docs state: `0` and `""` are falsy, so a stated zero thickness would compile
    as 1.6 mm and a blank finish as HASL — the author's value replaced by one
    they never chose, with nothing downstream able to see that it happened.

    Both of those documents ARE refused at the shared schema boundary, and that
    refusal stays. This test deliberately goes AROUND it, calling the derivation
    directly, because the point is that the derivation is correct on its own: a
    rule that is only safe because of a check somewhere else stops being safe
    the day that check moves.

    ORACLE: the defaults the module publishes. A field the board did not mention
    takes its default; a field it did mention keeps what it said, whatever the
    value's truthiness.
    """
    from pcb_worker.board_schema import (DEFAULT_FINISH, DEFAULT_MASK_COLOUR,
                                         DEFAULT_THICKNESS_MM)
    from pcb_worker.compile_board import _stated_appearance

    # Absent, and explicitly null — the two ways a board says nothing.
    for block in ({}, {"mask_colour": None, "finish": None, "thickness_mm": None}):
        assert _stated_appearance(block, "mask_colour") == DEFAULT_MASK_COLOUR
        assert _stated_appearance(block, "finish") == DEFAULT_FINISH
        assert _stated_appearance(block, "thickness_mm") == DEFAULT_THICKNESS_MM

    # Stated, and falsy. Each of these must come back as it was written.
    stated = {"mask_colour": "", "finish": "", "thickness_mm": 0}
    for field, value in stated.items():
        assert _stated_appearance(stated, field) == value, field
    assert _stated_appearance(stated, "thickness_mm") != DEFAULT_THICKNESS_MM

    # And the boundary that refuses those documents is still there, on the
    # compile path a board actually travels.
    for block in ({"finish": ""}, {"thickness_mm": 0}, {"mask_colour": "  "}):
        result = compile_board(_board(**block))
        assert isinstance(result, ResolutionFailure), block
        assert [d.code for d in result.diagnostics
                if d.severity.value == "error"] == ["invalid_board_structure"], block
