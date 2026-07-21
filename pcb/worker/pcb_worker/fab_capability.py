"""Neutral fabrication-capability profile — the SINGLE authority shared by the
compiler and every emitter (K2 review 623, decision a).

Neither the K2 compiler nor the K3 Gerber emitter may independently own the set
of layers/outputs the toolchain can produce; both import it from here.  A drift
test (``tests/test_fab_capability.py``) asserts the live emitter's actual
artifact set equals this profile, so a future emitter change that adds or drops
a layer forces a matching, reviewed change here.

Initial values are exactly today's Gerber surface (``gerber.py``
``_GERBER_SUFFIXES`` + the PTH/NPTH Excellon split): two copper layers, both
solder masks, TOP silk only, and the board edge.  No paste stencil, no fab, no
back silk.
"""

from __future__ import annotations

# The physical layers the emitter actually produces (KiCad canonical ids).
EMITTED_LAYERS: frozenset[str] = frozenset({
    "F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.SilkS", "Edge.Cuts",
})

# The Gerber file suffixes the emitter writes — the drift test pins these to the
# emitter's own ``_GERBER_SUFFIXES`` so this module cannot silently diverge.
EMITTED_GERBER_SUFFIXES: frozenset[str] = frozenset({
    "F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS", "Edge_Cuts",
})

# Fabrication-CRITICAL output domains: a captured feature whose loss corrupts one
# of these (when requested) is fatal.  Silk/fab/paste/documentation losses are
# cosmetic-or-unemitted and are warned, never fatal.  ``rules`` is included
# because the IR also feeds DRC/routing, where a dropped rule is a correctness
# hazard, not a cosmetic one.
FABRICATION_CRITICAL_OUTPUTS: tuple[str, ...] = ("copper", "drill", "mask", "rules")

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
