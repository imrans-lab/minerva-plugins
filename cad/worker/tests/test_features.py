"""Cylindrical features read off the B-Rep: the axes every fastener number rests on.

WHAT WOULD SHOW THIS WRONG (the oracle for the whole file)
A part whose bores were WRITTEN as numbers in the DSL. Every fixture below
places a cylinder at a stated centre, radius and length, and the assertions
compare what comes back against those literals — not against anything the code
under test derived. A caller with a pair of callipers and the source would get
the same numbers.

The second oracle is the SENSE. A hole and a boss have the same cylindrical
surface and differ only in which side the material is on, so a reader that gets
orientation wrong reports every bore as a boss and every boss as a bore and
still returns plausible-looking geometry. Each fixture therefore contains one
of each, at radii that cannot be confused, and asserts which is which.

31 tests. The ones that translate DSL need build123d/OCP, which ships in the
plugin's embedded runtime bundle and is not on a plain CI runner, so they skip
there. The refusals and every `_merge` test run unconditionally — the merge is
pure arithmetic over face records — so a skipped suite can never mean "the
method quietly stopped existing" or "the sweep stopped being a coverage".
"""

from __future__ import annotations

import math

import pytest

from mcad_worker import features as feat

# --- the fixture, in millimetres -------------------------------------------
# A 40 x 40 x 10 plate, corner at the origin (mcad's cube() convention), with:
#   a through bore of radius 3 on the axis x=10, y=10
#   a blind bore of radius 2, 6 deep, on the axis x=30, y=10
#   a boss (a standing pin) of radius 4, 8 tall, on the axis x=10, y=30
# Every one of those numbers is asserted back.
PLATE = "plate = cube(40, 40, 10)"
THROUGH_R = 3.0
THROUGH_XY = (10.0, 10.0)
BLIND_R = 2.0
BLIND_XY = (30.0, 10.0)
BLIND_DEPTH = 6.0
BOSS_R = 4.0
BOSS_XY = (10.0, 30.0)
BOSS_H = 8.0

SOURCE = "\n".join([
    PLATE,
    # A through bore: taller than the plate and started below it, so it cuts
    # cleanly through both faces rather than leaving a skin.
    "through = translate([%g, %g, -2], cylinder(r=%g, h=14))" % (
        THROUGH_XY[0], THROUGH_XY[1], THROUGH_R),
    # A blind bore: cut down from the top face, leaving 4 mm of floor.
    "blind = translate([%g, %g, %g], cylinder(r=%g, h=%g))" % (
        BLIND_XY[0], BLIND_XY[1], 10.0 - BLIND_DEPTH, BLIND_R, BLIND_DEPTH + 2.0),
    "boss = translate([%g, %g, 10], cylinder(r=%g, h=%g))" % (
        BOSS_XY[0], BOSS_XY[1], BOSS_R, BOSS_H),
    "part = plate - through - blind + boss",
])

#: The kernel's own numbers are exact; this only absorbs float formatting.
TOL_MM = 1.0e-6


def _features(**params):
    """Run the method on SOURCE and return its result, failing loudly on error."""
    return _features_of(SOURCE, **params)


def _features_of(source, **params):
    """The same, over a source the caller supplies."""
    pytest.importorskip("build123d")
    reply = feat.cylindrical_features(dict(params, source=source))
    assert reply["ok"], reply.get("error")
    return reply["result"]


def _find(cylinders, radius, xy):
    """The one cylinder at this radius and this axis position, or None."""
    for entry in cylinders:
        if abs(entry["radius_mm"] - radius) > 1.0e-4:
            continue
        centre = entry["centre_mm"]
        if abs(centre[0] - xy[0]) < 1.0e-4 and abs(centre[1] - xy[1]) < 1.0e-4:
            return entry
    return None


