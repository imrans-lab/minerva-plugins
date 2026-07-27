"""
Board representation for PCB routing.

Contains dataclasses for pads, nets, obstacles, and the main Board class
that loads from KiCad PCB files.
"""

from dataclasses import dataclass, field
from typing import Any, Optional, Sequence
from pathlib import Path as FilePath


@dataclass
class Pad:
    """Represents a single pad on the board."""
    component: str              # Component reference (e.g., "U1", "R1")
    number: str                 # Pad number (e.g., "1", "A4")
    net: Optional[str]          # Net name (e.g., "VCC", "GND") or None if unconnected
    position: tuple[float, float]  # Absolute position (x, y) in mm
    size: tuple[float, float]      # Size (width, height) in mm
    shape: str = "rect"            # "rect", "circle", "roundrect", "oval"
    pad_type: str = "smd"          # "smd", "thru_hole"
    drill: Optional[float] = None  # Drill diameter for through-hole pads
    layer: str = "F.Cu"            # Primary layer
    rotation: float = 0.0          # Pad rotation in degrees


@dataclass
class Net:
    """Represents a net (electrical connection) on the board."""
    name: str                              # Net name
    number: int                            # Net number in KiCad
    pads: list[Pad] = field(default_factory=list)  # Pads belonging to this net


@dataclass
class Obstacle:
    """Represents a blocked region on the board."""
    position: tuple[float, float]  # Center position (x, y) in mm
    type: str                      # "mounting_hole", "keepout", "via", etc.
    radius: Optional[float] = None  # For circular obstacles
    polygon: Optional[list[tuple[float, float]]] = None  # For polygon obstacles
    blocks_all_layers: bool = True  # Whether it blocks all layers or just one
    layer: Optional[str] = None     # Specific layer if not all


# ---------------------------------------------------------------------------
# The board's OWN design rules (019f9bc3909c).
#
# A ``Board`` used to carry geometry ONLY — pads, nets, obstacles, extent. Its
# rules and its already-accepted copper lived nowhere on it, so three
# consecutive rounds threaded them through ``route_board``'s RUN OPTIONS
# instead (A2+A3 width/clearance, A4 net-class widths + keepout values, B1
# existing traces/vias). The cost landed exactly where you would predict: a
# second entry point (``cli.py``) that built a Board correctly and then forgot
# most of the option list, and routed at the engine's defaults on a board that
# authored its own (bug 019f9b38a93f).
#
# The slots below make a correctly-built Board carry that data BY
# CONSTRUCTION. Run options are unchanged and still win — they are an OVERRIDE
# layer, not the source (see ``router.resolve_effective_rules`` for the one
# precedence chain both entry points now share).
# ---------------------------------------------------------------------------


class RoutingRulesError(Exception):
    """A design rule (or an explicit run option) is PRESENT but unusable, or no
    admissible value could be sourced at all.

    Routing FAILS CLOSED on either — the standing ruling is that canvas may
    degrade while routing, DRC and CAM do not. Lives here rather than in
    ``router`` because ``board`` is the lower module (router imports board), and
    the authored-rules reader below has to raise it too.
    """


@dataclass(frozen=True)
class RoutingDefaults:
    """The board's authored routing defaults. Duck-compatible with the worker
    IR's ``resolved_board.RoutingDefaults`` on the ONE field the precedence
    chain reads, so the worker can hand its real IR object straight to
    ``Board.design_rules`` with no translation step to drift.

    ``trace_width_mm`` is deliberately typed ``Any`` and holds the value AS
    AUTHORED. It is not filtered here — see :meth:`DesignRules.from_authored`.
    """
    trace_width_mm: Any = None


@dataclass(frozen=True)
class ManufacturingConstraints:
    """The board's authored manufacturing floor. Duck-compatible with the
    worker IR's ``resolved_board.ManufacturingConstraints`` on the ONE field
    the precedence chain reads (see :class:`RoutingDefaults`)."""
    min_clearance_mm: Any = None


