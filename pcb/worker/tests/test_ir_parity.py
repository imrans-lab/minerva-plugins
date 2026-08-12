"""STANDING GUARD 3 — CROSS-SURFACE GEOMETRY PARITY.

Stage-4 acceptance says every surface must report/use identical pad centres and
shapes, trace/via/hole geometry, outline, layer identity and net ownership.
:mod:`pcb_worker.ir_parity` tabulates four surfaces and diffs them; this file is
the gate that runs it, plus the proof that the gate has TEETH.

Three groups of test, in the order they matter:

  1. THE GATE — the harness runs green over both fixtures with the current
     enumerated baseline. This is what CI blocks on.
  2. THE TEETH — an ARTIFICIAL PERTURBATION of ONE surface must FAIL, with a
     message naming that surface and that field. Written for more than one
     surface, and for more than one kind of break (a moved pad, a resized land, a
     dropped net, a dropped drill), because a harness that only detects the one
     failure its author imagined is a harness nobody should trust.
  3. THE BASELINE MECHANISM — a NEW unexplained delta fails; a LISTED one does
     not; and a baseline entry that has been FIXED also fails, so the list must
     shrink with the code instead of rotting.

REAL, NON-MOCKED: every test compiles a real fixture and drives the production
emitters (``gerber.build_gerbers_ir``, ``kicad.generate_ir``) to real bytes. The
perturbations are applied to the TABULATED ROWS, never by monkeypatching an
emitter — so a teeth test can never accidentally leave a worker module modified,
and the thing being proven is that the DIFF reports a break, which is exactly the
harness's job.

FIXTURES — SYNTHETIC ONLY (docket 019fbe68c5f8, testdata/POLICY.md)
------------------------------------------------------------------
This suite's primary case used to be ``testdata/smart_remote.yaml``, a REAL
Turnrock product board. It was deleted from the corpus on 2026-07-30 because a
real design in a public repo is an IP leak, and this module kept a hard reference
to it — which is why four pcb jobs were red for two days.

The primary case is now ``testdata/parity_corners.yaml``, the purpose-built corner
fixture, joined by the independent synthetic ``pcb/spikes/gerber/board.yaml`` so
the gate is still proven over MORE THAN ONE board (a gate tuned to one fixture
certifies nothing about the next one).

Repointing a gate at a smaller fixture is how a gate silently narrows, so the
narrowing is measured rather than assumed:

  * ``test_the_synthetic_primary_reaches_every_geometry_class_the_gate_needs``
    is an explicit COVERAGE FLOOR — every geometry class the removed board
    contributed (through-hole and SMD lands, both board sides, plated and
    unplated board holes, vias, multi-layer traces, multi-net ownership,
    non-square lands, half- and quarter-turn placements) must be reachable on the
    synthetic primary, or this suite fails and says which class went missing.
  * ``test_the_excellon_micron_grid_rounding_class_is_still_exercised`` keeps the
    ONE class the removed board carried that no static synthetic fixture can:
    drill coordinates off the Excellon 1-micron grid. It was previously a
    SUPPRESSION (``SMART_REMOTE_BASELINE``); it is now a POSITIVE assertion built
    from a synthetic board, which is strictly stronger — the behaviour has to be
    present and correctly attributed, not merely tolerated.

NEVER repair this module by restoring the deleted fixture from git history.
"""

from __future__ import annotations

import ast
import copy
import math
from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import ir_parity
from pcb_worker.compile_board import compile_board
from pcb_worker.ir_parity import (
    NA,
    PARITY_CORNERS_BASELINE,
    Delta,
    KnownDelta,
    ParityRow,
    ParityCanonicalizationUnsupported,
    ParitySurfaceUnavailable,
    SurfaceTable,
    check_parity,
    diff_against_reference,
    format_report,
    tabulate_all,
)
from pcb_worker.resolved_board import ResolutionSuccess, Side

HERE = Path(__file__).resolve().parent
#: The PRIMARY case. Synthetic, purpose-built, and the only fixture the teeth
#: tests tabulate — see the module docstring on why it replaced a product board.
PARITY_CORNERS = HERE / "testdata" / "parity_corners.yaml"
#: A SECOND, independently authored synthetic board (blessed by
#: testdata/POLICY.md). It exists to keep the gate's claim plural: a harness run
#: over exactly one fixture proves only that the fixture agrees with itself. It
#: lives outside tests/, so a run from a packaged tree may not have it — that is
#: a skip, never a silent pass, because its case is a bonus rather than the floor.
GERBER_SPIKE = HERE.parent.parent / "spikes" / "gerber" / "board.yaml"

gerbonara = pytest.importorskip(
    "gerbonara",
    reason="the gerber surface needs the dev-only reader gerbonara "
           "(pip install -e '.[dev]'); without it the harness would silently "
           "check three surfaces instead of four, which is worse than skipping")


def _board(path: Path):
    result = compile_board(yaml.safe_load(path.read_text(encoding="utf-8")))
    assert isinstance(result, ResolutionSuccess), (
        f"{path.name} must COMPILE for the parity gate to mean anything; "
        f"got {type(result).__name__}")
    return result.board


@pytest.fixture(scope="module")
def corner_tables():
    """Tabulated once per module: the four surfaces each emit a full fabrication
    set, which is the slowest thing here. Safe to share because every table is
    frozen (``ParityRow``/``SurfaceTable`` are frozen dataclasses holding tuples)
    and every perturbation below builds a NEW table rather than mutating one."""
    return tabulate_all(_board(PARITY_CORNERS))


_needs_spike = pytest.mark.skipif(
    not GERBER_SPIKE.exists(),
    reason="pcb/spikes/gerber/board.yaml is outside tests/ and absent from this "
           "tree; the primary synthetic case still runs")

CASES = (
    pytest.param(PARITY_CORNERS, PARITY_CORNERS_BASELINE, id="parity_corners"),
    # An EMPTY baseline is the assertion, not an omission: this board's four
    # surfaces agree on every row with nothing enumerated away.
    pytest.param(GERBER_SPIKE, (), id="gerber_spike", marks=_needs_spike),
)


# ---------------------------------------------------------------------------
# 1. THE GATE
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path,baseline", CASES)
def test_surfaces_agree_within_the_enumerated_baseline(path, baseline):
    """THE STANDING GATE. Every surface agrees with the compiled IR except for the
    deltas enumerated in the baseline, each of which carries a reason."""
    report = check_parity(_board(path), baseline)
    assert report.ok, "\n" + format_report(report)


@pytest.mark.parametrize("path", [
    PARITY_CORNERS, pytest.param(GERBER_SPIKE, marks=_needs_spike)])
def test_every_surface_actually_produced_rows(path):
    """A harness that silently tabulated NOTHING would pass the gate above.

    Guard the floor explicitly: each surface must produce rows in each family it
    claims to participate in. This is the "the check is plugged in" test.
    """
    tables = tabulate_all(_board(path))
    assert set(tables) == set(ir_parity.SURFACES)
    # A family the REFERENCE itself has no rows for is one this BOARD has no
    # content in (a board with no interior cutouts, say) — no surface can be
    # required to produce rows for it. The guard's real target is a surface
    # that tabulates nothing for content the board demonstrably HAS, and that
    # is preserved: `populated` is the IR's own row families.
    populated = {row.family for row in tables["ir"].rows}
    for name, table in tables.items():
        families = {row.family for row in table.rows}
        missing = (table.families & populated) - families
        assert not missing, f"surface {name!r} claims {missing} but emitted no such rows"
        assert len(table.rows) > 10, f"surface {name!r} produced only {len(table.rows)} rows"


#: The geometry classes the cross-surface gate exists to compare. Each is a place
#: where two surfaces can legitimately disagree, so a fixture that cannot reach a
#: class leaves that disagreement unwatched. Named individually so a failure says
#: WHICH class went missing rather than "coverage dropped".
#:
#: Every entry maps a class name to a predicate over the tabulated IR table and
#: the compiled board — the two things the gate actually reads. Deriving them from
#: the FIXTURE TEXT instead would prove only that the YAML still contains some
#: words; deriving them from the tabulation proves the class survives compilation
#: and reaches the diff.
def _reached_classes(board, ir_table) -> set[str]:
    flashes = list(ir_table.by_family("copper_flash").values())
    drills = list(ir_table.by_family("drill").values())
    traces = ir_table.by_family("copper_trace")
    nets = ir_table.by_family("net_ownership")

    def entities(kind):
        return [d for d in drills if d.field_map().get("entity") == kind]

    reached = set()
    th_keys = {(round(d.field_map()["x_mm"], 2), round(d.field_map()["y_mm"], 2))
               for d in entities("pad")}
    flash_layers_at = {}
    for row in flashes:
        layer, x, y = row.key
        flash_layers_at.setdefault((round(x, 2), round(y, 2)), set()).add(layer)

    if any(len(flash_layers_at.get(k, ())) >= 2 for k in th_keys):
        reached.add("through_hole_land_on_every_copper_layer")
    if any(k not in th_keys and len(v) == 1 for k, v in flash_layers_at.items()):
        reached.add("smd_land_on_one_side_only")
    if {row.key[0] for row in flashes} >= {"F.Cu", "B.Cu"}:
        reached.add("copper_on_both_board_sides")
    if any(d.field_map().get("plated") for d in entities("board_hole")):
        reached.add("plated_board_hole")
    if any(not d.field_map().get("plated") for d in entities("board_hole")):
        reached.add("unplated_board_hole")
    if entities("via"):
        reached.add("via")
    if len({row.key[0] for row in traces.values()}) >= 2:
        reached.add("traces_on_more_than_one_layer")
    if len({row.field_map().get("net_name") for row in nets.values()
            if row.field_map().get("net_name")}) >= 2:
        reached.add("more_than_one_owning_net")
    if any(abs(row.field_map().get("w_mm", 0.0)
               - row.field_map().get("h_mm", 0.0)) > 1e-6 for row in flashes):
        reached.add("non_square_land")

    # MASK-side classes. Read off the BOARD rather than off the table, because
    # what is being pinned is that the fixture still CONTAINS the geometry — a
    # predicate reading the table would go quiet in exactly the case where the
    # tabulator, not the fixture, is what broke.
    for component in getattr(board, "components", ()):
        for pad in component.placed_pads:
            if pad.drill is None and pad.side is not Side.TOP:
                reached.add("smd_land_on_the_bottom_side")
            if pad.pad_type == "np_thru_hole":
                reached.add("unplated_through_hole_pad")
    for via in getattr(board, "vias", ()):
        if via.tented_front and via.tented_back:
            reached.add("tented_via")
        else:
            reached.add("untented_via")

    sides = {c.placement.side for c in board.components}
    turns = {round(c.placement.rotation_deg % 360.0, 3) for c in board.components}
    if len(sides) >= 2:
        reached.add("components_placed_on_both_sides")
    if turns & {90.0, 270.0}:
        reached.add("quarter_turn_placement")
    if 180.0 in turns:
        reached.add("half_turn_placement")
    return reached