class TestGeometry:
    """The numbers, against the literals the DSL was written with."""

    def test_every_bore_and_the_boss_are_found_once(self):
        result = _features()
        assert result["units"] == "mm"
        radii = sorted(round(c["radius_mm"], 6) for c in result["cylinders"])
        assert radii == sorted([BLIND_R, THROUGH_R, BOSS_R]), radii
        # One entry per surface, not one per FACE: OCCT splits a full cylinder
        # at its seam, so a reader that did not merge would report six.
        assert result["count"] == 3, result["cylinders"]
        assert result["faces_examined"] >= result["count"]

    def test_a_bore_is_concave_and_a_boss_is_convex(self):
        result = _features()
        bore = _find(result["cylinders"], THROUGH_R, THROUGH_XY)
        boss = _find(result["cylinders"], BOSS_R, BOSS_XY)
        assert bore is not None and boss is not None, result["cylinders"]
        assert bore["sense"] == "concave"
        assert boss["sense"] == "convex"

    def test_a_mirrored_part_keeps_a_bore_a_bore(self):
        """The sense survives an INDIRECT axis system, where it flips twice.

        A mirror leaves every cylindrical surface with a left-handed
        coordinate system, and the kernel compensates by reversing the faces
        that use it. A reader that consults only the surface's handedness, or
        only the face's orientation, reports every bore in a mirrored part as
        a boss and every boss as a bore — plausible geometry, inverted. Both
        flips have to be applied, and here they cancel.
        """
        mirrored = SOURCE.replace(
            "part = plate - through - blind + boss",
            "part = mirror([1, 0, 0], plate - through - blind + boss)")
        cylinders = _features_of(mirrored)["cylinders"]
        bore = _find(cylinders, THROUGH_R, (-THROUGH_XY[0], THROUGH_XY[1]))
        boss = _find(cylinders, BOSS_R, (-BOSS_XY[0], BOSS_XY[1]))
        assert bore is not None and boss is not None, cylinders
        assert bore["sense"] == "concave"
        assert boss["sense"] == "convex"

    def test_the_axis_is_the_one_the_dsl_placed(self):
        bore = _find(_features()["cylinders"], THROUGH_R, THROUGH_XY)
        origin = bore["axis"]["origin_mm"]
        direction = bore["axis"]["direction"]
        assert origin[0] == pytest.approx(THROUGH_XY[0], abs=TOL_MM)
        assert origin[1] == pytest.approx(THROUGH_XY[1], abs=TOL_MM)
        # cylinder()'s axis is +Z; either sense of it is the same line, and the
        # panel aligns the sign against the hole it is paired with.
        assert abs(direction[2]) == pytest.approx(1.0, abs=TOL_MM)
        assert abs(direction[0]) < TOL_MM and abs(direction[1]) < TOL_MM

    def test_a_through_bore_spans_the_whole_plate_and_a_blind_one_does_not(self):
        cylinders = _features()["cylinders"]
        through = _find(cylinders, THROUGH_R, THROUGH_XY)
        blind = _find(cylinders, BLIND_R, BLIND_XY)
        # The bore is cut by a taller cylinder, so the SURFACE that survives in
        # the solid is exactly the plate's thickness.
        assert through["length_mm"] == pytest.approx(10.0, abs=1.0e-4)
        assert blind["length_mm"] == pytest.approx(BLIND_DEPTH, abs=1.0e-4)
        assert blind["centre_mm"][2] == pytest.approx(10.0 - BLIND_DEPTH / 2.0, abs=1.0e-4)

    def test_a_boss_reports_its_own_height(self):
        boss = _find(_features()["cylinders"], BOSS_R, BOSS_XY)
        assert boss["length_mm"] == pytest.approx(BOSS_H, abs=1.0e-4)
        assert boss["dia_mm"] == pytest.approx(BOSS_R * 2.0, abs=TOL_MM)

    def test_start_mm_is_zero_and_end_mm_is_the_length(self):
        """The origin is moved onto the feature, so no caller has to guess."""
        for entry in _features()["cylinders"]:
            assert entry["start_mm"] == 0.0
            assert entry["end_mm"] == pytest.approx(entry["length_mm"], abs=TOL_MM)
            origin = entry["axis"]["origin_mm"]
            direction = entry["axis"]["direction"]
            midpoint = [
                origin[i] + direction[i] * entry["length_mm"] / 2.0 for i in range(3)
            ]
            assert entry["centre_mm"] == pytest.approx(midpoint, abs=1.0e-6)

    def test_a_full_bore_sweeps_a_full_turn(self):
        for entry in _features()["cylinders"]:
            assert entry["sweep_deg"] == pytest.approx(360.0, abs=0.5), entry
            assert entry["closed"] is True

    def test_a_fillet_is_not_a_hole(self):
        """The merge is what makes `closed` mean anything.

        A rounded corner is a cylindrical surface too, and a check that treated
        every cylinder as a fastener feature would try to put a screw in one.
        """
        pytest.importorskip("build123d")
        source = "\n".join([
            "block = cube(20, 20, 10)",
            "fillet block, [1], r=2",
            "part = block",
        ])
        reply = feat.cylindrical_features({"source": source, "closed_only": True})
        assert reply["ok"], reply.get("error")
        assert reply["result"]["count"] == 0, reply["result"]["cylinders"]
        open_reply = feat.cylindrical_features({"source": source})
        assert open_reply["ok"], open_reply.get("error")
        rounds = open_reply["result"]["cylinders"]
        assert rounds, "the fillet's own cylindrical face should still be listed"
        assert all(not c["closed"] for c in rounds)
        assert all(c["sweep_deg"] < 180.0 for c in rounds)