def _refuse_authored_net_classes(design_rules: dict) -> None:
    """REFUSE a board whose ``design_rules`` authors ``net_classes``.

    DELETE THIS WHOLE FUNCTION, its one call in
    ``DesignRules.from_authored``, and
    ``test_the_authored_rules_reader_refuses_a_board_carrying_net_classes``
    when this package grows a net-class notion — then drop the net-class
    qualifier from the entry-point-parity claim in ``from_authored``. It is
    deliberately a standalone guard rather than logic threaded through
    ``from_authored`` so that removal is clean.

    WHY IT EXISTS. This package has NO compiler and no net-class notion at
    all: ``DesignRules`` models exactly two scalars
    (``defaults.trace_width_mm`` / ``minimums.min_clearance_mm``) and the
    precedence chain in ``router`` has no per-net step to put a class into.
    The worker's compiler, by contrast, now compiles an authored
    ``design_rules.net_classes`` block into real per-net minima that
    ``pcb_worker.methods`` routes at. So the SAME board YAML routed through
    the standalone CLI would silently come out at the board's blanket width
    and clearance while the MCP path routes its classed nets wider — two
    entry points, one board, different copper, no signal.

    That is a divergence between entry points, not a margin problem, so it
    fails closed rather than carrying a documentation qualifier alone.

    WHAT IT REFUSES, precisely — this is a PRESENCE test, not a truthiness one,
    and the two differ on a case worth naming:

      * key ABSENT                -> passes (the board declares nothing)
      * ``net_classes: []``       -> passes (an explicitly empty LIST declares
                                    nothing either)
      * ``net_classes: {}``       -> REFUSED. An empty MAPPING is not an empty
                                    list; it is a malformed declaration, and
                                    treating it as absent would read a defect as
                                    a decision. This is the case a truthiness
                                    test (``if declared:``) would silently let
                                    through, and it is the whole reason the test
                                    is written the way it is.
      * one or more classes       -> REFUSED
      * any other value           -> REFUSED

    Byte-for-byte the shape ``compile_board`` uses to reject recognized-but-
    unsupported board features (the ``unsupported_board_feature`` loop over
    ``zones``/``board_graphics``/``keepouts``, whose own comment argues exactly
    this "PRESENCE, not truthiness" distinction from exactly the empty-mapping
    case). Cite THAT loop, not ``compile_board`` at large: the IR-level guards
    in ``kicad._ir_board_dict`` really are plain truthiness, because their
    inputs are typed tuples with no malformed-declaration case to catch, and
    conflating the two readings is how this docstring got misread once already.
    ``test_the_standalone_cli_refuses_a_board_carrying_net_classes`` pins all
    five rows above so this list cannot drift from the code.

    It still errs toward refusing WITHIN that scope: a class with no members
    constrains nothing today, and is refused anyway, because admitting it would
    make the guard depend on membership semantics this package does not model.
    """
    declared = design_rules.get("net_classes")
    if declared is None or (isinstance(declared, list) and not declared):
        return
    raise RoutingRulesError(
        "design_rules declares net_classes, and agent_router models no net "
        "classes at all — it has no compiler, and its rule chain carries one "
        "board-wide width and clearance with no per-net step. Routing here "
        "would lay a classed net's copper at the board's blanket rules while "
        "the worker 'route' method lays it at the class minima, so the same "
        "board would route differently through the two entry points and this "
        "command fails closed. Use the worker 'route' method, which does "
        "model net classes.")


