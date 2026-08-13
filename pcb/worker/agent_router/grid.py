"""
Routing grid with collision detection.

Provides a discrete grid representation of the board for pathfinding,
tracking occupied cells, nets, and clearance zones.
"""

from dataclasses import dataclass, field
from typing import Optional
import math


@dataclass
class GridCell:
    """Represents a single cell in the routing grid."""
    occupied: bool = False
    net: Optional[str] = None       # Which net owns this cell
    layer: Optional[str] = None     # "F.Cu" or "B.Cu"
    # "pad" is REAL copper; "pad_clearance" is the reserved ring around it (see
    # RoutingGrid.keepout_margin). The two are spelled apart because copper
    # outranks a reservation when both want the same cell — a halo must never
    # overwrite a neighbouring pad's copper claim.
    obstacle_type: Optional[str] = None  # "pad", "pad_clearance", "via",
                                         # "via_clearance", "trace",
                                         # "trace_clearance", "hole", "keepout"


# Real copper, vs the reservation held around it. A ring may never overwrite
# copper (see RoutingGrid._mark_clearance_cell); rings may downgrade each other.
#
# "via" was reserved here BEFORE anything wrote it, so that the day a via marker
# landed it would be copper by default rather than something a ring could quietly
# overwrite. That day is T7 (019f70ebc9ed): :meth:`RoutingGrid.mark_via` writes
# it for an EXISTING accepted via. The engine's OWN vias are still positional
# only (agent_router.router.Route.vias is a bare (x, y) list; pcb_worker.methods.
# _routes_to_vias is what gives them a layer span, downstream of the grid), so
# only accepted copper reaches this type today.
_COPPER_TYPES = frozenset({"pad", "trace", "via"})
_CLEARANCE_TYPES = frozenset({"pad_clearance", "trace_clearance", "via_clearance"})


