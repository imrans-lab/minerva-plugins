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
from pcb_worker.resolved_board import ResolutionSuccess

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
    for name, table in tables.items():
        families = {row.family for row in table.rows}
        missing = table.families - families
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
    ``pad_source`` / ``ir_pads``.

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
    """
    forbidden_modules = {"pad_source", "ir_pads"}
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

    from pcb_worker import ir_pads, pad_source

    def boom(*_args, **_kwargs):
        raise AssertionError(
            "the IR reference tabulator called the SHARED pad-land owner — that "
            "makes the reference agree with drc/kicad/gerber by construction")

    for module, name in ((pad_source, "th_land"), (pad_source, "placed_pad_to_geom"),
                         (ir_pads, "pad_land"), (ir_pads, "smd_shape"),
                         (ir_pads, "pad_copper_shape"), (ir_pads, "iter_ir_pads")):
        monkeypatch.setattr(module, name, boom)

    table = ir_parity.tabulate_ir(_board(PARITY_CORNERS))
    assert table.by_family("copper_flash"), "tabulate_ir produced no copper"
    assert table.by_family("drill")


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