GEOMETRY_CLASS_FLOOR = frozenset({
    "through_hole_land_on_every_copper_layer",
    "smd_land_on_one_side_only",
    "copper_on_both_board_sides",
    "plated_board_hole",
    "unplated_board_hole",
    "via",
    "traces_on_more_than_one_layer",
    "more_than_one_owning_net",
    "non_square_land",
    "components_placed_on_both_sides",
    "quarter_turn_placement",
    "half_turn_placement",
    # Added with the mask family (epoch CP2 S11). Both are classes whose ABSENCE
    # was measured to leave a real mask defect undetected — see the GAP 6 and
    # GAP 7 notes in the fixture.
    "smd_land_on_the_bottom_side",
    "untented_via",
    "tented_via",
    "unplated_through_hole_pad",
})


def test_the_synthetic_primary_reaches_every_geometry_class_the_gate_needs():
    """THE ANTI-NARROWING FLOOR (docket 019fbe68c5f8).

    Repointing a gate at a different fixture is the cheapest way to gut it: the
    suite stays green, the assertions all still run, and the geometry they were
    watching quietly stops existing. When the product board was withdrawn from
    this corpus, nothing in the tree could have told you which classes went with
    it.

    So the classes are ENUMERATED and asserted, not assumed. A future edit that
    trims parity_corners.yaml — or a compile change that stops emitting a class —
    fails here and names the class, instead of silently shrinking what four CI
    jobs are certifying.

    This is a floor, not a ceiling: extending the fixture is always fine, and the
    set is expected to GROW as the gate learns to compare more (zones, for
    instance, are not a parity family at all today — ir_parity.FAMILIES has no
    entry for them — so a zone-bearing fixture would prove nothing here yet).
    """
    board = _board(PARITY_CORNERS)
    reached = _reached_classes(board, tabulate_all(board)["ir"])
    missing = GEOMETRY_CLASS_FLOOR - reached
    assert not missing, (
        "the primary parity fixture no longer reaches: " + ", ".join(sorted(missing))
        + " — extend testdata/parity_corners.yaml (see its own header) rather than "
          "lowering this floor, and NEVER by importing a product board")


def test_the_geometry_class_floor_is_not_vacuous():
    """The floor above is only worth its line count if a missing class is
    DETECTED. A predicate that answers "reached" for everything would pass the
    floor on an empty board and certify nothing.

    Proven against the second synthetic case, which is deliberately simpler: it
    must reach FEWER classes than the primary. If the two ever report the same
    set, either the predicates stopped discriminating or the fixtures converged —
    both of which make the floor above meaningless.
    """
    corners = _reached_classes(_board(PARITY_CORNERS),
                              tabulate_all(_board(PARITY_CORNERS))["ir"])
    spike_board = _board(GERBER_SPIKE) if GERBER_SPIKE.exists() else None
    if spike_board is not None:
        spike = _reached_classes(spike_board, tabulate_all(spike_board)["ir"])
        assert spike < corners, (
            "the simpler synthetic board reaches the same classes as the corner "
            f"fixture ({sorted(spike)}) — the predicates are not discriminating")
    # ... and the predicates must report NOTHING for a board with no geometry,
    # which is the degenerate case a permissive predicate set would pass.
    empty = SurfaceTable(surface="ir", families=frozenset(ir_parity.FAMILIES),
                         rows=())

    class _NoComponents:
        components = ()

    assert _reached_classes(_NoComponents(), empty) == set()


def test_the_excellon_micron_grid_rounding_class_is_still_exercised():
    """THE ONE CLASS THE WITHDRAWN FIXTURE CARRIED THAT A STATIC SYNTHETIC CANNOT.

    The Excellon writer emits metric 3.3 decimal — a 1-micron grid
    (gerber.py:_excellon, ";FORMAT={3:3/ absolute / metric / decimal}"). A pad
    whose absolute coordinate falls BETWEEN grid steps is therefore reported by
    the drill file at a rounded position while every other surface reports it
    exactly. The product fixture happened to author three pads at x_mm -0.00368
    and hit this; parity_corners authors everything on clean coordinates and never
    will, because a fixture that hit it would need a permanent baseline entry
    suppressing its own deltas.

    So the class moves from SUPPRESSION to ASSERTION. The board is derived here,
    in the test, by nudging one synthetic component off the micron grid — and the
    gate must then report the rounding, ONLY on gerber, ONLY on drill x, and
    within one micron. Strictly stronger than the old ``SMART_REMOTE_BASELINE``:
    that entry tolerated the deltas, this demands them.

    FAILURE MEANINGS. No deltas: the drill surface stopped reading live
    coordinates, or the Excellon format silently gained precision. Deltas larger
    than a micron, or on another surface: the rounding is no longer just the
    format's own quantum, and somebody must look.
    """
    grid_mm = 1e-3
    off_grid = 0.00368          # the displacement the withdrawn fixture happened to have
    assert 0 < off_grid % grid_mm < grid_mm, "the nudge must land BETWEEN grid steps"

    authored = yaml.safe_load(PARITY_CORNERS.read_text(encoding="utf-8"))
    board_yaml = copy.deepcopy(authored)
    nudged = 0
    for component in board_yaml["components"]:
        if component["ref"] == "U2":
            component["x_mm"] = component["x_mm"] + off_grid
            nudged += 1
    assert nudged == 1, "fixture changed: expected exactly one U2 to nudge"

    result = compile_board(board_yaml)
    assert isinstance(result, ResolutionSuccess)

    # Baseline the SYNTHETIC board's own known delta away, so what is left is
    # attributable to the nudge alone.
    report = check_parity(result.board, PARITY_CORNERS_BASELINE)
    rounding = [d for d in report.unexplained if d.family == "drill"]
    assert rounding, (
        "a component placed off the Excellon 1-micron grid produced NO drill "
        "delta — either the drill surface is not reading live coordinates, or the "
        "Excellon coordinate format changed. Both need a human.")
    assert {d.surface for d in rounding} == {"gerber"}, (
        "only the Excellon writer quantises; another surface rounding drill "
        f"coordinates is a defect: {sorted({d.surface for d in rounding})}")
    assert {d.field for d in rounding} == {"x_mm"}, (
        "the nudge was on x alone, so a y delta means the surfaces disagree about "
        "something other than the grid")
    for delta in rounding:
        assert delta.kind == "field", "a sub-micron shift must still JOIN the rows"
        assert abs(delta.surface_value - delta.reference_value) <= grid_mm, (
            f"{delta.render()} is larger than the 1-micron Excellon quantum — that "
            f"is not rounding, that is a real disagreement")
    assert "[gerber]" in format_report(report)


def test_tabulation_is_deterministic():
    """Same board, two independent tabulations -> identical rows in identical order.

    The parity gate feeds a diff; a diff over an unstable order is noise. Pairs
    with tests/test_determinism_gate.py, which owns emitter BYTE determinism —
    this owns the harness's own ordering.
    """
    board = _board(PARITY_CORNERS)
    first, second = tabulate_all(board), tabulate_all(board)
    for name in ir_parity.SURFACES:
        assert first[name].rows == second[name].rows, f"{name} tabulation is unstable"


def test_reference_pad_land_is_not_delegated_to_the_shared_owner(monkeypatch):
    """The IR reference must NOT reach the copper-land decision through
    ``pad_source`` / ``ir_pads``, nor the SOLDER-MASK enumeration through
    ``mask_source``.

    This is the harness's whole claim to independence (module docstring, "honest
    limit"): drc, kicad and gerber all resolve a TH land through
    ``pad_source.th_land``, so if the reference did too, all four would agree by
    construction and the gate would prove nothing about that decision. A future
    edit that "DRYs up" ``_ir_pad_land`` by calling th_land would silently gut the
    harness, and nothing else would notice.

    Checked TWO ways, because the obvious check is weak on its own:

      (a) STRUCTURAL — no import of the shared owner anywhere in the module, at
          any scope. Catches the aliased dodge (``from .pad_source import
          th_land as _land``) that a substring scan of one function body missed.
      (b) BEHAVIOURAL — detonate the shared owner and demand that the IR
          tabulator still produces a full table. Catches delegation moved OUT of
          ``_ir_pad_land`` and up into ``tabulate_ir``, which (a) alone would not.

    ``mask_source`` was added to both halves in epoch CP2 S11, when the mask
    family landed. It is the SAME hazard one layer up: drc and gerber both
    enumerate openings through it, so a reference that called it would agree with
    them by construction about which entities open the mask at all — and the
    first attempt at that station did exactly this and had to be reverted.
    """
    forbidden_modules = {"pad_source", "ir_pads", "mask_source"}
    tree = ast.parse(Path(ir_parity.__file__).read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            assert (node.module or "") not in forbidden_modules, (
                f"ir_parity imports from {node.module!r} at line {node.lineno} — "
                f"the reference surface must re-derive the land from IR fields, "
                f"not borrow the owner the other three surfaces already share")
        elif isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name.split(".")[-1] not in forbidden_modules, alias.name

    from pcb_worker import ir_pads, mask_source, pad_source

    def boom(*_args, **_kwargs):
        raise AssertionError(
            "the IR reference tabulator called a SHARED geometry owner — that "
            "makes the reference agree with drc/kicad/gerber by construction")

    for module, name in ((pad_source, "th_land"), (pad_source, "placed_pad_to_geom"),
                         (ir_pads, "pad_land"), (ir_pads, "smd_shape"),
                         (ir_pads, "pad_copper_shape"), (ir_pads, "iter_ir_pads"),
                         (mask_source, "pad_openings"),
                         (mask_source, "via_openings"),
                         (mask_source, "board_hole_openings"),
                         (mask_source, "circle_opening"),
                         (mask_source, "resolve_ir_mask_clearance")):
        monkeypatch.setattr(module, name, boom)

    table = ir_parity.tabulate_ir(_board(PARITY_CORNERS))
    assert table.by_family("copper_flash"), "tabulate_ir produced no copper"
    assert table.by_family("drill")
    assert table.by_family("mask_opening"), "tabulate_ir produced no mask openings"


# ---------------------------------------------------------------------------
# 2. THE TEETH — perturb ONE surface, demand a named failure.
# ---------------------------------------------------------------------------


def _perturb(tables, surface: str, family: str, mutate, *, field: str | None = None) -> dict:
    """Return a copy of ``tables`` with ONE row of ``family`` on ``surface``
    replaced by ``mutate(row)``. Everything else is untouched, so any delta the
    harness then reports is attributable to exactly this change.

    When ``field`` is given, the chosen row is the first whose REFERENCE
    counterpart carries a comparable (non-NA) value for it. Corrupting a field the
    IR reports as NA — ``rot_deg`` on a circular land, which has no orientation to
    disagree about — is correctly ignored by the diff, so a teeth test that picked
    such a row would be testing nothing while looking like it tested something.
    """
    table = tables[surface]
    reference = tables["ir"].by_family(family)
    rows = list(table.rows)
    for index, row in enumerate(rows):
        if row.family != family:
            continue
        if field is not None:
            ref_row = reference.get(row.key)
            if ref_row is None or ref_row.field_map().get(field, NA) is NA:
                continue
        rows[index] = mutate(row)
        break
    else:  # pragma: no cover - a missing family is a harness bug, not a test skip
        pytest.fail(f"surface {surface!r} has no comparable {family!r} row to perturb")
    out = dict(tables)
    out[surface] = replace(table, rows=tuple(rows))
    return out


def _move(row: ParityRow) -> ParityRow:
    """Shift a row 0.5 mm — a displacement no fab tolerance forgives, and one far
    larger than the key quantum, so it must surface as a missing+extra pair rather
    than a field delta. Key AND position field move together, so the synthetic row
    stays internally consistent (a sub-quantum shift, which moves only the field,
    is covered by test_a_sub_bucket_displacement_is_reported_as_a_position_field)."""
    layer, x, y = row.key
    fields = dict(row.fields)
    fields["x_mm"] = fields["x_mm"] + 0.5
    return replace(row, key=(layer, x + 0.5, y),
                   fields=tuple(sorted(fields.items())))


def _set_field(name: str, value):
    def mutate(row: ParityRow) -> ParityRow:
        fields = dict(row.fields)
        fields[name] = value
        return replace(row, fields=tuple(sorted(fields.items())))
    return mutate


@pytest.mark.parametrize("surface", ["gerber", "kicad", "drc"])
def test_a_moved_pad_on_any_one_surface_fails_and_names_it(corner_tables,
                                                           surface):
    """THE ACCEPTANCE CRITERION. Move one copper land on ONE surface by 0.5 mm;
    the gate must fail and the message must name that surface.

    Run for THREE surfaces, because a harness that only catches the surface its
    author was thinking about is worse than none — it certifies the other two.
    """
    tables = _perturb(corner_tables, surface, "copper_flash", _move)
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)
    assert not report.ok
    message = format_report(report)
    offenders = {d.surface for d in report.unexplained}
    assert offenders == {surface}, (
        f"a break on {surface} must be attributed to {surface} alone, got {offenders}")
    assert f"[{surface}]" in message
    assert "copper_flash" in message
    # A key-changing break reads as the row vanishing and a stranger appearing.
    kinds = {d.kind for d in report.unexplained}
    assert kinds == {"missing_row", "extra_row"}, kinds