@dataclass
class RoutingGrid:
    """
    Discrete grid for routing and collision detection.

    Each cell tracks occupancy, owning net, and layer information.
    Supports marking pads, obstacles, and traces with proper clearance.
    """
    width: float           # Board width in mm
    height: float          # Board height in mm
    resolution: float      # Grid resolution in mm (cell size)
    clearance: float = 0.2  # Minimum clearance between different nets in mm
    layers: list[str] = field(default_factory=lambda: ["F.Cu", "B.Cu"])
    # Board ORIGIN in world mm: the world position of cell (0, 0)'s lower-left
    # corner. A board outline that does not start at (0, 0) — RectOutline.origin
    # in the ResolvedBoard IR — used to be ignored here, so world coordinates were
    # indexed as if the board began at the world origin and every pad landed in
    # the wrong cell (docket 019f783860c8, gap C). Callers keep speaking WORLD
    # coordinates at every boundary; the grid subtracts the origin internally.
    origin: tuple[float, float] = (0.0, 0.0)
    # The width of the traces this run will lay down, in mm. Round E2: a keepout
    # is not the copper's own extent — it is the region a trace CENTERLINE may
    # not enter, which is the copper grown by `clearance + trace_width / 2`. The
    # grid marks centerline-addressed cells (the pathfinder tests one cell per
    # step, and mark_trace is the only place a width appears), so without the
    # half-width term a trace could be centered exactly `clearance` from a pad
    # and still lay half its copper inside the clearance ring.
    #
    # 0.0 means "no half-width term", which is what this grid did before E2. The
    # routing entry points always pass the run's real width (router.py's two
    # RoutingGrid constructions), so 0.0 only ever reaches a grid a caller built
    # by hand — for whom clearance-only marking is the unchanged behaviour, not a
    # regression. It is deliberately NOT defaulted to the engine's own
    # `route_board(trace_width=...)` default: a second copy of that literal is
    # exactly the drift pcb_worker.methods._engine_default_mm exists to prevent.
    trace_width: float = 0.0

    def __post_init__(self):
        """Initialize the grid cells."""
        self.cols = int(math.ceil(self.width / self.resolution))
        self.rows = int(math.ceil(self.height / self.resolution))
        # Create grid for each layer
        self._grid: dict[str, list[list[GridCell]]] = {}
        for layer in self.layers:
            self._grid[layer] = [
                [GridCell() for _ in range(self.cols)]
                for _ in range(self.rows)
            ]

    # -- keepouts -----------------------------------------------------------

    @property
    def keepout_margin(self) -> float:
        """How far outside real copper a foreign centerline must stay, in mm.

        THE single owner of the inflation term, for the same reason
        ``_pos_to_cell`` is the single owner of the world<->cell transform: a
        margin applied in one marker and forgotten in another is an under-block,
        and under-blocking is the one direction that is never legal (see
        pcb/docs/routing.md, "the modeled keepout must be a SUPERSET of the
        fabricated copper").

        Negative inputs cannot shrink a keepout below the copper itself — a
        negative clearance or width would otherwise turn the superset invariant
        inside out.
        """
        return max(0.0, self.clearance) + max(0.0, self.trace_width) / 2.0

    def _mark_clearance_cell(self, cell: GridCell, net: Optional[str],
                             kind: str = "pad_clearance") -> None:
        """Claim one cell of a clearance ring, never WEAKENING it.

        Shared by every ring the grid marks — a pad's (``kind="pad_clearance"``)
        and a routed trace's (``"trace_clearance"``). Three rules, all of them the
        same invariant seen from a different side:

        * real COPPER (``"pad"`` / ``"trace"``) outranks a reservation and is left
          alone. The hazard is ordering: pads are marked in board order and traces
          as each net is routed, so pad A's ring can reach a cell pad B already
          claimed as copper. Overwriting it with A's net would let net A route
          straight through pad B's real land — the exact under-block this round is
          about.
        * a free cell becomes the ring's, owned by the marker's net. Its own net
          may approach its own copper (no clearance is owed to yourself); every
          other net is blocked, which is the point.
        * a cell two different rings both want belongs to NEITHER net
          (``net=None`` blocks everyone). Leaving it with the first writer's net
          would let that net route within `clearance` of the second owner.
        """
        if cell.obstacle_type in _COPPER_TYPES:
            return
        if not cell.occupied:
            cell.occupied = True
            cell.net = net
            cell.obstacle_type = kind
            return
        if cell.obstacle_type in _CLEARANCE_TYPES and cell.net != net:
            cell.net = None

    def _mark_copper_cell(self, cell: GridCell, net: Optional[str], kind: str,
                          layer: Optional[str] = None) -> None:
        """Claim one cell as REAL copper owned by ``net``, never stealing another
        owner's copper.

        THE single owner of the copper-marking rule, for the same reason
        :meth:`_mark_clearance_cell` owns the ring rule.

        The "never steal" clause is T7 (019f70ebc9ed). Before existing copper was
        imported, every copper mark came from the ENGINE — a pad the board census
        placed, or a trace the pathfinder had just been PERMITTED to lay, which by
        construction never runs through a foreign land. So an unconditional
        overwrite was unreachable-but-fine. Importing the board's own accepted
        copper marks geometry the grid never approved: an accepted trace that
        overlaps a foreign (or unconnected, ``net=None``) pad — a board that is
        already shorted — would hand that pad's land to the trace's net, and
        ``can_route_through`` lets a net cross its own cells. The result is a
        router licensed to route straight through real copper: an under-block
        introduced by describing the board more completely, which is exactly
        backwards. A cell already typed copper under a DIFFERENT owner is
        therefore left as it is.

        A HOLE is refused outright, whoever asks. A hole belongs to no net and
        clears any net it lands on (see :meth:`mark_obstacle`), so re-netting one
        of its cells is a licence to route through a mounting hole —
        ``can_route_through`` lets a net cross its own cells. The canonical order
        (pads -> existing copper -> obstacles, see
        ``router._mark_existing_copper``) already keeps accepted copper away from
        it, but ORDER IS NOT A GUARD: ``mark_trace`` and ``mark_via`` are public
        and the engine's OWN routed traces are marked AFTER the obstacles, where
        ``_cell_range``'s one-cell over-claim can reach a hole cell that no route
        ever passed through. This is checked here rather than trusted to the
        caller for the same reason the margin is owned here rather than by the
        call sites (cold review of 019f70ebc9ed, note 3).

        Re-marking a net's OWN copper (``cell.net == net``) still writes through —
        an accepted trace landing on its own pad, or the engine re-marking its own
        path, is not a conflict. So is the documented copper-over-contested-ring
        weakening (a ``net=None`` cell typed ``*_clearance``, not copper): see
        :meth:`_cell_range`.
        """
        if cell.obstacle_type == "hole":
            return
        if cell.obstacle_type in _COPPER_TYPES and cell.net != net:
            return
        cell.occupied = True
        cell.net = net
        cell.obstacle_type = kind
        if layer is not None:
            cell.layer = layer

    # -- world <-> cell -----------------------------------------------------
    # THE single owner of the transform, in both directions. Every marker, the
    # bounds test and the pathfinder go through these two methods; nothing
    # re-derives `x / resolution` on its own, so the origin cannot be honoured in
    # one place and forgotten in another.

    def _pos_to_cell(self, x: float, y: float) -> tuple[int, int]:
        """Convert a WORLD position in mm to grid cell indices.

        Uses floor, not truncation: for a position left of / above the origin,
        ``int()`` rounds toward zero and would fold two different out-of-bounds
        positions onto cell -0, which ``_cell_in_bounds`` then reads as index 0 —
        an out-of-board point testing as an in-board cell.
        """
        col = math.floor((x - self.origin[0]) / self.resolution)
        row = math.floor((y - self.origin[1]) / self.resolution)
        return (col, row)

    def _cell_to_pos(self, col: int, row: int) -> tuple[float, float]:
        """Convert grid cell indices to the WORLD position of the cell's centre.

        The inverse of :meth:`_pos_to_cell`. Path reconstruction returns world
        coordinates through here, so a routed proposal lands where the board says
        rather than offset by the origin.
        """
        return (self.origin[0] + (col + 0.5) * self.resolution,
                self.origin[1] + (row + 0.5) * self.resolution)

    def _cell_range(self, lo: float, hi: float, axis: int) -> range:
        """Inclusive cell index range covering the world span [lo, hi] on *axis*
        (0 = x/cols, 1 = y/rows). Shared by every rectangular marker so the
        origin is applied once.

        IT OVER-CLAIMS BY UP TO ONE CELL on the high edge: cell ``i`` covers
        ``[i*res, (i+1)*res)``, so the last cell a span truly touches is
        ``floor(hi/res)``, and ``ceil`` returns one more whenever ``hi`` is not an
        exact multiple. Kept, not tightened — tightening risks UNDER-claiming, and
        that is the one direction the keepout invariant forbids.

        E2 made this worth reasoning about explicitly, because mark_pad and
        mark_trace now split their span into COPPER and RING and this decides the
        boundary between them. Working it through:

        * for a FOREIGN net nothing changes. An over-claimed cell is typed copper
          and owned by the marking net, and ``can_route_through`` blocks an
          occupied cell owned by anyone else — exactly as the ring would have. The
          ring's inner edge is eaten by at most one cell, and the outer edge is
          computed from the same over-claiming call, so the reserved distance is
          if anything larger, never smaller.
        * for the OWNING net there is a bounded weakening: a cell a rival ring had
          downgraded to ``net=None`` can be re-typed as this net's copper, letting
          it route up to one resolution further into the rival's clearance than it
          should. That is the same acceptable weakening copper-over-contested-ring
          already carries (see _mark_clearance_cell), it is bounded by the grid's
          own quantisation rather than by the margin, and it is reachable only
          within one cell of where the net's real copper sits.
        """
        base = self.origin[axis]
        first = math.floor((lo - base) / self.resolution)
        last = math.ceil((hi - base) / self.resolution)
        return range(first, last + 1)

    def _cell_in_bounds(self, col: int, row: int) -> bool:
        """Check if cell indices are within grid bounds."""
        return 0 <= col < self.cols and 0 <= row < self.rows

    def get_cell(self, x: float, y: float, layer: str = "F.Cu") -> GridCell:
        """
        Get the grid cell at position (x, y).

        Args:
            x: X position in mm
            y: Y position in mm
            layer: Layer name

        Returns:
            GridCell at the position
        """
        col, row = self._pos_to_cell(x, y)
        if not self._cell_in_bounds(col, row):
            # Return blocked cell for out-of-bounds
            cell = GridCell(occupied=True, obstacle_type="boundary")
            return cell
        if layer not in self._grid:
            # FAIL CLOSED on a layer this grid does not model (epoch GA-2):
            # before N-layer stacks this KeyError'd — a crash — and the other
            # tolerable answer, "free cell", would let a route claim space on
            # a plane nobody allocated. A blocked synthetic cell makes an
            # unknown layer unroutable rather than fatal or silently free,
            # matching the out-of-bounds convention above.
            return GridCell(occupied=True, obstacle_type="unknown_layer")
        return self._grid[layer][row][col]

    def is_blocked(self, x: float, y: float, layer: str = "F.Cu") -> bool:
        """
        Check if position is blocked (occupied by obstacle or out of bounds).

        Args:
            x: X position in mm
            y: Y position in mm
            layer: Layer name

        Returns:
            True if blocked, False otherwise
        """
        cell = self.get_cell(x, y, layer)
        return cell.occupied and cell.net is None

    def can_route_through(self, x: float, y: float, net: str, layer: str = "F.Cu") -> bool:
        """
        Check if a net can route through this position.

        Allows routing through own pads/traces but not through other nets.

        Args:
            x: X position in mm
            y: Y position in mm
            net: Net name attempting to route
            layer: Layer name

        Returns:
            True if routing is allowed, False otherwise
        """
        cell = self.get_cell(x, y, layer)
        if not cell.occupied:
            return True
        # Can route through own net
        return cell.net == net

    def mark_pad(
        self,
        x: float,
        y: float,
        size: tuple[float, float],
        net: Optional[str],
        layer: str = "F.Cu",
        rotation: float = 0.0
    ) -> None:
        """
        Mark a pad's area as occupied in the grid.

        Marks TWO concentric regions: the pad's own extent as copper, and the
        ring out to :attr:`keepout_margin` around it as that copper's clearance
        reservation. ``size`` is expected to already be a SUPERSET of the real
        land (``route_bridge._router_pad`` hands over the axis-aligned bounding
        box, because this marker discards ``rotation`` — see below), and the ring
        composes with that superset rather than replacing it: growing an envelope
        that already contains the copper still contains the copper, so the
        rotation-safe over-block and the clearance reservation stack instead of
        fighting.

        Args:
            x: Pad center X position in mm
            y: Pad center Y position in mm
            size: Pad size (width, height) in mm
            net: Net name or None
            layer: Layer name
            rotation: Pad rotation in degrees — DISCARDED (see the class note in
                route_bridge: callers must pre-inflate to an axis-aligned box)
        """
        # Simple rectangular marking (ignoring rotation for now)
        half_w = size[0] / 2
        half_h = size[1] / 2
        margin = self.keepout_margin

        # Cell spans for the copper itself; membership in BOTH is what makes a
        # cell core rather than ring. `range.__contains__` is O(1) for ints, so
        # this is one pass over the inflated box, not two passes plus a set.
        core_cols = self._cell_range(x - half_w, x + half_w, 0)
        core_rows = self._cell_range(y - half_h, y + half_h, 1)

        # Mark cells covered by pad + its clearance ring (world span -> cells via
        # the shared owner, so the board origin is honoured here exactly as in
        # _pos_to_cell).
        for row in self._cell_range(y - half_h - margin, y + half_h + margin, 1):
            for col in self._cell_range(x - half_w - margin, x + half_w + margin, 0):
                if not self._cell_in_bounds(col, row):
                    continue
                cell = self._grid[layer][row][col]
                if col in core_cols and row in core_rows:
                    self._mark_copper_cell(cell, net, "pad")
                else:
                    self._mark_clearance_cell(cell, net)

    def mark_obstacle(
        self,
        x: float,
        y: float,
        radius: float,
        layer: Optional[str] = None
    ) -> None:
        """
        Mark a circular obstacle (like a mounting hole).

        Args:
            x: Center X position in mm
            y: Center Y position in mm
            radius: Obstacle radius in mm
            layer: Layer to mark, or None for all layers
        """
        # Grow by the FULL keepout margin, not clearance alone: a centerline
        # exactly `clearance` from the hole still puts half a trace width of
        # copper inside the clearance ring (Round E2, same term as mark_pad).
        block_radius = radius + self.keepout_margin

        layers_to_mark = [layer] if layer else self.layers

        # Iterate CELL INDICES and test each cell's OWN centre — the same
        # lattice fix mark_keepout_polygon carries (Codex 1056 finding 2's
        # class: the old bbox-anchored sample lattice was phase-shifted from
        # the cell lattice the router consults, so at coarse resolution a
        # cell whose CENTRE sat inside the disc could go unmarked). The cell
        # semantic is now exact: a cell is blocked iff its centre is within
        # the blocked disc.
        for row in self._cell_range(y - block_radius, y + block_radius, 1):
            for col in self._cell_range(x - block_radius, x + block_radius, 0):
                if not self._cell_in_bounds(col, row):
                    continue
                cx, cy = self._cell_to_pos(col, row)
                dist = math.sqrt((cx - x) ** 2 + (cy - y) ** 2)
                if dist <= block_radius:
                    for lyr in layers_to_mark:
                            cell = self._grid[lyr][row][col]
                            cell.occupied = True
                            # A hole belongs to NO net, so it must not inherit
                            # one. Obstacles are marked after pads, so a cell a
                            # pad (or, since E2, a pad's clearance ring) already
                            # claimed would otherwise keep that net — and
                            # `can_route_through` lets a net cross its own cells,
                            # i.e. route straight through a mounting hole. E2's
                            # wider rings made that latent under-block reachable
                            # on ordinary boards, so it is closed here.
                            #
                            # RECORDED DECISION (E2 review 2, note 3): this is a
                            # THIRD behaviour change, outside the round's stated
                            # scope, and it does alter which routes are found. It
                            # is kept because it is strictly MORE blocking, and
                            # because the only obstacles the canonical path emits
                            # are mechanical/board holes and NPTH pads
                            # (route_bridge._obstacles_from_board / _npth_obstacle
                            # / _hole_obstacle) — never a routable TH pad, which
                            # is a Pad and marked by mark_pad. So no net loses
                            # access to copper it must reach.
                            cell.net = None
                            cell.obstacle_type = "hole"

    def mark_via(
        self,
        x: float,
        y: float,
        diameter: float,
        net: Optional[str],
        layers: Optional[list[str]] = None,
    ) -> None:
        """Mark an EXISTING via's annulus as that net's copper, on every layer it
        spans, plus its clearance ring.

        T7 (019f70ebc9ed). A via is the one copper primitive that is NOT confined
        to one layer, and that span is the whole point of it: a net whose accepted
        copper crosses sides is only continuous if the grid agrees the via joins
        the two sides. Marking it on one layer would leave the other side's copper
        looking like an unconnected stub AND leave a foreign net free to route
        over real annulus copper.

        Deliberately NOT :meth:`mark_obstacle`, which is the other disc marker on
        this class: an obstacle belongs to NO net and clears any net it lands on
        (a mounting hole nobody may cross). A via belongs to a net and its own net
        must be able to reach it — routing an accepted via as an obstacle would
        keep its own net out of its own copper.

        ``diameter`` is the via's TRUE annulus diameter; the grid adds
        :attr:`keepout_margin` itself, exactly as :meth:`mark_trace` does with a
        width. Callers must NOT hand-inflate — the single-owner rule (see
        :attr:`keepout_margin`) is what stops one marker reserving less than
        another.

        Args:
            x: Via center X position in mm
            y: Via center Y position in mm
            diameter: Annulus (copper pad) diameter in mm — copper only
            net: Net name the via belongs to
            layers: Layers the via spans; None marks every layer of the grid
        """
        radius = max(0.0, diameter) / 2.0
        block_radius = radius + self.keepout_margin
        layers_to_mark = [lyr for lyr in (layers or self.layers)
                          if lyr in self._grid]

        for row in self._cell_range(y - block_radius, y + block_radius, 1):
            for col in self._cell_range(x - block_radius, x + block_radius, 0):
                if not self._cell_in_bounds(col, row):
                    continue
                # Distance is measured to the CELL CENTRE, the same point
                # _cell_to_pos hands back to the pathfinder — so "is this cell
                # inside the annulus" is asked about the position a route would
                # actually occupy, not about a corner.
                cx, cy = self._cell_to_pos(col, row)
                dist = math.hypot(cx - x, cy - y)
                if dist > block_radius:
                    continue
                for lyr in layers_to_mark:
                    cell = self._grid[lyr][row][col]
                    if dist <= radius:
                        self._mark_copper_cell(cell, net, "via", lyr)
                    else:
                        self._mark_clearance_cell(cell, net, "via_clearance")

    def mark_trace(
        self,
        start: tuple[float, float],
        end: tuple[float, float],
        width: float,
        net: str,
        layer: str = "F.Cu"
    ) -> None:
        """
        Mark a trace segment's copper, plus its clearance ring, as occupied.

        ``width`` is the trace's TRUE copper width. The grid adds
        :attr:`keepout_margin` itself — callers must NOT hand-inflate it.

        Round E2: the three call sites in router.py used to pass
        ``trace_width + 2 * clearance``, giving a half-extent of ``w/2 +
        clearance``. That under-blocks by exactly ``w/2``: the grid is addressed
        by CENTERLINE, so a foreign trace whose centre sits there lays its own
        half-width of copper inside the clearance gap. The correct half-extent is
        ``w/2 + clearance + w/2`` — the marked copper's half-width, the gap, and
        the newcomer's half-width — which is precisely ``w/2 + keepout_margin``.
        Routing it through the single owner also means a hand-inflated literal can
        no longer drift away from what mark_pad and mark_obstacle reserve.

        Args:
            start: Start position (x, y) in mm
            end: End position (x, y) in mm
            width: Trace width in mm (copper only — clearance is added here)
            net: Net name
            layer: Layer name
        """
        # Calculate cells along the trace
        dx = end[0] - start[0]
        dy = end[1] - start[1]
        length = math.sqrt(dx * dx + dy * dy)

        if length < self.resolution:
            # Very short trace, just mark start point
            self._mark_trace_point(start[0], start[1], width, net, layer)
            return

        # Step along the trace
        steps = int(math.ceil(length / self.resolution))
        for i in range(steps + 1):
            t = i / steps
            x = start[0] + t * dx
            y = start[1] + t * dy
            self._mark_trace_point(x, y, width, net, layer)

    def _mark_trace_point(
        self,
        x: float,
        y: float,
        width: float,
        net: str,
        layer: str
    ) -> None:
        """Mark one point of a trace: its copper, then its clearance ring.

        Same two-region shape as :meth:`mark_pad`, and for the same reason — the
        ring must not overwrite a neighbouring pad's or trace's copper claim. It
        used to write ``net`` over every cell it touched, so a trace routed past a
        foreign pad could hand that pad's land to the trace's net; inflating the
        ring by ``keepout_margin`` would have widened that reach.
        """
        half_w = width / 2
        margin = self.keepout_margin

        core_cols = self._cell_range(x - half_w, x + half_w, 0)
        core_rows = self._cell_range(y - half_w, y + half_w, 1)

        for row in self._cell_range(y - half_w - margin, y + half_w + margin, 1):
            for col in self._cell_range(x - half_w - margin, x + half_w + margin, 0):
                if not self._cell_in_bounds(col, row):
                    continue
                cell = self._grid[layer][row][col]
                if col in core_cols and row in core_rows:
                    self._mark_copper_cell(cell, net, "trace", layer)
                else:
                    self._mark_clearance_cell(cell, net, "trace_clearance")

    def _range_mm(self, start: float, end: float):
        """Generate positions from start to end at grid resolution."""
        pos = start
        while pos <= end:
            yield pos
            pos += self.resolution

    def mark_keepout_polygon(
        self,
        points: list[tuple[float, float]],
        layer: Optional[str] = None,
    ) -> None:
        """Mark an authored KEEPOUT region as an absolute polygon obstacle.

        Epoch UX3 station 2 (K6, router item 019fc155bc32): the rasteriser the
        keepout refusal in ``pcb_worker.route_bridge`` was waiting for. A cell
        is blocked when its centre is INSIDE the polygon or within
        ``keepout_margin`` of its boundary — the same clearance + half-trace
        growth every other marker applies, so a route centreline hugging the
        keepout still keeps its fabricated copper out of the forbidden region.

        ``layer`` honours the authored scope: a top-only keepout blocks F.Cu
        alone (``None`` blocks every layer), which is exactly the fidelity the
        old disc approximation could not offer and refused over.

        Marked cells follow the ``mark_obstacle`` hole idiom: ``occupied``,
        ``net = None`` (a prohibition belongs to no net — a pad's prior claim
        must not let its own net route through), ``obstacle_type = "keepout"``
        (the GridCell type reserved for this day). An absolute veto, never a
        downgradeable clearance ring.
        """
        if len(points) < 3:
            return
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        margin = self.keepout_margin
        layers_to_mark = [layer] if layer else self.layers

        # Iterate CELL INDICES and test each cell's OWN centre (_cell_to_pos)
        # — never a bbox-anchored sample lattice (Codex 1056 finding 2: a
        # sample lattice anchored at min(xs)-margin is offset from the cell
        # lattice the router consults, so at coarse resolution a sampled
        # point could fall outside the polygon while the CELL CENTRE it maps
        # to is inside — an unmarked, routable cell inside an authored
        # keepout, the one direction the invariant forbids). _cell_range
        # over-claims by up to one cell on the high edge, which is the legal
        # direction.
        for row in self._cell_range(min(ys) - margin, max(ys) + margin, 1):
            for col in self._cell_range(min(xs) - margin, max(xs) + margin, 0):
                if not self._cell_in_bounds(col, row):
                    continue
                cx, cy = self._cell_to_pos(col, row)
                if not (_point_in_polygon(cx, cy, points)
                        or _distance_to_polygon(cx, cy, points) <= margin):
                    continue
                for lyr in layers_to_mark:
                    cell = self._grid[lyr][row][col]
                    cell.occupied = True
                    cell.net = None
                    cell.obstacle_type = "keepout"


