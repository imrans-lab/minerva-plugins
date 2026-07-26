"""The FIXED mutant corpus for the PCB worker's Python test suite.

WHAT THIS IS
------------
Each entry describes ONE plausible source defect as an EXACT-STRING substitution
into a production file under ``pcb/worker``. ``run_sweep.py`` applies each one to
a throw-away copy of the tree, runs the real suite against it, and records
whether the suite goes red and exactly WHICH tests do the killing.

The corpus is the round's oracle: after tests are deleted or tightened, the set
of KILLED mutant ids must be IDENTICAL. It is deliberately small and fixed —
every entry costs ~180s of sweep — so entries are chosen for SPREAD across
modules and defect SHAPES, not for volume.

RECORD FIELDS
-------------
``id``          stable, descriptive, never reused for a different defect.
``file``        path relative to ``pcb/worker``.
``find``        exact source substring; MUST occur EXACTLY ONCE in the file.
                Zero or >=2 occurrences is a HARD FAIL, not a warning — that is
                what makes the corpus self-invalidating when the source moves.
``replace``     the replacement substring.
``kind``        "full"   — a guard/branch/return removed outright.
                "half"   — a guard WEAKENED: one conjunct of a compound
                           condition, one branch of a symmetric pair, one axis
                           of a 2D test. These are the important ones: a test
                           that dies under full removal can still pass under a
                           half-removal, and that is the vacuous test that looks
                           most like a good one.
                "canary" — exactly one; must be trivially killed (see below).
``rationale``   one sentence: what real defect this simulates.
``equivalent``  optional bool + ``equivalent_reason``. An equivalent mutant that
                survives is NOT evidence of a test gap and must never be counted
                as one.

THE CANARY
----------
Exactly one entry has ``kind="canary"``. Its job is to be unmissably killed. A
SURVIVING canary means the mutation is not reaching the code under test at all
(the editable-install ``.pth`` winning over the scratch copy is the live hazard
here), in which case every "survived" result in the matrix is indistinguishable
from that failure. The sweep hard-fails on a surviving canary.

NOT IN SCOPE
------------
Cosmetic edits, renames and dead-branch edits are excluded on purpose: they
measure nothing about the suite. So is anything that breaks IMPORT or COLLECTION
rather than execution — a mutant that stops the suite collecting is a DEFECTIVE
mutant, not a killed one, and ``run_sweep.py`` hard-fails it rather than counting
it (see the fail-closed classification there).
"""

from __future__ import annotations


def L(*lines: str) -> str:
    """Exact multi-line source fragment. Written line-by-line so leading
    whitespace is visible and reviewable in a diff."""
    return "\n".join(lines)


PATHFINDER = "agent_router/pathfinder.py"
GRID = "agent_router/grid.py"
ROUTER = "agent_router/router.py"
DRC = "pcb_worker/drc.py"
DRC_GEOM = "pcb_worker/drc_geometric.py"
IR_PARITY = "pcb_worker/ir_parity.py"
GERBER = "pcb_worker/gerber.py"
COMPILE_BOARD = "pcb_worker/compile_board.py"
RESOLVED_BOARD = "pcb_worker/resolved_board.py"