@dataclass(frozen=True)
class DesignRules:
    """A board's design rules, in the shape the precedence chain reads.

    Deliberately a STRUCTURAL match for the worker's compiled
    ``ResolvedDesignRules`` (``.defaults.trace_width_mm`` /
    ``.minimums.min_clearance_mm``) rather than a flat pair: the worker path
    assigns its real IR object to ``Board.design_rules`` unchanged, so there is
    no conversion layer between "what the compiler decided" and "what the
    router routes at" that could drift. This class exists for the callers that
    have NO compiler — principally ``agent_router.cli`` reading an authored
    board YAML.
    """
    defaults: RoutingDefaults = field(default_factory=RoutingDefaults)
    minimums: ManufacturingConstraints = field(default_factory=ManufacturingConstraints)

    @classmethod
    def from_authored(cls, design_rules: Any) -> Optional["DesignRules"]:
        """Build from the AUTHORED board-YAML ``design_rules`` mapping.

        Mirrors the authored-to-IR field mapping the worker's compiler applies
        (``compile_board``: authored ``trace_width_mm`` becomes
        ``defaults.trace_width_mm``, authored ``clearance_mm`` becomes
        ``minimums.min_clearance_mm``), so a board authoring a rule is routed at
        that rule through EITHER entry point.

        PURELY STRUCTURAL: it maps field NAMES and preserves values exactly as
        authored. It does NOT admit or filter them. That is deliberate — a
        filtering step here would turn an authored ``trace_width_mm: "0.35"``
        into ``None``, indistinguishable from a board that authored no width at
        all, and the chain would then quietly route at the engine's 0.25. That
        silent-0.25 signature IS bug 019f9b38a93f, so admission happens in ONE
        place (``router._board_rule_mm``) where "absent" and "present but
        unreadable" can still be told apart and the second one can fail closed.

        Returns None when the board authors no ``design_rules`` block at all —
        a legitimate absence that falls through to the engine default. A block
        that is PRESENT but not a mapping cannot be read and raises.

        It does NOT apply the worker's v1 manufacturing FLOOR
        (``compile_board._floor_with_clearance`` raises an authored clearance to
        the profile minimum) — that policy lives in the compiler, which this
        package must not import. See the note in ``cli.cmd_route``.

        AN AUTHORED ``net_classes`` BLOCK IS REFUSED — see
        :func:`_refuse_authored_net_classes`.
        """
        if design_rules is None:
            return None
        if not isinstance(design_rules, dict):
            raise RoutingRulesError(
                f"design_rules is present but is not a mapping "
                f"({type(design_rules).__name__}) — routing fails closed rather "
                f"than ignore rules the board authored")
        _refuse_authored_net_classes(design_rules)
        return cls(
            defaults=RoutingDefaults(
                trace_width_mm=design_rules.get("trace_width_mm")),
            minimums=ManufacturingConstraints(
                min_clearance_mm=design_rules.get("clearance_mm")),
        )


@dataclass
class Board:
    """
    Represents a PCB board for routing.

    Contains all pads, nets, obstacles, and board dimensions, plus the board's
    OWN design rules and already-accepted copper (see the module note above
    ``DesignRules``).
    """
    pads: list[Pad] = field(default_factory=list)
    nets: dict[str, Net] = field(default_factory=dict)
    obstacles: list[Obstacle] = field(default_factory=list)
    width: float = 0.0   # Board width in mm
    height: float = 0.0  # Board height in mm
    origin: tuple[float, float] = (0.0, 0.0)  # Board origin
    # The board's OWN authored design rules, or None when it has none (a bare
    # .kicad_pcb, which carries no rules the reader models). Anything exposing
    # `.defaults.trace_width_mm` / `.minimums.min_clearance_mm` — the worker
    # hands over its compiled `ResolvedDesignRules` directly.
    design_rules: Any = None
    # The board's ALREADY-ACCEPTED copper (019f70ebc9ed / B1). Same data the
    # `existing_traces` / `existing_vias` run options carry; carried HERE so a
    # caller that builds a Board from a partially-routed source inherits it
    # rather than having to remember two more options. Engine types
    # (`router.ExistingSegment` / `router.ExistingVia`), left untyped here to
    # keep board.py free of an import cycle with router.py.
    existing_traces: Sequence[Any] = ()
    existing_vias: Sequence[Any] = ()

    @classmethod
    def from_kicad(cls, pcb_file: str | FilePath) -> "Board":
        """
        Load a board from a KiCad PCB file.

        Args:
            pcb_file: Path to .kicad_pcb file

        Returns:
            Board instance with pads, nets, and obstacles populated
        """
        from .kicad_io import read_kicad_pcb
        return read_kicad_pcb(str(pcb_file))

    def get_pad(self, component: str, pad_number: str) -> Optional[Pad]:
        """
        Get a specific pad by component reference and pad number.

        Args:
            component: Component reference (e.g., "R1")
            pad_number: Pad number (e.g., "1")

        Returns:
            Pad if found, None otherwise
        """
        for pad in self.pads:
            if pad.component == component and pad.number == pad_number:
                return pad
        return None

    def get_net_pads(self, net_name: str) -> list[Pad]:
        """
        Get all pads belonging to a net.

        Args:
            net_name: Name of the net

        Returns:
            List of pads belonging to the net
        """
        if net_name in self.nets:
            return self.nets[net_name].pads
        return [p for p in self.pads if p.net == net_name]