class TestFilters:
    """The windows the panel narrows the question with."""

    def test_sense_selects_bores_or_bosses(self):
        concave = _features(sense="concave")["cylinders"]
        convex = _features(sense="convex")["cylinders"]
        assert {c["sense"] for c in concave} == {"concave"}
        assert {c["sense"] for c in convex} == {"convex"}
        assert len(concave) + len(convex) == _features()["count"]

    def test_the_diameter_window_is_inclusive_of_its_bounds(self):
        """min == max == the diameter itself must still match.

        A window written with `<` instead of `<=` passes any test whose bounds
        straddle the value, and fails only when they touch it — so the bounds
        are set ON the blind bore's 4.0 mm diameter, exactly.
        """
        exact = _features(min_dia_mm=BLIND_R * 2.0, max_dia_mm=BLIND_R * 2.0)
        assert exact["count"] == 1, exact["cylinders"]
        assert exact["cylinders"][0]["radius_mm"] == pytest.approx(BLIND_R, abs=TOL_MM)
        # And the neighbours really are outside it, so the window did the work.
        assert _features(min_dia_mm=THROUGH_R * 2.0,
                         max_dia_mm=THROUGH_R * 2.0)["count"] == 1

    def test_every_reply_says_the_numbers_are_exact(self):
        result = _features()
        assert result["exact"] is True
        assert "tessellation" in result["bound"]


class TestRefusals:
    """Run everywhere, so a skipped suite cannot hide a missing method."""

    def test_a_request_with_no_source_is_refused_by_name(self):
        reply = feat.cylindrical_features({})
        assert reply["ok"] is False
        assert "source" in reply["error"]["message"]

    def test_an_unknown_sense_is_refused_rather_than_ignored(self):
        reply = feat.cylindrical_features({"source": PLATE, "sense": "inside-out"})
        assert reply["ok"] is False
        assert "inside-out" in reply["error"]["message"]

    def test_a_document_with_no_solid_says_so(self):
        pytest.importorskip("build123d")
        reply = feat.cylindrical_features({"source": 'ref = mesh("board.glb")'})
        assert reply["ok"] is False
        assert "no 3D part" in reply["error"]["message"]

    def test_the_method_is_reachable_through_the_dispatcher(self):
        """The wire, not the arithmetic: an unrouted method is a silent no-op."""
        from mcad_worker import methods

        reply = methods.handle_request(
            {"id": 1, "method": "cylindrical_features", "params": {}}
        )
        assert reply["id"] == 1
        assert reply["ok"] is False
        # Refused for the missing source, NOT as "unknown method".
        assert "unknown method" not in reply["error"]["message"]


