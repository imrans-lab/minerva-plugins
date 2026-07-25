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
"""

from __future__ import annotations

import ast
from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import ir_parity
from pcb_worker.compile_board import compile_board
from pcb_worker.ir_parity import (
    NA,
    PARITY_CORNERS_BASELINE,
    SMART_REMOTE_BASELINE,
    Delta,
    KnownDelta,
    ParityRow,
    check_parity,
    diff_against_reference,
    format_report,
    tabulate_all,
)
from pcb_worker.resolved_board import ResolutionSuccess

HERE = Path(__file__).resolve().parent
SMART_REMOTE = HERE / "testdata" / "smart_remote.yaml"
PARITY_CORNERS = HERE / "testdata" / "parity_corners.yaml"

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
def smart_remote_tables():
    """Tabulated once per module: the four surfaces each emit a full fabrication
    set, which is the slowest thing here. Safe to share because every table is
    frozen (``ParityRow``/``SurfaceTable`` are frozen dataclasses holding tuples)
    and every perturbation below builds a NEW table rather than mutating one."""
    return tabulate_all(_board(SMART_REMOTE))


CASES = (
    pytest.param(SMART_REMOTE, SMART_REMOTE_BASELINE, id="smart_remote"),
    pytest.param(PARITY_CORNERS, PARITY_CORNERS_BASELINE, id="parity_corners"),
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


@pytest.mark.parametrize("path", [SMART_REMOTE, PARITY_CORNERS])
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
def test_a_moved_pad_on_any_one_surface_fails_and_names_it(smart_remote_tables,
                                                           surface):
    """THE ACCEPTANCE CRITERION. Move one copper land on ONE surface by 0.5 mm;
    the gate must fail and the message must name that surface.

    Run for THREE surfaces, because a harness that only catches the surface its
    author was thinking about is worse than none — it certifies the other two.
    """
    tables = _perturb(smart_remote_tables, surface, "copper_flash", _move)
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)
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
        smart_remote_tables, surface, family, field, value):
    """Corrupt ONE field on ONE surface; the failure must name the SURFACE, the
    ENTITY and the FIELD, and print both values.

    Spread across every family a surface participates in and across both geometry
    (size, shape, rotation, width, diameter) and non-geometry (net ownership,
    plating) so the gate is proven to be watching all of it, not just centres.
    """
    tables = _perturb(smart_remote_tables, surface, family,
                      _set_field(field, value), field=field)
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)
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


def test_a_dropped_row_on_one_surface_fails(smart_remote_tables):
    """A surface that silently LOSES copper must fail — the fabrication defect
    that matters most, and the one a field-by-field diff would miss if it only
    compared rows both sides happen to have.

    Drops COPPER, not drills: the baseline enumerates a gerber/drill/missing_row
    class, so a dropped drill exercises the count mechanism instead (covered by
    test_a_new_delta_cannot_hide_behind_a_listed_class). Copper has no listed
    class, so it must land in `unexplained` — which is the channel that says
    "nobody has an explanation for this".
    """
    table = smart_remote_tables["gerber"]
    victim = next(r for r in table.rows if r.family == "copper_flash")
    kept = tuple(r for r in table.rows if r is not victim)
    tables = dict(smart_remote_tables)
    tables["gerber"] = replace(table, rows=kept)

    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)
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

    Uses parity_corners, not smart_remote: every land in smart_remote is square,
    so transposing w/h there is a no-op and the test would silently prove nothing.
    """
    from pcb_worker import gerber

    original = gerber._shape_aperture
    monkeypatch.setattr(
        gerber, "_shape_aperture",
        lambda shape, w, h, rratio, func: original(shape, h, w, rratio, func))

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


def test_a_sub_bucket_displacement_is_reported_as_a_position_field(smart_remote_tables):
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

    tables = _perturb(smart_remote_tables, "kicad", "copper_flash", shift,
                      field="x_mm")
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)
    assert not report.ok
    named = [d for d in report.unexplained if d.field == "x_mm"]
    assert len(named) == 1 and named[0].surface == "kicad"
    assert named[0].kind == "field", "a sub-bucket shift must still JOIN the rows"


def test_not_applicable_never_reads_as_a_disagreement(smart_remote_tables):
    """A surface reporting NA for a field it cannot express must not fail the gate
    — and must not be able to hide a real value behind NA either.

    Both halves matter. The first is why gerber (no nets, no component identity)
    can be gated at all; the second is why NA is a distinct sentinel rather than
    ``None``, which is a REAL value in this domain.
    """
    tables = _perturb(smart_remote_tables, "kicad", "copper_flash",
                      _set_field("net_name", NA))
    assert check_parity(None, SMART_REMOTE_BASELINE, tables=tables).ok

    # ... whereas None is a claim ("this pad has no net"), and contradicting the
    # IR with it is a failure.
    ir_rows = smart_remote_tables["ir"].by_family("net_ownership")
    keyed = next(k for k, r in ir_rows.items() if r.field_map()["net_name"])
    table = tables["kicad"]
    rows = [_set_field("net_name", None)(r) if (r.family == "net_ownership"
                                                and r.key == keyed) else r
            for r in table.rows]
    tables = dict(tables)
    tables["kicad"] = replace(table, rows=tuple(rows))
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)
    assert not report.ok
    assert any(d.field == "net_name" and d.surface_value is None
               for d in report.unexplained)