@pytest.mark.parametrize("surface,family,field,value", [
    ("gerber", "copper_flash", "w_mm", 99.0),
    ("kicad", "copper_flash", "shape", "roundrect"),
    ("drc", "copper_flash", "rot_deg", 33.0),
    ("kicad", "copper_trace", "width_mm", 9.5),
    ("drc", "net_ownership", "net_name", "WRONG_NET"),
    ("kicad", "drill", "dia_mm", 7.25),
    ("gerber", "drill", "plated", False),
])
def test_a_wrong_field_on_one_surface_fails_and_names_the_field(
        corner_tables, surface, family, field, value):
    """Corrupt ONE field on ONE surface; the failure must name the SURFACE, the
    ENTITY and the FIELD, and print both values.

    Spread across every family a surface participates in and across both geometry
    (size, shape, rotation, width, diameter) and non-geometry (net ownership,
    plating) so the gate is proven to be watching all of it, not just centres.
    """
    tables = _perturb(corner_tables, surface, family,
                      _set_field(field, value), field=field)
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)
    assert not report.ok, f"corrupting {surface}.{family}.{field} was not detected"

    named = [d for d in report.unexplained
             if d.surface == surface and d.family == family and d.field == field]
    assert len(named) == 1, [d.render() for d in report.unexplained]
    delta = named[0]
    assert delta.kind == "field"
    assert delta.surface_value == value
    assert delta.reference_value != value

    message = format_report(report)
    assert f"[{surface}]" in message and family in message and repr(field) in message
    # Both values must be READABLE from CI output alone — that is the whole point
    # of a structured diff over a bare boolean.
    assert repr(value) in message
    assert repr(delta.reference_value) in message
    assert delta.entity in message


def test_a_dropped_row_on_one_surface_fails(corner_tables):
    """A surface that silently LOSES copper must fail — the fabrication defect
    that matters most, and the one a field-by-field diff would miss if it only
    compared rows both sides happen to have.

    Drops COPPER, not drills: the baseline enumerates a gerber/drill/missing_row
    class, so a dropped drill exercises the count mechanism instead (covered by
    test_a_new_delta_cannot_hide_behind_a_listed_class). Copper has no listed
    class, so it must land in `unexplained` — which is the channel that says
    "nobody has an explanation for this".
    """
    table = corner_tables["gerber"]
    victim = next(r for r in table.rows if r.family == "copper_flash")
    kept = tuple(r for r in table.rows if r is not victim)
    tables = dict(corner_tables)
    tables["gerber"] = replace(table, rows=kept)

    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)
    assert not report.ok
    missing = [d for d in report.unexplained if d.kind == "missing_row"]
    assert len(missing) == 1
    assert missing[0].surface == "gerber" and missing[0].family == "copper_flash"
    assert "ABSENT from gerber" in format_report(report)


def test_a_real_emitter_perturbation_is_caught_end_to_end(monkeypatch):
    """THE NON-SYNTHETIC TEETH TEST. Mutate the PRODUCTION emitter, re-emit real
    bytes, re-parse them, and demand the gate names gerber.

    Every other teeth test edits the harness's own row list, which proves
    ``diff_against_reference`` reports a break but NOT that any tabulator reads
    live values — a tabulator returning constants would pass all of them. This one
    transposes every aperture inside ``gerber._shape_aperture`` and goes through
    the whole path: emit -> gerbonara parse -> tabulate -> diff.

    Needs a NON-SQUARE land to mean anything: transposing w/h on a square is a
    no-op and the test would silently prove nothing. parity_corners carries
    oblong lands deliberately (its GAP 2 / SMD_OBLONG components) — which is one
    of the classes the coverage-floor test below pins so this stays true.
    """
    from pcb_worker import gerber

    original = gerber._shape_aperture
    # NB the trailing `angle` is forwarded UNCHANGED — only w/h are transposed. The
    # emitter takes the angle at aperture-construction time to work around
    # gerber-writer dropping a rotated obround's rotation (019f9af6e899); a mutation
    # that dropped it would be testing a different function, not perturbing this one.
    monkeypatch.setattr(
        gerber, "_shape_aperture",
        lambda shape, w, h, rratio, func, angle: original(
            shape, h, w, rratio, func, angle))

    report = check_parity(_board(PARITY_CORNERS), PARITY_CORNERS_BASELINE)
    assert not report.ok, "transposing every gerber aperture went undetected"
    assert {d.surface for d in report.unexplained} == {"gerber"}
    assert {d.field for d in report.unexplained} & {"w_mm", "h_mm"}
    assert "[gerber]" in format_report(report)


def test_a_real_kicad_position_perturbation_is_caught_end_to_end(monkeypatch):
    """The same end-to-end proof for the OTHER emitted-text surface: shift every
    pad 0.5 mm as the .kicad_pcb is written, and demand the gate names kicad.

    Guards the footprint-local inversion specifically — the transform this
    harness's kicad seam exists to watch.
    """
    from pcb_worker import kicad

    original = kicad._to_footprint_local
    monkeypatch.setattr(
        kicad, "_to_footprint_local",
        lambda px, py, rot, x, y: tuple(
            v + off for v, off in zip(original(px, py, rot, x, y), (0.5, 0.0))))

    report = check_parity(_board(PARITY_CORNERS), PARITY_CORNERS_BASELINE)
    assert not report.ok, "a 0.5 mm shift of every kicad pad went undetected"
    assert {d.surface for d in report.unexplained} == {"kicad"}
    assert "[kicad]" in format_report(report)


def test_a_sub_bucket_displacement_is_reported_as_a_position_field(corner_tables):
    """A displacement SMALLER than the key quantum must still be caught — as a
    legible ``x_mm`` field delta, with the rows still joined.

    This is the capability the coarser key bought. When the key quantum equalled
    the comparison epsilon, any displacement large enough to matter also broke the
    JOIN, so it surfaced as a missing row plus an unrelated extra row and position
    was never actually compared as a value anywhere.
    """
    nudge = ir_parity.PARITY_TOLERANCE_MM * 10      # 1 micron
    assert nudge < ir_parity.PARITY_KEY_QUANTUM_MM  # ... still inside the bucket

    def shift(row: ParityRow) -> ParityRow:
        fields = dict(row.fields)
        fields["x_mm"] = fields["x_mm"] + nudge
        return replace(row, fields=tuple(sorted(fields.items())))

    tables = _perturb(corner_tables, "kicad", "copper_flash", shift,
                      field="x_mm")
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)
    assert not report.ok
    named = [d for d in report.unexplained if d.field == "x_mm"]
    assert len(named) == 1 and named[0].surface == "kicad"
    assert named[0].kind == "field", "a sub-bucket shift must still JOIN the rows"


def test_not_applicable_never_reads_as_a_disagreement(corner_tables):
    """A surface reporting NA for a field it cannot express must not fail the gate
    — and must not be able to hide a real value behind NA either.

    Both halves matter. The first is why gerber (no nets, no component identity)
    can be gated at all; the second is why NA is a distinct sentinel rather than
    ``None``, which is a REAL value in this domain.
    """
    tables = _perturb(corner_tables, "kicad", "copper_flash",
                      _set_field("net_name", NA))
    assert check_parity(None, PARITY_CORNERS_BASELINE, tables=tables).ok

    # ... whereas None is a claim ("this pad has no net"), and contradicting the
    # IR with it is a failure.
    ir_rows = corner_tables["ir"].by_family("net_ownership")
    keyed = next(k for k, r in ir_rows.items() if r.field_map()["net_name"])
    table = tables["kicad"]
    rows = [_set_field("net_name", None)(r) if (r.family == "net_ownership"
                                                and r.key == keyed) else r
            for r in table.rows]
    tables = dict(tables)
    tables["kicad"] = replace(table, rows=tuple(rows))
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)
    assert not report.ok
    assert any(d.field == "net_name" and d.surface_value is None
               for d in report.unexplained)


def test_a_family_a_surface_cannot_express_is_skipped_not_failed(corner_tables):
    """gerber carries no nets AT ALL. That must read as non-participation, never
    as "gerber lost every net assignment on the board"."""
    gerber = corner_tables["gerber"]
    assert "net_ownership" not in gerber.families
    assert not [r for r in gerber.rows if r.family == "net_ownership"]
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=corner_tables)
    assert ("gerber", "net_ownership") in report.skipped
    assert not [d for d in report.deltas
                if d.surface == "gerber" and d.family == "net_ownership"]


# ---------------------------------------------------------------------------
# 3. THE BASELINE MECHANISM
# ---------------------------------------------------------------------------


def test_a_listed_delta_does_not_fail(corner_tables):
    """The known Excellon-rounding deltas ARE present, and the baseline explains
    them. Asserted positively so a future run that no longer produces them fails
    loudly (via the staleness check below) rather than quietly passing."""
    report = check_parity(None, (), tables=corner_tables)
    assert report.deltas, "expected the known baseline deltas to exist"
    assert not check_parity(None, PARITY_CORNERS_BASELINE,
                            tables=corner_tables).unexplained


