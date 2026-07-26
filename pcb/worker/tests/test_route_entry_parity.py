"""Round C2a — ONE routing answer, whichever entry point asks for it.

Three docket items (019f9bc3909c chore, 019f9b38a93f bug, 019f92beff51 bug) are
one defect: **the routing entry path did not carry the board's own rules,
validation, or existing copper.**

``agent_router.Board`` carried geometry only, so three consecutive rounds
threaded rules and copper through ``route_board``'s RUN OPTIONS instead — twelve
options past ``board``. The predictable happened: the OTHER entry point
(``agent_router.cli``) passed five of the twelve and hard-coded a default for two
more, so a board authoring a 0.35mm trace width was routed at the engine's 0.25.
The fix gives ``Board`` a design-rules slot and an existing-copper slot, so a
correctly-built Board inherits correct routing BY CONSTRUCTION. Run options are
unchanged and still win — they are an override layer, not the source.

WHAT THIS FILE PINS, and what it deliberately does not:

  * the two entry points agree — on every board that carries no already-routed
    copper and whose authored clearance is at or above the v1 fab floor
    (``test_the_same_board_rules_reach_the_engine_through_both_entry_points``),
    and the CLI's old answer is locked out. Both qualifiers are real and each is
    pinned: a sub-floor clearance diverges and is documented
    (``test_the_cli_routes_below_the_v1_fab_floor``); a source carrying copper
    the CLI cannot read is REFUSED rather than qualified, because routing it
    writes a short (``test_the_cli_refuses_a_source_that_already_carries_
    copper``, 019f9d0bc17c);
  * the precedence chain is tested AS A CHAIN — one test per link, so a future
    change that collapses two levels fails loudly rather than silently;
  * the Board's slots are LOAD-BEARING, not decorative: a run that names no
    options still gets the board's rules and routes around the board's copper;
  * malformed drill values fail closed on the ``_route`` path.

MANDATORY FIXTURES (standing gate 019f70f76c2f): a 3+ pin multi-path net with a
layer-changing via, and an undo-after-commit. See ``_staged_three_pin_reply``
for why the via half rides a STAGED reply — the real engine emits ZERO vias on
this fixture, and a docstring claiming otherwise would be a lie a later reader
would build on.
"""

from __future__ import annotations

import math
import textwrap

import pytest

from agent_router import router as engine_router
from agent_router import cli as engine_cli
from agent_router.board import Board, DesignRules
from agent_router.router import (
    ExistingSegment, ExistingVia, resolve_effective_rules, RoutingRulesError,
)

from pcb_worker import compile_board as cb
from pcb_worker import methods, route_bridge
from pcb_worker.methods import handle_request
from pcb_worker.resolved_board import NetClass

# Reuse — NOT a second copy. The board fixture, the compile helper, the engine
# spy and the net-class compiler patch all already exist next door for exactly
# this shape of board; duplicating them here is how two files start disagreeing
# about what "the fixture" is.
from tests.test_route_rules import (  # noqa: E402
    BOARD_WIDTH_MM, BOARD_CLEARANCE_MM,
    _three_pin_board, _compile, _call_route, _tp, _committed, _undone,
    routed_with, net_classed_compile,  # noqa: F401 - pytest fixtures
)


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------


def _kicad_pcb_text() -> str:
    """The SAME two-pad net as a .kicad_pcb, for the CLI entry point.

    The CLI reads geometry from KiCad, which carries no design rules; its rules
    come from the board YAML beside it. Geometry is deliberately trivial — this
    file is about which NUMBERS reach the engine, not about pathfinding.
    """
    return textwrap.dedent("""\
        (kicad_pcb (version 20221018) (generator pcbnew)
          (general (thickness 1.6))
          (paper "A4")
          (layers
            (0 "F.Cu" signal)
            (31 "B.Cu" signal)
            (44 "Edge.Cuts" user)
          )
          (net 0 "")
          (net 1 "SIG")
          (gr_rect (start 0 0) (end 60 40) (layer "Edge.Cuts") (width 0.1))
          (footprint "R_0603" (layer "F.Cu")
            (at 10 20)
            (property "Reference" "P1")
            (pad "1" smd rect (at 0 0) (size 1.6 1.6) (layers "F.Cu") (net 1 "SIG"))
          )
          (footprint "R_0603" (layer "F.Cu")
            (at 50 20)
            (property "Reference" "P2")
            (pad "1" smd rect (at 0 0) (size 1.6 1.6) (layers "F.Cu") (net 1 "SIG"))
          )
        )
        """)