MUTANTS: tuple[dict, ...] = (

    # ---------------------------------------------------------------- grid --
    {
        "id": "canary_grid_can_route_through_always_false",
        "file": GRID,
        "kind": "canary",
        "find": L(
            "        cell = self.get_cell(x, y, layer)",
            "        if not cell.occupied:",
            "            return True",
            "        # Can route through own net",
            "        return cell.net == net",
        ),
        "replace": "        return False",
        "rationale": "CANARY: the grid refuses every position, so no net can be "
                     "routed anywhere; if this survives, mutation is not reaching "
                     "the code under test and the whole matrix is void.",
    },
    {
        "id": "grid_keepout_margin_drops_half_trace_width",
        "file": GRID,
        "kind": "half",
        "find": "        return max(0.0, self.clearance) + max(0.0, self.trace_width) / 2.0",
        "replace": "        return max(0.0, self.clearance)",
        "rationale": "Reverts the Round-E2 half-width term, so a centerline may sit "
                     "exactly `clearance` from copper and still lay half a trace "
                     "width inside the clearance ring (an under-block).",
    },
    {
        "id": "grid_clearance_ring_overwrites_real_copper",
        "file": GRID,
        "kind": "full",
        "find": L(
            "        if cell.obstacle_type in _COPPER_TYPES:",
            "            return",
            "        if not cell.occupied:",
        ),
        "replace": "        if not cell.occupied:",
        "rationale": "Removes the copper-outranks-reservation early return, intended "
                     "to let one pad's clearance ring steal a neighbouring pad's real "
                     "land.",
        # PROVEN EQUIVALENT after the baseline sweep, by direct probe, not by
        # reasoning alone (tools/mutants: original and mutated agree on
        # obstacle_type, net and can_route_through for a ring landing on foreign
        # pad copper).
        #
        # WHY: with the early return gone, a copper cell falls through to
        # ``if not cell.occupied`` — False, because _mark_copper_cell always sets
        # occupied=True — and then to ``if cell.obstacle_type in _CLEARANCE_TYPES``
        # — also False, because a copper type is by construction not a clearance
        # type. Both remaining branches are no-ops for exactly the cells the guard
        # protects, and no code path can produce obstacle_type in _COPPER_TYPES
        # with occupied False. The guard is therefore DEFENSIVE and redundant with
        # the branch structure beneath it, not load-bearing.
        #
        # Consequence for the round: its survival is NOT a test gap and must never
        # be counted as one. Kept in the corpus rather than dropped so that if a
        # future change makes the guard load-bearing, its status flips visibly.
        "equivalent": True,
        "equivalent_reason": "the two branches below the removed early return are "
                             "both no-ops for a cell typed as copper, and no path "
                             "produces a copper type with occupied=False",
    },
    {
        "id": "grid_cell_in_bounds_checks_only_the_column_axis",
        "file": GRID,
        "kind": "half",
        "find": "        return 0 <= col < self.cols and 0 <= row < self.rows",
        "replace": "        return 0 <= col < self.cols",
        "rationale": "Drops one axis of a 2D bounds test: an out-of-board row reads "
                     "as in-bounds (and negative rows wrap onto the far side of the "
                     "grid).",
    },

    # ---------------------------------------------------------- pathfinder --
    {
        "id": "pathfinder_astar_start_cell_not_validated",
        "file": PATHFINDER,
        "kind": "full",
        "find": L(
            "    if not grid.can_route_through(start[0], start[1], net, layer):",
            "        return None",
            "",
            "    # A* algorithm",
        ),
        "replace": "    # A* algorithm",
        "rationale": "Removes the C2b blocked-start guard, so A* can launch out of a "
                     "cell owned by foreign copper and emit a segment beginning "
                     "inside it.",
    },
    {
        "id": "pathfinder_astar_diagonal_checks_one_corner_only",
        "file": PATHFINDER,
        "kind": "half",
        "find": L(
            "                if not grid.can_route_through(corner1[0], corner1[1], net, layer):",
            "                    continue",
            "                if not grid.can_route_through(corner2[0], corner2[1], net, layer):",
            "                    continue",
        ),
        "replace": L(
            "                if not grid.can_route_through(corner1[0], corner1[1], net, layer):",
            "                    continue",
        ),
        "rationale": "Checks one of the two corner cells a diagonal A* step cuts "
                     "instead of both, so a chord clipping the unchecked corner is "
                     "accepted.",
    },
    {
        "id": "pathfinder_simplify_drops_point_without_grid_recheck",
        "file": PATHFINDER,
        "kind": "full",
        "find": L(
            "        # Looks droppable. It only IS droppable if what replaces it stays inside",
            "        # the corridor the unsimplified path occupied.",
            "        if not _segment_clear(grid, prev, next_pt, net, layer):",
            "            simplified.append(curr)",
        ),
        "replace": L(
            "        # MUTANT: the replacement chord is no longer re-verified.",
            "        pass",
        ),
        "rationale": "Restores the geometry-only simplifier (docket 019f9bd5f2f2): a "
                     "path that correctly hugged an obstacle is emitted as one chord "
                     "straight across it.",
    },
    {
        "id": "pathfinder_l_path_emits_degenerate_leg_when_axis_aligned",
        "file": PATHFINDER,
        "kind": "full",
        "find": L(
            "    if start[0] == end[0] or start[1] == end[1]:",
            "        return _try_direct_path(grid, start, end, net, layer)",
            "",
            "    # Default order: horizontal-first then vertical-first",
        ),
        "replace": "    # Default order: horizontal-first then vertical-first",
        "rationale": "Restores docket 019f9cc3245d: an axis-aligned pair gets an 'L' "
                     "one of whose legs is zero-length, which poisons the whole "
                     "candidate batch downstream.",
    },

    # -------------------------------------------------------------- router --
    {
        "id": "router_coincidence_tolerance_not_capped_by_copper",
        "file": ROUTER,
        "kind": "half",
        "find": "    return min(grid_resolution * _COINCIDENT_CELLS, reach)",
        "replace": "    return grid_resolution * _COINCIDENT_CELLS",
        "rationale": "Drops the physical cap, so a caller asking for a coarse grid "
                     "merges two same-net stubs with a genuine air gap into one "
                     "pre-connected group and the router reports an OPEN net as routed.",
    },
    {
        "id": "router_pad_reaches_layer_ignores_through_hole",
        "file": ROUTER,
        "kind": "half",
        "find": L(
            '    return (pad.layer == layer or pad.layer == "*.Cu"',
            '            or pad.pad_type == "thru_hole")',
        ),
        "replace": '    return (pad.layer == layer or pad.layer == "*.Cu")',
        "rationale": "Weakens the connectivity predicate to two of its three "
                     "disjuncts, so a through-hole pad stops counting as present on "
                     "the layer its copper actually reaches.",
    },
    {
        "id": "router_route_board_ignores_board_owned_existing_copper",
        "file": ROUTER,
        "kind": "full",
        # Disambiguated by the trailing comment line: the identical two-line
        # fallback also appears in ``route_board_with_hints``, and the corpus's
        # exactly-once rule (correctly) refused the ambiguous form.
        "find": L(
            "    # slots are the source, options are the override layer.",
            "    existing_traces = existing_traces or board.existing_traces",
            "    existing_vias = existing_vias or board.existing_vias",
        ),
        "replace": "    pass  # MUTANT: board-owned accepted copper is ignored",
        "rationale": "Removes the 019f9bc3909c fallback from route_board, so a "
                     "partially-routed board whose caller passed no explicit copper is "
                     "routed straight through its own accepted traces and vias.",
    },

    # ----------------------------------------------------------------- drc --
    {
        "id": "drc_dangling_endpoint_loses_via_credit",
        "file": DRC,
        "kind": "full",
        "find": L(
            "                if any(_dist(pt, v) <= clr for v in vias):",
            "                    continue",
            "                # T-junction credit: on the interior of another same-net segment.",
        ),
        "replace": "                # T-junction credit: on the interior of another same-net segment.",
        "rationale": "Removes the via credit in check C, so every trace that "
                     "legitimately terminates on a via is reported as a dangling "
                     "endpoint (a DRC that cries wolf).",
    },
    {
        "id": "drc_crossing_dedupe_drops_the_location",
        "file": DRC,
        "kind": "half",
        "find": L(
            '            key = tuple(sorted([str(s1.net), str(s2.net)])) + (s1.layer,) \\',
            "                + _round_pt(pt)",
        ),
        "replace": '            key = tuple(sorted([str(s1.net), str(s2.net)])) + (s1.layer,)',
        "rationale": "Reverts the 019f9cc386b6 dedupe key to (net-pair, layer), so "
                     "two shorts between the same pair on the same layer at different "
                     "places collapse into one finding.",
    },
    {
        "id": "drc_point_on_segment_interior_tests_one_end_only",
        "file": DRC,
        "kind": "half",
        "find": "    if t <= eps or t >= 1.0 - eps:",
        "replace": "    if t <= eps:",
        "rationale": "Tests one end of a symmetric interior test instead of both, so "
                     "a point at the FAR endpoint of a segment is credited as lying "
                     "on its strict interior.",
    },

    # ------------------------------------------------------- drc_geometric --
    {
        "id": "drcgeo_same_net_exemption_treats_unassigned_as_shared",
        "file": DRC_GEOM,
        "kind": "half",
        "find": "    return a.net_id is not None and a.net_id == b.net_id",
        "replace": "    return a.net_id == b.net_id",
        "rationale": "Drops the NON-NULL half of the GC2 same-net exemption, so two "
                     "unassigned (net_id=None) copper primitives are exempted from "
                     "the clearance check — a missed short, i.e. a false clean.",
    },
    {
        "id": "drcgeo_gc5_stops_checking_the_right_board_edge",
        "file": DRC_GEOM,
        "kind": "half",
        "find": L(
            '            ("right", ox2 - box.max_x, (box.max_x, (box.min_y + box.max_y) / 2.0),',
            "             (ox2, (box.min_y + box.max_y) / 2.0)),",
        ),
        "replace": "",
        "rationale": "Checks three of the four board edges, so copper overhanging the "
                     "right-hand edge is certified clean.",
    },
    {
        "id": "drcgeo_via_padstack_fail_closed_guard_removed",
        "file": DRC_GEOM,
        "kind": "full",
        "find": L(
            "        if any(via.padstack is not None for via in rb.vias):",
            "            return _indeterminate(",
            '                "unsupported_geometry",',
            '                "per-layer via padstack copper is not modeled in GC2/GC5 yet; "',
            '                "geometric DRC is indeterminate rather than risk a false clean")',
        ),
        "replace": "        pass  # MUTANT: padstack fail-closed guard removed",
        "rationale": "Removes the 019f95893989 gate, so a via with per-layer padstack "
                     "lands is checked against the smaller global diameter and can be "
                     "certified clean while colliding.",
    },
    {
        "id": "drcgeo_unknown_copper_layer_silently_bucketed",
        "file": DRC_GEOM,
        "kind": "full",
        "find": L(
            "            if canon not in known_canon:",
            "                raise UnsupportedGeometry(",
            '                    f"copper {prim.entity_id!r} is on layer {lid!r} (canonical "',
            '                    f"{canon!r}), not a known board copper layer {sorted(known_canon)}")',
        ),
        "replace": "            pass  # MUTANT: unknown-layer fail-closed guard removed",
        "rationale": "Removes the fail-closed unknown-layer guard, so copper on an "
                     "unrecognised layer lands in its own singleton bucket, is never "
                     "paired, and is silently uncompared.",
    },

    # ---------------------------------------------------------- ir_parity --
    {
        "id": "irparity_key_quantum_collapses_onto_the_comparison_epsilon",
        "file": IR_PARITY,
        "kind": "half",
        "find": "PARITY_KEY_QUANTUM_MM = 1e-2",
        "replace": "PARITY_KEY_QUANTUM_MM = 1e-4",
        "rationale": "Re-introduces the documented design error: the row-identity "
                     "bucket becomes as tight as the value epsilon, so any real "
                     "disagreement also breaks the JOIN and is reported as an "
                     "unrelated missing+extra pair.",
    },
    {
        "id": "irparity_known_delta_matches_on_signature_without_the_row",
        "file": IR_PARITY,
        "kind": "half",
        "find": "        return delta.signature() == self.signature() and delta.key in set(self.keys)",
        "replace": "        return delta.signature() == self.signature()",
        "rationale": "Reverts the baseline to class-only matching, so a NEW delta of "
                     "an already-listed class is silently swallowed by the entry that "
                     "resembles it.",
    },
    {
        "id": "irparity_diff_never_reports_an_extra_row",
        "file": IR_PARITY,
        "kind": "full",
        "find": L(
            "        for key in sorted(set(got_rows) - set(ref_rows), key=str):",
            '            deltas.append(Delta(surface.surface, family, "extra_row", key, None,',
            '                                "absent", "present", got_rows[key].describe()))',
        ),
        "replace": "",
        "rationale": "Removes extra-row detection, so a surface that INVENTS copper "
                     "the IR does not carry passes the parity gate.",
    },

    # ------------------------------------------------------------- gerber --
    {
        "id": "gerber_obround_rotation_swap_disabled",
        "file": GERBER,
        "kind": "full",
        "find": L(
            "    if angle % 90 != 0:",
            "        return False           # upstream's EXACT gate: macro branch, angle kept",
            "    return abs((angle % 180.0) - 90.0) < _OBROUND_ANGLE_TOL_DEG",
        ),
        "replace": "    return False",
        "rationale": "Re-introduces defect 019f9af6e899: a quarter-turned fully-rounded "
                     "land is emitted with UNSWAPPED extents and fabricated "
                     "axis-aligned.",
    },
    {
        "id": "gerber_unplated_through_hole_pad_gets_copper",
        "file": GERBER,
        "kind": "half",
        "find": '            is_plated = pad.plated and pad.pad_type != "np_thru_hole"',
        "replace": '            is_plated = pad.pad_type != "np_thru_hole"',
        "rationale": "Weakens a two-conjunct plating predicate to one, so a "
                     "through-hole pad explicitly flagged NOT plated is given a copper "
                     "annulus the kicad emitter leaves bare (finding 019f8fe77068).",
    },
    {
        "id": "gerber_via_tenting_ignores_the_back_side",
        "file": GERBER,
        "kind": "half",
        "find": L(
            "        if not tented_front:",
            "            g.mask_top.append(_circle_mask(vx, vy, md))",
            "        if not tented_back:",
            "            g.mask_bot.append(_circle_mask(vx, vy, md))",
        ),
        "replace": L(
            "        if not tented_front:",
            "            g.mask_top.append(_circle_mask(vx, vy, md))",
        ),
        "rationale": "Handles one side of a symmetric per-side tenting rule, so an "
                     "untented via never gets its B.Cu mask opening (finding "
                     "019f8fe7cbaf).",
    },

    # ------------------------------------------------------ compile_board --
    {
        "id": "compile_via_drill_may_equal_or_exceed_diameter",
        "file": COMPILE_BOARD,
        "kind": "full",
        "find": L(
            "        if float(drill) >= float(diameter):",
            '            diags.error("via_bad_size", f"via {ordinal}: drill {drill} must be smaller than diameter {diameter}", via_ref)',
            "            continue",
        ),
        "replace": "        pass  # MUTANT: via drill-vs-diameter validation removed",
        "rationale": "Removes the compiler's via sanity check, so a via with no copper "
                     "annulus at all is accepted from source.",
    },
    {
        "id": "compile_plated_hole_annulus_invented_from_the_drill",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": L(
            "                if not _is_positive_number(raw_annulus):",
            "                    # Fail CLOSED: no invented copper on a fabrication-critical plated",
            "                    # hole. The source must author annulus_mm (> the drill diameter).",
            '                    diags.error("plated_hole_needs_annulus",',
            '                                f"{key}[{ordinal}]: a plated hole must author a positive "',
            "                                f\"'annulus_mm' (its copper ring diameter); got {raw_annulus!r}\",",
            "                                hole_ref)",
            "                    continue",
        ),
        "replace": L(
            "                if not _is_positive_number(raw_annulus):",
            "                    raw_annulus = float(diameter) * 2.0",
        ),
        "rationale": "Replaces the fail-closed rule with the retired 2x-drill "
                     "invention (finding 019f8dbb7104), so the two emitters can "
                     "disagree about a plated hole's copper.",
    },
    {
        "id": "compile_board_origin_reset_to_zero",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": '        origin = (float(raw_origin["x_mm"]), float(raw_origin["y_mm"]))',
        "replace": "        origin = (0.0, 0.0)",
        "rationale": "Validates the authored board origin and then discards it "
                     "(docket 019f783860c8 gap C), so every coordinate on a board that "
                     "does not start at (0, 0) is offset.",
    },

    # ----------------------------------------------------- resolved_board --
    {
        "id": "resolvedboard_unique_id_invariant_removed",
        "file": RESOLVED_BOARD,
        "kind": "full",
        "find": L(
            "def _unique_ids(items: tuple, field: str) -> None:",
            "    ids = [item.id for item in items]",
            "    if len(ids) != len(set(ids)):",
            '        raise ValueError(f"{field} contains duplicate ids")',
        ),
        "replace": L(
            "def _unique_ids(items: tuple, field: str) -> None:",
            "    return",
        ),
        "rationale": "Removes the IR's shared duplicate-id invariant, so two entities "
                     "can carry the same identity and every downstream id-keyed lookup "
                     "silently picks one of them.",
    },
    {
        "id": "resolvedboard_pad_net_crosscheck_removed",
        "file": RESOLVED_BOARD,
        "kind": "full",
        "find": L(
            "        if declared_pad_net != indexed_pad_net:",
            '            raise ValueError("PlacedPad.net_id and ResolvedNet.pad_refs disagree")',
        ),
        "replace": "        pass  # MUTANT: pad/net cross-check removed",
        "rationale": "Removes the agreement check between PlacedPad.net_id and the net "
                     "index, so a board whose two net representations disagree is "
                     "accepted as fabricable.",
    },
    {
        "id": "resolvedboard_corner_rratio_upper_bound_dropped",
        "file": RESOLVED_BOARD,
        "kind": "half",
        "find": "        if self.corner_rratio is not None and not 0 <= self.corner_rratio <= 0.5:",
        "replace": "        if self.corner_rratio is not None and not 0 <= self.corner_rratio:",
        "rationale": "Checks one end of a two-sided range instead of both, so a "
                     "roundrect corner ratio above 0.5 (a geometrically impossible "
                     "land) is accepted.",
    },
)