def test_a_new_delta_of_an_unlisted_class_fails(corner_tables):
    """An unexplained delta in a class NO baseline entry covers must fail."""
    tables = _perturb(corner_tables, "kicad", "copper_flash",
                      _set_field("h_mm", 12.5))
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)
    assert not report.ok
    assert [d for d in report.unexplained
            if d.surface == "kicad" and d.field == "h_mm"]


def test_a_displaced_baselined_row_is_not_swallowed(corner_tables):
    """REGRESSION (review finding). A baselined row that MOVES must fail.

    The hole this reproduces: when a KnownDelta matched on
    ``(surface, family, kind, field)`` plus a COUNT, displacing one already-
    baselined gerber drill hit by 80 mm kept the arity at 3 and the gate passed
    clean — ok=True, zero unexplained, zero stale. Any regression that landed
    inside an existing delta class and merely displaced a member was invisible.

    KnownDelta now pins the exact ROW KEYS, so the moved row is unexplained and
    the entry that lost it is stale.

    The victim is read OUT OF THE BASELINE rather than hard-coded, so this test
    keeps testing the property when the baseline shrinks (it is meant to) or when
    the fixture under it changes — the previous hard-coded gerber-drill key is
    exactly what made this test unrunnable when its fixture was withdrawn.
    """
    entry = PARITY_CORNERS_BASELINE[0]
    table = corner_tables[entry.surface]
    victim_key = entry.keys[0]
    # An 80 mm displacement, expressed in the victim's own key shape (copper keys
    # carry a leading layer name; drill keys do not).
    moved_key = victim_key[:-2] + (5.0, 90.0)
    rows = []
    displaced = 0
    for row in table.rows:
        if row.family == entry.family and row.key == victim_key:
            fields = dict(row.fields)
            fields["x_mm"], fields["y_mm"] = moved_key[-2:]
            rows.append(replace(row, key=moved_key, fields=tuple(sorted(fields.items()))))
            displaced += 1
        else:
            rows.append(row)
    assert displaced == 1, (
        f"fixture changed: {entry.surface}/{entry.family} has no row at the "
        f"baselined key {victim_key} — the baseline names a row nobody emits")

    tables = dict(corner_tables)
    tables[entry.surface] = replace(table, rows=tuple(rows))
    report = check_parity(None, PARITY_CORNERS_BASELINE, tables=tables)

    assert not report.ok, (
        "an 80 mm displacement of a BASELINED row passed the gate — the baseline "
        "is suppressing more than it names")
    assert any(d.kind == "extra_row" and d.key == moved_key for d in report.unexplained)
    assert any(d.kind == "missing_row" and d.key == victim_key for d in report.unexplained)
    # ... and the entries that declared that row must now read as stale.
    assert report.stale
    message = format_report(report)
    assert "STALE BASELINE" in message and "NO LONGER PRESENT" in message


def test_a_baseline_entry_only_explains_the_rows_it_names():
    """The unit form of the same property: same signature, unlisted key -> no match."""
    entry = KnownDelta("gerber", "drill", "field", "x_mm",
                       keys=((1.0, 2.0),), reason="x" * 50, docket="unattributed")
    listed = Delta("gerber", "drill", "field", (1.0, 2.0), "x_mm", 1.0, 2.0, "e")
    displaced = Delta("gerber", "drill", "field", (5.0, 90.0), "x_mm", 1.0, 2.0, "e")
    assert entry.matches(listed)
    assert not entry.matches(displaced)


def test_a_fixed_delta_forces_the_baseline_to_shrink(corner_tables):
    """A baseline entry naming a row that no longer disagrees must FAIL, not
    silently pass. Otherwise the list rots into a record of things that used to be
    true and "the baseline is empty" stops meaning anything.

    Simulated by declaring a row that does not disagree; the real trigger is a fix
    landing in a worker module.
    """
    inflated = (replace(PARITY_CORNERS_BASELINE[0],
                        keys=PARITY_CORNERS_BASELINE[0].keys + ((1.0, 1.0),)),
                ) + PARITY_CORNERS_BASELINE[1:]
    report = check_parity(None, inflated, tables=corner_tables)
    assert not report.ok
    assert report.stale
    message = format_report(report)
    assert "NO LONGER PRESENT: (1.0, 1.0)" in message
    assert "drop it from the entry" in message


def test_every_baseline_entry_is_explained_and_attributed():
    """A baseline entry with no reason, or with an invented docket id, is a
    suppression dressed up as documentation."""
    for _, baseline in ((c.values[0], c.values[1]) for c in CASES):
        for entry in baseline:
            assert entry.count > 0 and len(set(entry.keys)) == entry.count
            assert len(entry.reason) > 40, f"{entry} has no usable reason"
            assert entry.surface in ir_parity.SURFACES
            assert entry.family in ir_parity.FAMILIES
            assert entry.kind in ("field", "missing_row", "extra_row")
            # Either a real 12-hex-digit docket id, or the honest admission.
            assert entry.docket == "unattributed" or (
                len(entry.docket) == 12 and
                all(c in "0123456789abcdef" for c in entry.docket)), entry.docket


def test_the_exit_condition_is_measurable():
    """The migration's visible finish line: every live baseline empty.

    Asserted as an inequality rather than a target so it documents progress
    without failing today. When a baseline reaches 0, tighten this.
    """
    # RATCHET: tightened 5 -> 3 when the rotated-oval gerber defect (019f9af6e899)
    # was fixed and its PARITY_CORNERS entry deleted. The count going DOWN is the
    # visible proof the defect is gone, so the bound is re-tightened on every fix —
    # otherwise a fixed delta just leaves slack for the next one to hide in.
    #
    # RATCHET: tightened 3 -> 1 when the product-board fixture was withdrawn
    # (019fbe68c5f8). SMART_REMOTE_BASELINE's two Excellon-rounding entries are no
    # longer attached to any board, so counting them would leave two slots of
    # permanent slack for a real delta to hide in. The behaviour they described is
    # now asserted POSITIVELY by
    # test_the_excellon_micron_grid_rounding_class_is_still_exercised.
    # The dead constant itself still lives in ir_parity.__all__; deleting it is a
    # production change this suite deliberately does not make.
    total = sum(len(case.values[1]) for case in CASES)
    assert total <= 1, (
        f"{total} known parity deltas — the baseline is meant to SHRINK. If this "
        f"tripped because a new delta was added, justify the growth or fix the "
        f"surface.")


def test_report_of_a_clean_run_is_empty():
    """Silence on success. A gate that prints a wall of text when nothing is wrong
    trains people to ignore it."""
    report = check_parity(_board(PARITY_CORNERS), PARITY_CORNERS_BASELINE)
    assert report.ok
    assert "UNEXPLAINED" not in format_report(report)
    assert "STALE" not in format_report(report)


def test_diff_is_symmetric_about_extra_rows():
    """A surface that INVENTS copper the IR does not have must fail too — the
    mirror of a dropped row, and the one a naive "check every IR row is present"
    loop misses entirely."""
    tables = tabulate_all(_board(PARITY_CORNERS))
    table = tables["gerber"]
    ghost = ParityRow.make("copper_flash", ("F.Cu", 1.0, 1.0), shape="circle",
                           w_mm=1.0, h_mm=1.0, rot_deg=NA, entity=NA, ref=NA,
                           pad_number=NA, net_name=NA)
    deltas = diff_against_reference(tables["ir"],
                                    replace(table, rows=table.rows + (ghost,)))
    extra = [d for d in deltas if d.kind == "extra_row"]
    assert len(extra) == 1
    assert "ABSENT from ir" in extra[0].render()


# ---------------------------------------------------------------------------
# ORIENTATION-CANONICAL extents — and the proof it is not a suppression.
#
# _flash_row folds a quarter-turned land to its axis-aligned representative, so
# the IR's authored (w, h, rot=90) and gerber's (h, w, rot=0) — which the standard
# obround aperture FORCES, having no rotation parameter — stop reading as three
# field defects on copper that is fabricated correctly (019f9af6e899).
#
# A harness change that makes a parity failure disappear is indistinguishable from
# a cover-up unless you show the failure SURVIVES when the defect is real. These
# tests are that proof, expressed against _flash_row's own contract: no emitter is
# monkeypatched, so there is nothing here to rot when the emitters change.
# ---------------------------------------------------------------------------


def _flash_table(surface: str, *, shape: str, w: float, h: float, rot: float,
                 anonymous: bool = False) -> SurfaceTable:
    """A one-row copper_flash table for `surface`, built through the SAME
    constructor every real tabulator uses. `anonymous` mirrors the gerber surface,
    where a flash carries no ref/pad/net (so only geometry is compared)."""
    meta = dict(entity=NA, ref=NA, pad_number=NA, net_name=NA) if anonymous else \
        dict(entity="pad", ref="J1", pad_number="2", net_name="GND")
    row = ir_parity._flash_row("F.Cu", 10.54, 8.0, shape=shape, w=w, h=h,
                               rot_deg=rot, **meta)
    return SurfaceTable(surface=surface, families=frozenset({"copper_flash"}),
                        rows=(row,))


def test_canonicalization_equates_the_two_descriptions_of_one_turned_land():
    # A 1.2 x 2.4 oval at 90 deg IS a 2.4 x 1.2 oval at 0 deg — the same copper,
    # described the two legal ways. The IR carries the first, gerber is FORCED to
    # carry the second. After canonicalisation they must agree on every field.
    ir = _flash_table("ir", shape="oval", w=1.2, h=2.4, rot=90.0)
    gbr = _flash_table("gerber", shape="oval", w=2.4, h=1.2, rot=0.0, anonymous=True)
    assert not diff_against_reference(ir, gbr), (
        "two descriptions of the SAME land still disagree — canonicalisation failed")


def test_canonicalization_does_not_mask_a_genuinely_transposed_land():
    """THE ANTI-MASKING PROOF. The disagreement must MOVE, never VANISH.

    A gerber emitter that DROPS the rotation (the 019f9af6e899 defect) flashes an
    axis-aligned 1.2 x 2.4 land where the IR says the land is turned 90 deg. That
    is genuinely the wrong copper. Canonicalisation folds the IR side to
    (2.4, 1.2, rot 0) while the buggy gerber side stays (1.2, 2.4, rot 0) — so the
    surfaces now disagree on w_mm/h_mm instead of on rot_deg, and the gate still
    fires. Verified end-to-end by neutering gerber._obround_rotation_swap with the
    KnownDelta deleted: parity still failed, on w_mm/h_mm.
    """
    ir = _flash_table("ir", shape="oval", w=1.2, h=2.4, rot=90.0)
    buggy = _flash_table("gerber", shape="oval", w=1.2, h=2.4, rot=0.0, anonymous=True)
    deltas = diff_against_reference(ir, buggy)
    assert deltas, (
        "a land fabricated axis-aligned where the IR says it is turned 90 degrees "
        "went UNDETECTED — the canonicalisation is masking the defect it was added "
        "alongside. Do not ship this; find another approach.")
    assert {d.field for d in deltas} == {"w_mm", "h_mm"}
    assert all(d.surface == "gerber" for d in deltas)