def _board_yaml_text(trace_width_mm=BOARD_WIDTH_MM, clearance_mm=BOARD_CLEARANCE_MM) -> str:
    """A board YAML authoring the SAME design rules the canonical worker board
    authors — the authored (flat) shape, which is what a human writes and what
    the worker's compiler maps into ``defaults.trace_width_mm`` /
    ``minimums.min_clearance_mm``."""
    return textwrap.dedent(f"""\
        version: 1
        name: parity
        design_rules:
          trace_width_mm: {trace_width_mm}
          clearance_mm: {clearance_mm}
          via_diameter_mm: 0.8
          via_drill_mm: 0.4
        """)


def _with_copper(pcb_text: str, item: str =
                 '(segment (start 10 20) (end 30 20) (width 0.25) '
                 '(layer "F.Cu") (net 1))') -> str:
    """The same .kicad_pcb with one piece of already-routed copper in it —
    inserted before the closing paren, which is where KiCad writes it and where
    ``write_kicad_pcb`` appends."""
    assert pcb_text.rstrip().endswith(")")
    head = pcb_text.rstrip()[:-1].rstrip("\n")
    return f"{head}\n  {item}\n)\n"


@pytest.fixture
def cli_board(tmp_path):
    """A .kicad_pcb + board YAML pair on disk, ready for ``cli.main``."""
    pcb = tmp_path / "parity.kicad_pcb"
    pcb.write_text(_kicad_pcb_text())
    yaml_path = tmp_path / "parity.yaml"
    yaml_path.write_text(_board_yaml_text())
    return pcb, yaml_path


@pytest.fixture
def cli_engine_spy(monkeypatch):
    """Record the width/clearance the CLI hands the engine.

    ``cli`` imports the entry points by value (``from .router import
    route_board``), so the CLI module's own attributes are the seam to patch —
    patching ``router.route_board`` would not be seen.
    """
    seen: dict = {}

    def spy(board, *args, **kw):
        seen["trace_width"] = kw.get("trace_width")
        seen["clearance"] = kw.get("clearance")
        seen["board"] = board
        return engine_router.RoutingResult()

    monkeypatch.setattr(engine_cli, "route_board", spy)
    monkeypatch.setattr(engine_cli, "route_board_with_hints", spy)
    return seen


def _run_cli(monkeypatch, argv: list):
    monkeypatch.setattr("sys.argv", ["agent-router"] + argv)
    engine_cli.main()


def _bare_board() -> Board:
    """A Board with geometry and NO rules — what ``Board.from_kicad`` builds."""
    return Board(width=60.0, height=40.0)


def _ruled_board(trace_width_mm=BOARD_WIDTH_MM, clearance_mm=BOARD_CLEARANCE_MM) -> Board:
    board = _bare_board()
    board.design_rules = DesignRules.from_authored(
        {"trace_width_mm": trace_width_mm, "clearance_mm": clearance_mm})
    return board


# ---------------------------------------------------------------------------
# 1. THE HEADLINE — two entry points, one answer.
# ---------------------------------------------------------------------------


def test_the_same_board_rules_reach_the_engine_through_both_entry_points(
        monkeypatch, routed_with, cli_board, cli_engine_spy):
    """A board authoring trace_width 0.35 / clearance 0.25 is routed at 0.35/0.25
    whether the WORKER or the CLI asks — the defect this round exists to close.

    Neither number is an engine signature default (0.25 / 0.2), so a path that
    reports them can only have got them from the board's own rules.
    """
    pcb, yaml_path = cli_board

    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == BOARD_WIDTH_MM
    assert routed_with["engine_clearance"] == BOARD_CLEARANCE_MM

    _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(yaml_path)])
    assert cli_engine_spy["trace_width"] == BOARD_WIDTH_MM
    assert cli_engine_spy["clearance"] == BOARD_CLEARANCE_MM

    # Said once more as the identity it is, so a change that moves BOTH paths
    # together (and would pass the two assertions above) still fails here.
    assert (cli_engine_spy["trace_width"], cli_engine_spy["clearance"]) == \
        (routed_with["engine"], routed_with["engine_clearance"])


def test_the_cli_no_longer_answers_with_the_engines_defaults(
        monkeypatch, cli_board, cli_engine_spy):
    """The docket's literal repro (019f9b38a93f): the CLI used to report 0.25/0.2
    on this board because argparse supplied those two numbers itself, making an
    unset option indistinguishable from a typed one."""
    pcb, yaml_path = cli_board
    _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(yaml_path)])
    assert (cli_engine_spy["trace_width"], cli_engine_spy["clearance"]) != (0.25, 0.2)