def by_id() -> dict[str, dict]:
    return {m["id"]: m for m in MUTANTS}


def validate_shape() -> None:
    """Structural self-check of the corpus (not of the source it targets)."""
    seen: set[str] = set()
    canaries = [m for m in MUTANTS if m["kind"] == "canary"]
    if len(canaries) != 1:
        raise SystemExit(f"corpus must carry EXACTLY one canary, found {len(canaries)}")
    if not 24 <= len(MUTANTS) <= 36:
        raise SystemExit(f"corpus size {len(MUTANTS)} outside the 24..36 band")
    for m in MUTANTS:
        for key in ("id", "file", "find", "replace", "kind", "rationale"):
            if key not in m:
                raise SystemExit(f"mutant {m.get('id')!r} is missing {key!r}")
        if m["id"] in seen:
            raise SystemExit(f"duplicate mutant id {m['id']!r}")
        seen.add(m["id"])
        if m["kind"] not in ("full", "half", "canary"):
            raise SystemExit(f"mutant {m['id']!r} has unknown kind {m['kind']!r}")
        if m["find"] == m["replace"]:
            raise SystemExit(f"mutant {m['id']!r} is a no-op")


if __name__ == "__main__":  # pragma: no cover - manual sanity check
    validate_shape()
    print(f"{len(MUTANTS)} mutants, shape OK")