def test_a_family_a_surface_cannot_express_is_skipped_not_failed(smart_remote_tables):
    """gerber carries no nets AT ALL. That must read as non-participation, never
    as "gerber lost 76 net assignments"."""
    gerber = smart_remote_tables["gerber"]
    assert "net_ownership" not in gerber.families
    assert not [r for r in gerber.rows if r.family == "net_ownership"]
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=smart_remote_tables)
    assert ("gerber", "net_ownership") in report.skipped
    assert not [d for d in report.deltas
                if d.surface == "gerber" and d.family == "net_ownership"]


# ---------------------------------------------------------------------------
# 3. THE BASELINE MECHANISM
# ---------------------------------------------------------------------------


def test_a_listed_delta_does_not_fail(smart_remote_tables):
    """The known Excellon-rounding deltas ARE present, and the baseline explains
    them. Asserted positively so a future run that no longer produces them fails
    loudly (via the staleness check below) rather than quietly passing."""
    report = check_parity(None, (), tables=smart_remote_tables)
    assert report.deltas, "expected the known baseline deltas to exist"
    assert not check_parity(None, SMART_REMOTE_BASELINE,
                            tables=smart_remote_tables).unexplained


def test_a_new_delta_of_an_unlisted_class_fails(smart_remote_tables):
    """An unexplained delta in a class NO baseline entry covers must fail."""
    tables = _perturb(smart_remote_tables, "kicad", "copper_flash",
                      _set_field("h_mm", 12.5))
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)
    assert not report.ok
    assert [d for d in report.unexplained
            if d.surface == "kicad" and d.field == "h_mm"]


def test_a_displaced_baselined_row_is_not_swallowed(smart_remote_tables):
    """REGRESSION (review finding). A baselined row that MOVES must fail.

    The hole this reproduces: when a KnownDelta matched on
    ``(surface, family, kind, field)`` plus a COUNT, displacing one already-
    baselined gerber drill hit by 80 mm kept the arity at 3 and the gate passed
    clean — ok=True, zero unexplained, zero stale. Any regression that landed
    inside an existing delta class and merely displaced a member was invisible.

    KnownDelta now pins the exact ROW KEYS, so the moved row is unexplained and
    the entry that lost it is stale.
    """
    table = smart_remote_tables["gerber"]
    victim_key = (60.96, 12.7)          # one of the three baselined Excellon rows
    moved_key = (5.0, 90.0)             # the reviewer's 80 mm displacement
    rows = []
    displaced = 0
    for row in table.rows:
        if row.family == "drill" and row.key == victim_key:
            fields = dict(row.fields)
            fields["x_mm"], fields["y_mm"] = moved_key
            rows.append(replace(row, key=moved_key, fields=tuple(sorted(fields.items()))))
            displaced += 1
        else:
            rows.append(row)
    assert displaced == 1, "fixture changed: expected exactly one baselined row here"

    tables = dict(smart_remote_tables)
    tables["gerber"] = replace(table, rows=tuple(rows))
    report = check_parity(None, SMART_REMOTE_BASELINE, tables=tables)

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


def test_a_fixed_delta_forces_the_baseline_to_shrink(smart_remote_tables):
    """A baseline entry naming a row that no longer disagrees must FAIL, not
    silently pass. Otherwise the list rots into a record of things that used to be
    true and "the baseline is empty" stops meaning anything.

    Simulated by declaring a row that does not disagree; the real trigger is a fix
    landing in a worker module.
    """
    inflated = (replace(SMART_REMOTE_BASELINE[0],
                        keys=SMART_REMOTE_BASELINE[0].keys + ((1.0, 1.0),)),
                ) + SMART_REMOTE_BASELINE[1:]
    report = check_parity(None, inflated, tables=smart_remote_tables)
    assert not report.ok
    assert report.stale
    message = format_report(report)
    assert "NO LONGER PRESENT: (1.0, 1.0)" in message
    assert "drop it from the entry" in message


def test_every_baseline_entry_is_explained_and_attributed():
    """A baseline entry with no reason, or with an invented docket id, is a
    suppression dressed up as documentation."""
    for baseline in (SMART_REMOTE_BASELINE, PARITY_CORNERS_BASELINE):
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
    """The migration's visible finish line: both baselines empty.

    Asserted as an inequality rather than a target so it documents progress
    without failing today. When a baseline reaches 0, tighten this.
    """
    total = len(SMART_REMOTE_BASELINE) + len(PARITY_CORNERS_BASELINE)
    assert total <= 5, (
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
