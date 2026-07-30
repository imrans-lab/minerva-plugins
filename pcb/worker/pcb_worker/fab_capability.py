"""Neutral fabrication-capability profile — the SINGLE authority shared by the
compiler and every emitter (K2 review 623, decision a).

Neither the K2 compiler nor the K3 Gerber emitter may independently own the set
of layers/outputs the toolchain can produce; both import it from here.  A drift
test (``tests/test_fab_capability.py``) asserts the live emitter's actual
artifact set equals this profile, so a future emitter change that adds or drops
a layer forces a matching, reviewed change here.

Values are today's Gerber surface (``gerber.py`` ``_GERBER_SUFFIXES`` + the
PTH/NPTH Excellon split): two copper layers, both solder masks, both paste
stencils, TOP silk, a structurally-valid BACK silk, and the board edge.  No fab
layer (see the F.Fab note below).
"""

from __future__ import annotations

# The physical layers whose CAPTURED GEOMETRY the emitter actually fabricates.
# The compiler reads this as its accept-set: participation on a layer NOT listed
# here is reported as documentation-only (``captured_geometry_not_emitted``), so
# a layer may only be added once its geometry genuinely reaches an output file.
#
# F.Fab is deliberately ABSENT and must stay absent: KiCad's own .gbrjob
# classifies F.Fab as ``AssemblyDrawing,Top`` — KiCad itself says it is not a
# fabrication layer.
#
# B.SilkS is likewise ABSENT *on purpose*, even though ``B_SilkS`` IS written
# below.  The emitter has no bottom-silk harvest at all (``gerber._emit_silk``
# and ``_emit_refdes`` are top-side only, by their own documented restriction),
# so a bottom-side component's captured B.SilkS graphics are still NOT
# fabricated.  Listing B.SilkS here would silence that component's
# ``captured_geometry_not_emitted`` warning while changing nothing about the
# emitted bytes — trading a loud, correct gap for a silent one.  This is why
# EMITTED_LAYERS and EMITTED_GERBER_SUFFIXES are NOT a 1:1 mapping: "we write
# this file" and "we fabricate this layer's captured geometry" are two different
# claims, and B.SilkS is exactly the case that separates them.
EMITTED_LAYERS: frozenset[str] = frozenset({
    "F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.SilkS", "Edge.Cuts",
    "F.Paste", "B.Paste",
})

# The Gerber file suffixes the emitter writes — the drift test pins these to the
# emitter's own ``_GERBER_SUFFIXES`` so this module cannot silently diverge.
#
# This is KiCad's default fab plot set MINUS F.Fab: F.Cu B.Cu F.Paste B.Paste
# F.Silkscreen B.Silkscreen F.Mask B.Mask Edge.Cuts.  A layer with no content on
# a given board is still WRITTEN, as a valid aperture-less file (measured: KiCad
# 10.0.5 emits ``board-B_Paste.gbp`` / ``board-B_Silkscreen.gbo`` that way for a
# board with no such content).  A fab package with a silently-ABSENT layer is
# worse than one with an empty layer: the board house cannot tell "no back
# legend" from "the back legend went missing in transit".
EMITTED_GERBER_SUFFIXES: frozenset[str] = frozenset({
    "F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS", "B_SilkS", "Edge_Cuts",
    "F_Paste", "B_Paste",
})

# ---------------------------------------------------------------------------
# Shared stroke widths — one number per physical concept, read by BOTH emitters.
# ---------------------------------------------------------------------------