class TestTrimmedExtent:
    """A cut that is not perpendicular to the axis shortens the bore."""

    def test_a_bore_cut_by_a_tilted_face_reports_the_length_it_really_has(self):
        """The extent is the range of the face's OWN boundary.

        A 40 x 40 x 10 plate, its top lopped off by a plane tilted 20 degrees,
        with a through bore of radius 3 ON the tilt axis — so the trim curve is
        symmetric about it and the answer needs no sign convention to predict.
        The bore then runs from the plate's underside at z = -10 up to the
        HIGHEST point of that trim, which is 3 * tan(20 deg) above the plane's
        own height of -2.

            length = (-2 + 3 * tan 20) - (-10) = 8 + 1.09191 = 9.09191 mm

        ORACLE: the arithmetic in that line, done by hand from the DSL. A bore
        measured from anything other than its real trim reports the full 10 mm
        of plate, and a fastener graded on it engages a boss that is not there.

        The bore therefore has TWO lengths, and the reply carries both:

            extent_max_mm  = 8 + 3 tan 20 = 9.09191 mm, to the highest rim
                             point — how far the WALL reaches.
            extent_full_mm = 8 - 3 tan 20 = 6.90809 mm, the stretch that is
                             there at EVERY azimuth — how far a screw can
                             engage, since above it the thread exists on one
                             side of the axis only.

        ORACLE: both lines of arithmetic, done by hand from the DSL. Grading
        engagement on the max reports a screw as held by a boss that is only
        half there.

        HONEST NOTE: for a SINGLE face, BRepTools.UVBounds_s would give the
        same MAX here, because v IS the axial coordinate and the box of the
        boundary's v-values is the boundary's own range. What the boundary
        sampling buys is the SWEEP — see TestMerging below, where two patches
        covering the same arc no longer add up to a hole — and the
        per-azimuth extent this test's second number rests on.
        """
        pytest.importorskip("build123d")
        source = "\n".join([
            "plate = translate([-20, -20, -10], cube(40, 40, 10))",
            "bore = translate([0, 0, -12], cylinder(r=3, h=14))",
            # A half-space whose boundary plane passes through the origin, so
            # rotating it about Y leaves that plane through the origin, and
            # the translate then puts it at z = -2.
            "slab = translate([0, 0, -2], "
            "rotate([0, -20, 0], translate([-100, -100, 0], cube(200, 200, 50))))",
            "part = plate - bore - slab",
        ])
        reply = feat.cylindrical_features({"source": source, "sense": "concave"})
        assert reply["ok"], reply.get("error")
        bores = reply["result"]["cylinders"]
        assert len(bores) == 1, bores
        reach = 3.0 * math.tan(math.radians(20.0))
        assert bores[0]["length_mm"] == pytest.approx(8.0 + reach, abs=1.0e-3)
        assert bores[0]["extent_max_mm"] == pytest.approx(8.0 + reach, abs=1.0e-3)
        # The full-turn extent is measured per angular bin, so it carries the
        # bin width's worth of quantisation and nothing more.
        assert bores[0]["extent_full_mm"] == pytest.approx(8.0 - reach, abs=0.02)
        assert bores[0]["extent_full_mm"] < bores[0]["extent_max_mm"]
        assert bores[0]["length_mm"] < 10.0
        assert bores[0]["extent_exact"] is True
        # The full-turn number is read in angular bins, so it is never exact
        # and carries the bin's own resolution as an error bar. The reported
        # value must sit inside that bar of the hand-computed one, and the bar
        # must be a small fraction of the extent rather than a token.
        assert bores[0]["extent_full_exact"] is False
        bound = bores[0]["extent_full_bound_mm"]
        assert 0.0 < bound < 0.5, bound
        assert abs(bores[0]["extent_full_mm"] - (8.0 - reach)) <= bound
        assert bores[0]["bin_deg"] == pytest.approx(360.0 / feat.ANGULAR_BINS)
        # The bound is a sum of named parts, not a number from nowhere.
        parts = bores[0]["extent_full_bound_parts"]
        assert bores[0]["extent_full_bound_mm"] == pytest.approx(
            2.0 * (parts["bin_step_mm"] + parts["hidden_in_bin_mm"]
                   + parts["sampling_deflection_mm"]))
        # The boundary was sampled by deflection, so the bound is a bound and
        # not a floor: a spike between two samples is inside it by
        # construction.
        assert bores[0]["extent_full_bounded"] is True
        assert bores[0]["boundary_deflection_mm"] == pytest.approx(
            feat.EDGE_DEFLECTION_MM)