def test_an_explicit_cli_option_still_outranks_the_board(
        monkeypatch, cli_board, cli_engine_spy):
    """Options remain an OVERRIDE layer. Fixing the default must not invert the
    chain and make a board's rules un-overridable from the command line."""
    pcb, yaml_path = cli_board
    _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(yaml_path),
                           "--trace-width", "0.5", "--clearance", "0.4"])
    assert (cli_engine_spy["trace_width"], cli_engine_spy["clearance"]) == (0.5, 0.4)


def test_the_cli_writes_copper_at_the_width_it_routed_at(monkeypatch, cli_board):
    """The written segment width must be the RESOLVED width, not the raw option.

    The raw option is now None unless the user typed one, so a writer still
    reading it would emit `(width None)`; worse, before this round it would emit
    copper at 0.25 that the grid had reserved space for at the board's own width.
    """
    pcb, yaml_path = cli_board
    out = pcb.parent / "out.kicad_pcb"
    _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(yaml_path),
                           "-o", str(out)])
    if out.exists():
        for line in out.read_text().splitlines():
            if "(segment" in line:
                assert f"(width {BOARD_WIDTH_MM})" in line, line


# ---------------------------------------------------------------------------
# 2. THE CHAIN, LINK BY LINK.
#
# caller option -> hint -> net class -> board rules -> engine default.
# One test per link. A change that collapses two adjacent levels has to break
# exactly one of these, which is the point of testing it as a chain rather than
# as five independent facts.
# ---------------------------------------------------------------------------


def _width_hint(width_mm: float) -> dict:
    return {"id": "h1", "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
                             "net_names": ["SIG"], "waypoints": [],
                             "width_mm": width_mm}}


def test_link1_a_caller_option_beats_a_hint(routed_with):
    """Link 1/4. Both are present; the caller's number is what routes."""
    resp = _call_route({"board": _three_pin_board(),
                        "route_hints": [_width_hint(0.5)],
                        "options": {"trace_width": 0.45}})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == 0.45
    assert resp["result"]["effective_routing_rules"]["trace_width_mm"]["source"] \
        == "caller_option"


def test_link2_a_hint_beats_a_net_class(net_classed_compile, routed_with):
    """Link 2/4. A hint fixes the WHOLE RUN's width; a net class may not widen
    the run past it. (The class still applies to that net's own copper — what is
    pinned here is which number the RUN is resolved to.)"""
    net_classed_compile["nc"] = NetClass(id="nc:wide", name="Wide",
                                        min_trace_width_mm=0.9)
    net_classed_compile["net"] = "SIG"
    resp = _call_route({"board": _three_pin_board(),
                        "route_hints": [_width_hint(0.5)]})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == 0.5
    assert resp["result"]["effective_routing_rules"]["trace_width_mm"]["source"] \
        == "hint"


def test_link3_a_net_class_beats_the_board_rules(net_classed_compile):
    """Link 3/4. With no caller option and no hint, a class minimum narrows what
    the board's blanket rule would otherwise have given that net."""
    net_classed_compile["nc"] = NetClass(id="nc:wide", name="Wide",
                                        min_trace_width_mm=0.9)
    net_classed_compile["net"] = "SIG"
    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    # The RUN-WIDE answer is still the board's — width is per-net, so a class on
    # one net never moves the fallback the others use.
    rules = resp["result"]["effective_routing_rules"]
    assert rules["trace_width_mm"]["value"] == BOARD_WIDTH_MM

    # ...and on SIG's OWN copper the class beats it. width_mm lives on each
    # SEGMENT, not on the route dict — an earlier cut guarded on
    # `"width_mm" in route`, which is always False, so this link asserted
    # nothing at all.
    sig = next(r for r in resp["result"]["routes"] if r["net"] == "SIG")
    assert sig["segments"], "the classed net must actually route"
    sig_widths = sorted({s["width_mm"] for s in sig["segments"]})
    assert sig_widths == [pytest.approx(0.9)], sig_widths
    assert BOARD_WIDTH_MM not in sig_widths

    # The unclassed net still draws at the board's own rule — proving the class
    # is what moved SIG, not a run-wide change.
    other = next(r for r in resp["result"]["routes"] if r["net"] == "OTHER")
    assert sorted({s["width_mm"] for s in other["segments"]}) == \
        [pytest.approx(BOARD_WIDTH_MM)]


def test_link4_the_board_rules_beat_the_engine_default():
    """Link 4/4, at the chain itself. The board's number wins over the engine's,
    and reports itself as having done so."""
    width, width_src, clearance, clearance_src = resolve_effective_rules(
        _ruled_board(), {})
    assert (width, clearance) == (BOARD_WIDTH_MM, BOARD_CLEARANCE_MM)
    assert (width_src, clearance_src) == ("board_rules", "board_rules")
    # And they are genuinely not the engine's own numbers.
    assert width != engine_router.engine_default_mm("trace_width")
    assert clearance != engine_router.engine_default_mm("clearance")