def test_canonicalization_refuses_a_shape_it_cannot_transpose():
    # The identity (w, h, 90) -> (h, w, 0) needs symmetry about BOTH axes. An
    # asymmetric shape must fail LOUDLY rather than be silently transposed into a
    # false agreement, so adding one is a conscious decision, not an accident.
    #
    # The exception type matters as much as the raise. It must NOT be a
    # ParitySurfaceUnavailable, which reports an ENVIRONMENT condition (a reader
    # missing on this machine) that a caller may legitimately turn into "skip this
    # surface". Routing this gap down that path would silently disable the parity
    # gate for a newly-added asymmetric shape — so assert the types are distinct.
    assert not issubclass(ParityCanonicalizationUnsupported, ParitySurfaceUnavailable)
    with pytest.raises(ParityCanonicalizationUnsupported, match="_TRANSPOSABLE_SHAPES"):
        ir_parity._flash_row("F.Cu", 10.54, 8.0, shape="trapezoid", w=1.2, h=2.4,
                             rot_deg=90.0, entity="pad", ref="J1", pad_number="2",
                             net_name="GND")


@pytest.mark.parametrize("shape", ["rect", "oval", "roundrect"])
def test_every_transposable_shape_is_genuinely_both_axis_symmetric(shape):
    # Pins the MEMBERSHIP of the set, not just its use: each member must round-trip
    # a quarter turn to its transpose. If a shape is added that does not, this fails.
    turned = _flash_table("ir", shape=shape, w=1.2, h=2.4, rot=90.0)
    flat = _flash_table("ir", shape=shape, w=2.4, h=1.2, rot=0.0)
    assert not diff_against_reference(turned, flat)
    assert shape in ir_parity._TRANSPOSABLE_SHAPES


# ---------------------------------------------------------------------------
# OUTLINE STROKE WIDTH — the field the outline family used to be blind to.
# ---------------------------------------------------------------------------


def test_outline_row_carries_the_stroke_width_on_every_surface():
    """The outline row must EXPRESS the stroke, or nothing below can catch it.

    Before this, the outline family compared origin/width/height only: it checked
    the rectangle and never the pen. Two emitters drew the same physical board
    edge with two different widths (kicad 0.15, gerber 0.1) and no test on any
    surface could see it — the class was structurally invisible, not merely
    untested.
    """
    tables = tabulate_all(_board(PARITY_CORNERS))
    for surface, table in tables.items():
        rows = table.by_family("outline")
        if not rows:
            continue                       # a surface that cannot express outline
        for row in rows.values():
            assert "stroke_width_mm" in row.field_map(), (surface, row)


def test_outline_stroke_width_agrees_across_the_ir_and_both_emitters():
    """All three surfaces report the SAME edge stroke on a clean tree — which is
    only true because both emitters now read one constant instead of carrying a
    literal each."""
    from pcb_worker.fab_capability import EDGE_CUTS_WIDTH_MM

    tables = tabulate_all(_board(PARITY_CORNERS))
    seen = {}
    for surface, table in tables.items():
        for row in table.by_family("outline").values():
            seen[surface] = row.field_map()["stroke_width_mm"]
    assert seen, "no surface produced an outline row"
    assert set(seen.values()) == {EDGE_CUTS_WIDTH_MM}, seen


def test_a_drifted_gerber_outline_stroke_is_caught_end_to_end(monkeypatch):
    """THE TEETH. Make the GERBER emitter draw the board edge with a different
    pen, emit real bytes, re-parse them, and demand the gate names gerber.

    This is the falsifier for the whole single-source claim: unify the constant
    but leave the parity row blind and this test still passes; add the row but
    let an emitter keep a literal and the clean-tree test above fails. Both
    halves have to be real.
    """
    from pcb_worker import gerber

    monkeypatch.setattr(gerber, "EDGE_CUTS_WIDTH_MM", 0.15)
    report = check_parity(_board(PARITY_CORNERS), PARITY_CORNERS_BASELINE)
    assert not report.ok, "a gerber outline stroke of 0.15 vs the IR's 0.05 went undetected"
    assert {d.surface for d in report.unexplained} == {"gerber"}
    assert {d.field for d in report.unexplained} == {"stroke_width_mm"}
    assert "[gerber]" in format_report(report)


def test_a_drifted_kicad_outline_stroke_is_caught_end_to_end(monkeypatch):
    """The same proof for the other emitter — the one that actually carried the
    0.15 literal this work removed."""
    from pcb_worker import kicad

    monkeypatch.setattr(kicad, "EDGE_CUTS_WIDTH_MM", 0.15)
    report = check_parity(_board(PARITY_CORNERS), PARITY_CORNERS_BASELINE)
    assert not report.ok, "a kicad outline stroke of 0.15 vs the IR's 0.05 went undetected"
    assert {d.surface for d in report.unexplained} == {"kicad"}
    assert {d.field for d in report.unexplained} == {"stroke_width_mm"}
    assert "[kicad]" in format_report(report)


def test_every_surface_declares_the_cutout_family_unconditionally():
    """Declaring a family means "this surface CAN speak to it", not "it has
    rows". Both board-conditional variants were tried and each hid one
    direction of emitter error — see the note above tabulate_ir. This pins the
    declaration so neither is re-introduced."""
    from pcb_worker import ir_parity as ip

    rb = _board(PARITY_CORNERS)  # cutout-less
    for table in (ip.tabulate_ir(rb), ip.tabulate_kicad(rb),
                  ip.tabulate_gerber(rb)):
        assert "cutout" in table.families, table.surface
        assert not [r for r in table.rows if r.family == "cutout"]


def test_an_invented_cutout_is_reported_as_an_extra_row():
    """The end-to-end consequence of the union rule: a surface that fabricates
    a cutout the IR never had must FAIL the diff, not slip through."""
    from pcb_worker import ir_parity as ip

    rb = _board(PARITY_CORNERS)  # a cutout-less fixture, already compiled
    ir = ip.tabulate_ir(rb)
    assert not [r for r in ir.rows if r.family == "cutout"], \
        "fixture must genuinely have no cutouts"

    phantom_row = ip._cutout_row(1.0, 1.0, 3.0, 3.0, 4)
    real = ip.tabulate_kicad(rb)
    phantom = ip.SurfaceTable("kicad", real.families,
                              tuple(list(real.rows) + [phantom_row]))
    deltas = ip.diff_against_reference(ir, phantom)
    assert any(d.family == "cutout" and d.kind == "extra_row" for d in deltas), \
        [(d.family, d.kind) for d in deltas]


def test_a_reshaped_cutout_is_a_parity_delta_not_a_clean():
    """A bounding box is not an identity. A rectangle and a diamond share a
    bbox and an edge count, so before the canonical contour rode along they
    produced BYTE-IDENTICAL rows — an emitter could materially reshape the
    milled opening and the parity gate reported clean (Codex review 1090
    finding 3, reproduced). Geometric DRC does not compensate: it checks the
    IR contour, never the emitted one."""
    from pcb_worker import ir_parity as ip

    rect = [(2, 2), (8, 2), (8, 8), (2, 8)]
    diamond = [(5, 2), (8, 5), (5, 8), (2, 5)]
    r_rect = ip._cutout_row(2, 2, 8, 8, 4, contour=rect)
    r_diamond = ip._cutout_row(2, 2, 8, 8, 4, contour=diamond)
    assert r_rect.key == r_diamond.key, "same bbox is what makes them collide"
    assert r_rect.fields != r_diamond.fields, "but the SHAPE must differ"


def test_cutout_contour_is_start_and_winding_invariant():
    """The comparison must be exact about SHAPE without being brittle about
    representation: two surfaces may legitimately begin the same opening at a
    different vertex, or wind it the other way. Those are not divergences and
    must not be reported as ones."""
    from pcb_worker import ir_parity as ip

    rect = [(2, 2), (8, 2), (8, 8), (2, 8)]
    base = ip._cutout_row(2, 2, 8, 8, 4, contour=rect)
    rotated = ip._cutout_row(2, 2, 8, 8, 4,
                             contour=[(8, 2), (8, 8), (2, 8), (2, 2)])
    reversed_ = ip._cutout_row(2, 2, 8, 8, 4, contour=list(reversed(rect)))
    assert base.fields == rotated.fields
    assert base.fields == reversed_.fields


def test_malformed_cutout_graph_refuses_canonicalization():
    """A broken graph must not fall back to a coarser contour that can alias a
    valid opening. This exact graph previously produced the rectangle's row and
    therefore a false clean diff despite not being a closed contour."""
    from pcb_worker import ir_parity as ip

    outer = [
        ((0, 0), (10, 0)), ((10, 0), (10, 10)),
        ((10, 10), (0, 10)), ((0, 10), (0, 0)),
    ]
    a, b, c, d = (2, 2), (8, 2), (8, 8), (2, 8)
    malformed = [(a, b), (b, a), (c, d), (d, b)]

    with pytest.raises(ip.ParityCanonicalizationUnsupported,
                       match="simple closed ring"):
        ip._cutout_rows_from_segments(outer + malformed)


# ---------------------------------------------------------------------------
# APERTURE-MACRO DECODING (bug 019ff3696d95).
#
# The gerber surface's whole value is that it re-reads the EMITTED BYTES, so a
# reader that decodes an aperture wrongly does not merely report a wrong number
# — it destroys the independence the family is built on. The specific defect:
# _gerbonara_shape read `params[-1]` as the rotation for EVERY macro, on a
# docstring asserting the rotation was always the trailing parameter. True of
# gerber-writer's Rectangle macro (3 params), false of its RoundedRectangle,
# whose tail is a list of corner-circle centres. A pad authored at 0 degrees was
# reported rotated by its last corner ordinate.
#
# These tests drive the REAL gerber-writer and the REAL gerbonara, with no
# pcb_worker emitter in the path, so they pin the macro contract itself and fail
# loudly if either library reshapes it.
# ---------------------------------------------------------------------------

#: The fixture that actually contains a roundrect land. PARITY_CORNERS has none
#: — every macro it emits is a `Rectangle`, the one the old rule got right — so
#: the bug was invisible to the primary case by construction.
COUPON_JLC1 = HERE / "testdata" / "coupon_jlc1.yaml"

#: A partially-rounded land: radius is well under half the short side, so
#: gerber-writer emits the MACRO rather than collapsing to a standard obround.
_RR_W, _RR_H, _RR_RADIUS = 1.3, 1.1, 0.44


def _emitted_aperture(master, angle: float):
    """One pad master flashed at `angle` through gerber-writer, read back with
    gerbonara. Both libraries real; nothing of ours in between."""
    import warnings

    from gerber_writer import DataLayer
    from gerbonara import GerberFile

    layer = DataLayer("Copper,L1,Top", negative=False)
    layer.add_pad(master, (10.0, 10.0), angle)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        parsed = GerberFile.from_string(layer.dumps_gerber(), filename="t.gbr")
    flashes = [o for o in parsed.objects if type(o).__name__ == "Flash"]
    assert len(flashes) == 1, f"expected one flash, got {len(flashes)}"
    return flashes[0].aperture


class _FakeMacro:
    def __init__(self, name: str) -> None:
        self.name = name


