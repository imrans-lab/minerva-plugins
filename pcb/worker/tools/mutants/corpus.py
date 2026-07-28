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
MANUFACTURER_PROFILE = "pcb_worker/manufacturer_profile.py"
#: NOT source: the schema doc is TEST INPUT. Paths are relative to ``pcb/worker``,
#: so this escapes one level, exactly as ``run_sweep.PCB_SIBLINGS`` copies it.
BOARD_YAML_DOC = "../docs/board-yaml.md"


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

    # ------------------------------- drc_geometric: per-net-class minima --
    #
    # GC1's and GC2's floors are the global ManufacturingConstraints minima RAISED
    # by the net class in play (`_net_class_minima` -> `_effective_min_trace_width`
    # / `_effective_min_clearance`, docket 019f958b45b9). None of the four entries
    # above touch that logic, so without these the sweep would keep reporting a
    # healthy number while measuring nothing about it.
    #
    # Each entry names the test expected to kill it. An unnamed killer is one
    # refactor away from becoming a silent survivor, because "still killed by
    # SOMETHING" hides the loss of the test that was actually load-bearing.
    {
        "id": "drcgeo_gc1_class_width_floor_ignores_the_traces_own_net",
        "file": DRC_GEOM,
        "kind": "half",
        "find": L(
            "    entry = minima.get(net_id) if net_id is not None else None",
            "    if entry is None or entry[0] is None:",
            "        return global_min",
            "    return max(global_min, entry[0])",
        ),
        "replace": L(
            "    floors = [e[0] for e in minima.values() if e[0] is not None]",
            "    return max([global_min] + floors)  # MUTANT: board-wide, not per-net",
        ),
        # KILLER: test_drc_geometric.py::
        #   test_gc1_flags_the_classed_net_and_clears_an_unclassed_net_at_the_same_width
        "rationale": "Collapses GC1's per-net width floor to ONE board-wide scalar: "
                     "the strictest class's floor is applied to every trace, so an "
                     "UNCLASSED net is held to a floor no rule gives it. This is the "
                     "shape the whole feature is satisfiable by if net scoping is "
                     "never asserted, which is why the scoping test exists.",
    },
    {
        "id": "drcgeo_gc2_class_clearance_floor_ignores_the_pairs_own_nets",
        "file": DRC_GEOM,
        "kind": "half",
        "find": L(
            "    floor = global_min",
            "    for net_id in net_ids:",
            "        entry = minima.get(net_id) if net_id is not None else None",
            "        if entry is not None and entry[1] is not None:",
            "            floor = max(floor, entry[1])",
            "    return floor",
        ),
        "replace": L(
            "    floor = global_min",
            "    for entry in minima.values():  # MUTANT: board-wide, not per-pair",
            "        if entry[1] is not None:",
            "            floor = max(floor, entry[1])",
            "    return floor",
        ),
        # KILLER: test_drc_geometric.py::
        #   test_gc2_flags_the_classed_pair_and_clears_an_unclassed_pair_at_the_same_gap
        "rationale": "The GC2 twin of the entry above: every PAIR is compared against "
                     "the board's strictest class rather than its own two "
                     "participants' classes, so an unclassed-to-unclassed pair is "
                     "flagged for violating a rule neither net carries.",
    },
    {
        "id": "drcgeo_gc2_broad_phase_swept_at_the_global_floor",
        "file": DRC_GEOM,
        "kind": "half",
        "find": "    sweep_margin = _effective_min_clearance(global_min, minima, *minima)",
        "replace": "    sweep_margin = global_min  # MUTANT: un-inflated sweep margin",
        # KILLERS: test_drc_geometric.py::
        #   test_gc2_flags_a_pair_the_global_margin_would_have_pruned  (the false
        #     clean itself), and
        #   test_gc2_sweeps_the_broad_phase_at_exactly_the_board_wide_maximum
        "rationale": "Sweeps the broad phase at the GLOBAL clearance floor while a "
                     "class demands more. `_broad_phase_pairs` prunes anything beyond "
                     "2 x margin, so a pair that violates the class floor but clears "
                     "twice the global one is discarded BEFORE it is measured — a "
                     "false clean produced entirely by the pruning, with the per-pair "
                     "comparison left correct.",
    },
    {
        "id": "drcgeo_gc2_broad_phase_swept_at_infinity",
        "file": DRC_GEOM,
        "kind": "half",
        "find": "    sweep_margin = _effective_min_clearance(global_min, minima, *minima)",
        "replace": '    sweep_margin = float("inf")  # MUTANT: sweep never prunes',
        # KILLER (SOLE): test_drc_geometric.py::
        #   test_gc2_sweeps_the_broad_phase_at_exactly_the_board_wide_maximum
        # No findings-based test can see this one — it changes no verdict at all.
        "rationale": "The opposite error to the entry above, and the one no assertion "
                     "about FINDINGS can catch: an infinite margin is SUFFICIENT for "
                     "correctness but not MINIMAL, so GC2 silently degrades to "
                     "all-pairs on every board forever. Kept because 'nothing stops a "
                     "caller passing inf' is a real review finding, and the only "
                     "defence is a test that reads the margin itself.",
    },
    {
        "id": "drcgeo_class_width_floor_lowers_instead_of_raises",
        "file": DRC_GEOM,
        "kind": "half",
        "find": "    return max(global_min, entry[0])",
        "replace": "    return min(global_min, entry[0])  # MUTANT: max -> min",
        # KILLER: test_drc_geometric.py::
        #   test_net_class_min_trace_width_below_the_global_floor_cannot_weaken_it
        "rationale": "Composes the class term with min() instead of max(), so a class "
                     "minimum BELOW the manufacturing floor RELAXES it — the global "
                     "floor stops being a hard lower bound and copper the fab cannot "
                     "make is certified clean.",
    },
    {
        "id": "drcgeo_class_width_admission_predicate_dropped",
        "file": DRC_GEOM,
        "kind": "full",
        "find": "            width = positive_mm(nc.min_trace_width_mm)",
        "replace": "            width = float(nc.min_trace_width_mm)",
        # KILLER: test_drc_geometric.py::
        #   test_referenced_class_with_zero_min_trace_width_is_indeterminate
        "rationale": "Drops the fail-closed admission on a class WIDTH, so a class "
                     "authoring min_trace_width_mm: 0 is silently reinterpreted as "
                     "'no floor' instead of returning indeterminate. Routing refuses "
                     "the same value through the same predicate, so this is also the "
                     "two surfaces disagreeing about one class.",
    },
    {
        "id": "drcgeo_class_clearance_admission_predicate_dropped",
        "file": DRC_GEOM,
        "kind": "full",
        "find": "            clearance = nonnegative_mm(nc.min_clearance_mm)",
        "replace": "            clearance = float(nc.min_clearance_mm)",
        # KILLER: test_drc_geometric.py::
        #   test_a_class_clearance_that_is_not_a_sourceable_number_fails_closed
        "rationale": "The clearance half of the entry above — the second of the two "
                     "fail-closed dimensions. A non-sourceable class clearance stops "
                     "raising and becomes a silent no-op under max() (max(0.2, nan) "
                     "returns 0.2), while routing still fails closed on it.",
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
    {
        # Added in T0 wave 2. NOTE FOR WHOEVER READS THE SWEEP: this mutant is
        # KILLED, and was killed BEFORE the loop-assertion tightening that
        # prompted it — `test_smart_remote_structure` already pins
        # `len(board.holes) == 4`. It earns its place on the defect shape, not on
        # having exposed a gap: silently dropping every NPTH hole means the drill
        # file loses mounting holes while the board still looks well-formed.
        "id": "compile_unplated_holes_silently_dropped",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": "            holes.append(ResolvedHole(",
        "replace": L(
            "            if not raw_plated:",
            "                continue",
            "            holes.append(ResolvedHole(",
        ),
        "rationale": "Emits plated holes but silently drops unplated ones, so a board's "
                     "NPTH mounting holes vanish from the IR (and the drill file) while "
                     "every plated hole still arrives.",
    },
    {
        # Added in T0 wave 2. Also killed pre-tightening, by the same
        # `test_smart_remote_structure` census (`len(board.vias) == 4`).
        # `full` because this entry drops EVERY via unconditionally. An earlier
        # draft of this comment justified that by claiming no one-sided shape
        # exists here — that was FALSE and a cold review measured it so:
        # `raw_tented` is in scope immediately above and partitions the
        # collection. The half it exposes is now carried separately as
        # `compile_untented_vias_silently_dropped` below.
        "id": "compile_vias_constructed_then_discarded",
        "file": COMPILE_BOARD,
        "kind": "full",
        "find": "        vias.append(ResolvedVia(",
        "replace": "        _dropped_via = (ResolvedVia(",
        "rationale": "Builds each via — so every per-via validation still runs and still "
                     "reports — then throws it away instead of accumulating it, the "
                     "shape a refactor that loses an accumulator leaves behind.",
    },
    {
        # Added in T0 wave 2, on a cold review's measurement, after the author
        # wrongly asserted no `half` shape existed at this site. This is the
        # SHARP one of the three: measured killed by only 4 tests, ALL of them
        # tenting-specific, and it SURVIVES `test_smart_remote_structure`'s
        # `len(board.vias) == 4` census AND the vacuity guard in
        # test_smart_remote_vias_are_through.
        #
        # WHY it survives those two, stated correctly because a first draft of
        # this comment stated it backwards: `if not raw_tented` drops the
        # UNTENTED vias and keeps the tented ones. Every via on the smart-remote
        # fixture is tented (measured: tented_front/tented_back True on all 4),
        # so that board loses nothing and its count-based tests never notice.
        # The dropped case is only represented on the tenting fixtures.
        # A four-test margin on a fab-visible property is worth knowing about.
        "id": "compile_untented_vias_silently_dropped",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": "        vias.append(ResolvedVia(",
        "replace": L(
            "        if not raw_tented:",
            "            continue",
            "        vias.append(ResolvedVia(",
        ),
        "rationale": "Emits tented vias but silently drops untented ones, so a board's "
                     "mask-opened vias vanish from the IR while tented ones still "
                     "arrive — the one-sided counterpart to the unconditional drop above.",
    },

    # --- K21 board-house profiles (019f762004dc) ---------------------------
    {
        "id": "compileboard_authored_rule_profile_selection_ignored",
        "file": COMPILE_BOARD,
        "kind": "full",
        "find": '    profile_id = rules.get("rule_profile")',
        "replace": '    profile_id = None  # MUTANT: authored profile selection ignored',
        # KILLER: tests/test_compile_board.py::test_a_board_can_select_a_named_board_house_profile
        # (also tests/test_drc_geometric.py::test_two_profiles_same_board_different_verdicts)
        "rationale": "THE LAZY IMPLEMENTATION K21's acceptance wording is aimed at: the "
                     "profile subsystem loads and pins, but a board's own "
                     "design_rules.rule_profile is never actually read, so every board "
                     "silently compiles against v1 regardless of what it selects — a "
                     "profile 'loaded and recorded that changes no verdict' (the brief's "
                     "own phrase for the lazy fix this corpus entry is shaped on).",
    },
    {
        "id": "compileboard_rule_profile_reported_but_not_enforced",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": "        minimums=_floor_with_clearance(profile.floor, float(clearance)),",
        "replace": L(
            "        minimums=_floor_with_clearance(",
            "            _default_rule_profile().floor, float(clearance)),",
            "        # MUTANT: enforcement floor pinned to the default regardless of selection",
        ),
        # KILLER: tests/test_drc_geometric.py::test_two_profiles_same_board_different_verdicts
        # (the OSH Park compile stays "clean" instead of "violations"; the
        # rule_profile.id/digest reporting assertions in the SAME test still
        # pass, which is why they alone cannot be the acceptance test.)
        "rationale": "THE HALF THAT LOOKS WHOLE: design_rules.rule_profile and "
                     "provenance.rule_profile_ref still carry the SELECTED profile's ref "
                     "(drc_geometric's 'rule_profile' reporting stays correct), but the "
                     "floor that actually gates DRC findings stays v1's regardless of "
                     "selection. A test that only checks the reported id/digest — half of "
                     "K21's acceptance criterion — cannot see this; only a verdict "
                     "comparison can (brief R2's explicit warning against mistaking the "
                     "reporting half for the whole).",
    },

    # --- manufacturer_profile: fail-closed floor loading (019f762004dc) ----
    {
        "id": "manufacturerprofile_missing_field_guard_removed",
        "file": MANUFACTURER_PROFILE,
        "kind": "full",
        "find": L(
            "    missing = [key for key in REQUIRED_FLOOR_FIELDS if key not in floor]",
            "    if missing:",
            "        raise RuleProfileError(",
            '            f"rule profile {profile_id!r} floor is missing field(s) {\'/\'.join(missing)}; "',
            '            f"a profile must supply all ten ManufacturingConstraints fields or fail "',
            '            f"(no merge with another profile\'s defaults)")',
        ),
        "replace": "    missing = []  # MUTANT: missing-field guard removed entirely",
        # KILLER: tests/test_manufacturer_profile.py::
        #   test_a_floor_missing_any_single_field_fails_closed_not_merged[[]*10]
        # (all ten parametrizations; each now raises a bare KeyError instead
        # of RuleProfileError, which pytest.raises(RuleProfileError) does not
        # catch) and test_compile_board.py::
        #   test_a_profile_missing_a_field_fails_the_whole_compile_closed_never_merged.
        "rationale": "Removes the ten-fields-or-fail gate outright, so a profile file "
                     "missing any ManufacturingConstraints key is no longer refused before "
                     "reaching ManufacturingConstraints(**numeric_floor) — the exact "
                     "'merge with v1 defaults' failure shape the brief names by name, "
                     "just without even a merge: here the missing key crashes downstream "
                     "instead of being silently filled, which is still a fail-OPEN in the "
                     "sense that the intended fail-CLOSED diagnostic (RuleProfileError "
                     "naming the missing field) never fires.",
    },
    {
        "id": "manufacturerprofile_one_required_field_exempted_from_the_check",
        "file": MANUFACTURER_PROFILE,
        "kind": "half",
        "find": "    missing = [key for key in REQUIRED_FLOOR_FIELDS if key not in floor]",
        "replace": L(
            "    missing = [key for key in REQUIRED_FLOOR_FIELDS if key not in floor",
            '                and key != "solder_mask_expansion_mm"]',
            "    # MUTANT: one of the ten required fields silently exempted from the gate",
        ),
        # KILLER: tests/test_manufacturer_profile.py::
        #   test_a_floor_missing_any_single_field_fails_closed_not_merged[solder_mask_expansion_mm]
        # ONLY that one parametrization; the other nine still pass, which is
        # exactly the point of parametrizing over every field instead of
        # picking one representative.
        "rationale": "ONE OF TEN, not all ten: the same shape as "
                     "compileboard_net_class_min_clearance_parsed_then_dropped above — a "
                     "single field's completeness check quietly goes missing while the "
                     "other nine still gate correctly, so a test suite that only tries "
                     "ONE representative missing-field case (instead of every field) would "
                     "call this profile subsystem complete while a real board house's "
                     "profile missing exactly this key compiles anyway.",
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

    # --- AUTHORED NET CLASSES (905ce82) ------------------------------------
    #
    # A board now AUTHORS net classes under `design_rules.net_classes`, each
    # class naming its `members`; the compiler inverts those member lists into
    # `ResolvedNet.net_class_id`, and BOTH consumers
    # (`methods._net_class_overrides`, `drc_geometric._net_class_minima`) read
    # REFERENCED classes only. Everything upstream of that inversion is
    # therefore satisfiable WITHOUT it: a compiler that parses the block,
    # populates `design_rules.net_classes`, and never assigns a single
    # `net_class_id` passes every "classes are authorable" assertion while both
    # consumers still see nothing. That is the round's core risk and the first
    # two entries below are aimed straight at it.
    #
    # FOUR entries, chosen against a hard budget of four (corpus 40 -> 44, the
    # ceiling). They are picked for KILL POWER AND INDEPENDENCE, not for
    # covering every diagnostic the round added: the membership/identity
    # diagnostics (duplicate class name, unknown member, one net in two classes)
    # are each killed by a dedicated fail-closed test that a deletion would take
    # out loudly, whereas the four below guard the SILENT failures.
    {
        "id": "compileboard_net_class_id_never_assigned",
        "file": COMPILE_BOARD,
        "kind": "full",
        "find": "                                net_class_id=class_id_by_net.get(name)))",
        "replace": "                                net_class_id=None))  # MUTANT: never wired",
        # KILLER: tests/test_route_rules.py::
        #   test_an_authored_net_class_routes_that_nets_own_copper_at_the_class_width
        # (5 more: the GC1/GC2 authored-floor pair in test_drc_geometric.py, the
        # authored-clearance routing test, and the two IR-level wiring tests.)
        "rationale": "THE LAZY IMPLEMENTATION. Classes are still parsed and still "
                     "reach design_rules.net_classes, but no net ever carries an id, "
                     "so both consumers — which read REFERENCED classes only — go on "
                     "seeing nothing while the feature looks authorable. Measured "
                     "killed by 6 tests across all three modules; if that number "
                     "falls to zero the round's headline capability is untested.",
    },
    {
        "id": "compileboard_net_class_assigned_to_every_net_not_its_members",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": "                                net_class_id=class_id_by_net.get(name)))",
        "replace": L(
            "                                net_class_id=next(",
            "                                    iter(class_id_by_net.values()), None)))"
            "  # MUTANT: first class, every net",
        ),
        # KILLER: tests/test_drc_geometric.py::
        #   test_an_authored_net_class_clearance_does_not_reach_an_unclassed_pair
        "rationale": "MISPAIRED, NOT DROPPED — the same site as the entry above and "
                     "deliberately so, because the two fail differently: here every "
                     "net DOES get an id, just the wrong one. Only a fixture carrying "
                     "a classed AND an unclassed net can tell the two apart, which is "
                     "why the named killer is the negative test rather than any "
                     "positive one. A corpus that holds only the 'dropped' shape lets "
                     "a single-net fixture look adequate forever.",
    },
    {
        "id": "compileboard_net_class_min_clearance_parsed_then_dropped",
        "file": COMPILE_BOARD,
        "kind": "half",
        "find": '        min_clearance = _net_class_minimum(entry, "min_clearance_mm", name, diags)',
        "replace": "        min_clearance = None  # MUTANT: authored clearance discarded",
        # KILLER: tests/test_drc_geometric.py::
        #   test_an_authored_net_class_raises_this_pairs_gc2_floor
        "rationale": "ONE OF THE TWO AUTHORABLE DIMENSIONS, silently discarded: width "
                     "still works, so every width test stays green and half the "
                     "feature is dead. Clearance reached both consumers only through "
                     "synthetic dataclasses.replace helpers until this round, which is "
                     "exactly the state this entry exists to stop returning to.",
    },
    {
        "id": "docs_board_yaml_schema_example_regains_a_fatal_rule",
        "file": BOARD_YAML_DOC,
        "kind": "full",
        "find": L(
            "  via_drill_mm: 0.4",
            "  net_classes:                 # optional",
        ),
        "replace": L(
            "  via_drill_mm: 0.4",
            "  diff_pair_gap_mm: 0.15  # MUTANT: fatal whenever 'rules' is requested",
            "  net_classes:                 # optional",
        ),
        # KILLER: tests/test_compile_board.py::
        #   test_every_yaml_example_in_board_yaml_md_compiles
        "rationale": "THE ONLY ENTRY TARGETING TEST INPUT RATHER THAN SOURCE. The "
                     "canonical schema example had rotted to where it failed FIVE ways "
                     "at once while reading as authoritative; the doc is now executable "
                     "and this is what keeps it that way. Reproduces the exact defect "
                     "review caught — diff-pair rules are fatal under every production "
                     "output profile. If this survives, the schema doc is back to being "
                     "proofread instead of compiled.",
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
    # SIZE BAND — a COST guard, not a correctness one: every entry costs ~180s of
    # sweep, and the corpus is meant to be chosen for spread, not grown for volume.
    # The ceiling moved 36 -> 44 when the per-net-class minima landed in
    # drc_geometric (019f958b45b9): that round added ~250 lines of new fail-closed
    # logic across three functions with two independent floor dimensions, a broad
    # phase whose margin must be both sufficient AND minimal, and per-net scoping
    # that a single board-wide scalar would otherwise satisfy. Six entries was the
    # reviewed MINIMUM to cover it and the seventh is the GC2 twin of the scoping
    # one; there was no way to fit that under 36 without dropping coverage the
    # round was gated on. Raise this only with the same kind of reason.
    #
    # The ceiling moved 44 -> 56 at the epoch-2 boundary (019f783860c8). That
    # epoch shipped FIVE new fail-closed surfaces, not one: exact swept-cell
    # traversal replacing a point-sampling clearance predicate (pathfinder
    # ._swept_cells), copper-on-an-unemitted-layer promoted from warning to
    # error (compile_board._is_emitted_layer), a new .kicad_pcb existing-copper
    # parser whose net resolution is silently wrong if it carries an int
    # (agent_router.kicad_io), a ten-fields-or-fail board-house profile loader
    # (manufacturer_profile), and a stroke font emitting silk text. Only the
    # profile loader arrived with entries (4, taking the corpus to 48); the
    # other four owe theirs and are tracked. The 8 remaining slots are
    # allocated to exactly those four — they are not headroom for volume, and
    # the next raise past 56 needs its own reason.
    #
    # Cost at 56: ~180s each over -j 6 is roughly half an hour, which is a
    # phase-boundary price, not a per-round one. That is the number to
    # re-examine if the ceiling is ever pushed again.
    if not 24 <= len(MUTANTS) <= 56:
        raise SystemExit(f"corpus size {len(MUTANTS)} outside the 24..56 band")
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