def test_link5_the_engine_default_is_the_last_resort():
    """The chain's floor. A Board with NO rules (what `Board.from_kicad` builds)
    lands on the engine's signature default — read from the signature, never
    re-spelled as a literal."""
    width, width_src, clearance, clearance_src = resolve_effective_rules(
        _bare_board(), {})
    assert width == engine_router.engine_default_mm("trace_width")
    assert clearance == engine_router.engine_default_mm("clearance")
    assert (width_src, clearance_src) == ("engine_default", "engine_default")


def test_the_chain_is_ordered_not_merely_a_set_of_sources():
    """The links above, walked in one test as a strictly-narrowing sequence.

    Each step ADDS a higher-precedence source to the same board and the answer
    must change to it — a chain that silently collapsed two adjacent levels
    would return the same number twice here.
    """
    board = _ruled_board()
    assert resolve_effective_rules(_bare_board(), {})[0] == \
        engine_router.engine_default_mm("trace_width")
    assert resolve_effective_rules(board, {})[0] == BOARD_WIDTH_MM
    assert resolve_effective_rules(board, {"trace_width": 0.6})[0] == 0.6


def test_an_inadmissible_option_fails_closed_rather_than_falling_through():
    """An explicit option is ADMITTED OR REJECTED, never reinterpreted. Falling
    through to the board's rule would quietly route at a different number than
    the caller asked for."""
    board = _ruled_board()
    for bad in (0, -1, float("nan"), float("inf"), "0.3", True):
        with pytest.raises(RoutingRulesError, match="trace width"):
            resolve_effective_rules(board, {"trace_width": bad})
    for bad in (-1, float("nan"), float("inf"), "0.3", True):
        with pytest.raises(RoutingRulesError, match="clearance"):
            resolve_effective_rules(board, {"clearance": bad})
    # Zero clearance is a COHERENT request and is honoured, unlike zero width.
    assert resolve_effective_rules(board, {"clearance": 0})[2] == 0.0


@pytest.mark.parametrize("options", [
    {},                                    # board rules win
    {"trace_width": 0.6},                  # caller beats board (width only)
    {"clearance": 0.45},                   # caller beats board (clearance only)
    {"trace_width": 0.6, "clearance": 0.45},
    {"trace_width": 0.6, "clearance": 0},  # zero clearance is a legal request
], ids=["none", "width", "clearance", "both", "zero_clearance"])
def test_the_worker_resolver_is_an_adapter_not_a_second_chain(options):
    """The worker's resolver must produce the engine resolver's answer VERBATIM.

    Parametrized on purpose. With the single input ``{}`` this passed even
    against a deliberately DRIFTED second chain that put board rules ahead of
    the caller option — at ``{}`` there is no caller option, so a delegator and
    an independent implementation agree by construction. The inputs below all
    exercise a level ABOVE the board's rules, so any re-ordering of the chain
    shows up as a mismatch here rather than only in link1/link2.
    """
    rb = _compile(_three_pin_board())
    board = route_bridge.resolved_board_to_router(rb)
    assert methods._effective_routing_rules(dict(options), board) == \
        resolve_effective_rules(board, dict(options))[::2]


def test_the_worker_resolver_rejects_what_the_engine_resolver_rejects():
    """Divergence on the REFUSAL path would be just as real a second chain."""
    rb = _compile(_three_pin_board())
    board = route_bridge.resolved_board_to_router(rb)
    for bad in (0, -1, "0.3", float("inf")):
        with pytest.raises(RoutingRulesError):
            resolve_effective_rules(board, {"trace_width": bad})
        with pytest.raises(route_bridge.UnsupportedGeometry):
            methods._effective_routing_rules({"trace_width": bad}, board)


# ---------------------------------------------------------------------------
# 2b. RULES THAT ARE PRESENT BUT UNREADABLE FAIL CLOSED.
#
# The chain may fall through to the engine default ONLY when a board authors no
# such rule. A board that authored one we cannot read must stop the run: quietly
# resolving it to 0.25/0.2 is the exact silent-default signature of the bug this
# round removes, arriving one layer down.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("rules", [
    {"trace_width_mm": 0.35, "clearance_mm": 0.25},   # a plain dict, not a rules object
    DesignRules(),                                     # right type, both fields unset -> readable
], ids=["plain_dict", "empty_rules_object"])
def test_a_rules_object_we_cannot_walk_fails_closed_but_an_empty_one_does_not(rules):
    """The distinction the chain now draws.

    A plain ``dict`` is the most natural caller mistake and is PRESENT rules we
    cannot read — it must raise. A properly-shaped object whose fields are
    simply unset authored no rule, and legitimately falls through.
    """
    board = _bare_board()
    board.design_rules = rules
    if isinstance(rules, dict):
        with pytest.raises(RoutingRulesError, match="could not be read"):
            resolve_effective_rules(board, {})
    else:
        assert resolve_effective_rules(board, {})[0] == \
            engine_router.engine_default_mm("trace_width")