class ApertureMacroInstance:  # noqa: N801 - the reader dispatches on this NAME
    """Stands in for gerbonara's class of the same name. The reader identifies a
    macro instance by `type(x).__name__`, so the name here is load-bearing."""

    def __init__(self, macro_name: str, parameters) -> None:
        self.macro = _FakeMacro(macro_name)
        self.parameters = tuple(parameters)


@pytest.mark.parametrize("angle", [0.0, 17.5, 45.0, 90.0, 137.25])
def test_a_rounded_rectangle_macro_reports_the_authored_rotation(angle):
    """THE BUG, stated positively: whatever angle went in comes back out."""
    from gerber_writer import RoundedRectangle

    aperture = _emitted_aperture(
        RoundedRectangle(_RR_W, _RR_H, _RR_RADIUS, "SMDPad,CuDef"), angle)
    assert type(aperture).__name__ == "ApertureMacroInstance", (
        "this fixture is supposed to exercise the MACRO path; gerber-writer "
        "collapsed it to a standard aperture, so the test proves nothing")

    geom = ir_parity._gerbonara_shape(aperture)
    assert geom.shape == "roundrect"
    assert geom.rot_deg == pytest.approx(angle, abs=1e-6)
    assert geom.w_mm == pytest.approx(_RR_W, abs=1e-6)
    assert geom.h_mm == pytest.approx(_RR_H, abs=1e-6)
    assert geom.corner_radius_mm == pytest.approx(_RR_RADIUS, abs=1e-6)


def test_reading_the_macros_last_parameter_as_rotation_would_still_be_wrong():
    """NON-VACUITY of the test above. It only discriminates the defect if the
    trailing parameter genuinely differs from the rotation — otherwise the old
    code would pass it too, and this section would be decorative."""
    from gerber_writer import RoundedRectangle

    aperture = _emitted_aperture(
        RoundedRectangle(_RR_W, _RR_H, _RR_RADIUS, "SMDPad,CuDef"), 0.0)
    params = [float(p) for p in aperture.parameters]
    assert len(params) == 10, (
        f"gerber-writer's RoundedRectangle macro no longer emits 10 parameters "
        f"(got {len(params)}: {params}) — re-read its macro source and update "
        f"ir_parity._MACRO_PARAM_COUNTS")
    assert params[-1] != pytest.approx(0.0, abs=1e-9), (
        "the trailing parameter now happens to equal the rotation, so the old "
        "params[-1] rule would pass — this fixture no longer proves the fix")
    assert ir_parity._gerbonara_shape(aperture).rot_deg == 0.0


@pytest.mark.parametrize("angle", [30.0, 90.0])
def test_the_rectangle_macro_the_old_rule_got_right_still_decodes(angle):
    """The fix must not break the case the trailing-parameter rule handled: a
    rotated plain rectangle IS emitted as a 3-parameter macro ending in its
    angle."""
    from gerber_writer import Rectangle

    aperture = _emitted_aperture(Rectangle(1.2, 0.6, "SMDPad,CuDef"), angle)
    assert len(aperture.parameters) == 3
    geom = ir_parity._gerbonara_shape(aperture)
    assert (geom.shape, geom.corner_radius_mm) == ("rect", 0.0)
    assert geom.rot_deg == pytest.approx(angle, abs=1e-6)
    assert (geom.w_mm, geom.h_mm) == pytest.approx((1.2, 0.6), abs=1e-6)


def test_an_unknown_macro_is_refused_rather_than_decoded_by_position():
    """gerber-writer emits ChamferedRectangle too. The old substring test
    (`"rect" in macro`) claimed it as a plain rectangle and silently flattened
    the chamfer; this reader has never been checked against it, so it must say
    so instead of guessing."""
    aperture = ApertureMacroInstance("ChamferedRectangle",
                                     [0.6, 0.3, 0.4, 0.1, 45.0])
    with pytest.raises(ir_parity.ParityCanonicalizationUnsupported,
                       match="no canonical shape mapping"):
        ir_parity._gerbonara_shape(aperture)


def test_a_macro_whose_parameter_count_changed_fails_closed():
    """The arity IS the contract. If gerber-writer reshapes the macro, decoding
    by position would report false geometry — which is how this bug happened."""
    aperture = ApertureMacroInstance("RoundedRectangle", [0.65, 0.55, 0.0])
    with pytest.raises(ir_parity.ParityCanonicalizationUnsupported,
                       match="not the 10 this reader's decoding is pinned to"):
        ir_parity._gerbonara_shape(aperture)


def test_a_self_inconsistent_rounded_rectangle_is_refused():
    """Radius is stated three times over ($6/2, and each half-extent minus its
    corner offset). Disagreement means the parameter ORDER is not what the
    reader assumes, so no extent it reads can be trusted either."""
    # $3 says the x corner offset is 0.10, but $6/2 says the radius is 0.44,
    # which would make it 0.21. One of them is not the parameter we think it is.
    aperture = ApertureMacroInstance(
        "RoundedRectangle",
        [0.65, 0.55, 0.10, 0.11, 0.0, 0.88, 0.21, 0.11, -0.21, 0.11])
    with pytest.raises(ir_parity.ParityCanonicalizationUnsupported,
                       match="self-inconsistent on x"):
        ir_parity._gerbonara_shape(aperture)


def test_a_rotation_slot_that_disagrees_with_the_corner_geometry_is_refused():
    """THE CHECK THAT COULD NOT HAVE BEEN FOOLED BY THE ORIGINAL BUG: the
    rotation is re-derived from where the corner circles actually ended up, and
    compared against the parameter claiming to be the rotation. Here $5 says 0
    while the corners are plainly turned 30 degrees."""
    xc, yc, radius = 0.21, 0.11, 0.44
    turned = math.radians(30.0)
    q1 = (xc * math.cos(turned) - yc * math.sin(turned),
          xc * math.sin(turned) + yc * math.cos(turned))
    q2 = (-xc * math.cos(turned) - yc * math.sin(turned),
          -xc * math.sin(turned) + yc * math.cos(turned))
    aperture = ApertureMacroInstance(
        "RoundedRectangle",
        [xc + radius, yc + radius, xc, yc, 0.0, 2 * radius, q1[0], q1[1],
         q2[0], q2[1]])
    with pytest.raises(ir_parity.ParityCanonicalizationUnsupported,
                       match="is not the rotation"):
        ir_parity._gerbonara_shape(aperture)

    # And the SAME parameters with an honest $5 decode cleanly — otherwise the
    # guard above could be firing for an unrelated reason.
    honest = ApertureMacroInstance(
        "RoundedRectangle",
        [xc + radius, yc + radius, xc, yc, 30.0, 2 * radius, q1[0], q1[1],
         q2[0], q2[1]])
    assert ir_parity._gerbonara_shape(honest).rot_deg == pytest.approx(30.0)


def test_the_seed_coupons_roundrect_land_is_not_reported_rotated():
    """END TO END on the board that surfaced it. Before the fix this produced
    exactly one delta — `copper_flash rot_deg` at ('F.Cu', 19.05, 8.0), C1 pad 1
    — on a pad authored at 0 degrees."""
    tables = tabulate_all(_board(COUPON_JLC1))
    deltas = diff_against_reference(tables["ir"], tables["gerber"])
    assert deltas == [], "\n".join(d.render() for d in deltas)


# ---------------------------------------------------------------------------
# THE SOLDER-MASK FAMILY (epoch CP2 S11) — and the proof it can FAIL.
#
# S4/S5 declined this family as a tautology; the FAMILIES entry records why that
# was overturned. The load-bearing consequence is that "ir, drc and gerber all
# report 17 mask rows and agree" is not, by itself, evidence of anything: three
# columns that cannot disagree would report exactly that. These tests mutate one
# axis of the geometry at a time and demand each mutation is named.
# ---------------------------------------------------------------------------


def _mask_aperture(**overrides):
    """One partially-rounded F.Mask opening, with named overrides."""
    base = dict(side_token="F.Mask", x=10.0, y=8.0, shape="roundrect",
                w=1.3, h=1.1, rot_deg=0.0, corner_radius_mm=0.44,
                polarity="dark", entity="pad", ref="C1")
    base.update(overrides)
    return ir_parity._MaskAperture(**base)


def _mask_table(surface: str, apertures) -> SurfaceTable:
    """A mask-only table for `surface`, built through the SAME row constructor
    and the SAME occurrence numbering every real tabulator uses."""
    return SurfaceTable(surface=surface,
                        families=frozenset({"mask_opening"}),
                        rows=tuple(ir_parity._mask_rows(apertures)))


@pytest.mark.parametrize("mutation,expected_field", [
    pytest.param({"x": 10.0005}, "x_mm", id="position_within_the_bucket"),
    pytest.param({"w": 1.4}, "w_mm", id="width"),
    pytest.param({"h": 1.2}, "h_mm", id="height"),
    pytest.param({"rot_deg": 30.0}, "rot_deg", id="rotation"),
    # CORNER GEOMETRY. Same outline extents, different rounding — a real
    # fabrication difference that width and height cannot express, which is why
    # the family carries an absolute radius rather than trusting the shape name.
    pytest.param({"corner_radius_mm": 0.20}, "corner_radius_mm", id="corner_radius"),
    # POLARITY. Identical extents, opposite meaning: mask CLOSED where the
    # reference says OPEN. Geometry alone cannot catch this one at all.
    pytest.param({"polarity": "clear"}, "polarity", id="polarity"),
])
def test_a_mutated_mask_opening_is_named_as_a_field_delta(mutation, expected_field):
    reference = _mask_table("ir", [_mask_aperture()])
    surface = _mask_table("gerber", [_mask_aperture(**mutation)])

    deltas = diff_against_reference(reference, surface)
    assert [d.field for d in deltas] == [expected_field], \
        [d.render() for d in deltas]
    assert deltas[0].family == "mask_opening"


def test_an_opening_on_the_wrong_SIDE_is_not_a_field_delta_but_a_lost_row():
    """SIDE is IDENTITY, not a field. An opening that moved to the other side of
    the board did not change value — the front lost a window and the back grew
    one, and reporting it as "field side changed" would let a joined row hide a
    board that is unsolderable on one face."""
    reference = _mask_table("ir", [_mask_aperture()])
    surface = _mask_table("gerber", [_mask_aperture(side_token="B.Mask")])

    deltas = diff_against_reference(reference, surface)
    assert {d.kind for d in deltas} == {"missing_row", "extra_row"}
    rendered = " ".join(d.render() for d in deltas)
    assert "F.Mask" in rendered and "B.Mask" in rendered


def test_a_dropped_DUPLICATE_opening_is_caught():
    """THE MULTIPLICITY CONTROL, and the reason the row key carries an occurrence
    ordinal at all.

    Two coincident identical apertures are two real flash operations in the
    emitted file. ``SurfaceTable.by_family`` is a ``{key: row}`` dict, so without
    the ordinal both would collapse to one row and losing one would be a CLEAN
    diff — a silent discard of fabrication-critical geometry, reported as a
    healthy board.

    A fixture with unique centres cannot prove this, which is why the two
    apertures here are deliberately identical in every field.
    """
    twice = [_mask_aperture(), _mask_aperture()]
    reference = _mask_table("ir", twice)
    assert len(reference.rows) == 2, "the ordinal must keep both rows distinct"
    assert {row.key[3] for row in reference.rows} == {0, 1}

    surface = _mask_table("gerber", twice[:1])
    deltas = diff_against_reference(reference, surface)
    assert [d.kind for d in deltas] == ["missing_row"], \
        [d.render() for d in deltas]