# Board-outline stroke width, in mm. THE SINGLE SOURCE: ``gerber.py`` (Gerber
# Edge_Cuts aperture) and ``kicad.py`` (the ``.kicad_pcb`` Edge.Cuts ``gr_line``
# width) both import THIS name. It lives here, not in ``gerber.py``, because
# ``gerber.py`` imports ``gerber_writer`` at module level and ``kicad.py`` must
# stay free of that runtime dependency — this module imports nothing at all, so
# both emitters can read it. ``ir_parity``'s outline family compares the value
# against what each emitter actually WROTE, so a future divergence is caught
# rather than merely discouraged.
#
# The value is KiCad's own default: BOARD_DESIGN_SETTINGS.GetLineThickness(
# Edge_Cuts) == 0.05 (measured directly, KiCad 10.0.5).
#
# TWO DECOYS, both measured, neither of which drives this:
#   * ``pcbnew.DEFAULT_PCB_EDGE_THICKNESS`` is 0.15. It exists; it is not the
#     board-outline default.
#   * Emitting ``(width 0)`` does NOT make KiCad substitute its default — its
#     Gerber plotter substitutes 0.100000 (identical in 9.0.9 and 10.0.5).
#     Never emit a zero width hoping for a default.
#
# NOT a defect fix. The outline stroke is fabrication-IMMATERIAL: board houses
# route the outline centreline, so 0.1, 0.15 and 0.05 all fabricate the same
# board. The durable value here is that ONE number governs the concept and a
# test can see it — not the number itself.
EDGE_CUTS_WIDTH_MM: float = 0.05

# Fabrication-CRITICAL output domains: a captured feature whose loss corrupts one
# of these (when requested) is fatal.  ``paste`` joined copper/drill/mask here
# because c065c2b started emitting F.Paste/B.Paste Gerbers — before that commit
# no paste geometry reached any output file (``_GERBER_SUFFIXES`` had no
# F_Paste/B_Paste entry), so a lost paste datum was genuinely inert; after it, a
# dropped or wrongly-defaulted paste margin silently changes the stencil
# aperture a board house cuts from this package, and that aperture reaches
# physical hardware with no further review (docket 019fb0155d93 /
# 019fb079ce60). Silk/fab/documentation losses are still cosmetic-or-unemitted
# and are warned, never fatal.  ``rules`` is included because the IR also feeds
# DRC/routing, where a dropped rule is a correctness hazard, not a cosmetic one.
FABRICATION_CRITICAL_OUTPUTS: tuple[str, ...] = ("copper", "drill", "mask", "paste", "rules")

# ROUTING-critical output domains (Round E, docket 019f783860c8). Routing needs
# the same copper/drill/rules truth fabrication does, but a solder-MASK
# limitation cannot make a route unsafe — so a mask-only capability loss must not
# disable routing, while any dropped copper, drill or rule stays fatal. Codex
# ruling 2: compile against a routing-specific capability set, not the full CAM
# set. Keep this a SUBSET of FABRICATION_CRITICAL_OUTPUTS: a board that fails to
# compile for routing must also fail for fabrication, never the reverse.
ROUTING_CRITICAL_OUTPUTS: tuple[str, ...] = ("copper", "drill", "rules")

# ---------------------------------------------------------------------------
# Geometry capability dimensions (K2 review 625.2).  The profile is not just
# filenames/layers: it also declares the pad shapes, graphic primitives, and
# hole kinds the IR subset may contain.  The COMPILER consumes these as its
# accept-set; a matching "the emitter can actually render every supported
# primitive faithfully" test is a K3 gate (the current gerber.py flattens every
# SMD to a rectangle, so that gate is not yet green — see K3 019f7aed6d9e).
# ---------------------------------------------------------------------------

# Pad copper shapes the v1 IR subset admits (KiCad pad-shape tokens).
SUPPORTED_PAD_SHAPES: frozenset[str] = frozenset({"rect", "roundrect", "circle", "oval"})

# Footprint/board graphic primitives the v1 IR subset admits.
SUPPORTED_GRAPHIC_PRIMITIVES: frozenset[str] = frozenset({"line", "circle", "arc", "poly"})

# Hole geometries the v1 IR subset admits (round only for v1).
SUPPORTED_HOLE_SHAPES: frozenset[str] = frozenset({"round", "circle"})