@pytest.mark.parametrize("bad", ["0.35", float("inf"), float("nan"), -1, 0, True],
                         ids=["string", "inf", "nan", "negative", "zero", "bool"])
def test_an_authored_width_we_cannot_use_fails_closed_rather_than_defaulting(bad):
    """STRING NUMERICS ARE REJECTED, NOT COERCED — the deliberate call.

    ``trace_width_mm: "0.35"`` is a real authoring mistake and the tempting fix
    is to coerce it. We refuse, for two reasons: routing sits in the fail-closed
    bucket by standing ruling, and the raw CAM path already refuses a string in
    exactly this position (``pad_source._require_valid_authored_drill`` on
    ``drill_mm``). Coercing here would put routing and fabrication back out of
    step on the same input.

    What must NOT happen — and did, before this fix — is that it silently
    becomes the engine's 0.25.
    """
    board = _bare_board()
    board.design_rules = DesignRules.from_authored(
        {"trace_width_mm": bad, "clearance_mm": BOARD_CLEARANCE_MM})
    with pytest.raises(RoutingRulesError, match="not a usable millimetre"):
        resolve_effective_rules(board, {})


def test_an_unreadable_rule_is_not_quietly_the_engine_default():
    """Said as the negative, because the failure mode is silence, not noise."""
    board = _bare_board()
    board.design_rules = DesignRules.from_authored({"trace_width_mm": "0.35"})
    try:
        resolved = resolve_effective_rules(board, {})
    except RoutingRulesError:
        return
    pytest.fail(f"unreadable authored rule silently resolved to {resolved!r}")


def test_a_partially_authored_rules_block_falls_through_for_the_unset_field():
    """A board may author a width and no clearance. The authored one is used;
    the absent one falls through. Fail-closed must not mean fail-noisy."""
    board = _bare_board()
    board.design_rules = DesignRules.from_authored({"trace_width_mm": 0.35})
    width, width_src, clearance, clearance_src = resolve_effective_rules(board, {})
    assert (width, width_src) == (0.35, "board_rules")
    assert (clearance, clearance_src) == (
        engine_router.engine_default_mm("clearance"), "engine_default")


def test_a_design_rules_block_that_is_not_a_mapping_fails_closed():
    with pytest.raises(RoutingRulesError, match="not a mapping"):
        DesignRules.from_authored(["trace_width_mm", 0.35])


def test_the_cli_fails_closed_on_rules_it_cannot_read(monkeypatch, tmp_path,
                                                      cli_engine_spy):
    """End to end: the CLI must exit non-zero, not route at 0.25."""
    pcb = tmp_path / "b.kicad_pcb"; pcb.write_text(_kicad_pcb_text())
    y = tmp_path / "b.yaml"
    y.write_text('version: 1\nname: bad\ndesign_rules:\n  trace_width_mm: "0.35"\n')
    with pytest.raises(SystemExit) as exc:
        _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(y)])
    assert exc.value.code == 2
    assert "trace_width" not in cli_engine_spy


def test_the_cli_refuses_a_source_that_already_carries_copper(
        monkeypatch, tmp_path, cli_engine_spy):
    """THE SHORT, refused rather than qualified (019f9d0bc17c).

    ``kicad_io.read_kicad_pcb`` parses no ``(segment ...)`` / ``(via ...)``, so
    a CLI-built Board always has EMPTY existing-copper slots while
    ``methods._route`` always fills them. Routing a partially-routed board here
    would lay copper straight through the copper already on it, and
    ``write_kicad_pcb`` appends to the preserved original — a shorted board in a
    gerber source. Unlike the fab-floor divergence (a margin problem, pinned and
    documented) this one fails the run closed.

    DELETE THIS TEST together with ``cli._refuse_if_source_carries_copper`` when
    the parser lands.
    """
    pcb = tmp_path / "partial.kicad_pcb"
    pcb.write_text(_with_copper(_kicad_pcb_text()))
    y = tmp_path / "partial.yaml"; y.write_text(_board_yaml_text())

    with pytest.raises(SystemExit) as exc:
        _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(y)])
    assert exc.value.code == 2
    # It must refuse BEFORE routing — a refusal after the fact is no refusal.
    assert "trace_width" not in cli_engine_spy