def test_coincident_openings_that_DIFFER_still_read_as_field_deltas():
    """The ordinal must not turn a wrong size into an illegible missing+extra
    pair. Numbering is by canonical geometry WITHIN a position bucket, so the
    two openings still pair up and only the changed one is reported."""
    reference = _mask_table("ir", [_mask_aperture(w=1.3), _mask_aperture(w=2.0)])
    surface = _mask_table("gerber", [_mask_aperture(w=1.3), _mask_aperture(w=2.5)])

    deltas = diff_against_reference(reference, surface)
    assert [(d.kind, d.field) for d in deltas] == [("field", "w_mm")], \
        [d.render() for d in deltas]


@pytest.mark.parametrize("radius,expected", [
    pytest.param(0.0, "rect", id="zero_radius_is_a_rectangle"),
    pytest.param(0.55, "oval", id="fully_rounded_is_an_obround"),
    pytest.param(0.44, "roundrect", id="partially_rounded_stays_a_roundrect"),
])
def test_a_roundrect_at_a_degenerate_radius_folds_to_the_shape_it_IS(radius,
                                                                    expected):
    """The emitter degenerates a zero-radius roundrect to a Rectangle and
    gerber-writer collapses a fully-rounded one to the standard obround, so the
    bytes name shapes the IR still calls "roundrect". Folding both ends keeps
    that from reading as a shape defect."""
    rows = ir_parity._mask_rows(
        [_mask_aperture(w=1.3, h=1.1, corner_radius_mm=radius)])
    assert rows[0].field_map()["shape"] == expected


def test_the_degenerate_fold_does_not_swallow_a_WRONG_radius():
    """PROOF THE FOLD IS NOT A SUPPRESSION. It fires only at the two radii where
    the outlines are provably identical; a roundrect rounded merely differently
    still disagrees."""
    reference = _mask_table("ir", [_mask_aperture(corner_radius_mm=0.44)])
    for wrong in (0.30, 0.10, 0.50):
        surface = _mask_table("gerber",
                              [_mask_aperture(corner_radius_mm=wrong)])
        deltas = diff_against_reference(reference, surface)
        assert deltas, f"radius {wrong} was swallowed"


def test_kicad_cannot_express_the_mask_family_and_says_so():
    """KiCad writes a per-pad solder_mask_margin and never an aperture, so it
    must DECLINE the family rather than contribute zero rows to it — the
    difference between "cannot answer" and "answered nothing" is the whole point
    of a surface's family set."""
    tables = tabulate_all(_board(COUPON_JLC1))
    assert "mask_opening" not in tables["kicad"].families
    assert not [r for r in tables["kicad"].rows if r.family == "mask_opening"]
    for surface in ("ir", "drc", "gerber"):
        assert "mask_opening" in tables[surface].families
        assert [r for r in tables[surface].rows if r.family == "mask_opening"], \
            f"{surface} declares the mask family but produced no rows"


@pytest.mark.parametrize("path", [PARITY_CORNERS, COUPON_JLC1])
def test_the_three_mask_columns_are_independently_derived_and_agree(path):
    """The standing mask assertion. The IR column re-derives openings from
    ResolvedBoard fields, the gerber column parses emitted bytes, and DRC reads
    the shared owner they are both held up against."""
    tables = tabulate_all(_board(path))
    counts = {s: len([r for r in tables[s].rows if r.family == "mask_opening"])
              for s in ("ir", "drc", "gerber")}
    assert len(set(counts.values())) == 1, counts
    assert counts["ir"] > 0
    for surface in ("drc", "gerber"):
        deltas = [d for d in diff_against_reference(tables["ir"], tables[surface])
                  if d.family == "mask_opening"]
        assert deltas == [], "\n".join(d.render() for d in deltas)


def test_a_real_dropped_mask_aperture_is_caught_end_to_end(monkeypatch):
    """THE NON-SYNTHETIC MASK TEETH TEST — the one that proves the gerber column
    reads live bytes rather than restating a harvest.

    Drops the LAST mask opening inside the production emitter, re-emits real
    Gerber, re-parses it and demands the gate name gerber. A tabulator returning
    constants, or one wired to mask_source instead of to the file, passes every
    table-level test above and fails this one.
    """
    from pcb_worker import gerber

    original = gerber._add_mask

    def drop_one(layer, openings, *args, **kwargs):
        return original(layer, list(openings)[:-1], *args, **kwargs)

    monkeypatch.setattr(gerber, "_add_mask", drop_one)

    report = check_parity(_board(PARITY_CORNERS), PARITY_CORNERS_BASELINE)
    assert not report.ok, "a dropped mask aperture went undetected"
    assert {d.surface for d in report.unexplained} == {"gerber"}
    assert {d.family for d in report.unexplained} == {"mask_opening"}
    assert "missing_row" in {d.kind for d in report.unexplained}


def test_a_non_flash_object_in_a_mask_file_fails_closed(monkeypatch):
    """Skipping an object would SHRINK the gerber surface's row set, and a
    shrunken set makes "no extra rows" pass more easily. Refuse instead."""
    from pcb_worker import gerber

    original = gerber.build_gerbers_ir

    def with_a_stray_draw(rb, **kwargs):
        files = dict(original(rb, **kwargs))
        name = next(f for f in files if f.endswith("F_Mask.gbr"))
        files[name] = files[name].replace(
            "M02*", "%ADD99C,0.20*%\nD99*\nX10000000Y10000000D02*\n"
                    "X11000000Y10000000D01*\nM02*")
        return files

    monkeypatch.setattr(gerber, "build_gerbers_ir", with_a_stray_draw)

    with pytest.raises(ir_parity.ParityCanonicalizationUnsupported,
                       match="mask output is flashes only"):
        ir_parity.tabulate_gerber(_board(PARITY_CORNERS))


def test_a_HALF_tented_via_opens_mask_on_exactly_one_side():
    """THE TENTING ASYMMETRY, which no fixture can author.

    A via is the one entity whose "has copper here" and "opens mask here"
    answers differ, and the rule is PER SIDE (019f8fe7cbaf). Board YAML carries a
    single symmetric `tented` boolean, so a half-tented via cannot be written
    into a fixture — it is constructed here on the compiled IR instead, and all
    three surfaces are re-derived from it.

    Without this, the per-side branch is only ever run with both answers equal,
    and an emitter (or this module's own walk) that read one side's flag for both
    would agree with everyone. Measured: with the corpus alone, opening mask over
    a tented via left the whole suite green.
    """
    board = _board(PARITY_CORNERS)
    tented, untented = sorted(board.vias,
                              key=lambda v: not (v.tented_front and v.tented_back))
    half = replace(tented, tented_front=False, tented_back=True)
    board = replace(board, vias=(half, untented))

    tables = tabulate_all(board)
    for surface in ("ir", "drc", "gerber"):
        openings = [r for r in tables[surface].rows
                    if r.family == "mask_opening"
                    and r.key[1:3] == (ir_parity._q(half.position[0]),
                                       ir_parity._q(half.position[1]))]
        sides = {r.key[0] for r in openings}
        assert sides == {"F.Mask"}, (
            f"{surface} put the half-tented via's mask openings on {sides or 'no'} "
            f"side(s); the untented FRONT must open and the tented BACK must not")

    for surface in ("drc", "gerber"):
        deltas = [d for d in diff_against_reference(tables["ir"], tables[surface])
                  if d.family == "mask_opening"]
        assert deltas == [], "\n".join(d.render() for d in deltas)


# ---------------------------------------------------------------------------
# COLD-REVIEW REPAIRS (Codex on 6360a90, question 019ff39ea6c9).
#
# Three findings, each of which had shipped green: an occurrence ordinal
# assigned from PRE-canonical geometry (a proven false parity failure), a
# fail-closed refusal filed under the environment-skippable exception class, and
# one derivation branch no fixture could reach because its behaviour is ABSENCE.
# ---------------------------------------------------------------------------


def test_coincident_apertures_described_the_two_LEGAL_ways_still_pair_up():
    """FINDING 1, the P1. Occurrence ordinals were assigned by sorting the RAW
    aperture while the ROW was built from the folded one, so two surfaces
    describing the SAME multiset the two legal ways numbered it differently.

    The reproduction is the reviewer's: a rect beside a FULLY-ROUNDED roundrect
    at one position. The IR calls the second 'roundrect'; the emitted bytes call
    it an obround, because gerber-writer collapses a fully-rounded RoundedRectangle
    to the standard `O,` aperture. Sorted raw, that is rect-then-roundrect on one
    surface and oval-then-rect on the other — "oval" < "rect" < "roundrect" as
    strings — so occurrence 0 on the IR joined occurrence 0 on the gerber across
    two DIFFERENT apertures. Measured before the fix: EIGHT false field deltas on
    a board with nothing wrong with it.
    """
    def aperture(shape, w, h, radius):
        return ir_parity._MaskAperture("F.Mask", 10.0, 8.0, shape, w, h, 0.0,
                                       radius, "dark", "pad", "C1")

    # A fully-rounded roundrect IS an obround; radius == min(w, h) / 2.
    reference = _mask_table("ir", [aperture("rect", 1.2, 1.0, 0.0),
                                   aperture("roundrect", 1.3, 1.1, 0.55)])
    surface = _mask_table("gerber", [aperture("rect", 1.2, 1.0, 0.0),
                                     aperture("oval", 1.3, 1.1, 0.55)])

    # Both surfaces must reach the same canonical shape AND the same ordinal.
    assert [(r.key[3], r.field_map()["shape"]) for r in reference.rows] == \
           [(r.key[3], r.field_map()["shape"]) for r in surface.rows]
    deltas = diff_against_reference(reference, surface)
    assert deltas == [], "\n".join(d.render() for d in deltas)


def test_same_geometry_inside_one_position_bucket_is_input_order_independent():
    """The canonical-geometry repair still needs a TOTAL anonymous ordering.

    These two apertures share the 10 um identity bucket and have identical
    geometry, but their raw centres differ by 3 um — well above the 0.1 um field
    tolerance. Geometry alone therefore ties, and a stable sort would preserve
    whichever surface-specific input order happened to arrive. Reversing the
    same semantic multiset must not swap its occurrence ordinals and invent two
    position defects.
    """
    def aperture(x):
        return ir_parity._MaskAperture(
            "F.Mask", x, 8.0, "circle", 1.0, 1.0, 0.0, ir_parity.NA,
            "dark", "pad", "C1")

    apertures = [aperture(10.001), aperture(10.004)]
    reference = _mask_table("ir", apertures)
    surface = _mask_table("gerber", list(reversed(apertures)))

    assert [(r.key[3], r.field_map()["x_mm"]) for r in reference.rows] == \
           [(r.key[3], r.field_map()["x_mm"]) for r in surface.rows]
    deltas = diff_against_reference(reference, surface)
    assert deltas == [], "\n".join(d.render() for d in deltas)


