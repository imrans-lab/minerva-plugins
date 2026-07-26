"""
Command-line interface for agent-router.

Provides commands for routing, visualization, and pad extraction.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

from .board import Board, DesignRules
from .router import (
    route_board, route_board_with_hints, resolve_effective_rules,
    RoutingRulesError,
)
from .kicad_io import read_kicad_pcb, write_kicad_pcb, KiCadPCB, TraceSegment, Via
from .visualizer import visualize_ascii, visualize_svg
from .yaml_loader import load_board_with_hints


def _refuse_if_source_carries_copper(pcb_path) -> None:
    """REFUSE to route a .kicad_pcb that already contains copper (019f9d0bc17c).

    DELETE THIS WHOLE FUNCTION, its one call in ``cmd_route``, and
    ``test_the_cli_refuses_a_source_that_already_carries_copper`` when
    019f9d0bc17c lands — then drop the existing-copper qualifier from the
    entry-point-parity claim in ``cmd_route``. It is deliberately a standalone
    guard rather than logic threaded through ``cmd_route`` so that removal is
    clean.

    WHY IT EXISTS. ``kicad_io.read_kicad_pcb`` parses pads, nets and obstacles
    but NOT ``(segment ...)`` or ``(via ...)``, so a Board built here always has
    empty ``existing_traces``/``existing_vias`` — while ``methods._route``
    always populates them from the compiled IR. On a partially-routed board the
    worker therefore routes AROUND existing copper and this command would route
    straight THROUGH it, after which ``write_kicad_pcb`` appends the new
    segments onto the preserved originals. The output is a shorted board in a
    file that is a gerber source.

    That is a SHORT, not a margin problem, so it fails closed rather than
    carrying a documentation qualifier alone. Detection is textual because the
    parser this guard stands in for does not exist yet; it deliberately errs
    toward refusing (a commented-out segment would also trip it), which is the
    safe direction for a guard whose alternative is shorted copper.
    """
    try:
        text = Path(pcb_path).read_text()
    except OSError:
        return  # not our error to report — the reader below will surface it
    if not re.search(r"\(\s*(?:segment|via)\b", text):
        return
    raise RoutingRulesError(
        f"{pcb_path}: this board already contains routed copper (segments "
        f"and/or vias), and agent_router.kicad_io cannot read it yet — "
        f"read_kicad_pcb parses pads, nets and obstacles only. Routing anyway "
        f"would lay new copper straight through the existing copper and write "
        f"a shorted board, so this command fails closed. Use the worker "
        f"'route' method, which does model accepted copper. Tracking: docket "
        f"019f9d0bc17c (agent_router.kicad_io reads no existing copper).")


def _design_rules_from_yaml(board_yaml_path) -> DesignRules | None:
    """The authored ``design_rules`` block of a board YAML, or None if the board
    authors none.

    A MISSING FILE yields None — ``load_board_with_hints`` already treats that as
    "no YAML guidance", and this must not disagree with it. Anything else that
    goes wrong RAISES. An earlier cut swallowed ``OSError``/``YAMLError`` into
    None, which was a silent-degradation path in two ways at once: it disagreed
    with ``load_board_with_hints``'s own unguarded ``yaml.safe_load`` (which
    raises on the same file), and an unparseable rules block became the engine's
    default width — the exact silent-0.25 failure this round exists to remove.
    ``DesignRules.from_authored`` owns the authored-field mapping and fails
    closed on a block it cannot read.
    """
    path = Path(board_yaml_path)
    if not path.exists():
        return None
    with open(path) as handle:
        data = yaml.safe_load(handle)
    if data is None:
        return None
    if not isinstance(data, dict):
        raise RoutingRulesError(
            f"{path}: board YAML is not a mapping ({type(data).__name__}); its "
            f"design rules cannot be read and routing fails closed")
    return DesignRules.from_authored(data.get("design_rules"))


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        prog="agent-router",
        description="Standalone PCB routing tool for KiCad"
    )
    parser.add_argument(
        "--version",
        action="version",
        version="%(prog)s 0.1.0"
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # Route command
    route_parser = subparsers.add_parser("route", help="Route a PCB")
    route_parser.add_argument("input", help="Input .kicad_pcb file")
    route_parser.add_argument("-o", "--output", help="Output .kicad_pcb file")
    route_parser.add_argument(
        "--board-yaml",
        help="Board YAML file with routing_hints and internal_nets"
    )
    route_parser.add_argument(
        "--single-layer",
        action="store_true",
        help="Route on single layer only (F.Cu)"
    )
    route_parser.add_argument(
        "--no-vias",
        action="store_true",
        help="Disable vias"
    )
    # NOT defaulted to a number (bug 019f9b38a93f). A hard default here is
    # indistinguishable from the user typing it, so the board's OWN authored
    # rules could never win — a board authoring 0.35mm was silently routed at
    # 0.25. None means "unset", which lets the precedence chain fall through to
    # the board's rules and only then to the engine's default.
    route_parser.add_argument(
        "--trace-width",
        type=float,
        default=None,
        help="Trace width in mm (default: the board's own "
             "design_rules.trace_width_mm, else the engine default)"
    )
    route_parser.add_argument(
        "--clearance",
        type=float,
        default=None,
        help="Minimum clearance in mm (default: the board's own "
             "design_rules.clearance_mm, else the engine default)"
    )
    route_parser.add_argument(
        "--order",
        choices=["shortest_first", "longest_first", "signals_first"],
        default="shortest_first",
        help="Net ordering strategy (signals_first routes signal nets before power/GND)"
    )
    route_parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON"
    )

    # Visualize command
    viz_parser = subparsers.add_parser("visualize", help="Visualize a PCB")
    viz_parser.add_argument("input", help="Input .kicad_pcb file")
    viz_parser.add_argument(
        "--format",
        choices=["ascii", "svg"],
        default="ascii",
        help="Output format"
    )
    viz_parser.add_argument(
        "-o", "--output",
        help="Output file (default: stdout for ASCII, required for SVG)"
    )
    viz_parser.add_argument(
        "--scale",
        type=float,
        default=2.0,
        help="Scale factor (mm/char for ASCII, px/mm for SVG)"
    )
    viz_parser.add_argument(
        "--layer",
        default="F.Cu",
        help="Layer to visualize (for ASCII)"
    )

    # Dump-pads command
    pads_parser = subparsers.add_parser("dump-pads", help="Extract pad positions")
    pads_parser.add_argument("input", help="Input .kicad_pcb file")
    pads_parser.add_argument(
        "--format",
        choices=["json", "csv"],
        default="json",
        help="Output format"
    )
    pads_parser.add_argument(
        "-o", "--output",
        help="Output file (default: stdout)"
    )

    args = parser.parse_args()

    if args.command == "route":
        cmd_route(args)
    elif args.command == "visualize":
        cmd_visualize(args)
    elif args.command == "dump-pads":
        cmd_dump_pads(args)
    else:
        parser.print_help()
        sys.exit(1)


def cmd_route(args):
    """Execute route command.

    THE RULES COME FROM THE BOARD (019f9bc3909c / bug 019f9b38a93f). This
    command used to pass five of ``route_board``'s options and hard-code a
    default for two of them, so a board authoring its own trace width and
    clearance was routed at the engine's 0.25/0.2 — a different answer from the
    one the worker entry point gives for the same board. It now resolves the
    effective pair through the SAME chain the worker uses
    (``router.resolve_effective_rules``): explicit ``--trace-width`` /
    ``--clearance`` still win, and behind them sit the board's own rules and
    then the engine default.

    ONE INPUT CLASS STILL DIVERGES, and the claim is narrowed to match rather
    than mitigated away. The worker's compiler raises an authored clearance to
    the v1 manufacturing floor (``compile_board._floor_with_clearance``, floor
    0.127mm); this package must not import the compiler, so that floor is
    unreachable here. A board authoring ``clearance_mm: 0.05`` therefore routes
    at 0.127 through the worker and at 0.05 here — tighter than the process can
    build.

    An earlier draft of this docstring waved that away on the grounds that
    fabrication output does not come from this command. That was FALSE and is
    recorded here so it is not re-argued: ``-o`` writes a ``.kicad_pcb``
    carrying this copper, which is a gerber source, and
    ``test_the_cli_writes_copper_at_the_width_it_routed_at`` proves the segments
    are written.

    So the accurate statement of this round's result carries TWO qualifiers:
    **the two entry points agree on every board that carries no already-routed
    copper and whose authored clearance is at or above the v1 fab floor.**

      * clearance below the floor — this command routes tighter than the
        process can build. Pinned by ``test_the_cli_routes_below_the_v1_fab_
        floor`` so it stays visible; gating it needs the floor to become
        reachable from this package, which is out of this round's fence.
      * already-routed copper — this command cannot SEE it
        (``kicad_io.read_kicad_pcb`` parses no segments or vias), and routing
        through it writes a short. That one is not left to a qualifier at all:
        ``_refuse_if_source_carries_copper`` fails the run closed. Tracking:
        019f9d0bc17c, which also owns removing the guard and this bullet.
    """
    # Only options the user ACTUALLY set — an unset option must stay absent so
    # the chain can fall through to the board (see the note above).
    options = {}
    if args.trace_width is not None:
        options["trace_width"] = args.trace_width
    if args.clearance is not None:
        options["clearance"] = args.clearance

    # Fail closed BEFORE any parsing work, so the refusal is the first thing a
    # user of a partially-routed board sees. See the function for why, and for
    # how to remove it (019f9d0bc17c).
    try:
        _refuse_if_source_carries_copper(args.input)
    except RoutingRulesError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)

    if args.board_yaml:
        # Load board geometry from KiCad, hints from YAML. A malformed YAML
        # raises out of yaml_loader's own unguarded safe_load, which would
        # otherwise reach the user as a traceback and exit 1; a bad input file
        # is a user error, so it gets the same clean exit 2 as every other
        # fail-closed path here.
        try:
            board, hints, internal_nets = load_board_with_hints(
                args.input, args.board_yaml
            )
        except yaml.YAMLError as exc:
            print(f"error: {args.board_yaml}: board YAML could not be parsed: "
                  f"{exc}", file=sys.stderr)
            sys.exit(2)
        # The board YAML is also where a CLI-loaded board's design rules come
        # from — the .kicad_pcb reader models none. Without this the Board's
        # rules slot stays empty and the chain has nothing to fall through TO.
        # Inside the same fail-closed boundary as the resolution below: rules
        # that cannot be READ must end the run exactly as rules that cannot be
        # SOURCED do.
        try:
            board.design_rules = _design_rules_from_yaml(args.board_yaml)
        except RoutingRulesError as exc:
            print(f"error: {exc}", file=sys.stderr)
            sys.exit(2)
    else:
        # Standard mode: load board from KiCad only. It carries no authored
        # design rules (read_kicad_pcb models pads, nets and obstacles only), so
        # design_rules stays None and the chain lands on the engine default —
        # which is what this mode has always done, now explicitly rather than by
        # a hard-coded argparse default.
        board = Board.from_kicad(args.input)
        hints = internal_nets = None

    try:
        trace_width, _width_src, clearance, _clearance_src = \
            resolve_effective_rules(board, options)
    except RoutingRulesError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)

    if args.board_yaml:
        result = route_board_with_hints(
            board,
            hints,
            internal_nets=internal_nets,
            allow_vias=not args.no_vias,
            single_layer=args.single_layer,
            order=args.order,
            trace_width=trace_width,
            clearance=clearance,
        )
    else:
        result = route_board(
            board,
            allow_vias=not args.no_vias,
            single_layer=args.single_layer,
            order=args.order,
            trace_width=trace_width,
            clearance=clearance,
        )

    if args.json:
        # Output as JSON
        output = {
            "success": result.success,
            "routes": len(result.routes),
            "via_count": result.via_count,
            "unrouted": [
                {"net": net, "from": f"{p1.component}.{p1.number}", "to": f"{p2.component}.{p2.number}"}
                for net, p1, p2 in result.unrouted
            ]
        }
        print(json.dumps(output, indent=2))
    else:
        # Human-readable output
        print(f"Routing complete: {'SUCCESS' if result.success else 'INCOMPLETE'}")
        print(f"  Routes: {len(result.routes)}")
        print(f"  Vias: {result.via_count}")
        if result.unrouted:
            print(f"  Unrouted: {len(result.unrouted)}")
            for net, p1, p2 in result.unrouted[:5]:  # Show first 5
                print(f"    - {net}: {p1.component}.{p1.number} -> {p2.component}.{p2.number}")
            if len(result.unrouted) > 5:
                print(f"    ... and {len(result.unrouted) - 5} more")

    # Write output if specified
    if args.output and result.routes:
        # Read original PCB
        pcb = KiCadPCB(raw_content=Path(args.input).read_text())

        # Get net number mapping from board
        net_map = {name: net.number for name, net in board.nets.items()}

        # Add segments and vias
        for route in result.routes:
            net_num = net_map.get(route.net, 0)
            for path in route.paths:
                for segment in path.segments:
                    pcb.add_segment(TraceSegment(
                        start=segment.start,
                        end=segment.end,
                        # The width the run ACTUALLY routed at, not the raw
                        # option — which is None unless the user typed one. The
                        # written copper and the copper the grid reserved space
                        # for have to be the same width.
                        width=trace_width,
                        layer=segment.layer,
                        net=net_num
                    ))

                for via_pos in path.vias:
                    pcb.add_via(Via(
                        position=via_pos,
                        size=0.8,
                        drill=0.4,
                        net=net_num
                    ))

        write_kicad_pcb(pcb, args.output)
        print(f"Written to: {args.output}")


def cmd_visualize(args):
    """Execute visualize command."""
    board = Board.from_kicad(args.input)

    if args.format == "ascii":
        output = visualize_ascii(board, scale=args.scale, layer=args.layer)
        if args.output:
            Path(args.output).write_text(output)
        else:
            print(output)

    elif args.format == "svg":
        output = visualize_svg(board, scale=args.scale if args.scale != 2.0 else 10.0)
        if args.output:
            Path(args.output).write_text(output)
            print(f"Written to: {args.output}")
        else:
            print(output)


def cmd_dump_pads(args):
    """Execute dump-pads command."""
    board = Board.from_kicad(args.input)

    if args.format == "json":
        output = {
            "pads": [
                {
                    "component": pad.component,
                    "pad": pad.number,
                    "net": pad.net,
                    "x": round(pad.position[0], 3),
                    "y": round(pad.position[1], 3),
                    "size": [round(s, 3) for s in pad.size],
                    "shape": pad.shape,
                    "type": pad.pad_type
                }
                for pad in board.pads
            ],
            "nets": {
                name: [[p.component, p.number] for p in net.pads]
                for name, net in board.nets.items()
                if net.pads
            },
            "obstacles": [
                {
                    "type": obs.type,
                    "x": round(obs.position[0], 3),
                    "y": round(obs.position[1], 3),
                    "radius": round(obs.radius, 3) if obs.radius else None
                }
                for obs in board.obstacles
            ],
            "board": {
                "width": round(board.width, 3),
                "height": round(board.height, 3)
            }
        }
        text = json.dumps(output, indent=2)

    elif args.format == "csv":
        lines = ["component,pad,net,x,y,width,height,shape,type"]
        for pad in board.pads:
            lines.append(
                f"{pad.component},{pad.number},{pad.net or ''},"
                f"{pad.position[0]:.3f},{pad.position[1]:.3f},"
                f"{pad.size[0]:.3f},{pad.size[1]:.3f},"
                f"{pad.shape},{pad.pad_type}"
            )
        text = '\n'.join(lines)

    if args.output:
        Path(args.output).write_text(text)
        print(f"Written to: {args.output}")
    else:
        print(text)


if __name__ == "__main__":
    main()