def test_the_copper_refusal_names_what_is_missing_and_where_to_track_it(tmp_path):
    """A guard a developer cannot act on just looks like a broken tool."""
    pcb = tmp_path / "p.kicad_pcb"
    pcb.write_text(_with_copper(
        _kicad_pcb_text(), '(via (at 20 20) (size 0.8) (drill 0.4) (net 1))'))
    with pytest.raises(RoutingRulesError) as exc:
        engine_cli._refuse_if_source_carries_copper(pcb)
    message = str(exc.value)
    assert "kicad_io" in message
    assert "019f9d0bc17c" in message
    assert "shorted" in message


def test_a_clean_source_is_not_refused(tmp_path):
    """The control: the guard must not refuse every board it is given."""
    pcb = tmp_path / "clean.kicad_pcb"
    pcb.write_text(_kicad_pcb_text())
    engine_cli._refuse_if_source_carries_copper(pcb)  # must not raise


def test_the_cli_turns_a_malformed_board_yaml_into_a_clean_exit(
        monkeypatch, tmp_path, cli_engine_spy):
    """A parse error fires inside ``yaml_loader``'s own unguarded safe_load,
    which reached the user as a TRACEBACK and exit 1. A bad input file is a user
    error and now gets the same clean exit 2 as every other fail-closed path."""
    pcb = tmp_path / "b.kicad_pcb"; pcb.write_text(_kicad_pcb_text())
    y = tmp_path / "b.yaml"; y.write_text("design_rules: {trace_width_mm: 0.35\n  bad")
    with pytest.raises(SystemExit) as exc:
        _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(y)])
    assert exc.value.code == 2
    assert "trace_width" not in cli_engine_spy


def test_the_cli_routes_below_the_v1_fab_floor(monkeypatch, tmp_path, cli_engine_spy):
    """THE RESIDUAL DIVERGENCE, pinned so it stays visible.

    ``compile_board._floor_with_clearance`` raises an authored clearance to the
    v1 manufacturing floor (0.127mm). That floor lives in the compiler, which
    ``agent_router`` must not import, so the CLI honours the authored number as
    authored: 0.05 here where the worker gives 0.127.

    This is asserted rather than hidden because the round's headline is narrowed
    to match it — the two entry points agree on every board at or above the fab
    floor, not on every board. If the floor ever becomes reachable in-package,
    this test is the one that should start failing.
    """
    pcb = tmp_path / "b.kicad_pcb"; pcb.write_text(_kicad_pcb_text())
    y = tmp_path / "b.yaml"; y.write_text(_board_yaml_text(clearance_mm=0.05))
    _run_cli(monkeypatch, ["route", str(pcb), "--board-yaml", str(y)])
    assert cli_engine_spy["clearance"] == 0.05

    worker = _compile(_three_pin_board(
        design_rules={"clearance_mm": 0.05, "trace_width_mm": BOARD_WIDTH_MM,
                      "via_diameter_mm": 0.8, "via_drill_mm": 0.4}))
    assert worker.design_rules.minimums.min_clearance_mm == 0.127
    assert cli_engine_spy["clearance"] < worker.design_rules.minimums.min_clearance_mm


# ---------------------------------------------------------------------------
# 3. THE BOARD SLOTS ARE LOAD-BEARING.
# ---------------------------------------------------------------------------


def test_the_bridge_puts_the_boards_own_rules_on_the_board():
    """The projection carries rules now (019f9bc3909c). This is the seam that
    makes any Board-building caller inherit them by construction."""
    rb = _compile(_three_pin_board())
    board = route_bridge.resolved_board_to_router(rb)
    assert board.design_rules is rb.design_rules
    assert board.design_rules.defaults.trace_width_mm == BOARD_WIDTH_MM
    assert board.design_rules.minimums.min_clearance_mm == BOARD_CLEARANCE_MM