def _point_in_polygon(x: float, y: float, points: list[tuple[float, float]]) -> bool:
    """Ray-cast containment test (even-odd rule) against a closed polygon.

    Boundary-touching points are not guaranteed either way here — the caller
    pairs this with a boundary-distance test whose margin is strictly positive,
    so every boundary cell is blocked regardless (fail-safe direction:
    over-block, never under-block)."""
    inside = False
    j = len(points) - 1
    for i in range(len(points)):
        xi, yi = points[i]
        xj, yj = points[j]
        if (yi > y) != (yj > y):
            x_cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def _distance_to_polygon(x: float, y: float, points: list[tuple[float, float]]) -> float:
    """Minimum distance from (x, y) to the polygon's boundary segments."""
    best = math.inf
    j = len(points) - 1
    for i in range(len(points)):
        ax, ay = points[j]
        bx, by = points[i]
        seg_dx, seg_dy = bx - ax, by - ay
        seg_len_sq = seg_dx * seg_dx + seg_dy * seg_dy
        if seg_len_sq <= 0.0:
            d = math.hypot(x - ax, y - ay)
        else:
            t = max(0.0, min(1.0, ((x - ax) * seg_dx + (y - ay) * seg_dy) / seg_len_sq))
            d = math.hypot(x - (ax + t * seg_dx), y - (ay + t * seg_dy))
        best = min(best, d)
        j = i
    return best