def test_the_ordinal_is_assigned_from_the_geometry_that_is_REPORTED():
    """The invariant behind the fix, asserted directly rather than through one
    fixture: for every aperture, the fields the row carries are the same
    canonical form its ordinal was sorted on.

    Stated as its own test because the bug was not a wrong comparison — both
    halves were individually correct — it was two halves reading DIFFERENT
    geometry. A future edit that recomputes either side independently
    reintroduces it, and this fails.
    """
    for shape, w, h, radius in (("roundrect", 1.3, 1.1, 0.55),   # -> oval
                                ("roundrect", 1.3, 1.1, 0.0),    # -> rect
                                ("oval", 1.2, 2.4, 0.6),         # 90-deg fold
                                ("rect", 2.0, 1.0, 0.0)):
        aperture = ir_parity._MaskAperture("F.Mask", 4.0, 4.0, shape, w, h, 90.0,
                                           radius, "dark", "pad", "U1")
        canon = ir_parity._mask_canonical(aperture)
        row = ir_parity._mask_rows([aperture])[0].field_map()
        assert (row["shape"], row["w_mm"], row["h_mm"], row["rot_deg"]) == \
               (canon.shape, canon.w, canon.h, canon.rot)


def test_the_two_refusal_classes_stay_distinct():
    """FINDING 2. Unsupported or corrupt fabrication data must NOT raise the
    environment-skippable class.

    ``ParitySurfaceUnavailable`` means "a dev-only reader is missing on this
    machine", which a caller may legitimately turn into "skip this surface".
    An unknown aperture, a macro whose parameters do not match its contract, or
    a graphic a family cannot tabulate does not get better on another machine —
    routing one down the skip path would let the gate go quiet on exactly the
    data it exists to refuse.

    Asserted STRUCTURALLY, over every raise in the module, so a future raise
    added at a new site cannot pick the wrong class unnoticed.
    """
    assert not issubclass(ParityCanonicalizationUnsupported, ParitySurfaceUnavailable)

    tree = ast.parse(Path(ir_parity.__file__).read_text(encoding="utf-8"))
    environmental = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Raise) or node.exc is None:
            continue
        call = node.exc
        name = getattr(getattr(call, "func", call), "id", None)
        if name == "ParitySurfaceUnavailable":
            environmental.append(node.lineno)
    # Exactly one: the lazy gerbonara import. Every other refusal is about DATA.
    assert len(environmental) == 1, (
        f"ParitySurfaceUnavailable is raised at lines {environmental} — it means "
        f"'a reader is missing on this machine' and nothing else. A refusal about "
        f"the DATA must raise ParityCanonicalizationUnsupported, or a caller's "
        f"environment-skip path could swallow it")
    source = Path(ir_parity.__file__).read_text(encoding="utf-8").splitlines()
    context = "\n".join(source[environmental[0] - 6:environmental[0]])
    assert "ImportError" in context, \
        "the one environmental raise is supposed to be the missing-reader path"


def test_a_plated_hole_with_no_annulus_is_UNREPRESENTABLE_not_merely_untested():
    """FINDING 3, and the review's premise needed one correction.

    The finding asked for a negative control on "plated board hole without an
    annulus contributes no opening", on the reading that it was a reachable
    branch no fixture covered. It is not reachable: ``ResolvedHole`` REFUSES to
    construct in that state (resolved_board.py, "a plated hole must carry an
    authored copper annulus" — the author-don't-invent invariant of finding
    019f8dbb7104). No board that compiles can carry one, so no fixture and no
    constructed IR can exercise the branch, and a test asserting "it contributes
    nothing" would be asserting something about a value that cannot exist.

    So the guard in ``_ir_mask_openings`` is a DEFENSIVE branch over an
    already-impossible state, not a live rule — and this test pins the invariant
    that makes it dead. If the IR ever relaxes it, this fails and says so, which
    is the moment the guard becomes load-bearing and needs its own control. That
    is a stronger arrangement than a fixture: it cannot rot into a test of
    something the type no longer forbids.

    ``mask_source.board_hole_openings`` keeps its own ``annulus is None`` branch
    for the same defensive reason, and it takes loose arguments rather than a
    ``ResolvedHole``, so there the state IS representable.
    """
    board = _board(PARITY_CORNERS)
    plated = next(h for h in board.holes if h.plated and h.annulus_mm)

    with pytest.raises(ValueError, match="authored copper annulus"):
        replace(plated, annulus_mm=None)

    # And the positive half, which IS reachable: the annulus-bearing hole opens
    # a window on both sides, on all three participating surfaces.
    tables = tabulate_all(board)
    where = (ir_parity._q(plated.feature.position[0]),
             ir_parity._q(plated.feature.position[1]))
    for surface in ("ir", "drc", "gerber"):
        rows = [r for r in tables[surface].rows
                if r.family == "mask_opening" and r.key[1:3] == where]
        assert {r.key[0] for r in rows} == {"F.Mask", "B.Mask"}, (
            f"{surface} did not open mask on both sides over the plated hole's "
            f"copper ring")

    # The UNPLATED board hole is the neighbouring branch and IS reachable — it
    # opens to the drill on both sides with no margin. Asserted here so the two
    # hole rules are pinned side by side rather than one of them by accident.
    unplated = next(h for h in board.holes if not h.plated)
    bare = (ir_parity._q(unplated.feature.position[0]),
            ir_parity._q(unplated.feature.position[1]))
    for surface in ("ir", "drc", "gerber"):
        rows = [r for r in tables[surface].rows
                if r.family == "mask_opening" and r.key[1:3] == bare]
        assert {r.key[0] for r in rows} == {"F.Mask", "B.Mask"}
        assert all(r.field_map()["w_mm"] == pytest.approx(
            unplated.feature.diameter_mm, abs=1e-9) for r in rows), (
            "an unplated board hole opens to the DRILL, with no margin")


def test_a_pads_own_side_agrees_with_its_components_placement():
    """The asymmetry the review asked about (answer d), pinned instead of left
    implicit.

    ``mask_source`` keys an SMD opening off the COMPONENT's side; this module's
    reference walk keys it off ``PlacedPad.side``. The compiler makes the two
    agree on every board it produces, so the difference is invisible — which is
    exactly why it is worth an assertion rather than a comment. Keeping the
    distinct read is deliberate (a genuine divergence SHOULD surface as a parity
    delta), but a hand-built inconsistent IR would otherwise produce a confusing
    mask failure with no statement anywhere of which reading is authoritative.

    If this ever fails, the mask family is not the bug — the board is.
    """
    for path in (PARITY_CORNERS, COUPON_JLC1):
        board = _board(path)
        for component in board.components:
            for pad in component.placed_pads:
                assert pad.side is component.placement.side, (
                    f"{path.name}: {component.ref} pad {pad.source_id} sits on "
                    f"{pad.side} while its component is placed on "
                    f"{component.placement.side} — mask_source keys the opening "
                    f"off the COMPONENT and ir_parity off the PAD, so the two "
                    f"will now disagree")


@pytest.mark.parametrize("radius,expected", [
    # RECT end: at the fold window, and one step outside it.
    pytest.param(0.0, "rect", id="exactly_zero"),
    pytest.param(ir_parity.PARITY_TOLERANCE_MM * 0.9, "rect", id="inside_zero_window"),
    pytest.param(ir_parity.PARITY_TOLERANCE_MM * 10, "roundrect", id="outside_zero_window"),
    # OVAL end: min(w, h) / 2 == 0.55 for the 1.3 x 1.1 aperture below.
    pytest.param(0.55, "oval", id="exactly_fully_rounded"),
    pytest.param(0.55 - ir_parity.PARITY_TOLERANCE_MM * 0.9, "oval",
                 id="inside_fully_rounded_window"),
    pytest.param(0.55 - ir_parity.PARITY_TOLERANCE_MM * 10, "roundrect",
                 id="outside_fully_rounded_window"),
])
def test_the_degenerate_fold_windows_are_exactly_where_they_claim(radius, expected):
    """Answer f: the fold is only honest if its WINDOW is where the comment says.

    Both endpoints are asserted just inside and just outside PARITY_TOLERANCE_MM
    — a fold even slightly too wide is a suppression, and one too narrow reports
    a shape defect on a correctly fabricated land."""
    rows = ir_parity._mask_rows(
        [_mask_aperture(w=1.3, h=1.1, corner_radius_mm=radius)])
    assert rows[0].field_map()["shape"] == expected


def test_the_sort_key_covers_every_field_the_row_compares():
    """THE RULE BEHIND THE OCCURRENCE ORDINAL, enforced structurally rather than
    field by field.

    Two apertures that tie on the sort key fall to Python's stable sort and take
    whatever order their surface happened to enumerate in. That is only safe if
    a tie means the rows are INTERCHANGEABLE — which requires the key to cover
    everything ``diff_against_reference`` will compare. Miss one and two correct
    surfaces enumerating in different orders assign the ordinals differently and
    report false deltas on that field.

    This has now happened twice, on two different fields: raw position (found in
    the S11 cold review) and entity/ref (found reviewing the fix for the first).
    Both were reachable only by constructing them, which is precisely why this
    is a derived test rather than two more hand-written cases: it enumerates the
    row's OWN field set, so a field added later is covered the day it appears.
    """
    base = _mask_aperture()
    row_fields = set(ir_parity._mask_rows([base])[0].field_map())

    # Each compared field, paired with a change to the aperture that produces it.
    perturbations = {
        "x_mm": {"x": 10.004},
        "y_mm": {"y": 8.004},
        "shape": {"shape": "circle", "w": 1.1, "h": 1.1, "corner_radius_mm": NA},
        "w_mm": {"w": 1.4},
        "h_mm": {"h": 1.2},
        "rot_deg": {"rot_deg": 30.0},
        "corner_radius_mm": {"corner_radius_mm": 0.2},
        "polarity": {"polarity": "clear"},
        "entity": {"entity": "via"},
        "ref": {"ref": "U9"},
    }
    assert set(perturbations) == row_fields, (
        "a mask_opening row carries fields this test does not perturb: "
        f"{sorted(row_fields - set(perturbations))}. Every COMPARED field must "
        f"appear in _mask_sort_key, or two surfaces that enumerate coincident "
        f"apertures in different orders will assign occurrence ordinals "
        f"differently and report false deltas on it. Add the field here AND to "
        f"the sort key.")

    base_key = ir_parity._mask_sort_key(base, ir_parity._mask_canonical(base))
    for field, mutation in perturbations.items():
        other = _mask_aperture(**mutation)
        other_key = ir_parity._mask_sort_key(
            other, ir_parity._mask_canonical(other))
        assert other_key != base_key, (
            f"apertures differing in {field!r} produce the SAME sort key, so "
            f"their order — and therefore their occurrence ordinal — is decided "
            f"by whichever surface enumerated first. {field!r} is a compared "
            f"field; add it to _mask_sort_key.")