def test_a_board_carrying_its_own_copper_blocks_a_run_that_names_no_options():
    """The existing-copper slot, doing the job the run options used to do alone.

    A caller that builds a Board from a partially-routed source and forgets the
    two ``existing_*`` options must still route AROUND that copper. The board
    below has a single narrow channel; foreign copper laid across it is the only
    thing that can make the net unroutable, so a proposal appearing here means
    the slot was ignored.
    """
    def _two_pin(**slots) -> Board:
        from agent_router.board import Pad, Net
        a = Pad(component="P1", number="1", net="SIG",
                position=(5.0, 10.0), size=(1.0, 1.0))
        b = Pad(component="P2", number="1", net="SIG",
                position=(35.0, 10.0), size=(1.0, 1.0))
        board = Board(pads=[a, b], nets={"SIG": Net(name="SIG", number=1, pads=[a, b])},
                      width=40.0, height=20.0)
        for key, value in slots.items():
            setattr(board, key, value)
        return board

    clear = engine_router.route_board(_two_pin(), single_layer=True)
    assert clear.routes, "control: the net must be routable with no copper in the way"

    wall = [ExistingSegment(net="OTHER", start=(20.0, 0.0), end=(20.0, 20.0),
                            layer="F.Cu", width=1.0)]
    # Passed as a RUN OPTION — the pre-existing, still-supported way.
    via_option = engine_router.route_board(
        _two_pin(), single_layer=True, existing_traces=wall)
    # Carried on the BOARD — the new way, and the one a forgetful caller gets.
    via_slot = engine_router.route_board(
        _two_pin(existing_traces=wall), single_layer=True)

    assert not via_option.routes, "control: the wall must actually block"
    assert not via_slot.routes, (
        "a Board carrying its own accepted copper routed straight through it — "
        "the existing_traces slot was ignored")


def test_a_run_option_still_overrides_the_boards_copper_slot():
    """Slots are the SOURCE; options are the OVERRIDE. A caller that passes
    explicit copper must get exactly that copper, not the union with the slot."""
    from agent_router.board import Pad, Net
    a = Pad(component="P1", number="1", net="SIG", position=(5.0, 10.0), size=(1.0, 1.0))
    b = Pad(component="P2", number="1", net="SIG", position=(35.0, 10.0), size=(1.0, 1.0))
    wall = [ExistingSegment(net="OTHER", start=(20.0, 0.0), end=(20.0, 20.0),
                            layer="F.Cu", width=1.0)]
    elsewhere = [ExistingSegment(net="OTHER", start=(39.0, 19.0), end=(39.5, 19.5),
                                 layer="F.Cu", width=0.1)]
    board = Board(pads=[a, b], nets={"SIG": Net(name="SIG", number=1, pads=[a, b])},
                  width=40.0, height=20.0, existing_traces=wall)
    result = engine_router.route_board(
        board, single_layer=True, existing_traces=elsewhere)
    assert result.routes, (
        "the explicit run option must REPLACE the board's slot, not union with it")


# ---------------------------------------------------------------------------
# 4. MALFORMED DRILLS FAIL CLOSED ON THE _route PATH (019f92beff51).
#
# NOTE ON THE DOCKET'S PREMISE. The item describes `_route` reaching
# `route_bridge.board_to_router` (whose permissive `_num` coerces a bad drill)
# without compiling first. That is no longer the code: the Round E cutover
# (019f783860c8) routed the canonical path through `_compile_or_fail` +
# `resolved_board_to_router`, and `board_to_router` now has no production
# caller. The malformed values below are therefore ALREADY rejected — by the
# compiler, ahead of the bridge. These tests are the regression LOCK on that,
# because nothing else pinned it from the `_route` entry point.
# ---------------------------------------------------------------------------


def _board_with_drill(drill):
    board = _three_pin_board()
    board["components"] = [dict(c) for c in board["components"]]
    bad = dict(board["components"][0])
    bad["pins"] = [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                    "drill_mm": drill, "annulus_diameter_mm": 1.6}]
    board["components"][0] = bad
    return board


@pytest.mark.parametrize("drill", ["1.0", float("inf"), -1.0, True],
                         ids=["string", "positive_infinity", "negative", "bool_true"])
def test_a_malformed_drill_is_rejected_not_coerced_on_the_route_path(drill):
    """Fail-closed is the house rule for routing: a malformed drill is REJECTED,
    never coerced into the nearest sensible thing.

    Each of these, left to the permissive bridge, changes what the pad IS —
    ``"1.0"`` becomes a thru-hole, while ``+Inf`` / negative / ``True`` become
    SMD with no hole. Either way the obstacle set changes and the router may path
    through invalid pad geometry.

    The identity asserted is the STRUCTURED reply, not merely "something raised":
    a compile-kind error carrying zero routes.
    """
    resp = _call_route({"board": _board_with_drill(drill)})
    assert resp["ok"] is False, resp
    assert resp["error"]["kind"] == "compile"
    assert "routes" not in resp.get("result", {})
    # It must name the pin whose drill was refused, not fail somewhere generic.
    assert "P1" in resp["error"]["message"]


def test_the_same_board_with_a_valid_drill_routes():
    """The control. Without it, the four rejections above would also pass if
    routing were broken for every board."""
    resp = _call_route({"board": _board_with_drill(0.8)})
    assert resp["ok"] is True, resp


# ---------------------------------------------------------------------------
# 5. BEHAVIOUR PRESERVATION + THE STANDING VIA/UNDO GATE (019f70f76c2f).
# ---------------------------------------------------------------------------