class TestSmallBore:
    """The bore a fastener check actually meets, at the size it meets it."""

    def test_a_real_m2_bore_reads_as_closed_with_its_own_length(self):
        """A 2.4 mm hole, translated through the kernel and read back.

        THE REGRESSION THIS EXISTS FOR. The boundary is sampled by DEFLECTION,
        which places points where the curvature asks for them: a 1.2 mm rim at
        0.01 mm of deflection needs only about two dozen points on a full
        turn, one every fifteen degrees. Binning those POINTS leaves two bins
        in three empty, the sweep reads about 120 degrees, and a drilled hole
        is reported as a partial cylinder that no screw may be paired with.
        Binning the SEGMENTS between them is what makes the coverage a
        coverage.

        ORACLE: the DSL's own literals. A 10 mm plate with a radius-1.2
        cylinder cut through it has one concave cylindrical surface, radius
        1.2, sweeping a full turn, 10 mm long — and the arithmetic is the
        plate's own thickness, not anything this code derived.
        """
        source = "\n".join([
            "plate = cube(20, 20, 10)",
            "bore = translate([10, 10, -2], cylinder(r=1.2, h=14))",
            "part = plate - bore",
        ])
        result = _features_of(source, sense="concave")
        bores = [c for c in result["cylinders"]
                 if abs(c["radius_mm"] - 1.2) < 1.0e-4]
        assert len(bores) == 1, result["cylinders"]
        bore = bores[0]
        assert bore["sweep_deg"] == pytest.approx(360.0, abs=feat.BIN_DEG)
        assert bore["closed"] is True
        assert bore["length_mm"] == pytest.approx(10.0, abs=1.0e-3)
        # Square-cut at both ends, so the stretch that goes all the way round
        # is the whole bore, less only what the measurement owes.
        assert bore["extent_full_mm"] == pytest.approx(
            10.0, abs=bore["extent_full_bound_mm"] + 1.0e-3)
        assert bore["extent_full_bounded"] is True


def _arc_face(radius, z_low, z_high, angle_from, angle_to, sense="concave",
              samples=400, low_of=None, high_of=None):
    """A stand-in face record whose boundary really covers that arc.

    The points are what `_merge` measures, so a face built here is indexed into
    angular bins exactly as a sampled OCCT boundary would be. They are also
    kept as TWO EDGES — the lower rim and the upper one — which is the shape
    OCCT hands over and the only shape a rate along the boundary can be read
    from: two samples at one azimuth on different rims are a seam, not a
    slope.

    `low_of` / `high_of` take the azimuth and return that rim's height, for a
    trim that is not perpendicular to the axis.
    """
    low_rim = []
    high_rim = []
    for i in range(samples):
        angle = angle_from + (angle_to - angle_from) * (i / float(samples - 1))
        x = radius * math.cos(angle)
        y = radius * math.sin(angle)
        low_rim.append((x, y, low_of(angle) if low_of else z_low))
        high_rim.append((x, y, high_of(angle) if high_of else z_high))
    return {
        "origin": (0.0, 0.0, 0.0),
        "direction": (0.0, 0.0, 1.0),
        "radius": radius,
        "v_min": z_low,
        "v_max": z_high,
        "sweep": abs(angle_to - angle_from),
        "points": low_rim + high_rim,
        "edges": [low_rim, high_rim],
        # Sampled the way the kernel's deflection sampler samples, which is
        # what the reported bound rests on.
        "deflection_bounded": True,
        "deflection_mm": feat.EDGE_DEFLECTION_MM,
        "sense": sense,
        "area": 1.0,
    }