def _staged_three_pin_reply() -> list:
    """The mandatory route SHAPE: a 3-pin net whose copper is TWO DISCONNECTED
    paths joined by a LAYER-CHANGING via.

    STAGED, and this docstring says so on purpose: **the real engine emits ZERO
    vias on this fixture.** Earlier rounds were bitten by exactly this, so to be
    unambiguous — no assertion below claims the router produced a via. The staged
    reply exists to pin what the ACCEPTANCE/undo path does with that shape, which
    needs the shape to be exact rather than whatever the router happens to emit
    today. End-to-end engine coverage of this board is
    ``test_the_worker_path_routes_this_board_identically_through_the_slots``,
    which asserts only what the engine actually guarantees.
    """
    return [{
        "net": "SIG",
        "segments": [
            {"start": [10.0, 20.0], "end": [10.0, 28.0], "layer": "F.Cu"},
            {"start": [10.0, 28.0], "end": [22.0, 28.0], "layer": "F.Cu"},
            {"start": [40.0, 20.0], "end": [50.0, 20.0], "layer": "B.Cu"},
        ],
        "vias": [[40.0, 20.0]],
    }]


def test_the_staged_three_pin_via_fixture_is_two_paths_joined_by_a_via():
    """The GATE fixture's own shape, asserted rather than assumed: two copper
    groups with NO shared endpoint, and a via sitting between them. A fixture
    that quietly degraded to one connected path would make every test using it
    a 2-pin single-path test again — the exact blind spot the gate exists for."""
    reply = _staged_three_pin_reply()
    assert len(reply) == 1
    segments, vias = reply[0]["segments"], reply[0]["vias"]
    assert len(vias) == 1
    layers = {s["layer"] for s in segments}
    assert layers == {"F.Cu", "B.Cu"}, "the via must change LAYER, not just jump"
    top = [s for s in segments if s["layer"] == "F.Cu"]
    bottom = [s for s in segments if s["layer"] == "B.Cu"]
    top_pts = {tuple(p) for s in top for p in (s["start"], s["end"])}
    bottom_pts = {tuple(p) for s in bottom for p in (s["start"], s["end"])}
    assert not (top_pts & bottom_pts), "the two groups must be DISCONNECTED"
    assert tuple(vias[0]) in bottom_pts


def test_the_worker_path_routes_this_board_identically_through_the_slots(routed_with):
    """BEHAVIOUR PRESERVATION. The worker path already passed every option
    correctly, so moving the source of truth onto the Board must not change one
    number it produces — this is the test that says so for a representative
    board, end to end through the REAL engine.

    Asserts only what the engine guarantees on this fixture: it routes the
    3-pin net at the board's own rules, over two connections. It does NOT assert
    a via (see ``_staged_three_pin_reply``).
    """
    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    rules = resp["result"]["effective_routing_rules"]
    assert rules["trace_width_mm"]["value"] == BOARD_WIDTH_MM
    assert rules["clearance_mm"]["value"] == BOARD_CLEARANCE_MM
    assert rules["trace_width_mm"]["source"] == "board_rules"
    assert routed_with["engine"] == BOARD_WIDTH_MM
    assert routed_with["engine_clearance"] == BOARD_CLEARANCE_MM

    sig = [r for r in resp["result"]["routes"] if r["net"] == "SIG"]
    assert sig, "the 3-pin net must route"
    assert sum(len(r["segments"]) for r in sig) >= 2


def test_commit_then_undo_returns_the_board_to_its_own_rules():
    """The mandatory UNDO-AFTER-COMMIT case (gate 019f70f76c2f).

    The worker is stateless, so "undo" is expressed the only honest way it can
    be: the same board, WITH the commit's copper accepted onto it, and then with
    that copper taken back off. The board's own rules must survive the round
    trip — an undo that silently reverted to the engine's defaults would be the
    same defect this round closes, arriving by a different door.

    The accepted copper here is the STAGED via fixture, so this covers the
    layer-changing-via shape on the acceptance path.
    """
    base = _three_pin_board()
    committed = _committed(base)

    before = _call_route({"board": base})
    assert before["ok"] is True, before

    during = _call_route({"board": committed})
    assert during["ok"] is True, during
    assert during["result"]["effective_routing_rules"]["trace_width_mm"]["value"] \
        == BOARD_WIDTH_MM

    after = _call_route({"board": _undone(committed)})
    assert after["ok"] is True, after
    assert after["result"]["effective_routing_rules"] == \
        before["result"]["effective_routing_rules"]
    assert [r["net"] for r in after["result"]["routes"]] == \
        [r["net"] for r in before["result"]["routes"]]