class TestMerging:
    """The seam split, driven directly — it is the one step with no fixture."""

    def test_two_halves_of_one_surface_become_one_feature(self):
        """The seam split OCCT actually produces, both halves sampled.

        The second half carries the OPPOSITE axis sense and an origin further
        up the line — both of which OCCT does in practice — so this also pins
        that the group's frame, not each face's, is what the extents land in.
        """
        lower = _arc_face(1.5, 0.0, 4.0, 0.0, math.pi)
        upper = _arc_face(1.5, 0.0, 4.0, math.pi, 2 * math.pi)
        upper["origin"] = (0.0, 0.0, 4.0)
        upper["direction"] = (0.0, 0.0, -1.0)
        merged = feat._merge([lower, upper])
        assert len(merged) == 1
        entry = feat._reported(merged[0])
        assert entry["length_mm"] == pytest.approx(4.0, abs=1.0e-6)
        assert entry["sweep_deg"] == pytest.approx(360.0, abs=1.0e-6)
        assert entry["closed"] is True
        assert entry["faces"] == 2

    def test_two_patches_covering_the_SAME_arc_do_not_add_up_to_a_hole(self):
        """The discriminator for measuring sweep as coverage.

        Two half-turn patches on one cylinder line covering the same 180
        degrees — two fillets on the two edges of one rounded pocket. Summing
        their parametric spans gives 360 and calls it a closed hole, which is
        how a fastener check ends up trying to put a screw in a fillet.
        A union of occupied bins counts each part of the turn once.

        ORACLE: the geometry itself — half a cylinder is half a cylinder no
        matter how many faces it was cut into.
        """
        merged = feat._merge([
            _arc_face(1.5, 0.0, 4.0, 0.0, math.pi),
            _arc_face(1.5, 1.0, 3.0, 0.0, math.pi),
        ])
        assert len(merged) == 1
        entry = feat._reported(merged[0])
        assert entry["sweep_deg"] == pytest.approx(180.0, abs=6.0)
        assert entry["closed"] is False
        assert entry["faces"] == 2

    def test_two_bores_on_one_line_with_a_gap_are_two_features(self):
        """Collinear is not the same as continuous.

        Two 4 mm bores 10 mm apart on one axis — a hole through two plates of
        a stack, drilled to different depths. Merging them reports one 18 mm
        bore, and a screw graded against that engages air.
        """
        merged = feat._merge([
            _arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi),
            _arc_face(1.5, 14.0, 18.0, 0.0, 2 * math.pi),
        ])
        assert len(merged) == 2
        assert sorted(round(feat._reported(g)["length_mm"], 6) for g in merged) \
            == [4.0, 4.0]

    def test_a_parallel_bore_beside_it_is_a_separate_feature(self):
        pair = [_arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi),
                _arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi)]
        pair[1]["origin"] = (5.0, 0.0, 0.0)
        pair[1]["points"] = [(x + 5.0, y, z) for (x, y, z) in pair[1]["points"]]
        assert len(feat._merge(pair)) == 2

    def test_a_bore_and_a_boss_on_one_axis_do_not_merge(self):
        """A pin standing in a bore shares the axis and not the material."""
        pair = [_arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi),
                _arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi, sense="convex")]
        assert len(feat._merge(pair)) == 2

    def test_the_extent_bound_covers_a_bore_trimmed_BOTH_ways(self):
        """The bound has to be conservative at BOTH ends at once.

        A bore whose entrance rises where its exit falls: the lower rim runs
        at +a cos(theta) and the upper at H - a cos(theta), so the two trims
        tilt in opposite directions and their extremes are half a turn apart.
        The full-turn extent is then max(low rim) .. min(high rim) = a .. H - a,
        and binning can UNDER-state the start and OVER-state the end in the
        same reply — the extent comes out too long by up to both errors
        together, which is why the reported bound is twice their sum.

        ORACLE: the fixture's own rims. The true engageable stretch is
        H - 2a = 4.0 mm, computed by hand; whatever the reply says must not
        exceed it by more than the bound it reports. A bound counting one end
        only can fail this on a steeper pair of trims, and no smooth or square
        fixture can show it.
        """
        amplitude = 1.0
        height = 6.0
        face = _arc_face(
            2.0, 0.0, height, 0.0, 2 * math.pi,
            low_of=lambda a: amplitude * math.cos(a),
            high_of=lambda a: height - amplitude * math.cos(a))
        entry = feat._reported(feat._merge([face])[0])
        true_extent = height - 2.0 * amplitude
        bound = entry["extent_full_bound_mm"]
        assert bound > 0.0
        assert entry["extent_full_mm"] - true_extent <= bound
        assert entry["extent_full_mm"] >= true_extent - bound
        # And the slack that only a rate can see is really in there: these
        # rims turn, so the hidden-in-bin term is not zero.
        assert entry["extent_full_bound_parts"]["hidden_in_bin_mm"] > 0.0

    def test_a_rim_sampled_every_fifteen_degrees_still_sweeps_a_full_turn(self):
        """Coverage comes from the SEGMENTS, not from the sample points.

        Twenty-four samples on a full turn is what a 1.2 mm rim gets from a
        0.01 mm deflection sampler, and 24 points cannot fill 72 bins. A
        reader that bins points alone calls this a 120-degree partial surface;
        one that walks the chord between two samples fills every bin the chord
        crosses.

        ORACLE: the circle itself. A closed rim sweeps a full turn however
        many points were taken along it.
        """
        entry = feat._reported(feat._merge(
            [_arc_face(1.2, 0.0, 5.0, 0.0, 2 * math.pi, samples=25)])[0])
        assert entry["sweep_deg"] == pytest.approx(360.0, abs=1.0e-6)
        assert entry["closed"] is True
        assert entry["extent_full_mm"] == pytest.approx(5.0, abs=1.0e-6)

    def test_an_unreadable_rim_makes_the_whole_feature_inexact(self):
        """One rim missing is a boundary that cannot be trusted.

        An edge the kernel cannot adapt is skipped — there is nothing else to
        do with it — but what remains is only PART of the trim, and an extent
        measured from part of a trim is understated by however much the
        missing rim would have added. Reporting it as exact, with a finite
        error bar, is a bound the reply cannot honour.

        ORACLE: the flags. The face here carries the same points as an honest
        one and is marked incomplete; the feature must come back inexact and
        unbounded, so the panel grades its engagement as unknown.
        """
        face = _arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi)
        face["boundary_complete"] = False
        entry = feat._reported(feat._merge([face])[0])
        assert entry["extent_exact"] is False
        assert entry["extent_full_bounded"] is False
        assert entry["boundary_deflection_mm"] is None

    def test_a_square_cut_bore_owes_only_the_sampling_deflection(self):
        """The bound is MEASURED, not a constant.

        A bore trimmed square to its axis reaches the same height at every
        azimuth, so binning loses nothing and the trim has no slope: both
        measured terms are zero and all that is left is the deflection the
        boundary was sampled at, once for each end. A fixed bound would fail
        an honest joint by a tenth of a millimetre it does not owe.

        ORACLE: the fixture's own rim — a flat one at z = 4 for a full turn —
        and EDGE_DEFLECTION_MM, the sampler's stated guarantee.
        """
        entry = feat._reported(
            feat._merge([_arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi)])[0])
        parts = entry["extent_full_bound_parts"]
        assert parts["bin_step_mm"] == pytest.approx(0.0, abs=1.0e-9)
        assert parts["hidden_in_bin_mm"] == pytest.approx(0.0, abs=1.0e-9)
        assert entry["extent_full_bound_mm"] == pytest.approx(
            2.0 * feat.EDGE_DEFLECTION_MM)
        assert entry["extent_full_bounded"] is True
        assert entry["extent_full_mm"] == pytest.approx(4.0, abs=1.0e-6)
        assert entry["extent_full_exact"] is False

    def test_a_boundary_walked_at_a_fixed_pitch_is_not_bounded_at_all(self):
        """The honest label on the fallback.

        The deflection sampler is what makes the bound a BOUND: it promises
        the polyline stays within a stated distance of the real curve
        everywhere, so a spike between two samples is still inside the number.
        A face the sampler refused is walked at a fixed pitch instead, and
        nothing at all limits what the trim does between two of those points —
        the reply has to say so, and a consumer must not grade a threshold
        against it.

        ORACLE: the flag itself, against a face built without the sampler's
        guarantee. A reply that reports the same number in both cases without
        distinguishing them is claiming a guarantee it does not have.
        """
        face = _arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi)
        face["deflection_bounded"] = False
        face["deflection_mm"] = None
        entry = feat._reported(feat._merge([face])[0])
        assert entry["extent_full_bounded"] is False
        assert entry["boundary_deflection_mm"] is None
        assert "FLOOR" in entry["extent_full_bound"]

    def test_a_patch_that_bridges_two_others_coalesces_them(self):
        """The seam order OCCT does not promise.

        Three patches of one bore: [0,1], [2,3], and then the one that spans
        [1,2] and joins them. A merge that only asks "does this face touch a
        group I already have" leaves the bridge in whichever group it met
        first and reports TWO bores where the part has one continuous 3 mm
        one — and a screw is then graded against a third of the thread it
        really has.

        ORACLE: the intervals themselves. [0,1] u [1,2] u [2,3] = [0,3],
        whatever order the three arrive in.
        """
        patches = [_arc_face(1.5, 0.0, 1.0, 0.0, 2 * math.pi),
                   _arc_face(1.5, 2.0, 3.0, 0.0, 2 * math.pi),
                   _arc_face(1.5, 1.0, 2.0, 0.0, 2 * math.pi)]
        merged = feat._merge(patches)
        assert len(merged) == 1, [feat._reported(g)["length_mm"] for g in merged]
        assert feat._reported(merged[0])["length_mm"] == pytest.approx(3.0, abs=1.0e-6)
        assert feat._reported(merged[0])["faces"] == 3
        # And the same three in the order that already worked.
        assert len(feat._merge([patches[0], patches[2], patches[1]])) == 1

    def test_a_tilted_trim_reports_the_length_that_goes_all_the_way_round(self):
        """The two extents, driven through `_merge` alone.

        One patch whose upper rim rises and falls by 1 mm around the turn: the
        wall reaches 5 mm at its highest azimuth and 3 mm at its lowest, and
        the stretch present at every azimuth is the lower one.

        ORACLE: the rim the fixture was written with. A single reported length
        cannot be both, and reporting only the max credits a screw with
        engagement that exists on one side of the bore only.
        """
        face = _arc_face(1.5, 0.0, 5.0, 0.0, 2 * math.pi,
                         high_of=lambda a: 4.0 + math.cos(a))
        entry = feat._reported(feat._merge([face])[0])
        # A trim that rises and falls is exactly where the bin resolution
        # costs something, and the bound has to be big enough to cover the
        # step between neighbouring bins.
        assert entry["extent_full_bound_mm"] > 0.0
        assert entry["extent_max_mm"] == pytest.approx(5.0, abs=0.01)
        assert entry["extent_full_mm"] == pytest.approx(3.0, abs=0.05)
        assert entry["full_start_mm"] == pytest.approx(0.0, abs=0.01)
        assert entry["full_end_mm"] == pytest.approx(3.0, abs=0.05)

    def test_a_face_with_no_samplable_boundary_says_its_extent_is_not_exact(self):
        """The fallback exists, and it is labelled.

        A degenerate face contributes no boundary points, so the parametric
        box is used — and `extent_exact` false is how a reader knows the length
        may be the box's and not the trim's.
        """
        blind = _arc_face(1.5, 0.0, 4.0, 0.0, 2 * math.pi)
        blind["points"] = []
        blind["edges"] = []
        entry = feat._reported(feat._merge([blind])[0])
        assert entry["extent_exact"] is False
        assert entry["length_mm"] == pytest.approx(4.0, abs=TOL_MM)
